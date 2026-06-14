#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# src/jira_sink.sh — the Jira WRITER half of the reconcile bridge (the SINK).
#
# ORIGIN: STUB → US1 MVP. The vendor-neutral engine (src/reconcile.sh,
#   adapted-from spec-kit-linear @ 7dbe6bd) calls this fixed interface; the
#   sibling proved the seam against Linear's GraphQL writer. This file replaces
#   that writer with Jira REST implementations. The names + return shapes come
#   from specs/001-core-bridge/contracts/engine-sink-interface.md.
#
# US1 SCOPE (this file): the fresh CREATE path. A reconcile of a repo whose
#   specs are not yet mirrored creates a per-repo Epic, a Story per spec, and a
#   Subtask per task phase, over the mocked REST (curl-shim). The READ functions
#   are implemented enough to report ABSENT (rc 0 + empty) so the engine
#   proceeds to create; idempotent diff/update of EXISTING issues (US2), real
#   drift recency (US3), and comments/issue-links (US4) remain stubs.
#
# Read contract (engine-sink-interface.md §Read):
#   * A genuinely ABSENT issue is rc 0 with EMPTY/`[]` stdout — NOT rc 3. The
#     engine's drift gate fails closed on rc 3, so a brand-new spec MUST read as
#     absent (rc 0) or it would never get created.
#   * rc 3 is reserved for a REAL unreadable read: jira_rest signals
#     JIRA_REST_RC_UNREADABLE (401/403/404/network) on the GET/JQL. We propagate
#     that verbatim so the engine degrades safely.
#
# Write contract (engine-sink-interface.md §Write): writes honour DRY_RUN by
#   logging the intended mutation to stderr and skipping the curl (the
#   jira_rest transport ALSO short-circuits writes under DRY_RUN, so this layer
#   only needs to synthesize the placeholder ids the engine reads back).
#
# Sourcing: jira_rest.sh (auth + retry/backoff transport), adf.sh
# (Markdown→ADF body rendering), and config.sh (the per-repo id/label bindings)
# are pulled in here. The `# shellcheck source=` directives document the API
# surface for IDE-side shellcheck.
#
# PRIVACY (Principle IX): this file holds NO real Jira coordinates. The project
# key, issue-type ids, status/transition ids, and label prefixes all come from
# the gitignored jira-config.yml via config::*; the base URL + token live only
# in the gitignored .env and are read solely by jira_rest.sh.
# =============================================================================

# NOTE: no `set -euo pipefail` here — this module is SOURCED by reconcile.sh
# (which already sets the shell options) and by the contract bats suites. A
# nested `set -e` would change the caller's option state on source.

# shellcheck source=./jira_rest.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jira_rest.sh"
# shellcheck source=./adf.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/adf.sh"
# NOTE: config.sh is NOT sourced here. reconcile.sh sources config.sh BEFORE the
# sink (strict order, so config validates ids first), and config.sh declares
# `readonly` constants that a second source would error on. The sink relies on
# the engine (or a contract test) having sourced + loaded config first; the
# config::* getters it calls fail closed if config was never loaded.

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# jira_sink::_dry_run
#   Return 0 iff the engine is in --dry-run mode. Reads DRY_RUN (the sink's
#   contract name, kept in sync with ARG_DRY_RUN by the engine's parse_args).
jira_sink::_dry_run() {
    [[ "${DRY_RUN:-0}" == "1" ]]
}

# jira_sink::_log <message...>
#   Per-mutation diagnostic to stderr (never stdout). Used by the DRY_RUN
#   intent lines so a --dry-run pass narrates what it WOULD write.
jira_sink::_log() {
    printf 'spec-kit-jira-sync: sink: %s\n' "$*" >&2
}

# jira_sink::_error_detail
#   Echo a compact " — <errorMessages/errors>" suffix derived from the Jira
#   response body the transport captured on the last non-2xx write
#   (JIRA_REST_LAST_ERROR_BODY), or empty when there is none. Lets a write-failure
#   line quote a field-level error (e.g. INVALID_INPUT on an empty taskList)
#   without the operator re-deriving it. Never leaks the token; only the JSON
#   `errorMessages` / `errors` are surfaced.
jira_sink::_error_detail() {
    local body="${JIRA_REST_LAST_ERROR_BODY:-}"
    [[ -n "$body" ]] || return 0
    local detail
    detail="$(printf '%s' "$body" | jq -c \
        '{errorMessages: (.errorMessages // []), errors: (.errors // {})}' \
        2>/dev/null)" || detail=""
    if [[ -n "$detail" && "$detail" != '{"errorMessages":[],"errors":{}}' ]]; then
        printf ' — %s' "$detail"
    fi
}

# =============================================================================
# Feature 007 — author-based attribution (sink-side: identity map + accountId/
# handle MECHANICS). Author RESOLUTION is vendor-neutral and already happened in
# the engine/parser (the neutral `author {value, source}` floor on the item,
# threaded through compose_payload). HERE the sink maps `value` (an email/owner
# string) → a Jira `{accountId, handle}` via the gitignored operator map and
# projects the two attribution tracks (label always; assignee on create only).
#
# PRIVACY (Principle IX): the map holds real emails + account ids (PII) and is
# gitignored; only a placeholder `.sample` ships. Labels carry a non-PII handle,
# NEVER an email. This loader reads the gitignored file; nothing here is tracked.
# =============================================================================

# jira_sink::_load_authors <path>
#   Parse the gitignored authors map (jira-authors.local.yml) into a NEUTRAL
#   JSON object on stdout:
#     { "authors": { "<email>": {"accountId": <id|null>, "handle": "<h>"} ... },
#       "default_assignee": <id|null> }
#   An ABSENT/unreadable file → `{"authors":{},"default_assignee":null}` (rc 0 —
#   attribution then yields no label/assignee for any author, surfaced upstream).
#
#   The map shape is shallow + fixed (per contracts/authors-map.md), so it is
#   parsed with a small awk state machine emitting `email\tfield\tvalue` rows
#   that jq folds into the object — no yq dependency (keeps the dep surface bash
#   + jq, matching config.sh's no-yq stance). `null` (unquoted) maps to JSON
#   null; a quoted value is a JSON string.
jira_sink::_load_authors() {
    local path="${1:-}"
    if [[ -z "$path" || ! -r "$path" ]]; then
        printf '%s' '{"authors":{},"default_assignee":null}'
        return 0
    fi

    # Emit TAB-separated rows the jq reducer consumes:
    #   A\t<email>\taccountId\t<raw>       (author field)
    #   A\t<email>\thandle\t<raw>
    #   D\t<raw>                            (default_assignee)
    # <raw> is the YAML scalar verbatim (quotes/`null` preserved) so jq can
    # decide string-vs-null. The awk tracks the current author key by indent.
    local rows
    rows="$(awk '
        function strip(s) {
            gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s
        }
        function unquote(s,   t) {
            t = s
            if (t ~ /^".*"$/) { sub(/^"/, "", t); sub(/"$/, "", t) }
            else if (t ~ /^'"'"'.*'"'"'$/) { sub(/^'"'"'/, "", t); sub(/'"'"'$/, "", t) }
            return t
        }
        # Strip a trailing comment (no # inside the simple values we accept).
        { sub(/[ \t]+#.*$/, "") }
        /^[ \t]*$/ { next }
        {
            # Compute indent (leading spaces).
            line = $0
            n = 0
            while (substr(line, n + 1, 1) == " ") n++
            content = strip(line)
        }
        # Top-level keys (indent 0): authors:, default_assignee:, schema_version:
        n == 0 {
            if (content ~ /^authors:/) { in_authors = 1; cur = ""; next }
            if (content ~ /^default_assignee:/) {
                in_authors = 0
                v = content; sub(/^default_assignee:[ \t]*/, "", v); v = strip(v)
                printf "D\t%s\n", v
                next
            }
            in_authors = 0
            next
        }
        # An author email key (indent 2): "<email>:" with no value after the colon.
        in_authors && n <= 2 {
            ci = index(content, ":")
            key = strip(substr(content, 1, ci - 1))
            cur = unquote(key)
            next
        }
        # An author field (indent >= 4): accountId: / handle:
        in_authors && cur != "" && n >= 4 {
            ci = index(content, ":")
            fld = strip(substr(content, 1, ci - 1))
            val = strip(substr(content, ci + 1))
            if (fld == "accountId" || fld == "handle") {
                printf "A\t%s\t%s\t%s\n", cur, fld, val
            }
            next
        }
    ' "$path")"

    printf '%s\n' "$rows" | jq -Rs '
        def toval(raw): if (raw == "null" or raw == "") then null
                        else (raw | ltrimstr("\"") | rtrimstr("\"")
                                  | ltrimstr("'"'"'") | rtrimstr("'"'"'")) end;
        reduce (split("\n")[] | select(length > 0) | split("\t")) as $r
          ( {authors: {}, default_assignee: null};
            if $r[0] == "D" then .default_assignee = toval($r[1])
            elif $r[0] == "A" then
              .authors[$r[1]] = ((.authors[$r[1]] // {}) + { ($r[2]): toval($r[3]) })
            else . end )
    '
}

# jira_sink::_author_accountId <loaded_json> <email>
#   Echo the mapped accountId for <email>, or empty (rc 0) when the author is
#   absent OR mapped with a null accountId (label-only, the non-Jira-user case).
jira_sink::_author_accountId() {
    local loaded="${1:-}" email="${2:-}"
    printf '%s' "$loaded" | jq -r --arg e "$email" \
        '.authors[$e].accountId // empty' 2>/dev/null || true
}

# jira_sink::_author_handle <loaded_json> <email>
#   Echo the non-PII handle for <email> on rc 0. rc 1 (empty) when the author is
#   UNKNOWN (not in the map) OR is mapped but missing a `handle` — a config error
#   surfaced to the operator, NEVER a PII email fallback (FR-004).
jira_sink::_author_handle() {
    local loaded="${1:-}" email="${2:-}"
    local handle
    handle="$(printf '%s' "$loaded" | jq -r --arg e "$email" \
        '.authors[$e].handle // empty' 2>/dev/null || true)"
    if [[ -n "$handle" ]]; then
        printf '%s\n' "$handle"
        return 0
    fi
    # Known author with no handle → config error (caller surfaces it); unknown
    # author → graceful no-op. Either way: no label token.
    return 1
}

# jira_sink::_author_known <loaded_json> <email>
#   rc 0 iff <email> is a key in the loaded map (a KNOWN author, regardless of
#   accountId/handle). Lets the projection distinguish a config error (known but
#   no handle) from a graceful no-op (unknown author).
jira_sink::_author_known() {
    local loaded="${1:-}" email="${2:-}"
    [[ -n "$email" ]] || return 1
    printf '%s' "$loaded" | jq -e --arg e "$email" \
        '.authors | has($e)' >/dev/null 2>&1
}

# jira_sink::_apply_author_label <labels_json> <handle>
#   Echo the labels array with `author:*` hygiene applied: strip ANY existing
#   `author:*` label and set the current `author:<handle>` (the same strip-stale-
#   then-set idempotency as the lifecycle `phase:*` labels). Works on create AND
#   update; an author change replaces (never stacks). Built with jq.
jira_sink::_apply_author_label() {
    local labels_json="${1:-[]}" handle="${2:-}"
    printf '%s' "$labels_json" | jq -c --arg h "author:${handle}" '
        ([ .[] | select(startswith("author:") | not) ] + [$h]) | unique'
}

# jira_sink::_resolve_attribution <level> <input_json>
#   The single attribution entry point for sync_level_artifact. OFF-by-default
#   SHORT-CIRCUIT first: returns rc 1 immediately (no map load, no resolution
#   side-effect, no global mutation) when attribution is disabled OR this is not
#   the spec level (attribution is spec→Task level only — M2; epic/phase label
#   inheritance is a documented future stretch, not implemented).
#
#   When active it resolves the neutral `input.author.value` against the
#   gitignored map and sets three OUT globals consumed by the caller:
#     _ATTR_LABELS_JSON   the labels with author:<handle> applied (stale stripped)
#                         — empty when no label is warranted (unknown author /
#                         label track off / missing handle).
#     _ATTR_ACCOUNT_ID    the accountId to set on CREATE (empty = omit assignee).
#     _ATTR_SUMMARY       a human row: author + source + outcome.
#   rc 0 when attribution is active (even if it yields no label/assignee — the
#   caller still consulted it); rc 1 when short-circuited (caller does nothing).
jira_sink::_resolve_attribution() {
    local level="${1:-}" input_json="${2:-}"
    _ATTR_LABELS_JSON=""
    _ATTR_ACCOUNT_ID=""
    _ATTR_SUMMARY=""

    # OFF by default + spec-level only — short-circuit BEFORE any map load.
    config::attribution_enabled || return 1
    [[ "$level" == "spec" ]] || return 1

    # The neutral author floor threaded through compose_payload.
    local value source
    value="$(printf '%s' "$input_json" | jq -r '.author.value // ""' 2>/dev/null || printf '')"
    source="$(printf '%s' "$input_json" | jq -r '.author.source // ""' 2>/dev/null || printf '')"

    if [[ -z "$value" ]]; then
        _ATTR_SUMMARY="author unknown (no Owner: line, no git history) — no label, no assignee"
        return 0
    fi

    # Load the gitignored operator map (absent → empty map).
    local authors_file loaded
    authors_file="$(config::attribution_authors_file)"
    loaded="$(jira_sink::_load_authors "$authors_file")"

    # Label track (always-on, account-independent) — gated on attribution.label.
    if config::attribution_label; then
        local handle
        if handle="$(jira_sink::_author_handle "$loaded" "$value")"; then
            _ATTR_LABELS_JSON="$handle"   # caller applies via _apply_author_label
        elif jira_sink::_author_known "$loaded" "$value"; then
            # Known author but no handle → config error, surfaced; no PII fallback.
            jira_sink::_log "attribution: author '${value}' is mapped but has no 'handle' — no author label applied (config error; add a non-PII handle to the authors map)"
        fi
    fi

    # Assignee track (create-only; applied by the caller) — gated on
    # attribution.assignee. A null/absent accountId ⇒ label-only (omit assignee).
    if config::attribution_assignee; then
        _ATTR_ACCOUNT_ID="$(jira_sink::_author_accountId "$loaded" "$value")"
    fi

    # Summary outcome row.
    local outcome
    if [[ -n "$_ATTR_ACCOUNT_ID" ]]; then
        outcome="assigned + labelled"
    elif [[ -n "$_ATTR_LABELS_JSON" ]]; then
        outcome="label-only"
    else
        outcome="no attribution applied"
    fi
    _ATTR_SUMMARY="author ${value} (${source:-unknown}) — ${outcome}"
    return 0
}

# -----------------------------------------------------------------------------
# Feature 002 — mapping-driven level projection (US1/T013).
#
# The 001 orchestrators hardcoded repo→Epic / spec→Story / phase→Subtask. They
# now route their artifact (issue type) + parent relationship through the config
# layer's mapping::resolve_level, so an operator's configured mapping (US2+)
# drives the projection — WITHOUT changing the default. With no `mapping:` block,
# the alias layer synthesizes today's default (repo→Epic, spec→Story,
# phase→Subtask, task→checklist), so these helpers resolve to exactly the same
# issue-type ids the 001 path used: byte-for-byte unchanged (FR-001, FR-018).
#
# Vendor-neutrality holds: the MAPPING (level→artifact name + relationship) lives
# in config.sh; the sink only translates the resolved artifact NAME to its Jira
# issue-type id via the existing issue_types.* bindings.
# -----------------------------------------------------------------------------

# jira_sink::_resolve_level <level>
#   Echo `<artifact>\t<relationship_to_parent>` for a workstate level via the
#   config layer's mapping::resolve_level. The engine runs mapping::parse at
#   config-load (T014), so production always resolves through the loaded (or
#   alias-synthesized) block. As a SELF-HEALING fallback, when the mapping was
#   not synthesized (a caller that loaded config but skipped mapping::parse —
#   e.g. a 001-era contract test), resolve the level from the synthesized DEFAULT
#   table directly, so the projection is still today's default (repo→Epic,
#   spec→Story, phase→Subtask, task→checklist). This keeps the sink's default
#   projection byte-for-byte identical regardless of which load path reached it
#   (FR-001), without coupling every caller to the mapping API.
jira_sink::_resolve_level() {
    local level="$1"
    if [[ "${CONFIG_MAPPING_SYNTHESIZED:-0}" == "1" ]]; then
        mapping::resolve_level "$level"
        return
    fi
    # Fallback: emit the default level mapping (artifact<TAB>relationship).
    printf '%s\n' "${CONFIG_MAPPING_DEFAULT[$level]:-}"
}

# jira_sink::_level_artifact <level>
#   Echo the artifact name resolved for the given workstate level (e.g. `Epic`
#   for repo, `checklist` for task in the default).
jira_sink::_level_artifact() {
    local level="$1"
    jira_sink::_resolve_level "$level" | cut -f1
}

# jira_sink::_level_relationship <level>
#   Echo the relationship_to_parent resolved for the level (e.g. `none` for repo,
#   `parent` for spec/phase, `checklist` for task in the default).
jira_sink::_level_relationship() {
    local level="$1"
    jira_sink::_resolve_level "$level" | cut -f2
}

# jira_sink::_artifact_issue_type_id <artifact>
#   Translate a resolved artifact NAME to its configured Jira issue-type id via
#   the existing issue_types.* bindings (Epic→issue_types.epic, etc.). The four
#   built-in artifacts map to today's required ids; a configured Task projects to
#   issue_types.task (US2). The `checklist` sentinel is NOT an issue type and has
#   no id — callers must branch on it before reaching here. An unknown artifact
#   is a config error (config::get halts on the missing key).
jira_sink::_artifact_issue_type_id() {
    local artifact="$1"
    case "$artifact" in
        Epic)      config::get issue_types.epic ;;
        Story)     config::get issue_types.story ;;
        Subtask)   config::get issue_types.subtask ;;
        Task)      config::get issue_types.task ;;
        checklist)
            jira_sink::_log "internal: checklist is a render sentinel, not an issue type"
            return 1
            ;;
        *)
            # A non-default artifact name reuses the lowercased issue_types.<name>
            # binding (US2 operator-configured types resolve their id the same
            # way). config::get halts (config rc) if the id is absent.
            local key
            key="$(printf '%s' "$artifact" | tr '[:upper:]' '[:lower:]')"
            config::get "issue_types.${key}"
            ;;
    esac
}

# jira_sink::_level_issue_type_id <level>
#   Convenience: resolve a workstate level straight to its Jira issue-type id via
#   the mapping layer. The default aliases (repo→Epic→10001, spec→Story→10002,
#   phase→Subtask→10003) reproduce the exact ids the 001 orchestrators used.
jira_sink::_level_issue_type_id() {
    local level="$1"
    jira_sink::_artifact_issue_type_id "$(jira_sink::_level_artifact "$level")"
}

# -----------------------------------------------------------------------------
# US2 disposition channel.
#
# The orchestrators (sync_spec_issue / sync_task_phase_subissues) own the
# find-or-create-or-update decision; the engine's process_spec needs to know
# whether the result was a CREATE, an UPDATE, or a no-op SKIP so its run summary
# distinguishes created / updated / skipped (FR-008, FR-015). The orchestrators
# stash that verdict on these module globals (function stdout stays reserved for
# the issue key / phase-map the engine reads back), and process_spec reads them
# right after the call.
#   value ∈ { created | updated | skipped }
# Exported because reconcile.sh (a separate file across the engine↔sink seam)
# reads them; `export` also keeps shellcheck — which scans this file in
# isolation — from flagging the assignments as unused (SC2034).
declare -gx JIRA_SINK_SPEC_DISPOSITION=""
# Per-phase Subtask verdicts: a JSON object `{phase_index: disposition}` so the
# engine can tally created vs updated vs skipped Subtasks per run. A phase whose
# Subtask CREATE failed at the transport gets disposition `failed`, so the engine
# surfaces it as an error row instead of reporting silent success — the phase is
# un-mirrored (US5 observable failure; FR-015, Principle VIII).
declare -gx JIRA_SINK_SUBISSUE_DISPOSITIONS="{}"
# US5 observable-failure channel: a real TRANSITION transport failure (the POST
# itself failed, NOT the benign "no transition available" case which is rc 0).
# sync_spec_issue sets this to 1 so the engine surfaces a warned row + promotes
# the exit (the Story is mirrored, but its status did not apply — warn, don't
# fail closed). Reset to 0 per spec by the engine wrapper before each call.
declare -gx JIRA_SINK_SPEC_TRANSITION_FAILED="0"

# jira_sink::_normalize_adf <adf_json>
#   Echo a canonical, comparison-stable form of an ADF body. Descriptions are
#   ADF JSON whose key order is not significant; two semantically-identical
#   bodies MUST compare EQUAL so an unchanged re-run produces no update (the
#   SC-017 zero-churn guarantee). `jq -S -c` sorts object keys recursively and
#   strips insignificant whitespace, so a round-tripped Jira body and a freshly
#   rendered one collapse to the same string. A non-JSON / empty input echoes
#   the empty string (so two absent bodies also compare equal).
jira_sink::_normalize_adf() {
    local raw="${1:-}"
    [[ -n "$raw" && "$raw" != "null" ]] || { printf ''; return 0; }
    # Canonicalize for comparison. REAL-JIRA CONTRACT (both verified live):
    #  (1) Jira drops empty paragraphs on store — an empty body we POST as
    #      {doc:[{paragraph,content:[]}]} reads back as {doc:content:[]}.
    #  (2) Right after a fresh CREATE, Jira returns the description as `null`
    #      until a later write settles it — so a just-created empty Story reads
    #      back null on the very first re-run.
    # All three (null, {doc:content:[]}, {doc:[empty paragraph]}) are SEMANTICALLY
    # EMPTY and MUST compare equal, else the Story description churns one write
    # per fresh create before settling (SC-017 zero-write edge). Strip
    # content-less paragraphs, then collapse any empty-content doc to the SAME
    # canonical form as null/absent (no output → "" via jq `empty`).
    printf '%s' "$raw" | jq -S -c '
        walk(
            if type == "object" and (.content | type) == "array"
            then .content |= map(select((.type != "paragraph") or (((.content // []) | length) > 0)))
            else . end
        )
        | if (.type == "doc" and ((.content // []) | length) == 0) then empty else . end
    ' 2>/dev/null || printf ''
}

# jira_sink::_labels_equal <desired_json> <current_json>
#   Return 0 iff the two JSON arrays of label strings are set-equal (order
#   insignificant). Used so a re-run whose desired labels match the issue's
#   current labels produces no `labels` diff entry.
jira_sink::_labels_equal() {
    local desired="${1:-[]}" current="${2:-[]}"
    local d c
    d="$(printf '%s' "$desired" | jq -S -c '(. // []) | unique' 2>/dev/null || printf '[]')"
    c="$(printf '%s' "$current" | jq -S -c '(. // []) | unique' 2>/dev/null || printf '[]')"
    [[ "$d" == "$c" ]]
}

# =============================================================================
# Read (idempotency + drift)  — engine-sink-interface.md §Read
#
# Absent → rc 0 with empty/`[]` stdout (the engine then CREATES). rc 3 ONLY on
# a real unreadable read (jira_rest signals JIRA_REST_RC_UNREADABLE). The
# difference is critical: the engine fails closed on rc 3, so conflating
# "absent" with "unreadable" would mean no spec ever gets created.
# =============================================================================

# jira_sink::_search_issues <jql>
#   Run a JQL search via jira_rest::search_jql and echo the `.issues` array
#   (newest-first if the JQL ordered it). Distinguishes ABSENT from UNREADABLE:
#     * jira_rest rc 0 + parseable JSON → echo `.issues` (possibly `[]`), rc 0.
#     * jira_rest rc 0 + UNPARSEABLE JSON → rc 3 (a malformed read is unreadable).
#     * jira_rest rc≠0 → rc 3 (transport/auth/permission unreadable).
#   No stdout on the rc-3 paths.
jira_sink::_search_issues() {
    local jql="$1"
    local raw rc
    if raw="$(jira_rest::search_jql "$jql" 2>/dev/null)"; then
        rc=0
    else
        rc=$?
    fi
    if (( rc != 0 )); then
        # A real unreadable read (transport / auth / permission / malformed).
        return 3
    fi
    # rc 0 but malformed/empty body is ALSO unreadable — we cannot prove the
    # issue is absent, so fail closed rather than silently treat as absent.
    local issues
    if ! issues="$(printf '%s' "$raw" | jq -ce '.issues // []' 2>/dev/null)"; then
        return 3
    fi
    printf '%s\n' "$issues"
    return 0
}

# query_spec_issue <spec_label> <project>
#   Returns a JSON array of matching Stories, newest first
#   `[{id,key,status,updated,labels}]`. rc 3 on unreadable; rc 0 + `[]` absent.
#   JQL `labels = "<spec_label>" AND project = "<project>"`, newest first.
query_spec_issue() {
    local spec_label="${1:-}" project="${2:-}"
    jira_sink::_search_issues \
        "labels = \"${spec_label}\" AND project = \"${project}\" ORDER BY updated DESC"
}

# query_subissue_for_phase <parent_key> <phase_label>
#   Returns a JSON array of Subtasks. rc 3 on unreadable; rc 0 + `[]` absent.
#   JQL `parent = <parent_key> AND labels = "<phase_label>"`.
query_subissue_for_phase() {
    local parent_key="${1:-}" phase_label="${2:-}"
    jira_sink::_search_issues \
        "parent = \"${parent_key}\" AND labels = \"${phase_label}\""
}

# query_issue_full <key>
#   GET /issue/<key>?fields=summary,description,labels,status,parent and echo
#   the `.fields` object (so the idempotent diff can compare summary /
#   description / labels / status against the disk-derived desired). A JQL
#   `/search/jql` result omits `description`, so the diff needs this targeted
#   read. rc 3 on an unreadable read; the engine fails closed on it.
query_issue_full() {
    local key="${1:-}"
    local raw rc
    if raw="$(jira_rest::get "issue/${key}?fields=summary,description,labels,status,parent" 2>/dev/null)"; then
        rc=0
    else
        rc=$?
    fi
    if (( rc != 0 )); then
        return 3
    fi
    local fields
    if ! fields="$(printf '%s' "$raw" | jq -ce '.fields // {}' 2>/dev/null)"; then
        return 3
    fi
    printf '%s\n' "$fields"
    return 0
}

# query_issue_blocks <issue_key>
#   GET the Story's issuelinks and echo the SET of already-linked target issue
#   KEYS as a JSON array (both inward and outward neighbours — a link's presence
#   is symmetric for idempotency purposes). rc 3 on an unreadable read; rc 0 +
#   `[]` when the issue has no links. The block-link reconcile reads this to skip
#   a POST whose target is already linked (FR-007: at-most-once).
#
#   Reads /issue/<key>?fields=issuelinks. Each issuelink carries a `type.name`
#   plus either an `outwardIssue` or an `inwardIssue` with a `.key`. We retain
#   the link TYPE and DIRECTION alongside the neighbour KEY — NOT just the key —
#   so the dedup in sync_inter_phase_blocks compares by (rel, target) per the
#   data-model. Collapsing to the bare key would wrongly skip a desired
#   dependency when an UNRELATED link type, or the OPPOSITE direction, already
#   names that same neighbour (US4 P2).
#
#   Output: a JSON array of `{type, dir, key}` records, where `dir` is
#   `outward` or `inward` (the neighbour's role relative to this issue) and
#   `type` is the link-type display name (e.g. "Blocks"). `unique` collapses
#   identical edges.
query_issue_blocks() {
    local key="${1:-}"
    local raw rc
    if raw="$(jira_rest::get "issue/${key}?fields=issuelinks" 2>/dev/null)"; then
        rc=0
    else
        rc=$?
    fi
    if (( rc != 0 )); then
        return 3
    fi
    local edges
    if ! edges="$(printf '%s' "$raw" | jq -ce '
        [ (.fields.issuelinks // [])[]
          | (.type.name // "") as $t
          | ( if (.outwardIssue.key // "") != ""
                then {type: $t, dir: "outward", key: .outwardIssue.key} else empty end ),
            ( if (.inwardIssue.key // "") != ""
                then {type: $t, dir: "inward", key: .inwardIssue.key} else empty end )
        ]
        | unique
    ' 2>/dev/null)"; then
        return 3
    fi
    printf '%s\n' "$edges"
    return 0
}

# query_existing_comment_body <issue_key> <marker>
#   GET the issue's comments and echo the FIRST comment whose rendered body text
#   contains the stable hidden <marker> (the dedup probe for FR-007 at-most-once
#   comment posting), else EMPTY. rc 3 on an unreadable read; rc 0 + empty when
#   no comment carries the marker.
#
#   Reads /issue/<key>/comment. The comment endpoint is PAGINATED
#   (`{startAt,maxResults,total,comments:[…]}`); we walk pages until the marker
#   is found or every comment has been examined. Without this, a marker living
#   beyond the first page reads as ABSENT → the note is re-posted → a DUPLICATE
#   comment on re-run (US4 P2). A comment body is ADF JSON; we stringify the
#   whole body and test for the marker substring, so the marker survives whatever
#   ADF node it was embedded in (we embed it as a trailing paragraph text run).
query_existing_comment_body() {
    local key="${1:-}" marker="${2:-}"
    local start_at=0
    # Page size is server-bounded; we request a generous page and follow the
    # `total` to decide whether another page exists. A defensive page cap stops
    # a malformed `total` (e.g. always-greater-than-startAt) from looping forever.
    local page_size=100 page_guard=0
    while (( page_guard < 1000 )); do
        page_guard=$(( page_guard + 1 ))
        local raw rc
        if raw="$(jira_rest::get "issue/${key}/comment?startAt=${start_at}&maxResults=${page_size}" 2>/dev/null)"; then
            rc=0
        else
            rc=$?
        fi
        if (( rc != 0 )); then
            return 3
        fi
        # Find the first comment on THIS page whose ADF body, flattened to a JSON
        # string, contains the marker. Echo that comment's {id,body} and stop.
        local hit
        if ! hit="$(printf '%s' "$raw" | jq -c --arg m "$marker" '
            [ (.comments // [])[]
              | select((.body | tostring) | contains($m)) ]
            | (.[0] // empty)
        ' 2>/dev/null)"; then
            return 3
        fi
        if [[ -n "$hit" && "$hit" != "null" ]]; then
            printf '%s\n' "$hit"
            return 0
        fi
        # Advance pagination: stop when this page exhausts the reported total, or
        # when a page returned zero comments (defensive against a missing total).
        local total page_count
        total="$(printf '%s' "$raw" | jq -r '(.total // 0)' 2>/dev/null || printf '0')"
        page_count="$(printf '%s' "$raw" | jq -r '((.comments // []) | length)' 2>/dev/null || printf '0')"
        [[ "$total" =~ ^[0-9]+$ ]] || total=0
        [[ "$page_count" =~ ^[0-9]+$ ]] || page_count=0
        start_at=$(( start_at + page_count ))
        if (( page_count == 0 )) || (( start_at >= total )); then
            break
        fi
    done
    # No comment on any page carried the marker → ABSENT (rc 0, empty stdout).
    printf ''
    return 0
}

# _fetch_drift_issue_json <feature_number>
#   The drift gate's read. Locate the freshest spec Story (`speckit-spec:NNN`,
#   scoped to this repo's project) and echo the issue reshaped into the ENGINE'S
#   drift contract, or EMPTY (rc 0) when the issue is genuinely ABSENT. rc 3
#   ONLY on a real unreadable read.
#
#   A brand-new spec is ABSENT, not unreadable: the engine fails closed on
#   rc 3, so absent MUST be rc 0 + empty output or no spec would ever get
#   created on a fresh reconcile.
#
#   ENGINE CONTRACT (US3): reconcile::compute_drift /
#   reconcile::_tracker_phase_token are COPIED VERBATIM from spec-kit-linear and
#   read a Linear-shaped object — `.updatedAt`, `.labels.nodes[].name` (filtering
#   `phase:*`), and `.state.type == "completed"` → merged. The SINK adapts to
#   that contract (the engine is NEVER touched, so the planned shared-engine
#   extraction stays mechanical) by reshaping Jira's native fields:
#       updatedAt ← fields.updated
#       labels    ← { nodes: [ {name: <each fields.labels[] string>} ] }
#       state     ← { type: (fields.status.statusCategory.key == "done"
#                              ? "completed" : "open") }
#   US1 already stamps a `phase:<state>` label on the Story, so
#   _tracker_phase_token reads the tracker phase straight from labels.nodes[]; a
#   done-category status carrying no phase label degrades to `merged`.
_fetch_drift_issue_json() {
    local feature_number="${1:-}"
    local spec_prefix project label lifecycle_prefix
    # Config getters halt (exit 2) on a missing key; in a fresh reconcile config
    # is already loaded + validated, so these resolve. Guard defensively so a
    # contract test that forgot to load config fails closed rather than exits.
    spec_prefix="$(config::get labels.spec_prefix 2>/dev/null || true)"
    project="$(config::get project_key 2>/dev/null || true)"
    if [[ -z "$spec_prefix" || -z "$project" ]]; then
        return 3
    fi
    label="${spec_prefix}${feature_number}"
    # The lifecycle label prefix is operator-configurable, but the engine's drift
    # comparator (_tracker_phase_token) only knows the fixed `phase:` contract.
    # The reshape below translates `<lifecycle_prefix><state>` → `phase:<state>`
    # so a non-default prefix (e.g. `stage:`) still surfaces the tracker phase —
    # otherwise drift is missed and even --on-drift=abort could overwrite an
    # ahead Story (codex review P1).
    lifecycle_prefix="$(config::get labels.lifecycle_prefix 2>/dev/null || true)"
    [[ -n "$lifecycle_prefix" ]] || lifecycle_prefix="phase:"

    local issues
    if ! issues="$(query_spec_issue "$label" "$project")"; then
        # Propagate the unreadable signal (rc 3) verbatim.
        return 3
    fi

    # Absent: empty array → empty stdout, rc 0 (the engine then CREATES).
    local count
    count="$(printf '%s' "$issues" | jq -r 'length' 2>/dev/null || printf '0')"
    if [[ "$count" == "0" ]]; then
        return 0
    fi

    # Present: reshape the freshest match into the engine's Linear-shaped drift
    # schema. The JQL ordered newest-first, so element 0 is freshest. Jira's
    # native fields are mapped to the contract the engine reads verbatim:
    #   * updatedAt ← fields.updated (the tracker recency key compute_drift uses),
    #     NORMALISED to the engine's expected `%cI` ISO spelling. Jira emits
    #     `2026-05-26T09:41:00.000+0000` (fractional seconds + colon-less zone);
    #     git_helpers::iso_to_epoch (engine side, untouched) parses the git `%cI`
    #     form `2026-05-26T09:41:00+00:00`, so the sink strips the fractional
    #     seconds and reinserts the offset colon here. Without this, recency
    #     mis-parses and the corroborating recency signal never fires.
    #   * labels.nodes[].name ← each string in fields.labels[] (so the engine's
    #     `phase:*` filter finds the lifecycle phase US1 stamped on the Story)
    #   * state.type ← "completed" iff the status's statusCategory is the done
    #     category (Jira's terminal bucket), else "open" — _tracker_phase_token
    #     reads `state.type == "completed"` as the no-phase-label `merged` signal.
    printf '%s' "$issues" | jq -c --arg lp "$lifecycle_prefix" '
        # Normalise a Jira timestamp to the engine'\''s %cI ISO spelling:
        # drop optional .fff fractional seconds, and turn a trailing Z or
        # ±HHMM zone into ±HH:MM. A value that does not match is passed through.
        def norm_ts:
            if . == null then null
            else
                gsub("\\.[0-9]+"; "")
                | if test("Z$") then sub("Z$"; "+00:00")
                  elif test("[+-][0-9]{4}$")
                  then sub("(?<o>[+-][0-9]{2})(?<m>[0-9]{2})$"; "\(.o):\(.m)")
                  else . end
            end;
        .[0] as $i
        | {
            updatedAt: (($i.fields.updated // null) | norm_ts),
            labels: {
                nodes: ((($i.fields.labels) // [])
                    | map(if startswith($lp) then "phase:" + ltrimstr($lp) else . end)
                    | map({name: .}))
            },
            state: {
                type: (
                    if (($i.fields.status.statusCategory.key) // "")
                        | ascii_downcase == "done"
                    then "completed" else "open" end
                )
            }
          }
    ' 2>/dev/null || return 3
    return 0
}

# =============================================================================
# Write (mutations)  — engine-sink-interface.md §Write
#
# All writes honour DRY_RUN: log the intended mutation, synthesize the
# placeholder id the engine reads back, skip the curl.
# =============================================================================

# mutate_issue_create <fields_json>
#   POST /issue with the given `{fields:{...}}` payload; echo `{id,key}` of the
#   created issue. Under DRY_RUN, log + synthesize a stable placeholder.
mutate_issue_create() {
    local fields_json="${1:-}"
    if jira_sink::_dry_run; then
        jira_sink::_log "DRY-RUN mutate_issue_create (no-op): ${fields_json}"
        printf '{"id":"dry-run-issue-id","key":"DRY-0"}\n'
        return 0
    fi
    local resp _rc
    if ! resp="$(jira_rest::post "issue" "$fields_json")"; then
        _rc=$?
        jira_sink::_log "mutate_issue_create: POST /issue failed (rc ${_rc})$(jira_sink::_error_detail)"
        return 1
    fi
    # Echo just {id,key} for a clean engine boundary.
    printf '%s' "$resp" | jq -c '{id: .id, key: .key}' 2>/dev/null || {
        jira_sink::_log "mutate_issue_create: malformed create response"
        return 1
    }
}

# mutate_issue_update <key> <fields_json>
#   PUT /issue/<key>; **no-op when fields are `{}`** (idempotency — the
#   empty-diff no-op the engine's probe produces).
mutate_issue_update() {
    local key="${1:-}" fields_json="${2:-}"
    # Idempotency: an empty diff is a no-op success regardless of dry-run, so
    # the engine's zero-churn reconcile stays a verifiable observation.
    if [[ "$fields_json" == "{}" ]] \
        || printf '%s' "$fields_json" | jq -e 'length == 0' >/dev/null 2>&1; then
        return 0
    fi
    if jira_sink::_dry_run; then
        jira_sink::_log "DRY-RUN mutate_issue_update ${key} (no-op): ${fields_json}"
        return 0
    fi
    if ! jira_rest::put "issue/${key}" "$fields_json" >/dev/null; then
        local _rc=$?
        jira_sink::_log "mutate_issue_update: PUT /issue/${key} failed (rc ${_rc})$(jira_sink::_error_detail)"
        return 1
    fi
    return 0
}

# mutate_comment_create <issue_key> <body_adf>
#   POST /issue/<key>/comment with `{body: <ADF doc>}`; echo `{id}` of the
#   created comment. Under DRY_RUN, log + synthesize a stable placeholder. The
#   caller (sync_clarify_comments) has already proven the comment is absent via
#   query_existing_comment_body, so this only fires for a genuinely new note.
mutate_comment_create() {
    local key="${1:-}" body_adf="${2:-}"
    if jira_sink::_dry_run; then
        jira_sink::_log "DRY-RUN mutate_comment_create ${key} (no-op)"
        printf '{"id":"dry-run-comment-id"}\n'
        return 0
    fi
    # Wrap the ADF body in the comment payload `{body: <doc>}` (Jira REST v3).
    local payload
    payload="$(jq -cn --argjson b "$body_adf" '{body: $b}' 2>/dev/null)" || {
        jira_sink::_log "mutate_comment_create: malformed ADF body for ${key}"
        return 1
    }
    local resp
    if ! resp="$(jira_rest::post "issue/${key}/comment" "$payload")"; then
        jira_sink::_log "mutate_comment_create: POST /issue/${key}/comment failed (rc $?)"
        return 1
    fi
    printf '%s' "$resp" | jq -c '{id: .id}' 2>/dev/null || {
        jira_sink::_log "mutate_comment_create: malformed comment response"
        return 1
    }
}

# mutate_comment_update <issue_key> <comment_id> <body_adf>
#   PUT /issue/<key>/comment/<id> with `{body: <ADF doc>}` to UPDATE an existing
#   comment IN PLACE (feature 005, FR-005 — never a second comment). Mirrors
#   mutate_comment_create: honours DRY_RUN (log + no-op), guards a malformed ADF
#   body, and logs a failed write with the transport's error detail. Echoes the
#   updated comment's `{id}` on success. The caller (sync_decision_records) has
#   already located the comment by its stable marker, so <comment_id> is known.
mutate_comment_update() {
    local key="${1:-}" comment_id="${2:-}" body_adf="${3:-}"
    if jira_sink::_dry_run; then
        jira_sink::_log "DRY-RUN mutate_comment_update ${key}/${comment_id} (no-op)"
        printf '{"id":"%s"}\n' "$comment_id"
        return 0
    fi
    # Wrap the ADF body in the comment payload `{body: <doc>}` (Jira REST v3).
    local payload
    payload="$(jq -cn --argjson b "$body_adf" '{body: $b}' 2>/dev/null)" || {
        jira_sink::_log "mutate_comment_update: malformed ADF body for ${key}/${comment_id}"
        return 1
    }
    local resp _rc=0
    resp="$(jira_rest::put "issue/${key}/comment/${comment_id}" "$payload")" || _rc=$?
    if (( _rc != 0 )); then
        jira_sink::_log "mutate_comment_update: PUT /issue/${key}/comment/${comment_id} failed (rc ${_rc})$(jira_sink::_error_detail)"
        return 1
    fi
    printf '%s' "$resp" | jq -c '{id: .id}' 2>/dev/null || {
        jira_sink::_log "mutate_comment_update: malformed comment response"
        return 1
    }
}

# transition_issue <key> <target_status_id>
#   Set <key>'s status by POSTing a transition. GET /issue/<key>/transitions,
#   select the transition whose `to.id` == target (or honour a configured
#   explicit transition id given as `<status>\t<transition>`), then POST it
#   (research D6: Jira has no "set status" write — transitions are the only
#   path; the observed board uses global transitions so a single POST suffices).
transition_issue() {
    local key="${1:-}" target="${2:-}"

    # The config vendor lever may hand us `<status-id>\t<transition-id>`: an
    # explicit transition id pins the POST without resolving by target status.
    local target_status="$target" explicit_transition=""
    if [[ "$target" == *$'\t'* ]]; then
        target_status="${target%%$'\t'*}"
        explicit_transition="${target#*$'\t'}"
    fi

    if jira_sink::_dry_run; then
        jira_sink::_log "DRY-RUN transition_issue ${key} -> status ${target_status}${explicit_transition:+ (transition ${explicit_transition})} (no-op)"
        return 0
    fi

    local transition_id="$explicit_transition"
    if [[ -z "$transition_id" ]]; then
        # Resolve dynamically: fetch transitions, pick the one whose to.id == target.
        local trs
        if ! trs="$(jira_rest::get "issue/${key}/transitions")"; then
            jira_sink::_log "transition_issue: GET transitions for ${key} failed (rc $?)"
            return 1
        fi
        transition_id="$(printf '%s' "$trs" | jq -r \
            --arg s "$target_status" \
            '(.transitions // []) | map(select(.to.id == $s)) | (.[0].id // "")' \
            2>/dev/null || printf '')"
        if [[ -z "$transition_id" ]]; then
            jira_sink::_log "transition_issue: no transition to status ${target_status} for ${key}; status unchanged (Principle VIII)"
            return 0
        fi
    fi

    local payload
    payload="$(jq -cn --arg id "$transition_id" '{transition:{id:$id}}')"
    if ! jira_rest::post "issue/${key}/transitions" "$payload" >/dev/null; then
        jira_sink::_log "transition_issue: POST transition ${transition_id} for ${key} failed (rc $?)"
        return 1
    fi
    return 0
}

# =============================================================================
# Orchestrators — REMOVED in feature 003 (engine orchestration unification).
#
# The 001-era ensure_repo_epic / sync_spec_issue / sync_task_phase_subissues are
# gone. The engine now drives the generic mapping-driven projection
# (sync_level_artifact + link_to_parent) for EVERY level via a neutral level
# loop in reconcile.sh, so the sink carries no per-level orchestrator. See
# specs/003-engine-orchestration-unification/.
# =============================================================================

# =============================================================================
# Feature 002 — Phase 5/US3: 2-level checklist mode (keyed sub-tree byte-diff).
#
# In 2-level mode the phase + task levels resolve to the `checklist` sentinel:
# no Subtask/Task child issues are created; the tasks collapse into an in-body
# ADF checklist carried by the SPEC issue's description. The body is CO-OWNED —
# the prose above the marker is human-editable and PRESERVED across re-runs; the
# bridge owns only the checklist SUB-TREE (marker paragraph + taskList). The
# sub-tree is byte-compared in isolation so (a) an unchanged re-run writes
# nothing (FR-008, SC-004) and (b) an unrelated prose edit does NOT trigger a
# rewrite (Q7, US3 scenario 3). The render lives in adf.sh
# (adf::render_checklist_subtree, keyed by workstate task id); these helpers do
# the read/compare/write.
# =============================================================================

# Disposition channel for the 2-level checklist body write, mirroring the spec /
# subissue channels (read by reconcile.sh for the run summary).
JIRA_SINK_CHECKLIST_DISPOSITION=""

# jira_sink::_split_body_at_marker <description_json>
#   Split an ADF description doc at the stable checklist marker (Q9). Echoes a
#   JSON object {preamble:[…], subtree:[…]} where `preamble` is the content
#   nodes BEFORE the marker paragraph (the human-owned prose) and `subtree` is
#   the marker paragraph plus everything after it (the bridge-owned checklist).
#   When no marker is present (a fresh issue, or one mirrored before 2-level),
#   `preamble` is the whole content and `subtree` is `[]`. A null/absent
#   description yields empty preamble + empty subtree.
jira_sink::_split_body_at_marker() {
    local desc="${1:-null}"
    local marker="${2:-$ADF_CHECKLIST_MARKER}"
    printf '%s' "$desc" | jq -c --arg m "$marker" '
        ((. // {}) | .content // []) as $c
        | ( [ $c
              | to_entries[]
              | select(.value.type == "paragraph"
                       and (([.value.content[]?.text] | join("")) == $m))
              | .key ] | first ) as $idx
        | if $idx == null
          then { preamble: $c, subtree: [] }
          else { preamble: $c[0:$idx], subtree: $c[$idx:] }
          end
    ' 2>/dev/null || printf '{"preamble":[],"subtree":[]}'
}

# jira_sink::_canonical_subtree <subtree_json_array>
#   Canonical, comparison-stable form of a checklist sub-tree array. Wraps the
#   array in a doc and reuses the live-proven ADF normalizer (jira_sink::_normalize_adf:
#   recursive key sort + empty-paragraph collapse) so a round-tripped Jira body
#   and a freshly rendered one compare EQUAL despite key-order differences. An
#   empty/absent sub-tree canonicalizes to the empty string.
jira_sink::_canonical_subtree() {
    local subtree="${1:-[]}"
    local doc
    doc="$(printf '%s' "$subtree" | jq -c '{version:1,type:"doc",content:(. // [])}' 2>/dev/null || printf 'null')"
    jira_sink::_normalize_adf "$doc"
}

# diff_checklist_subtree <issue_key> <rendered_subtree>
#   Byte-compare ONLY the checklist sub-tree of <issue_key>'s description against
#   <rendered_subtree>. Echoes `unchanged` (sub-trees canonically equal → no
#   write needed) or `changed`. Reads via query_issue_full; an unreadable read
#   fails closed (rc 3) so the engine never blind-writes (FR-017).
diff_checklist_subtree() {
    local key="${1:-}" rendered="${2:-[]}"

    local fields
    if ! fields="$(query_issue_full "$key")"; then
        jira_sink::_log "diff_checklist_subtree: ${key} read unreadable; failing closed (rc 3)"
        return 3
    fi
    local cur_desc cur_subtree
    cur_desc="$(printf '%s' "$fields" | jq -c '.description // null' 2>/dev/null || printf 'null')"
    cur_subtree="$(jira_sink::_split_body_at_marker "$cur_desc" | jq -c '.subtree' 2>/dev/null || printf '[]')"

    local cur_norm desired_norm
    cur_norm="$(jira_sink::_canonical_subtree "$cur_subtree")"
    desired_norm="$(jira_sink::_canonical_subtree "$rendered")"

    if [[ "$cur_norm" == "$desired_norm" ]]; then
        printf 'unchanged\n'
    else
        printf 'changed\n'
    fi
    return 0
}

# sync_body_checklist <issue_key> <rendered_subtree>
#   Reconcile the in-body checklist sub-tree of <issue_key>. Reads the current
#   description, isolates the sub-tree, and:
#     * sub-tree unchanged → SKIP the write (zero churn); disposition `skipped`.
#     * sub-tree changed    → PUT a description = the PRESERVED prose preamble +
#       the new sub-tree (so a human's prose edit survives and no duplicate
#       checklist is appended); disposition `updated`.
#   An unreadable read fails closed (rc 3, no write). Records the verdict on
#   JIRA_SINK_CHECKLIST_DISPOSITION.
sync_body_checklist() {
    local key="${1:-}" rendered="${2:-[]}"
    JIRA_SINK_CHECKLIST_DISPOSITION=""

    local fields
    if ! fields="$(query_issue_full "$key")"; then
        jira_sink::_log "sync_body_checklist: ${key} read unreadable; failing closed (rc 3)"
        return 3
    fi
    local cur_desc split preamble cur_subtree
    cur_desc="$(printf '%s' "$fields" | jq -c '.description // null' 2>/dev/null || printf 'null')"
    split="$(jira_sink::_split_body_at_marker "$cur_desc")"
    preamble="$(printf '%s' "$split" | jq -c '.preamble' 2>/dev/null || printf '[]')"
    cur_subtree="$(printf '%s' "$split" | jq -c '.subtree' 2>/dev/null || printf '[]')"

    local cur_norm desired_norm
    cur_norm="$(jira_sink::_canonical_subtree "$cur_subtree")"
    desired_norm="$(jira_sink::_canonical_subtree "$rendered")"
    if [[ "$cur_norm" == "$desired_norm" ]]; then
        JIRA_SINK_CHECKLIST_DISPOSITION="skipped"
        return 0
    fi

    # Compose the desired body: PRESERVE the prose preamble, swap in the new
    # sub-tree. Building the doc in jq keeps text escaped + key order fixed.
    local desired_desc payload
    desired_desc="$(jq -cn --argjson pre "$preamble" --argjson st "$rendered" \
        '{version:1, type:"doc", content: ($pre + $st)}')"
    payload="$(jq -cn --argjson d "$desired_desc" '{fields: {description: $d}}')"

    if ! mutate_issue_update "$key" "$payload"; then
        jira_sink::_log "sync_body_checklist: description write for ${key} failed"
        JIRA_SINK_CHECKLIST_DISPOSITION="failed"
        return 1
    fi
    JIRA_SINK_CHECKLIST_DISPOSITION="updated"
    return 0
}

# =============================================================================
# Feature 002 — Phase 6/US4: status rollup (transition only on changed
# completion). OFF by default (mapping.status_rollup.enabled). Reuses the 001
# transition_issue / config::get_status_transition levers — NO new status
# surface (Q11, FR-011/FR-012). The "done" status is the one the terminal
# lifecycle phase (`merged`) maps to; a regressed (complete→partial) issue
# transitions back to the active (`implementing`) status.
# =============================================================================

# rollup::compute_completion <kind> <items_json>
#   kind=phase: <items_json> is the phase's tasks array [{done}], `complete`
#     iff it is non-empty AND every task is checked.
#   kind=repo:  <items_json> is the specs' lifecycle states ["implementing",…],
#     `complete` iff non-empty AND every spec is in the terminal `merged` state.
#   Anything else (or empty) is `partial` — no vacuous done. Echoes the verdict.
rollup::compute_completion() {
    local kind="${1:-}" items="${2:-[]}"
    local complete=1
    case "$kind" in
        phase)
            printf '%s' "$items" \
                | jq -e '(length > 0) and (all(.[]; (.done // false) == true))' \
                    >/dev/null 2>&1 || complete=0 ;;
        repo)
            printf '%s' "$items" \
                | jq -e '(length > 0) and (all(.[]; . == "merged"))' \
                    >/dev/null 2>&1 || complete=0 ;;
        *)
            complete=0 ;;
    esac
    if (( complete == 1 )); then printf 'complete\n'; else printf 'partial\n'; fi
    return 0
}

# rollup::done_status_id
#   The status id the rollup treats as "done" — the one the terminal lifecycle
#   phase (`merged`) maps to. Echoes the status id (empty if unmapped). Used by
#   the caller to derive an issue's PRIOR completion from its current status.
rollup::done_status_id() {
    local st
    st="$(config::get_status_transition "merged" 2>/dev/null)" || { printf ''; return 0; }
    printf '%s\n' "${st%%$'\t'*}"
}

# rollup::transition_if_changed <issue_key> <computed> <prior>
#   Transition <issue_key> to reflect <computed> completion ONLY when it differs
#   from <prior> (forward AND backward); equal ⇒ `noop`, no write (FR-012).
#   complete ⇒ the done status (`merged`); partial ⇒ the active status
#   (`implementing`). Reuses config::get_status_transition + transition_issue.
#   Echoes `transitioned` or `noop`; a transport failure returns rc 1.
rollup::transition_if_changed() {
    local key="${1:-}" computed="${2:-partial}" prior="${3:-}"
    if [[ "$computed" == "$prior" ]]; then
        printf 'noop\n'
        return 0
    fi
    local phase target
    if [[ "$computed" == "complete" ]]; then phase="merged"; else phase="implementing"; fi
    if ! target="$(config::get_status_transition "$phase" 2>/dev/null)"; then
        # No status mapping for the target phase → nothing to transition to.
        printf 'noop\n'
        return 0
    fi
    if ! transition_issue "$key" "$target"; then
        jira_sink::_log "rollup::transition_if_changed: transition for ${key} failed"
        return 1
    fi
    printf 'transitioned\n'
    return 0
}

# =============================================================================
# Feature 002 — Phase 8/US6: Initiative super-level + graceful degradation.
# OFF by default (mapping.initiative.enabled). Maps the narrative super-level to
# a Jira Initiative where the instance supports it, and folds the narrative onto
# the repo Epic (behind a stable marker, with the repo grouping label) where it
# does not — NEVER hard-failing for lack of the Initiative type (Q5, FR-013/
# FR-014, SC-007). The narrative is populated ONLY from the explicit spec_input
# source (never inferred); in --workstate mode it is gracefully absent.
# =============================================================================

# query_initiative <repo_label> <project> <initiative_type_id>
#   Find the repo's Initiative by its repo identity label AND issue type (so it
#   never collides with the same-labelled Epic). Echoes the `.issues` array; rc 3
#   on an unreadable read, rc 0 + `[]` when absent.
query_initiative() {
    local label="${1:-}" project="${2:-}" itype="${3:-}"
    jira_sink::_search_issues \
        "labels = \"${label}\" AND issuetype = \"${itype}\" AND project = \"${project}\" ORDER BY updated DESC"
}

# initiative::probe_available
#   `present` when the target project lists the configured initiative artifact in
#   its issue-type metadata, else `absent`. An unreadable probe fails closed
#   (rc 3) — the caller then leaves the super-level untouched (no blind write).
initiative::probe_available() {
    local want rows
    want="$(config::get mapping.initiative.artifact 2>/dev/null || printf 'Initiative')"
    if ! rows="$(mapping::detect_available_types)"; then
        return 3
    fi
    # detect_available_types emits `<name>\t<id>` rows — match the NAME column.
    if printf '%s\n' "$rows" | cut -f1 | grep -qxF "$want"; then
        printf 'present\n'
    else
        printf 'absent\n'
    fi
    return 0
}

# ensure_initiative <narrative> <repo_slug>
#   Find-or-create the repo's Initiative (issue_types.initiative), carrying the
#   repo identity label and the narrative as its body. Idempotent: an existing
#   Initiative is matched (by repo label + type) and its description/labels are
#   reconciled only on a real diff (zero churn). Echoes the Initiative key. rc 3
#   on an unreadable lookup/read; rc 1 on a write failure.
ensure_initiative() {
    local narrative="${1:-}" repo_slug="${2:-}"
    local project itype repo_prefix label
    project="$(config::get project_key)"
    itype="$(jira_sink::_artifact_issue_type_id "$(config::get mapping.initiative.artifact 2>/dev/null || printf 'Initiative')")"
    repo_prefix="$(config::get labels.repo_prefix)"
    label="${repo_prefix}${repo_slug}"

    local description
    description="$(adf::from_markdown "$narrative")"
    local labels_json
    labels_json="$(jq -cn --arg l "$label" '[$l]')"

    local existing existing_key
    if ! existing="$(query_initiative "$label" "$project" "$itype")"; then
        jira_sink::_log "ensure_initiative: lookup unreadable; failing closed (rc 3)"
        return 3
    fi
    existing_key="$(printf '%s' "$existing" | jq -r '(.[0].key // "")' 2>/dev/null || printf '')"

    if [[ -z "$existing_key" || "$existing_key" == "null" ]]; then
        local fields created key
        fields="$(jq -cn \
            --arg project "$project" --arg itype "$itype" \
            --arg summary "${repo_slug} — Initiative" \
            --argjson description "$description" --argjson labels "$labels_json" \
            '{fields:{project:{key:$project},issuetype:{id:$itype},
              summary:$summary,description:$description,labels:$labels}}')"
        if ! created="$(mutate_issue_create "$fields")"; then
            jira_sink::_log "ensure_initiative: create failed"
            return 1
        fi
        key="$(printf '%s' "$created" | jq -r '.key // ""' 2>/dev/null || printf '')"
        JIRA_SINK_INITIATIVE_DISPOSITION="created"
        printf '%s\n' "$key"
        return 0
    fi

    # PRESENT → reconcile description + labels only on a real diff.
    local current cur_desc cur_labels
    if ! current="$(query_issue_full "$existing_key")"; then
        jira_sink::_log "ensure_initiative: ${existing_key} read unreadable; failing closed (rc 3)"
        return 3
    fi
    cur_desc="$(printf '%s' "$current" | jq -c '.description // null' 2>/dev/null || printf 'null')"
    cur_labels="$(printf '%s' "$current" | jq -c '.labels // []' 2>/dev/null || printf '[]')"

    local diff='{}'
    if [[ "$(jira_sink::_normalize_adf "$description")" != "$(jira_sink::_normalize_adf "$cur_desc")" ]]; then
        diff="$(printf '%s' "$diff" | jq -c --argjson d "$description" '. + {description: $d}')"
    fi
    if ! jira_sink::_labels_equal "$labels_json" "$cur_labels"; then
        diff="$(printf '%s' "$diff" | jq -c --argjson l "$labels_json" '. + {labels: $l}')"
    fi
    if [[ "$diff" != "{}" ]]; then
        if ! mutate_issue_update "$existing_key" "$(printf '%s' "$diff" | jq -c '{fields: .}')"; then
            jira_sink::_log "ensure_initiative: update for ${existing_key} failed"
            return 1
        fi
        JIRA_SINK_INITIATIVE_DISPOSITION="updated"
    else
        JIRA_SINK_INITIATIVE_DISPOSITION="skipped"
    fi
    printf '%s\n' "$existing_key"
    return 0
}

# Disposition channel for the Initiative super-level (read by reconcile.sh across
# the engine↔sink seam; -gx also silences SC2034 in the isolated file scan).
declare -gx JIRA_SINK_INITIATIVE_DISPOSITION=""

# initiative::degrade_onto_epic <epic_key> <narrative> <repo_slug>
#   When the instance lacks the Initiative type, fold the narrative onto the repo
#   Epic behind the stable ADF_INITIATIVE_MARKER, preserving the Epic's other
#   body content; the repo grouping rides the existing repo_prefix label (already
#   on the Epic). Idempotent: the marker-delimited narrative section is byte-
#   compared in isolation, so a degraded re-run (or an unrelated Epic body edit)
#   writes nothing. NEVER hard-fails for lack of Initiative; an unreadable Epic
#   read still fails closed (rc 3).
initiative::degrade_onto_epic() {
    local epic_key="${1:-}" narrative="${2:-}" repo_slug="${3:-}"
    : "${repo_slug:=}"

    local current cur_desc
    if ! current="$(query_issue_full "$epic_key")"; then
        jira_sink::_log "initiative::degrade_onto_epic: ${epic_key} read unreadable; failing closed (rc 3)"
        return 3
    fi
    cur_desc="$(printf '%s' "$current" | jq -c '.description // null' 2>/dev/null || printf 'null')"

    local section split preamble cur_section
    section="$(adf::render_initiative_section "$narrative")"
    split="$(jira_sink::_split_body_at_marker "$cur_desc" "$ADF_INITIATIVE_MARKER")"
    preamble="$(printf '%s' "$split" | jq -c '.preamble' 2>/dev/null || printf '[]')"
    cur_section="$(printf '%s' "$split" | jq -c '.subtree' 2>/dev/null || printf '[]')"

    if [[ "$(jira_sink::_canonical_subtree "$cur_section")" == "$(jira_sink::_canonical_subtree "$section")" ]]; then
        JIRA_SINK_INITIATIVE_DISPOSITION="skipped"
        return 0
    fi

    local desired_desc payload
    desired_desc="$(jq -cn --argjson pre "$preamble" --argjson sec "$section" \
        '{version:1, type:"doc", content: ($pre + $sec)}')"
    payload="$(jq -cn --argjson d "$desired_desc" '{fields: {description: $d}}')"
    if ! mutate_issue_update "$epic_key" "$payload"; then
        jira_sink::_log "initiative::degrade_onto_epic: description write for ${epic_key} failed"
        return 1
    fi
    JIRA_SINK_INITIATIVE_DISPOSITION="updated"
    return 0
}

# =============================================================================
# Feature 002 — Phase 4/US2: mapping-driven level projection
# (engine-sink-interface-002 §mapping-driven projection).
#
# The 001 orchestrators (ensure_repo_epic / sync_spec_issue /
# sync_task_phase_subissues) hardcode the default repo→Epic / spec→Story /
# phase→Subtask projection. `sync_level_artifact` is the GENERIC, mapping-driven
# create/update for ANY configured level: it resolves the level's artifact +
# parent relationship through the config mapping layer, finds-or-creates the
# configured issue type, and re-matches by the supplied IDENTITY LABEL so a
# re-run UPDATES rather than re-creates (idempotent, FR-009). A `checklist`
# sentinel level creates NO issue (it renders into the parent body, US3).
#
# `link_to_parent` applies the configured relationship after a create: `parent`
# and `Epic-link` both set Jira's native `parent` field (modern Jira folds the
# classic Epic-link onto the parent field); `none` and `checklist` are no-ops.
#
# Vendor-neutrality (FR-018): the level→artifact + relationship MAPPING lives in
# config.sh (validated at config-load); this sink only translates the resolved
# names to Jira ids/payloads. The disposition channel mirrors the 001 channel so
# the engine's created/updated/skipped tally works for the configured path too.
#
# TRACKED DEFERRAL (US2 phase boundary — tasks.md T055/T056): these two
# functions are the proven, unit+integration-tested mapping-driven projection,
# but the engine (reconcile.sh process_spec) is NOT yet wired to call them — it
# still drives the 001-era ensure_repo_epic / sync_spec_issue /
# sync_task_phase_subissues orchestrators. That wiring (and a full-stack
# live-reconcile zero-churn test of a non-default label/parent shape) is a
# DELIBERATE later task, OUT OF US2 SCOPE — do not wire it here.
# =============================================================================

# Per-call disposition for the generic level projection (mirrors
# JIRA_SINK_SPEC_DISPOSITION). value ∈ { created | updated | skipped }. Empty
# when the level was a checklist sentinel (no issue). Exported so reconcile.sh
# (across the seam) can read it and so shellcheck does not flag it unused.
declare -gx JIRA_SINK_LEVEL_DISPOSITION=""
# Transport-failure channel for a level's lifecycle status transition (feature
# 003; mirrors JIRA_SINK_SPEC_TRANSITION_FAILED). Read by the engine to surface
# a US5 observable failure. -gx silences SC2034 in the isolated file scan.
declare -gx JIRA_SINK_LEVEL_TRANSITION_FAILED=0
# Attribution fail-soft channel (feature-007 FR-008): set to 1 when a create's
# assignee write was rejected and retried without the assignee (the label still
# landed). The engine surfaces it as an observable, non-fatal warning. -gx
# silences SC2034 in the isolated file scan.
declare -gx JIRA_SINK_LEVEL_ASSIGNEE_FAILED=0

# jira_sink::_compose_create_fields <project> <itype> <parent_id> <summary>
#   <description_json> <labels_json> <set_parent> <omit_desc> <assignee_json>
#   Build the `{fields: {...}}` create body. Extracted so the attribution
#   fail-soft path (feature-007) can recompose the SAME create without the
#   assignee on a rejected assignee write. `assignee_json` is `null` (omit) or a
#   `{accountId: "..."}` object — the assignee is a create-only attribution
#   (FR-003); the update path never composes it.
jira_sink::_compose_create_fields() {
    local project="$1" itype="$2" parent_id="$3" summary="$4" \
        description="$5" labels_json="$6" set_parent="$7" omit_description="$8" \
        assignee_json="${9:-null}"
    jq -cn \
        --arg project "$project" \
        --arg itype "$itype" \
        --arg parent "$parent_id" \
        --arg summary "$summary" \
        --argjson description "$description" \
        --argjson labels "$labels_json" \
        --argjson set_parent "$set_parent" \
        --argjson omit_desc "$omit_description" \
        --argjson assignee "$assignee_json" \
        '{fields:(
            {
                project:     {key: $project},
                issuetype:   {id: $itype},
                summary:     $summary,
                labels:      $labels
            }
            + (if ($omit_desc == 1) then {} else {description: $description} end)
            + (if ($set_parent == 1) then {parent: {key: $parent}} else {} end)
            + (if ($assignee == null) then {} else {assignee: $assignee} end)
        )}'
}

# sync_level_artifact <level> <identity_label> <parent_id> <input_json>
#                      [find_only] [reconcile_parent] [parent_scoped_find]
#   Mapping-driven create/update of the level's CONFIGURED issue type under
#   <parent_id>, matched/updated by <identity_label> (idempotent, FR-009).
#   <input_json> is `{summary, body}` (the sink-neutral level payload). Echoes
#   `{id,key}` of the issue (empty for a checklist sentinel). Records the verdict
#   on JIRA_SINK_LEVEL_DISPOSITION. rc 3 on an unreadable lookup (fail-closed).
#
#   <parent_scoped_find> (default 0) scopes the idempotency find. A level whose
#   identity label is unique only WITHIN its parent (a phase: `task-phase:N` is a
#   phase NUMBER, unique per spec, not per repo) must be matched scoped to its
#   parent or every spec's "Phase N" collides on the SAME issue. When this is 1
#   AND <parent_id> is non-empty, the find is `parent = <parent_id> AND labels =
#   <identity_label>`; otherwise the find is the globally-unique label+project
#   search (repo/spec, whose identity is unique across the board). This is a
#   STRUCTURAL property (identity-uniqueness scope), set by the engine — NOT Jira
#   vocabulary — so the engine stays vendor-neutral.
sync_level_artifact() {
    local level="${1:-}" identity_label="${2:-}" parent_id="${3:-}" input_json="${4:-}" find_only="${5:-0}" reconcile_parent="${6:-1}" parent_scoped_find="${7:-0}"

    JIRA_SINK_LEVEL_DISPOSITION=""
    JIRA_SINK_LEVEL_TRANSITION_FAILED=0
    JIRA_SINK_LEVEL_ASSIGNEE_FAILED=0

    # Resolve the configured artifact + parent relationship for this level.
    local artifact relationship
    artifact="$(jira_sink::_level_artifact "$level")"
    relationship="$(jira_sink::_level_relationship "$level")"

    # A checklist-sentinel level projects NO standalone issue (it renders into
    # the parent body, US3). No-op success with empty stdout.
    if [[ "$artifact" == "checklist" ]]; then
        JIRA_SINK_LEVEL_DISPOSITION=""
        printf ''
        return 0
    fi

    local project itype
    project="$(config::get project_key)"
    itype="$(jira_sink::_artifact_issue_type_id "$artifact")"

    # Compose the desired issue from the neutral level input. Description source
    # (feature 003 absorption — gated on the neutral input fields so 002 callers,
    # which pass `body`, are unchanged):
    #   .tasks present → an in-body ADF taskList (the phase Subtask body)
    #   .body  present → markdown → ADF (the spec body + the 002 callers)
    #   neither        → OMIT the description entirely (matches the 001 repo Epic,
    #                    which carries no description field)
    #   .checklist_tasks present → 2-level spec: prose + keyed checklist sub-tree
    #                    in ONE create; the sub-tree is reconciled in isolation on
    #                    update (preserving prose), mirroring sync_spec_issue's
    #                    2-level path.
    local summary description omit_description=0 two_level_spec=0 _ck_subtree=''
    summary="$(printf '%s' "$input_json" | jq -r '.summary // ""' 2>/dev/null || printf '')"
    if printf '%s' "$input_json" | jq -e 'has("checklist_tasks")' >/dev/null 2>&1; then
        local _ck_tasks _prose
        _ck_tasks="$(printf '%s' "$input_json" | jq -c '.checklist_tasks // []')"
        _ck_subtree="$(adf::render_checklist_subtree "$_ck_tasks")"
        _prose="$(adf::from_markdown "$(printf '%s' "$input_json" | jq -r '.body // ""')")"
        description="$(jq -cn --argjson p "$_prose" --argjson st "$_ck_subtree" \
            '{version:1, type:"doc", content: ((($p.content) // []) + $st)}')"
        two_level_spec=1
    elif printf '%s' "$input_json" | jq -e 'has("tasks")' >/dev/null 2>&1; then
        local _tasks_json
        _tasks_json="$(printf '%s' "$input_json" | jq -c '.tasks // []')"
        description="$(jq -cn --argjson tl "$(adf::task_list "$_tasks_json")" \
            '{version:1, type:"doc", content:[$tl]}')"
    elif printf '%s' "$input_json" | jq -e 'has("body")' >/dev/null 2>&1; then
        local _body
        _body="$(printf '%s' "$input_json" | jq -r '.body // ""')"
        description="$(adf::from_markdown "$_body")"
    else
        omit_description=1
        description='null'
    fi

    # The desired label set = the identity label (the re-match key — the
    # task_prefix identity for a Task-projected level, FR-009; always carried so a
    # re-run finds it) UNION the caller's desired labels (input.labels — the phase
    # label + the workstate item's own labels). Composing the FULL set here is
    # load-bearing for zero-churn: the PRESENT-path diff below rebuilds the desired
    # labels from THIS value, so omitting input.labels would PUT labels:[identity]
    # and WIPE the phase + operator labels on every update (F1). Mirrors
    # sync_spec_issue's `([$spec,$phase] + (.labels // [])) | unique`.
    local labels_json
    labels_json="$(printf '%s' "$input_json" | jq -c \
        --arg id "$identity_label" \
        '([$id] + (.labels // [])) | unique')"

    # Author-based attribution (feature-007). OFF by default + spec-level only —
    # _resolve_attribution rc 1 short-circuits with zero side-effects so the
    # default path is byte-identical (US4/SC-004). When active it yields a
    # non-PII handle (→ the author:<handle> label, strip-stale-then-set, applied
    # to labels_json here so it rides BOTH create and update) and, separately,
    # the accountId to set on CREATE only (captured here, injected in the create
    # branch below — never on update, so a manual reassignment survives, FR-003).
    local attr_account_id=""
    if jira_sink::_resolve_attribution "$level" "$input_json"; then
        if [[ -n "$_ATTR_LABELS_JSON" ]]; then
            labels_json="$(jira_sink::_apply_author_label "$labels_json" "$_ATTR_LABELS_JSON")"
        fi
        attr_account_id="$_ATTR_ACCOUNT_ID"
        [[ -n "$_ATTR_SUMMARY" ]] && jira_sink::_log "${_ATTR_SUMMARY}"
    fi

    # Whether the configured relationship sets a native parent link on create.
    local set_parent=0
    case "$relationship" in
        parent|Epic-link) [[ -n "$parent_id" ]] && set_parent=1 ;;
    esac

    # Lifecycle status (feature 003 absorption): when the neutral payload carries a
    # `state` that maps to a status, drive the transition (the spec Story). Gated
    # on `.state`, so non-stateful levels (repo/phase) and 002 callers skip it.
    local _state status_transition="" desired_status_id=""
    _state="$(printf '%s' "$input_json" | jq -r '.state // ""' 2>/dev/null || printf '')"
    if [[ -n "$_state" ]] && status_transition="$(config::get_status_transition "$_state" 2>/dev/null)"; then
        desired_status_id="${status_transition%%$'\t'*}"
    else
        status_transition=""
    fi

    # --- Find-or-create-or-update by identity label ----------------------
    # Match the existing artifact by identity. For a PARENT-LOCAL identity (a
    # phase: `task-phase:N` is unique only within its spec) scope the find to the
    # parent — `parent = <parent_id> AND labels = <identity_label>` — so two
    # specs' "Phase N" do NOT collide on the same Subtask. For a globally-unique
    # identity (repo/spec) use the label+project search. rc 3 (unreadable) fails
    # closed — a blind create could dupe.
    local existing existing_key
    if (( parent_scoped_find == 1 )) && [[ -n "$parent_id" ]]; then
        if ! existing="$(query_subissue_for_phase "$parent_id" "$identity_label")"; then
            jira_sink::_log "sync_level_artifact: ${level} (${identity_label}) parent-scoped lookup unreadable; failing closed (rc 3)"
            return 3
        fi
    elif ! existing="$(query_spec_issue "$identity_label" "$project")"; then
        jira_sink::_log "sync_level_artifact: ${level} (${identity_label}) lookup unreadable; failing closed (rc 3)"
        return 3
    fi
    existing_key="$(printf '%s' "$existing" | jq -r '(.[0].key // "")' 2>/dev/null || printf '')"

    if [[ -z "$existing_key" || "$existing_key" == "null" ]]; then
        # ABSENT → create the configured issue type. Attribution (feature-007):
        # the assignee is set HERE — on CREATE ONLY — when the author maps to a
        # non-null accountId (FR-003, Linear FR-034). It is NEVER added on the
        # update path below, so a manual reassignment in Jira survives.
        local _assignee_json='null'
        if [[ -n "$attr_account_id" ]]; then
            _assignee_json="$(jq -cn --arg a "$attr_account_id" '{accountId: $a}')"
        fi
        local fields
        fields="$(jira_sink::_compose_create_fields \
            "$project" "$itype" "$parent_id" "$summary" "$description" \
            "$labels_json" "$set_parent" "$omit_description" "$_assignee_json")"

        local created key
        if ! created="$(mutate_issue_create "$fields")"; then
            # FAIL-SOFT (FR-008): a rejected create that carried an assignee
            # (e.g. a stale/deactivated accountId) MUST NOT abort — surface it,
            # then retry the SAME create WITHOUT the assignee so the spec still
            # lands with its author:<handle> label. A create failure with NO
            # assignee is a real failure (return 1 as before).
            if [[ "$_assignee_json" != "null" ]]; then
                jira_sink::_log "attribution: assignee write rejected for ${level} (${identity_label}) — accountId '${attr_account_id}' may be stale/deactivated; creating WITHOUT assignee, the author label is still applied$(jira_sink::_error_detail)"
                JIRA_SINK_LEVEL_ASSIGNEE_FAILED=1
                local fields_noassignee
                fields_noassignee="$(jira_sink::_compose_create_fields \
                    "$project" "$itype" "$parent_id" "$summary" "$description" \
                    "$labels_json" "$set_parent" "$omit_description" 'null')"
                if ! created="$(mutate_issue_create "$fields_noassignee")"; then
                    jira_sink::_log "sync_level_artifact: failed to create ${artifact} for ${level} (${identity_label})"
                    return 1
                fi
            else
                jira_sink::_log "sync_level_artifact: failed to create ${artifact} for ${level} (${identity_label})"
                return 1
            fi
        fi
        key="$(printf '%s' "$created" | jq -r '.key // ""' 2>/dev/null || printf '')"
        if [[ -z "$key" || "$key" == "null" ]]; then
            jira_sink::_log "sync_level_artifact: created ${artifact} has no key"
            return 1
        fi
        # Drive the lifecycle status on a fresh create (gated on .state).
        if [[ -n "$status_transition" ]]; then
            if ! transition_issue "$key" "$status_transition"; then
                JIRA_SINK_LEVEL_TRANSITION_FAILED=1
                jira_sink::_log "sync_level_artifact: transition for ${key} (state ${_state}) did not apply"
            fi
        fi
        JIRA_SINK_LEVEL_DISPOSITION="created"
        printf '%s\n' "$created"
        return 0
    fi

    # Find-or-create-ONLY mode (feature 003): the repo Epic is never field-
    # reconciled (ensure_repo_epic semantics) — return the found key WITHOUT the
    # present-path read/diff, so it stays byte-identical to the 001 path (no extra
    # GET, no field PUT).
    if (( find_only == 1 )); then
        JIRA_SINK_LEVEL_DISPOSITION="skipped"
        printf '%s\n' "$(printf '%s' "$existing" | jq -c '{id:(.[0].id // ""), key:(.[0].key // "")}')"
        return 0
    fi

    # PRESENT → diff the desired against the current; update only the delta so an
    # unchanged level performs ZERO writes (idempotency, FR-009/SC-017).
    local current
    if ! current="$(query_issue_full "$existing_key")"; then
        jira_sink::_log "sync_level_artifact: ${level} (${existing_key}) read unreadable; failing closed (rc 3)"
        return 3
    fi
    local cur_summary cur_description cur_labels cur_parent cur_status_id
    cur_summary="$(printf '%s' "$current" | jq -r '.summary // ""' 2>/dev/null || printf '')"
    cur_description="$(printf '%s' "$current" | jq -c '.description // null' 2>/dev/null || printf 'null')"
    cur_labels="$(printf '%s' "$current" | jq -c '.labels // []' 2>/dev/null || printf '[]')"
    cur_parent="$(printf '%s' "$current" | jq -r '.parent.key // ""' 2>/dev/null || printf '')"
    cur_status_id="$(printf '%s' "$current" | jq -r '.status.id // ""' 2>/dev/null || printf '')"
    local cur_id
    cur_id="$(printf '%s' "$existing" | jq -r '(.[0].id // "")' 2>/dev/null || printf '')"

    local diff='{}'
    if [[ "$summary" != "$cur_summary" ]]; then
        diff="$(printf '%s' "$diff" | jq -c --arg s "$summary" '. + {summary: $s}')"
    fi
    # Skip the description diff for a description-less level (the repo Epic,
    # omit_description=1) AND for a 2-level spec (two_level_spec=1) — there the
    # prose is co-owned and the checklist sub-tree is reconciled separately below,
    # so the full-body diff would clobber human prose (mirrors sync_spec_issue).
    if (( omit_description == 0 && two_level_spec == 0 )); then
        local desired_desc_norm current_desc_norm
        desired_desc_norm="$(jira_sink::_normalize_adf "$description")"
        current_desc_norm="$(jira_sink::_normalize_adf "$cur_description")"
        if [[ "$desired_desc_norm" != "$current_desc_norm" ]]; then
            diff="$(printf '%s' "$diff" | jq -c --argjson d "$description" '. + {description: $d}')"
        fi
    fi
    if ! jira_sink::_labels_equal "$labels_json" "$cur_labels"; then
        diff="$(printf '%s' "$diff" | jq -c --argjson l "$labels_json" '. + {labels: $l}')"
    fi
    # Re-parent on update only when the level reconciles its parent (spec→Epic is
    # mutable, reconcile_parent=1 default — matches sync_spec_issue). A native
    # Subtask parent is immutable in Jira and was NEVER reconciled on update by
    # sync_task_phase_subissues, so the phase wire passes reconcile_parent=0 (no
    # spurious parent PUT on a zero-churn re-run).
    if (( set_parent == 1 && reconcile_parent == 1 )) && [[ "$parent_id" != "$cur_parent" ]]; then
        diff="$(printf '%s' "$diff" | jq -c --arg p "$parent_id" '. + {parent: {key: $p}}')"
    fi

    local wrote_update=0
    if [[ "$diff" != "{}" ]]; then
        local diff_payload
        diff_payload="$(printf '%s' "$diff" | jq -c '{fields: .}')"
        if ! mutate_issue_update "$existing_key" "$diff_payload"; then
            jira_sink::_log "sync_level_artifact: update for ${existing_key} (${level}) failed"
            return 1
        fi
        wrote_update=1
    fi
    # Reconcile STATUS (gated on .state): transition ONLY when the current status
    # differs from the desired (restores a manual edit; a match fires nothing).
    local wrote_transition=0
    if [[ -n "$desired_status_id" && "$desired_status_id" != "$cur_status_id" ]]; then
        if transition_issue "$existing_key" "$status_transition"; then
            wrote_transition=1
        else
            JIRA_SINK_LEVEL_TRANSITION_FAILED=1
            jira_sink::_log "sync_level_artifact: transition for ${existing_key} (state ${_state}) did not apply"
        fi
    fi

    # 2-level spec: reconcile the in-body checklist sub-tree (preserving prose),
    # mirroring sync_spec_issue. A write counts as an update; fail-closed on an
    # unreadable read; surface a write failure.
    if (( two_level_spec == 1 )); then
        local _ck_rc=0
        sync_body_checklist "$existing_key" "$_ck_subtree" || _ck_rc=$?
        if (( _ck_rc == 3 )); then
            return 3
        elif (( _ck_rc != 0 )); then
            return 1
        fi
        [[ "${JIRA_SINK_CHECKLIST_DISPOSITION}" == "updated" ]] && wrote_update=1
    fi

    if (( wrote_update == 1 || wrote_transition == 1 )); then
        JIRA_SINK_LEVEL_DISPOSITION="updated"
    else
        JIRA_SINK_LEVEL_DISPOSITION="skipped"
    fi
    printf '%s\n' "$(jq -cn --arg id "$cur_id" --arg key "$existing_key" '{id: $id, key: $key}')"
    return 0
}

# link_to_parent <child_id> <parent_id> <relationship>
#   Apply the configured parent relationship to an already-created child. Both
#   `parent` and `Epic-link` set Jira's native `parent` field (modern Jira folds
#   the classic Epic-link onto the parent field — the operator's project_style
#   declares which vocabulary they use, but the write is the same). `none` and
#   `checklist` are NO-OPS (the top level has no parent; a checklist renders
#   in-body). A no-op or a successful PUT returns 0.
link_to_parent() {
    local child_id="${1:-}" parent_id="${2:-}" relationship="${3:-}"

    case "$relationship" in
        none|checklist|"")
            # Top level / in-body render — nothing to link.
            return 0
            ;;
        parent|Epic-link)
            [[ -n "$child_id" && -n "$parent_id" ]] || return 0
            # Read-before-write (zero-churn, F3): an UNCONDITIONAL parent PUT
            # churns on every reconcile. Read the child's current parent and
            # NO-OP when it already matches (mirrors the sync_level_artifact
            # parent-diff). An unreadable read fails closed (rc 3): we cannot
            # prove the parent matches, so silently writing could clobber.
            local current cur_parent
            if ! current="$(query_issue_full "$child_id")"; then
                jira_sink::_log "link_to_parent: ${child_id} read unreadable; failing closed (rc 3)"
                return 3
            fi
            cur_parent="$(printf '%s' "$current" | jq -r '.parent.key // ""' 2>/dev/null || printf '')"
            if [[ "$cur_parent" == "$parent_id" ]]; then
                # Already correctly parented — zero churn.
                return 0
            fi
            local payload
            payload="$(jq -cn --arg p "$parent_id" '{fields:{parent:{key:$p}}}')"
            if ! mutate_issue_update "$child_id" "$payload"; then
                jira_sink::_log "link_to_parent: setting parent ${parent_id} on ${child_id} (${relationship}) failed"
                return 1
            fi
            return 0
            ;;
        *)
            # Dependency-style links are rejected at config-load (matrix); reaching
            # here is a defensive no-op rather than a corrupt write.
            jira_sink::_log "link_to_parent: '${relationship}' is not a hierarchy link; no-op (config-load should have rejected it)"
            return 0
            ;;
    esac
}

# =============================================================================
# US4 marker scheme (FR-007 — at-most-once comments + idempotent links).
#
# A clarify/decision NOTE is mirrored as ONE comment carrying a stable HIDDEN
# marker derived from the note's content (timestamp + body). On re-run,
# query_existing_comment_body finds the marker and the note is SKIPPED — so a
# note appears at most once regardless of how often reconcile runs. The marker
# is a short, opaque hash so it neither leaks PII nor changes between runs for an
# unchanged note.
#
# A cross-spec LINK is idempotent structurally: query_issue_blocks reports the
# already-linked target keys, and sync_inter_phase_blocks POSTs /issueLink ONLY
# for a target not already present — so a re-run adds nothing.
# =============================================================================

# jira_sink::_note_marker <note_json>
#   Echo the stable hidden marker for a workstate note `{body,timestamp_iso}`.
#   Derived from timestamp_iso + body via a content hash so it is identical
#   across runs for an unchanged note and distinct for a different one. Shape:
#   `[speckit-note:<12-hex>]` — embedded as a trailing text run in the comment
#   ADF so query_existing_comment_body can substring-match it.
jira_sink::_note_marker() {
    local note_json="${1:-}"
    local digest
    # Hash the (timestamp_iso \n body) tuple. cksum is POSIX and dependency-free;
    # we fold it to a short hex token. The exact algorithm is irrelevant — only
    # stability (same input → same token) and low collision risk matter here.
    digest="$(printf '%s' "$note_json" \
        | jq -r '((.timestamp_iso // "") + "\n" + (.body // ""))' 2>/dev/null \
        | cksum | awk '{ printf "%08x%04x", $1, ($2 % 65536) }')"
    printf '[speckit-note:%s]' "$digest"
}

# sync_clarify_comments <story_key> <item_json>
#   For each workstate note on the spec item, post ONE comment idempotently:
#     1. Compute the note's stable hidden marker.
#     2. query_existing_comment_body(story, marker) — PRESENT → SKIP (the note
#        was already mirrored on a prior run; at-most-once, FR-007).
#     3. ABSENT → render the note body (Markdown→ADF), append the hidden marker
#        as a trailing paragraph, and mutate_comment_create.
#   An unreadable comment read (rc 3) fails closed for the whole call (we cannot
#   prove a note is absent, so posting could duplicate it). A note with an empty
#   body is skipped. Returns 0 on success; rc 3 fails closed.
sync_clarify_comments() {
    local story_key="${1:-}" item_json="${2:-}"

    local notes_count i
    notes_count="$(printf '%s' "$item_json" | jq -r '(.notes // []) | length' 2>/dev/null || printf '0')"
    [[ "$notes_count" =~ ^[0-9]+$ ]] || notes_count=0

    for (( i = 0; i < notes_count; i++ )); do
        local note note_body marker
        note="$(printf '%s' "$item_json" | jq -c --argjson n "$i" '.notes[$n]' 2>/dev/null)"
        note_body="$(printf '%s' "$note" | jq -r '.body // ""' 2>/dev/null || printf '')"
        # Skip an empty-bodied note (nothing to mirror).
        [[ -n "$note_body" ]] || continue

        marker="$(jira_sink::_note_marker "$note")"

        # Idempotency probe. rc 3 (unreadable) fails closed — we cannot prove the
        # comment is absent, so a blind post could duplicate it.
        local existing
        if ! existing="$(query_existing_comment_body "$story_key" "$marker")"; then
            jira_sink::_log "sync_clarify_comments: comment read for ${story_key} unreadable; failing closed (rc 3)"
            return 3
        fi
        if [[ -n "$existing" ]]; then
            # Already mirrored — at-most-once: skip.
            continue
        fi

        # Render the note body to ADF and append the hidden marker as a trailing
        # paragraph so a future run finds it. The marker text is opaque (a hash),
        # carrying no PII.
        local doc marked_doc
        doc="$(adf::from_markdown "$note_body")"
        marked_doc="$(jq -cn --argjson d "$doc" --arg m "$marker" '
            .version = $d.version
            | .type = $d.type
            | .content = ($d.content + [
                {type:"paragraph", content:[{type:"text", text:$m}]}
              ])
        ' 2>/dev/null)" || marked_doc="$doc"

        if ! mutate_comment_create "$story_key" "$marked_doc" >/dev/null; then
            jira_sink::_log "sync_clarify_comments: comment create for ${story_key} failed"
            return 1
        fi
    done
    return 0
}

# sync_inter_phase_blocks <story_key> <item_json>
#   For each cross-spec dependency link on the spec item (rel `depends_on` or
#   `blocks`) whose target resolves to a mirrored spec Story, POST /issueLink —
#   but ONLY when that target is not already linked. query_issue_blocks reports
#   the Story's current link set first, so a re-run adds nothing (FR-007).
#
#   A link's `target` is a feature number (or a spec id `NNN-<slug>`); we resolve
#   it to the mirrored Story's key via query_spec_issue(speckit-spec:NNN). A
#   target that is NOT mirrored yet is skipped (nothing to link to). An
#   unreadable link/resolve read (rc 3) fails closed for the whole call.
#
#   The issuelink `type` name maps the rel: `blocks`/`depends_on` → "Blocks".
#   `inwardIssue`/`outwardIssue` are assigned so the edge direction matches the
#   rel: depends_on(story→target) means TARGET blocks STORY.
sync_inter_phase_blocks() {
    local story_key="${1:-}" item_json="${2:-}"

    local links_count i
    links_count="$(printf '%s' "$item_json" | jq -r '(.links // []) | length' 2>/dev/null || printf '0')"
    [[ "$links_count" =~ ^[0-9]+$ ]] || links_count=0
    (( links_count > 0 )) || return 0

    local project spec_prefix link_type
    project="$(config::get project_key)"
    spec_prefix="$(config::get labels.spec_prefix)"
    # The Jira issue-link type name. Configurable; defaults to the built-in
    # "Blocks" type every Jira site ships. config::get HALTS (exit 2) on a
    # missing key, and that `exit` fires from the command-substitution subshell
    # BEFORE any trailing `|| true` can run — so under the engine's `set -e` a
    # `$(... || true)` assignment would STILL abort the whole reconcile when the
    # optional `links` block is absent (the common case: data-model leaves it
    # unset). Probe inside an `if` (which suppresses errexit for the tested
    # command) so a missing key degrades to the built-in default instead.
    if ! link_type="$(config::get links.block_type 2>/dev/null)"; then
        link_type=""
    fi
    [[ -n "$link_type" ]] || link_type="Blocks"

    # Read the Story's existing link set ONCE (idempotency baseline). rc 3 fails
    # closed — we cannot prove a target is unlinked, so a blind POST could
    # duplicate the link.
    local existing_targets
    if ! existing_targets="$(query_issue_blocks "$story_key")"; then
        jira_sink::_log "sync_inter_phase_blocks: link read for ${story_key} unreadable; failing closed (rc 3)"
        return 3
    fi

    for (( i = 0; i < links_count; i++ )); do
        local link rel target
        link="$(printf '%s' "$item_json" | jq -c --argjson n "$i" '.links[$n]' 2>/dev/null)"
        rel="$(printf '%s' "$link" | jq -r '.rel // ""' 2>/dev/null || printf '')"
        target="$(printf '%s' "$link" | jq -r '.target // ""' 2>/dev/null || printf '')"
        # Only dependency rels become issue links (other rels are out of scope).
        case "$rel" in
            depends_on|blocks) : ;;
            *) continue ;;
        esac
        [[ -n "$target" ]] || continue

        # Normalise the target to a feature number (the leading NNN of an id).
        local target_num="${target%%-*}"
        [[ "$target_num" =~ ^[0-9]+$ ]] || continue
        local target_label="${spec_prefix}${target_num}"

        # Resolve the target's mirrored Story key. rc 3 fails closed; an absent
        # target (not yet mirrored) is skipped (nothing to link to).
        local target_issues target_key
        if ! target_issues="$(query_spec_issue "$target_label" "$project")"; then
            jira_sink::_log "sync_inter_phase_blocks: target ${target_label} lookup unreadable; failing closed (rc 3)"
            return 3
        fi
        target_key="$(printf '%s' "$target_issues" | jq -r '(.[0].key // "")' 2>/dev/null || printf '')"
        if [[ -z "$target_key" || "$target_key" == "null" ]]; then
            # DEFER (review-debt): a FORWARD dependency in the same --all sweep —
            # spec A depends on spec B whose Story is created LATER this run — is
            # absent here and skipped. It CONVERGES on the next reconcile (the
            # engine is idempotent/re-runnable), so it is acceptable, not fixed.
            continue
        fi

        # Edge direction for the CREATE payload: depends_on(story→target) ⇒ target
        # Blocks story, so inwardIssue=story, outwardIssue=target. `blocks` is the
        # reverse.
        local inward outward
        if [[ "$rel" == "blocks" ]]; then
            inward="$target_key"; outward="$story_key"
        else
            inward="$story_key"; outward="$target_key"
        fi

        # Idempotency by (rel, target): skip ONLY when an edge of the SAME link
        # TYPE already names this neighbour. We deliberately match on (type, key)
        # and NOT on direction: Jira's reciprocal representation surfaces the SAME
        # link as the neighbour's `inwardIssue` OR `outwardIssue` depending on
        # which side is read, so a desired Blocks-dependency to a target is
        # already satisfied by a Blocks edge to that target either way. The TYPE
        # check is the real guard — an UNRELATED link type (e.g. "Relates") to the
        # same neighbour must NOT wrongly skip the desired dependency (data-model:
        # dedup by (rel,target); US4 P2). The retained `dir` in the edge records
        # supports that type-scoped comparison without conflating link types.
        if printf '%s' "$existing_targets" | jq -e \
            --arg t "$link_type" --arg k "$target_key" \
            'any(.[]; .type == $t and .key == $k)' \
            >/dev/null 2>&1; then
            continue
        fi

        if jira_sink::_dry_run; then
            jira_sink::_log "DRY-RUN sync_inter_phase_blocks ${outward} ${link_type} ${inward} (no-op)"
            # Fold the intended edge into the in-run baseline so a duplicate dep
            # bullet resolving to the same (rel,target) is recognised as already
            # handled this run — no second (dry-run) emission.
            existing_targets="$(printf '%s' "$existing_targets" | jq -c \
                --arg t "$link_type" --arg k "$target_key" \
                '. + [{type:$t, dir:"outward", key:$k}] | unique')"
            continue
        fi

        local payload
        payload="$(jq -cn \
            --arg type "$link_type" \
            --arg inward "$inward" \
            --arg outward "$outward" \
            '{type:{name:$type}, inwardIssue:{key:$inward}, outwardIssue:{key:$outward}}')"
        if ! jira_rest::post "issueLink" "$payload" >/dev/null; then
            jira_sink::_log "sync_inter_phase_blocks: POST /issueLink (${outward}→${inward}) failed (rc $?)"
            return 1
        fi
        # Update the baseline mid-run: a later dep bullet resolving to the SAME
        # (rel,target) — e.g. two "depends on NNN" bullets, or an id and its bare
        # feature number — must NOT POST a second identical /issueLink this run
        # (US4 P2: dedup within one sweep, not just across runs).
        existing_targets="$(printf '%s' "$existing_targets" | jq -c \
            --arg t "$link_type" --arg k "$target_key" \
            '. + [{type:$t, dir:"outward", key:$k}] | unique')"
    done
    return 0
}

# =============================================================================
# Feature 005 — ADR / decision-record mirroring.
#
# A PARALLEL, ISOLATED clone of the clarify-comment path: one Jira comment per
# decision on the spec issue, carrying a stable hidden marker
# `[speckit-adr:<spec>-<id>]` (DISJOINT from the clarify `[speckit-note:…]`
# namespace — FR-008). Unlike the clarify path (create-or-skip on a content
# marker), ADRs are keyed by IDENTITY (spec+decision id) and UPDATED IN PLACE
# when the rendered body changes (FR-005): query_existing_comment_body locates
# the one comment + its id; a normalized-body comparison decides skip vs update.
# The body shape is parity-locked to Linear 008 (contracts/adr-comment-layout.md).
# =============================================================================

# jira_sink::_adr_marker <spec_num> <decision_id>
#   Echo the stable hidden ADR marker `[speckit-adr:<spec>-<id>]`. Keyed by
#   identity (NOT content) so the comment is located stably across edits +
#   reordering (FR-003) — which is what enables update-in-place. Embedded as a
#   trailing text run so query_existing_comment_body can substring-match it.
jira_sink::_adr_marker() {
    local spec_num="${1:-}" decision_id="${2:-}"
    printf '[speckit-adr:%s-%s]' "$spec_num" "$decision_id"
}

# jira_sink::_render_adr_body <decision_json> <spec_num>
#   Render ONE decision to an ADF comment body in the parity layout
#   (contracts/adr-comment-layout.md): a title line `ADR <id> — <title>`, then
#   Status (default "Accepted"), Decision, Rationale, Alternatives (each OMITTED
#   when absent), Source `research.md#<id>`, and the hidden marker LAST. Built as
#   Markdown then converted via adf::from_markdown (reusing the comment builders).
jira_sink::_render_adr_body() {
    local decision="${1:-}" spec_num="${2:-}"

    local id title status decision_t rationale alternatives source marker
    id="$(printf '%s' "$decision" | jq -r '.id // ""' 2>/dev/null || printf '')"
    title="$(printf '%s' "$decision" | jq -r '.title // ""' 2>/dev/null || printf '')"
    status="$(printf '%s' "$decision" | jq -r '.status // ""' 2>/dev/null || printf '')"
    decision_t="$(printf '%s' "$decision" | jq -r '.decision // ""' 2>/dev/null || printf '')"
    rationale="$(printf '%s' "$decision" | jq -r '.rationale // ""' 2>/dev/null || printf '')"
    alternatives="$(printf '%s' "$decision" | jq -r '.alternatives // ""' 2>/dev/null || printf '')"
    source="$(printf '%s' "$decision" | jq -r '.source // ""' 2>/dev/null || printf '')"
    [[ -n "$status" ]] || status="Accepted"
    [[ -n "$source" ]] || source="research.md#${id}"
    marker="$(jira_sink::_adr_marker "$spec_num" "$id")"

    # Compose the Markdown body in the fixed parity order. Each field is its own
    # paragraph; absent sub-parts are omitted entirely (omit-don't-blank).
    local md
    md="ADR ${id} — ${title}"$'\n\n'
    md+="Status: ${status}"$'\n\n'
    md+="Decision: ${decision_t}"
    if [[ -n "$rationale" ]]; then
        md+=$'\n\n'"Rationale: ${rationale}"
    fi
    if [[ -n "$alternatives" ]]; then
        md+=$'\n\n'"Alternatives: ${alternatives}"
    fi
    md+=$'\n\n'"Source: ${source}"

    local doc marked_doc
    doc="$(adf::from_markdown "$md")"
    # Append the hidden marker as a trailing paragraph text run (locatable by the
    # comment probe; excluded from the content digest below).
    marked_doc="$(jq -cn --argjson d "$doc" --arg m "$marker" '
        .version = $d.version
        | .type = $d.type
        | .content = ($d.content + [
            {type:"paragraph", content:[{type:"text", text:$m}]}
          ])
    ' 2>/dev/null)" || marked_doc="$doc"
    printf '%s' "$marked_doc"
}

# jira_sink::_adr_body_digest <body_adf>
#   Echo a stable, normalized content digest of an ADR comment body (M2). The
#   digest flattens the body to its text runs, EXCLUDES any `[speckit-adr:…]`
#   marker run (the identity anchor is stable in both the desired + fetched body,
#   so it must not affect the compare), and collapses cosmetic whitespace before
#   hashing — so re-serialization / trailing-space noise does not churn, while a
#   genuine content change flips the digest. Same discipline as the clarify-note
#   marker hash (cksum, dependency-free).
jira_sink::_adr_body_digest() {
    local body_adf="${1:-}"
    local normalized
    normalized="$(printf '%s' "$body_adf" | jq -r '
        [ .. | .text? // empty ]
        | map(select(test("^\\[speckit-adr:") | not))
        | join("\n")
    ' 2>/dev/null || printf '')"
    # Collapse all runs of whitespace to single spaces and trim.
    normalized="$(printf '%s' "$normalized" | tr '\n\t' '  ' | tr -s ' ')"
    normalized="${normalized#"${normalized%%[![:space:]]*}"}"
    normalized="${normalized%"${normalized##*[![:space:]]}"}"
    printf '%s' "$normalized" | cksum | awk '{ printf "%08x%04x", $1, ($2 % 65536) }'
}

# sync_decision_records <issue_key> <item_json>
#   For each workstate decision on the spec item, mirror ONE comment idempotently
#   (FR-002/004/005/010):
#     1. Compute the marker `[speckit-adr:<spec>-<id>]` (spec num from item.id)
#        and render the desired ADR body.
#     2. query_existing_comment_body(key, marker) → rc 3 fails CLOSED for the
#        whole call (we cannot prove absence, so a blind post could duplicate).
#     3. ABSENT  → mutate_comment_create (one new comment).
#        PRESENT → compare the normalized body digest of the FETCHED comment to
#                  the desired body; MISMATCH → mutate_comment_update IN PLACE
#                  using the returned comment id (never a second comment);
#                  MATCH → skip (zero churn).
#   A decision with an empty id or empty decision text is skipped. Returns 0 on
#   success; rc 3 fails closed. The clarify (`speckit-note:`) stream is untouched
#   — disjoint marker namespaces (FR-008).
sync_decision_records() {
    local issue_key="${1:-}" item_json="${2:-}"

    # Derive the spec number from the item id (`NNN-<short>` → `NNN`). The marker
    # is spec-scoped so two specs' same-id decisions never collide.
    local spec_num
    spec_num="$(printf '%s' "$item_json" | jq -r '(.id // "") | split("-")[0]' 2>/dev/null || printf '')"

    local count i
    count="$(printf '%s' "$item_json" | jq -r '(.decisions // []) | length' 2>/dev/null || printf '0')"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0

    for (( i = 0; i < count; i++ )); do
        local decision id decision_t marker
        decision="$(printf '%s' "$item_json" | jq -c --argjson n "$i" '.decisions[$n]' 2>/dev/null)"
        id="$(printf '%s' "$decision" | jq -r '.id // ""' 2>/dev/null || printf '')"
        decision_t="$(printf '%s' "$decision" | jq -r '.decision // ""' 2>/dev/null || printf '')"
        # A decision needs an id (the marker anchor) and a Decision statement.
        [[ -n "$id" && -n "$decision_t" ]] || continue

        marker="$(jira_sink::_adr_marker "$spec_num" "$id")"

        # Idempotency probe (returns {id,body} when present). rc 3 fails closed.
        local existing
        if ! existing="$(query_existing_comment_body "$issue_key" "$marker")"; then
            jira_sink::_log "sync_decision_records: comment read for ${issue_key} unreadable; failing closed (rc 3)"
            return 3
        fi

        local desired_body
        desired_body="$(jira_sink::_render_adr_body "$decision" "$spec_num")"

        if [[ -z "$existing" ]]; then
            # ABSENT → create one comment.
            if ! mutate_comment_create "$issue_key" "$desired_body" >/dev/null; then
                jira_sink::_log "sync_decision_records: comment create for ${issue_key} failed"
                return 1
            fi
            continue
        fi

        # PRESENT → compare the normalized body digests (marker excluded).
        local existing_id existing_body desired_digest existing_digest
        existing_id="$(printf '%s' "$existing" | jq -r '.id // ""' 2>/dev/null || printf '')"
        existing_body="$(printf '%s' "$existing" | jq -c '.body // {}' 2>/dev/null || printf '{}')"
        desired_digest="$(jira_sink::_adr_body_digest "$desired_body")"
        existing_digest="$(jira_sink::_adr_body_digest "$existing_body")"

        if [[ "$desired_digest" == "$existing_digest" ]]; then
            # Unchanged → zero churn (FR-004).
            continue
        fi
        # Changed → update the ONE existing comment in place (FR-005). No id →
        # cannot update safely; skip rather than risk a duplicate.
        [[ -n "$existing_id" ]] || continue
        if ! mutate_comment_update "$issue_key" "$existing_id" "$desired_body" >/dev/null; then
            jira_sink::_log "sync_decision_records: comment update for ${issue_key}/${existing_id} failed"
            return 1
        fi
    done
    return 0
}

# =============================================================================
# Label resolution  — engine-sink-interface.md §Label resolution
# =============================================================================

# resolve_labels <names…>
#   Echo the same names — Jira labels are plain strings; near-passthrough (no
#   UUID indirection, unlike the sibling's Linear labelId resolver). Echoes a
#   JSON array of the (non-empty) names for a clean engine boundary.
resolve_labels() {
    local -a names=()
    local n
    for n in "$@"; do
        [[ -n "$n" ]] && names+=("$n")
    done
    if (( ${#names[@]} == 0 )); then
        printf '[]\n'
        return 0
    fi
    printf '%s\n' "${names[@]}" | jq -Rcs 'split("\n") | map(select(length > 0))'
}

# =============================================================================
# Feature 004 — re-mode / orphan pruning (Jira-specific prune mechanic + reads).
#
# The engine owns the NEUTRAL orphan diff (reconcile::compute_orphans); the sink
# owns everything Jira here: the bridge-owned predicate (which labels mark an
# issue as ours), the descendant enumeration (parent-walk), and the prune
# mechanic (hard-delete | archive). Destruction is gated by the v1.1.0
# controlled-destruction carve-out (Principle I): bridge-owned only, flag-only,
# dry-run-previewable, fail-closed.
# =============================================================================

# jira_sink::_identity_prefixes
#   Echo the configured IDENTITY label prefixes (newline-separated). These mark
#   bridge ownership: repo/spec/phase/task. The lifecycle prefix (phase:*) is a
#   STATUS label, NOT an identity, so it is deliberately excluded (research R3).
jira_sink::_identity_prefixes() {
    local key p
    for key in repo_prefix spec_prefix phase_prefix task_prefix; do
        p="$(config::get "labels.${key}" 2>/dev/null || true)"
        [[ -n "$p" ]] && printf '%s\n' "$p"
    done
}

# jira_sink::is_bridge_owned <labels_json>
#   rc 0 (true) iff the issue carries at least one label whose value BEGINS WITH
#   a configured identity prefix; rc 1 otherwise. Pure/client-side — no read.
#   The sole ownership test (FR-002/FR-015): an issue with no identity-prefix
#   label is the operator's and is left untouched.
jira_sink::is_bridge_owned() {
    local labels_json="${1:-[]}"
    local prefixes_json
    prefixes_json="$(jira_sink::_identity_prefixes | jq -Rcs 'split("\n") | map(select(length > 0))')"
    [[ "$prefixes_json" == "[]" ]] && return 1
    if printf '%s' "$labels_json" | jq -e --argjson ps "$prefixes_json" '
        any((. // [])[]; . as $l | ($ps | any(. as $p | ($l | startswith($p)))))
    ' >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# jira_sink::enumerate_bridge_descendants <root_key>
#   Echo a JSON array of the BRIDGE-OWNED issues in the root's subtree —
#   `[{key, labels, parent, updated, status}]` — for the engine's orphan diff.
#   rc 3 on ANY unreadable read (fail-closed, contract I-2): a partial picture
#   could misclassify an orphan or miss an operator issue's identity.
#
#   Coverage:
#     * the root itself (the repo Epic) when bridge-owned;
#     * C1 (research R2 / analyze finding): the root's PARENT when bridge-owned —
#       a no-longer-wanted Initiative super-level sits ABOVE the root and a
#       downward walk would miss it;
#     * every bridge-owned descendant via the `parent = "<key>"` BFS.
jira_sink::enumerate_bridge_descendants() {
    local root_key="${1:-}"
    [[ -n "$root_key" ]] || { printf '[]\n'; return 0; }

    local acc='[]'
    declare -A _bd_seen=()

    # Root's own record (and its parent, for C1) come from a full read.
    local root_full
    root_full="$(query_issue_full "$root_key")" || return 3

    # C1 — inspect one level UP for an orphan super-level (e.g. a disabled
    # Initiative). Include it if bridge-owned; the diff drops it unless the
    # current mapping still projects its identity.
    local parent_key
    parent_key="$(printf '%s' "$root_full" | jq -r '.parent.key // ""' 2>/dev/null || printf '')"
    if [[ -n "$parent_key" ]]; then
        local pfull plabels
        pfull="$(query_issue_full "$parent_key")" || return 3
        plabels="$(printf '%s' "$pfull" | jq -c '.labels // []' 2>/dev/null || printf '[]')"
        if jira_sink::is_bridge_owned "$plabels"; then
            _bd_seen["$parent_key"]=1
            acc="$(jq -cn --argjson a "$acc" --arg k "$parent_key" --argjson l "$plabels" \
                '$a + [{key:$k, labels:$l, parent:null, updated:null, status:null}]')"
        fi
    fi

    # Seed the BFS with the root (recorded if bridge-owned).
    local root_labels
    root_labels="$(printf '%s' "$root_full" | jq -c '.labels // []' 2>/dev/null || printf '[]')"
    if jira_sink::is_bridge_owned "$root_labels"; then
        _bd_seen["$root_key"]=1
        local root_parent root_updated root_status
        root_parent="$(printf '%s' "$root_full" | jq -c '.parent.key // null')"
        root_updated="$(printf '%s' "$root_full" | jq -c '.updated // null')"
        root_status="$(printf '%s' "$root_full" | jq -c '.status.id // null')"
        acc="$(jq -cn --argjson a "$acc" --arg k "$root_key" --argjson l "$root_labels" \
            --argjson p "$root_parent" --argjson u "$root_updated" --argjson st "$root_status" \
            '$a + [{key:$k, labels:$l, parent:$p, updated:$u, status:$st}]')"
    fi

    local -a frontier=("$root_key")
    while (( ${#frontier[@]} )); do
        local -a next=()
        local k
        for k in "${frontier[@]}"; do
            local kids
            kids="$(jira_sink::_search_issues "parent = \"${k}\"")" || return 3
            local count i
            count="$(printf '%s' "$kids" | jq 'length' 2>/dev/null || printf '0')"
            for (( i = 0; i < count; i++ )); do
                local rec key labels
                rec="$(printf '%s' "$kids" | jq -c --argjson x "$i" '.[$x]')"
                key="$(printf '%s' "$rec" | jq -r '.key // ""')"
                [[ -n "$key" && -z "${_bd_seen[$key]:-}" ]] || continue
                labels="$(printf '%s' "$rec" | jq -c '.fields.labels // .labels // []')"
                if jira_sink::is_bridge_owned "$labels"; then
                    _bd_seen["$key"]=1
                    acc="$(jq -cn --argjson a "$acc" --argjson r "$rec" --argjson l "$labels" '
                        $a + [{ key:    ($r.key),
                                labels: $l,
                                parent: ($r.fields.parent.key // $r.parent.key // null),
                                updated:($r.fields.updated // $r.updated // null),
                                status: ($r.fields.status.id // $r.status.id // null) }]')"
                    next+=("$key")
                fi
            done
        done
        frontier=( ${next[@]+"${next[@]}"} )
    done

    printf '%s\n' "$acc"
    return 0
}

# jira_sink::_strip_identity_labels <key>
#   Remove every identity-prefix label from <key> and add a `speckit-archived`
#   marker, so an archived orphan LEAVES the bridge-owned set (idempotent: a
#   later re-mode no longer sees it). A PUT — honors DRY_RUN at the REST layer.
jira_sink::_strip_identity_labels() {
    local key="${1:-}"
    [[ -n "$key" ]] || return 1
    local fields
    fields="$(query_issue_full "$key")" || return 1
    local labels prefixes_json new
    labels="$(printf '%s' "$fields" | jq -c '.labels // []')"
    prefixes_json="$(jira_sink::_identity_prefixes | jq -Rcs 'split("\n") | map(select(length > 0))')"
    new="$(printf '%s' "$labels" | jq -c --argjson ps "$prefixes_json" '
        [ .[] | select(. as $l | (($ps | any(. as $p | ($l | startswith($p)))) | not)) ]
        + ["speckit-archived"] | unique')"
    jira_rest::put "issue/${key}" "$(jq -cn --argjson l "$new" '{fields:{labels:$l}}')" >/dev/null || return 1
    return 0
}

# jira_sink::prune_artifact <key>
#   Remove a bridge-owned orphan per the configured destruction model. Called
#   ONLY with a key that already passed is_bridge_owned (engine invariant I-1).
#     hard-delete (default) → DELETE /issue/<key>
#     archive               → transition to remode.archive_status + strip identity
#   rc 0 success; rc 1 a write failed (engine surfaces + continues, FR-009);
#   rc 2 a config error (archive without archive_status). DRY_RUN no-ops at the
#   REST layer (zero writes, contract I-3).
jira_sink::prune_artifact() {
    local key="${1:-}"
    [[ -n "$key" ]] || return 2
    local model
    model="${CONFIG_VALUES[remode.destruction]:-hard-delete}"
    case "$model" in
        hard-delete)
            if jira_rest::delete "issue/${key}" >/dev/null; then
                return 0
            fi
            jira_sink::_log "prune_artifact: hard-delete of ${key} failed (rc $?)"
            return 1
            ;;
        archive)
            local status_id
            status_id="${CONFIG_VALUES[remode.archive_status]:-}"
            if [[ -z "$status_id" ]]; then
                jira_sink::_log "prune_artifact: destruction=archive but remode.archive_status is unset. Set it to an archived-status id (Principle V), then re-run. Pruned nothing for ${key}."
                return 2
            fi
            if ! transition_issue "$key" "$status_id"; then
                jira_sink::_log "prune_artifact: archive transition of ${key} failed"
                return 1
            fi
            jira_sink::_strip_identity_labels "$key" || return 1
            return 0
            ;;
        *)
            jira_sink::_log "prune_artifact: unknown remode.destruction='${model}' (expected hard-delete|archive)"
            return 2
            ;;
    esac
}

# =============================================================================
# Consumer-side privacy guard — Jira-AWARE providers (feature 006).
#
# These are the ONLY vendor-aware pieces of the consumer-tree privacy guard; the
# scan mechanism (src/privacy_guard.sh) and orchestrator (reconcile::privacy_gate)
# stay vendor-neutral. Each function prints lines the neutral scanner consumes.
#
# PRIVACY IX / FR-009: every literal that could itself match a forbidden shape is
# FRAGMENTED across string concatenation so this source file never self-matches
# when the guard scans the bridge's own tree (the dogfood case, C-11). The
# Atlassian token prefix and the `.atlassian.net` site literal are each split.
# =============================================================================

# jira_sink::privacy_shapes
#   Print the five `severity<TAB>class<TAB>regex` shape rows, TIERED (FR-002):
#     block: api-token (the Atlassian Cloud token prefix), site (<name>.atlassian.net)
#     warn : email, cloudId-uuid, accountId (broad — advisory only)
#   Each regex is assembled from fragments so the literal never appears whole in
#   this source (FR-009). Emitted as extended-regex for `grep -E`.
jira_sink::privacy_shapes() {
    # BLOCK — vendor-unique, near-zero false positive.
    # Atlassian Cloud API-token prefix (v3). Fragmented: "ATA" + "TT".
    local _tok="ATA""TT"'[A-Za-z0-9_=-]{8,}'
    # Site host <name>.atlassian.net — the leading label EXCLUDES the IANA-
    # reserved documentation host `example` (RFC 2606), the Atlassian analogue
    # of the WARN-tolerated example.com email: a real tenant is never literally
    # `example.atlassian.net`, so excluding it keeps the bridge's own
    # placeholder fixtures clean (dogfood, C-11/SC-005) while every REAL tenant
    # host still fails closed. The match is boundary-anchored so `example` as a
    # sub-label (e.g. `example-corp`) still BLOCKs. The `atlassian` literal is
    # fragmented ("atlas"+"sian") so this source never self-matches (FR-009).
    local _lbl='[A-Za-z0-9-]'
    local _notexample="(${_lbl}{1,6}|${_lbl}{8,}|[^eE]${_lbl}{6}|${_lbl}[^xX]${_lbl}{5}|${_lbl}{2}[^aA]${_lbl}{4}|${_lbl}{3}[^mM]${_lbl}{3}|${_lbl}{4}[^pP]${_lbl}{2}|${_lbl}{5}[^lL]${_lbl}|${_lbl}{6}[^eE])"
    local _site="(^|[^A-Za-z0-9.@_-])${_notexample}"'\.atlas''sian\.net'
    printf 'block\tapi-token\t%s\n' "$_tok"
    printf 'block\tsite\t%s\n' "$_site"
    # WARN — broad, high false-positive: surface, never fail closed.
    printf 'warn\temail\t%s\n' '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
    printf 'warn\tcloudId-uuid\t%s\n' '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    # accountId: a bare 24-hex OR the NNNNNN:UUID form.
    printf 'warn\taccountId\t%s\n' '[0-9a-f]{24}|[0-9]{5,}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
}

# jira_sink::_privacy_authors_file
#   Resolve the authors-map path for the known-value pass without requiring
#   config to be loaded: PRIVACY_AUTHORS_FILE override (tests) → the config
#   getter when available → the documented default. Never echoes a value.
jira_sink::_privacy_authors_file() {
    if [[ -n "${PRIVACY_AUTHORS_FILE:-}" ]]; then
        printf '%s\n' "${PRIVACY_AUTHORS_FILE}"
        return 0
    fi
    if declare -F config::attribution_authors_file >/dev/null 2>&1; then
        config::attribution_authors_file
        return 0
    fi
    printf '%s\n' ".specify/extensions/jira/jira-authors.local.yml"
}

# jira_sink::privacy_known_values
#   Print `block<TAB>class<TAB>literal` for each PRESENT operator coordinate
#   (known values are always BLOCK — exact, zero false positive):
#     email     → $JIRA_EMAIL
#     site      → ${JIRA_BASE_URL#scheme} (host, trailing / stripped)
#     api-token → $JIRA_API_TOKEN
#     accountId → each non-null id parsed from the gitignored authors map
#   An absent value contributes NO line (the pass degrades to a no-op; the shape
#   pass still covers it). The literals are passed to the scanner as grep args
#   only — never written, never echoed elsewhere.
jira_sink::privacy_known_values() {
    [[ -n "${JIRA_EMAIL:-}" ]] && printf 'block\temail\t%s\n' "${JIRA_EMAIL}"
    if [[ -n "${JIRA_BASE_URL:-}" ]]; then
        local _host="${JIRA_BASE_URL#*://}"
        _host="${_host%%/*}"
        [[ -n "$_host" ]] && printf 'block\tsite\t%s\n' "$_host"
    fi
    [[ -n "${JIRA_API_TOKEN:-}" ]] && printf 'block\tapi-token\t%s\n' "${JIRA_API_TOKEN}"

    # accountIds from the gitignored authors map (absent ⇒ no rows). Reuse the
    # neutral loader; emit one block row per non-null accountId.
    local _authors_file _loaded
    _authors_file="$(jira_sink::_privacy_authors_file)"
    if [[ -n "$_authors_file" && -r "$_authors_file" ]]; then
        _loaded="$(jira_sink::_load_authors "$_authors_file")"
        local _id
        while IFS= read -r _id; do
            [[ -n "$_id" ]] && printf 'block\taccountId\t%s\n' "$_id"
        done < <(printf '%s' "$_loaded" | jq -r '.authors[].accountId // empty' 2>/dev/null || true)
    fi
    return 0
}

# jira_sink::privacy_ignore_targets
#   Print the consumer paths that MUST be gitignored-and-untracked: the active
#   resolved config path (RECONCILE_CONFIG_PATH, falling back to the default),
#   .env, and the authors map. The neutral scanner asserts each is untracked +
#   ignored (FR-004).
jira_sink::privacy_ignore_targets() {
    local _cfg="${RECONCILE_CONFIG_PATH:-${RECONCILE_CONFIG_PATH_DEFAULT:-.specify/extensions/jira/jira-config.yml}}"
    printf '%s\n' "$_cfg"
    printf '%s\n' ".env"
    printf '%s\n' "$(jira_sink::_privacy_authors_file)"
}
