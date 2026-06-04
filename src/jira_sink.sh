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
    local resp
    if ! resp="$(jira_rest::post "issue" "$fields_json")"; then
        jira_sink::_log "mutate_issue_create: POST /issue failed (rc $?)"
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
        jira_sink::_log "mutate_issue_update: PUT /issue/${key} failed (rc $?)"
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
# Orchestrators  — engine-sink-interface.md §Orchestrators
#
# The engine calls these once per spec. In US1 they own the find-or-CREATE
# path; the idempotent diff/update against the reads above is US2.
# =============================================================================

# ensure_repo_epic <repo_slug>
#   Find the per-repo Epic by `speckit-repo:<slug>`; if absent, create one
#   (issue_types.epic from config, summary from slug, the repo label) and
#   return its key (research D5: the Epic is a sink projection of
#   workstate.source.repo, not a workstate item).
ensure_repo_epic() {
    local repo_slug="${1:-}"
    local repo_prefix project epic_type label
    repo_prefix="$(config::get labels.repo_prefix)"
    project="$(config::get project_key)"
    # T013: the repo level's issue type is resolved through the mapping layer
    # (default repo→Epic→issue_types.epic). Byte-for-byte unchanged in the
    # default; an operator's mapping (US2+) re-targets it without touching this.
    epic_type="$(jira_sink::_level_issue_type_id repo)"
    label="${repo_prefix}${repo_slug}"

    # Find-or-create: an existing Epic with the repo label is reused (idempotent).
    # An UNREADABLE lookup (rc 3) MUST fail closed — we cannot prove the Epic is
    # absent, so creating one would risk a duplicate (codex review P1 / FR-013 /
    # Principle IV). Only a clean rc-0 "no match" is a genuine absence → create.
    local existing existing_key lookup_rc=0
    existing="$(query_spec_issue "$label" "$project")" || lookup_rc=$?
    if (( lookup_rc != 0 )); then
        jira_sink::_log "ensure_repo_epic: repo Epic lookup unreadable (rc ${lookup_rc}); failing closed (no create)"
        return 3
    fi
    existing_key="$(printf '%s' "$existing" | jq -r '(.[0].key // "")' 2>/dev/null || printf '')"
    if [[ -n "$existing_key" && "$existing_key" != "null" ]]; then
        printf '%s\n' "$existing_key"
        return 0
    fi
    # rc 0 + no match = genuine absence → create below.

    local fields
    fields="$(jq -cn \
        --arg project "$project" \
        --arg itype "$epic_type" \
        --arg summary "Specs — ${repo_slug}" \
        --arg label "$label" \
        '{fields:{
            project:   {key: $project},
            issuetype: {id: $itype},
            summary:   $summary,
            labels:    [$label]
        }}')"

    local created key
    if ! created="$(mutate_issue_create "$fields")"; then
        jira_sink::_log "ensure_repo_epic: failed to create Epic for ${repo_slug}"
        return 1
    fi
    key="$(printf '%s' "$created" | jq -r '.key // ""' 2>/dev/null || printf '')"
    if [[ -z "$key" || "$key" == "null" ]]; then
        jira_sink::_log "ensure_repo_epic: created Epic has no key"
        return 1
    fi
    printf '%s\n' "$key"
}

# sync_spec_issue <item_json> <epic_key>
#   Idempotently mirror the spec as a Story under the repo Epic. Compose the
#   desired Story from the workstate item: summary `NNN — <title>`, description
#   via adf::from_markdown(body), labels (speckit-spec:NNN + phase:<state> +
#   item labels), parent = epic key. Then:
#     * ABSENT (query_spec_issue → []) → CREATE the Story (the US1 fresh path)
#       and set status via config::get_status_transition + transition_issue.
#     * PRESENT → compute the desired-vs-current DIFF (summary, description,
#       labels, parent). Only CHANGED fields enter the diff; an all-unchanged
#       spec yields `{}` → mutate_issue_update no-ops → ZERO writes (FR-008,
#       SC-017). Then reconcile STATUS: transition ONLY when the current status
#       differs from the desired one (so an operator's manual status change in
#       Jira is restored, US2 acceptance #2 — but a matching status fires no
#       transition).
#   Echoes the Story key. Records the create/update/skip verdict on
#   JIRA_SINK_SPEC_DISPOSITION for the engine's summary.
#
#   The engine drives this from workstate::item_for_spec (see reconcile.sh
#   process_spec wiring), so the title/state/body/labels all come off the item.
sync_spec_issue() {
    local item_json="${1:-}" epic_key="${2:-}"

    local project story_type spec_prefix lifecycle_prefix
    project="$(config::get project_key)"
    # T013: the spec level's issue type is resolved through the mapping layer
    # (default spec→Story→issue_types.story). Unchanged in the default path.
    story_type="$(jira_sink::_level_issue_type_id spec)"
    spec_prefix="$(config::get labels.spec_prefix)"
    lifecycle_prefix="$(config::get labels.lifecycle_prefix)"

    # Pull the fields the Story needs off the workstate item.
    local feature_number title state body
    feature_number="$(printf '%s' "$item_json" | jq -r '.id | split("-")[0]')"
    title="$(printf '%s' "$item_json" | jq -r '.title // ""')"
    state="$(printf '%s' "$item_json" | jq -r '.state // ""')"
    body="$(printf '%s' "$item_json" | jq -r '.body // ""')"

    local summary="${feature_number} — ${title}"
    local spec_label="${spec_prefix}${feature_number}"
    local phase_label="${lifecycle_prefix}${state}"

    # Labels = speckit-spec:NNN + phase:<state> + the item's own labels (deduped).
    local labels_json
    labels_json="$(printf '%s' "$item_json" | jq -c \
        --arg spec "$spec_label" \
        --arg phase "$phase_label" \
        '([$spec, $phase] + (.labels // [])) | unique')"

    # Description: render the spec body Markdown to ADF (empty body still yields
    # a valid single-paragraph doc).
    local description
    description="$(adf::from_markdown "$body")"

    # The desired status id the lifecycle phase maps to (vendor lever). The
    # config getter may hand us `<status-id>\t<transition-id>`; the status id
    # is the part before the tab. Empty when the phase has no status mapping.
    local status_transition="" desired_status_id=""
    if status_transition="$(config::get_status_transition "$state" 2>/dev/null)"; then
        desired_status_id="${status_transition%%$'\t'*}"
    fi

    # --- Find-or-create-or-update ----------------------------------------
    # query_spec_issue fails closed (rc 3) on an unreadable read; propagate
    # that so the engine's fail-closed contract holds (no blind create).
    local existing existing_key
    if ! existing="$(query_spec_issue "$spec_label" "$project")"; then
        jira_sink::_log "sync_spec_issue: spec ${feature_number} lookup unreadable; failing closed (rc 3)"
        return 3
    fi
    existing_key="$(printf '%s' "$existing" | jq -r '(.[0].key // "")' 2>/dev/null || printf '')"

    if [[ -z "$existing_key" || "$existing_key" == "null" ]]; then
        # ABSENT → create (US1 fresh path), then set status.
        local fields
        fields="$(jq -cn \
            --arg project "$project" \
            --arg itype "$story_type" \
            --arg parent "$epic_key" \
            --arg summary "$summary" \
            --argjson description "$description" \
            --argjson labels "$labels_json" \
            '{fields:(
                {
                    project:     {key: $project},
                    issuetype:   {id: $itype},
                    summary:     $summary,
                    description: $description,
                    labels:      $labels
                }
                + (if ($parent | length) > 0 then {parent: {key: $parent}} else {} end)
            )}')"

        local created key
        if ! created="$(mutate_issue_create "$fields")"; then
            jira_sink::_log "sync_spec_issue: failed to create Story for spec ${feature_number}"
            return 1
        fi
        key="$(printf '%s' "$created" | jq -r '.key // ""' 2>/dev/null || printf '')"
        if [[ -z "$key" || "$key" == "null" ]]; then
            jira_sink::_log "sync_spec_issue: created Story has no key"
            return 1
        fi

        # Set the Story's status to match the lifecycle phase via a transition.
        # A real transport failure (transition_issue rc≠0) is surfaced via the
        # observable-failure channel so the engine warns + promotes the exit; the
        # benign "no transition available" case returns rc 0 and is silent (US5).
        if [[ -n "$status_transition" ]]; then
            if ! transition_issue "$key" "$status_transition"; then
                JIRA_SINK_SPEC_TRANSITION_FAILED=1
                jira_sink::_log "sync_spec_issue: transition for ${key} (phase ${state}) did not apply"
            fi
        fi

        JIRA_SINK_SPEC_DISPOSITION="created"
        printf '%s\n' "$key"
        return 0
    fi

    # PRESENT → diff the desired against the current and update only the delta.
    # Read the full issue (the JQL search omits description) for the diff.
    local current
    if ! current="$(query_issue_full "$existing_key")"; then
        jira_sink::_log "sync_spec_issue: spec ${feature_number} (${existing_key}) read unreadable; failing closed (rc 3)"
        return 3
    fi

    local cur_summary cur_description cur_labels cur_parent cur_status_id
    cur_summary="$(printf '%s' "$current" | jq -r '.summary // ""' 2>/dev/null || printf '')"
    cur_description="$(printf '%s' "$current" | jq -c '.description // null' 2>/dev/null || printf 'null')"
    cur_labels="$(printf '%s' "$current" | jq -c '.labels // []' 2>/dev/null || printf '[]')"
    cur_parent="$(printf '%s' "$current" | jq -r '.parent.key // ""' 2>/dev/null || printf '')"
    cur_status_id="$(printf '%s' "$current" | jq -r '.status.id // ""' 2>/dev/null || printf '')"

    # Build the diff field-by-field; unchanged fields MUST NOT appear (so an
    # all-unchanged spec yields `{}` and mutate_issue_update no-ops).
    local diff='{}'
    if [[ "$summary" != "$cur_summary" ]]; then
        diff="$(printf '%s' "$diff" | jq -c --arg s "$summary" '. + {summary: $s}')"
    fi
    # ADF descriptions are key-order-insensitive — normalize both sides before
    # comparing so a semantically-identical body produces no diff entry.
    local desired_desc_norm current_desc_norm
    desired_desc_norm="$(jira_sink::_normalize_adf "$description")"
    current_desc_norm="$(jira_sink::_normalize_adf "$cur_description")"
    if [[ "$desired_desc_norm" != "$current_desc_norm" ]]; then
        diff="$(printf '%s' "$diff" | jq -c --argjson d "$description" '. + {description: $d}')"
    fi
    if ! jira_sink::_labels_equal "$labels_json" "$cur_labels"; then
        diff="$(printf '%s' "$diff" | jq -c --argjson l "$labels_json" '. + {labels: $l}')"
    fi
    # Re-parent only when an Epic is known AND the current parent differs.
    if [[ -n "$epic_key" && "$epic_key" != "$cur_parent" ]]; then
        diff="$(printf '%s' "$diff" | jq -c --arg p "$epic_key" '. + {parent: {key: $p}}')"
    fi

    # mutate_issue_update no-ops on an empty diff (idempotency), so an
    # all-unchanged spec performs ZERO field writes here.
    local diff_payload
    diff_payload="$(printf '%s' "$diff" | jq -c '{fields: .}')"
    local wrote_update=0
    if [[ "$diff" != "{}" ]]; then
        if ! mutate_issue_update "$existing_key" "$diff_payload"; then
            jira_sink::_log "sync_spec_issue: update for ${existing_key} (spec ${feature_number}) failed"
            return 1
        fi
        wrote_update=1
    fi

    # Reconcile STATUS: transition ONLY when the current status differs from the
    # desired one. A matching status fires NO transition (zero churn); a
    # mismatch (e.g. an operator hand-edited the Story status in Jira) restores
    # the disk-derived status (US2 acceptance #2).
    local wrote_transition=0
    if [[ -n "$desired_status_id" && "$desired_status_id" != "$cur_status_id" ]]; then
        if transition_issue "$existing_key" "$status_transition"; then
            wrote_transition=1
        else
            # A real transport failure (rc≠0) is surfaced; "no transition
            # available" is rc 0 and never reaches here (US5 observable failure).
            JIRA_SINK_SPEC_TRANSITION_FAILED=1
            jira_sink::_log "sync_spec_issue: transition for ${existing_key} (phase ${state}) did not apply"
        fi
    fi

    if (( wrote_update == 1 || wrote_transition == 1 )); then
        JIRA_SINK_SPEC_DISPOSITION="updated"
    else
        JIRA_SINK_SPEC_DISPOSITION="skipped"
    fi
    printf '%s\n' "$existing_key"
    return 0
}

# sync_task_phase_subissues <story_key> <item_json>
#   Idempotently mirror each workstate child (a task phase) as a Subtask under
#   the Story. Per phase: query_subissue_for_phase(story, task-phase:N).
#     * ABSENT → CREATE the Subtask (issue_types.subtask, parent = Story key,
#       label task-phase:N, body an ADF taskList from child.extensions.tasks).
#     * PRESENT → DIFF the desired summary/description/labels against the
#       current and update only the delta; an unchanged phase yields `{}` →
#       no write (zero churn). ADF bodies are normalized before comparing.
#   Echoes the `{phase_index → subtask_key}` map for downstream block reconcile,
#   and records the per-phase verdict on JIRA_SINK_SUBISSUE_DISPOSITIONS.
sync_task_phase_subissues() {
    local story_key="${1:-}" item_json="${2:-}"

    local project subtask_type phase_prefix
    project="$(config::get project_key)"
    # T013: the phase level's issue type is resolved through the mapping layer
    # (default phase→Subtask→issue_types.subtask). Unchanged in the default path.
    # The task level (default task→checklist) renders in-body below — the
    # checklist sentinel projects no standalone issue (FR-001).
    subtask_type="$(jira_sink::_level_issue_type_id phase)"
    phase_prefix="$(config::get labels.phase_prefix)"

    # Build the phase→subtask map + the per-phase disposition map incrementally.
    local map='{}'
    local dispositions='{}'
    local children_count i
    children_count="$(printf '%s' "$item_json" | jq -r '(.children // []) | length' 2>/dev/null || printf '0')"

    for (( i = 0; i < children_count; i++ )); do
        local child child_id child_title phase_index tasks_json body description
        child="$(printf '%s' "$item_json" | jq -c --argjson n "$i" '.children[$n]')"
        child_id="$(printf '%s' "$child" | jq -r '.id // ""')"
        child_title="$(printf '%s' "$child" | jq -r '.title // ""')"
        # Phase index = the trailing integer of the child id (NNN-phase-N).
        phase_index="${child_id##*-}"
        [[ "$phase_index" =~ ^[0-9]+$ ]] || phase_index="$(( i + 1 ))"

        tasks_json="$(printf '%s' "$child" | jq -c '(.extensions.tasks) // []')"
        body="$(adf::task_list "$tasks_json")"
        # Wrap the taskList in a doc so it is a valid issue description.
        description="$(jq -cn --argjson tl "$body" '{version:1,type:"doc",content:[$tl]}')"

        local phase_label="${phase_prefix}${phase_index}"
        local desired_labels_json
        desired_labels_json="$(jq -cn --arg label "$phase_label" '[$label]')"

        # Find-or-create-or-update the Subtask for this phase.
        local existing existing_key key disposition
        if ! existing="$(query_subissue_for_phase "$story_key" "$phase_label")"; then
            jira_sink::_log "sync_task_phase_subissues: phase ${phase_index} lookup unreadable; failing closed (rc 3)"
            return 3
        fi
        existing_key="$(printf '%s' "$existing" | jq -r '(.[0].key // "")' 2>/dev/null || printf '')"

        if [[ -z "$existing_key" || "$existing_key" == "null" ]]; then
            # ABSENT → create.
            local fields
            fields="$(jq -cn \
                --arg project "$project" \
                --arg itype "$subtask_type" \
                --arg parent "$story_key" \
                --arg summary "$child_title" \
                --argjson description "$description" \
                --argjson labels "$desired_labels_json" \
                '{fields:{
                    project:     {key: $project},
                    issuetype:   {id: $itype},
                    parent:      {key: $parent},
                    summary:     $summary,
                    description: $description,
                    labels:      $labels
                }}')"

            local created
            if ! created="$(mutate_issue_create "$fields")"; then
                jira_sink::_log "sync_task_phase_subissues: failed to create Subtask for phase ${phase_index}"
                # The phase is un-mirrored — record a `failed` verdict so the
                # engine surfaces an error row (US5: no silent success). We keep
                # processing the remaining phases (per-phase isolation, FR-014).
                dispositions="$(printf '%s' "$dispositions" | jq -c --arg p "$phase_index" '. + {($p): "failed"}')"
                continue
            fi
            key="$(printf '%s' "$created" | jq -r '.key // ""' 2>/dev/null || printf '')"
            disposition="created"
        else
            # PRESENT → diff desired vs current; update only the delta.
            key="$existing_key"
            local current
            if ! current="$(query_issue_full "$existing_key")"; then
                jira_sink::_log "sync_task_phase_subissues: phase ${phase_index} (${existing_key}) read unreadable; failing closed (rc 3)"
                return 3
            fi
            local cur_summary cur_description cur_labels
            cur_summary="$(printf '%s' "$current" | jq -r '.summary // ""' 2>/dev/null || printf '')"
            cur_description="$(printf '%s' "$current" | jq -c '.description // null' 2>/dev/null || printf 'null')"
            cur_labels="$(printf '%s' "$current" | jq -c '.labels // []' 2>/dev/null || printf '[]')"

            local diff='{}'
            if [[ "$child_title" != "$cur_summary" ]]; then
                diff="$(printf '%s' "$diff" | jq -c --arg s "$child_title" '. + {summary: $s}')"
            fi
            local desired_desc_norm current_desc_norm
            desired_desc_norm="$(jira_sink::_normalize_adf "$description")"
            current_desc_norm="$(jira_sink::_normalize_adf "$cur_description")"
            if [[ "$desired_desc_norm" != "$current_desc_norm" ]]; then
                diff="$(printf '%s' "$diff" | jq -c --argjson d "$description" '. + {description: $d}')"
            fi
            if ! jira_sink::_labels_equal "$desired_labels_json" "$cur_labels"; then
                diff="$(printf '%s' "$diff" | jq -c --argjson l "$desired_labels_json" '. + {labels: $l}')"
            fi

            if [[ "$diff" != "{}" ]]; then
                local diff_payload
                diff_payload="$(printf '%s' "$diff" | jq -c '{fields: .}')"
                if ! mutate_issue_update "$existing_key" "$diff_payload"; then
                    jira_sink::_log "sync_task_phase_subissues: update for ${existing_key} (phase ${phase_index}) failed"
                    # Surface the un-applied phase as an error (US5: no silent
                    # success); keep processing remaining phases (FR-014).
                    dispositions="$(printf '%s' "$dispositions" | jq -c --arg p "$phase_index" '. + {($p): "failed"}')"
                    continue
                fi
                disposition="updated"
            else
                disposition="skipped"
            fi
        fi

        if [[ -n "$key" && "$key" != "null" ]]; then
            map="$(printf '%s' "$map" | jq -c --arg p "$phase_index" --arg k "$key" '. + {($p): $k}')"
            dispositions="$(printf '%s' "$dispositions" | jq -c --arg p "$phase_index" --arg d "$disposition" '. + {($p): $d}')"
        fi
    done

    JIRA_SINK_SUBISSUE_DISPOSITIONS="$dispositions"
    printf '%s\n' "$map"
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

# sync_level_artifact <level> <identity_label> <parent_id> <input_json>
#   Mapping-driven create/update of the level's CONFIGURED issue type under
#   <parent_id>, matched/updated by <identity_label> (idempotent, FR-009).
#   <input_json> is `{summary, body}` (the sink-neutral level payload). Echoes
#   `{id,key}` of the issue (empty for a checklist sentinel). Records the verdict
#   on JIRA_SINK_LEVEL_DISPOSITION. rc 3 on an unreadable lookup (fail-closed).
sync_level_artifact() {
    local level="${1:-}" identity_label="${2:-}" parent_id="${3:-}" input_json="${4:-}"

    JIRA_SINK_LEVEL_DISPOSITION=""

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

    # Compose the desired issue from the neutral level input.
    local summary body description
    summary="$(printf '%s' "$input_json" | jq -r '.summary // ""' 2>/dev/null || printf '')"
    body="$(printf '%s' "$input_json" | jq -r '.body // ""' 2>/dev/null || printf '')"
    description="$(adf::from_markdown "$body")"

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

    # Whether the configured relationship sets a native parent link on create.
    local set_parent=0
    case "$relationship" in
        parent|Epic-link) [[ -n "$parent_id" ]] && set_parent=1 ;;
    esac

    # --- Find-or-create-or-update by identity label ----------------------
    # query_spec_issue is a generic label+project JQL search; reuse it to match
    # the identity. rc 3 (unreadable) fails closed — a blind create could dupe.
    local existing existing_key
    if ! existing="$(query_spec_issue "$identity_label" "$project")"; then
        jira_sink::_log "sync_level_artifact: ${level} (${identity_label}) lookup unreadable; failing closed (rc 3)"
        return 3
    fi
    existing_key="$(printf '%s' "$existing" | jq -r '(.[0].key // "")' 2>/dev/null || printf '')"

    if [[ -z "$existing_key" || "$existing_key" == "null" ]]; then
        # ABSENT → create the configured issue type.
        local fields
        fields="$(jq -cn \
            --arg project "$project" \
            --arg itype "$itype" \
            --arg parent "$parent_id" \
            --arg summary "$summary" \
            --argjson description "$description" \
            --argjson labels "$labels_json" \
            --argjson set_parent "$set_parent" \
            '{fields:(
                {
                    project:     {key: $project},
                    issuetype:   {id: $itype},
                    summary:     $summary,
                    description: $description,
                    labels:      $labels
                }
                + (if ($set_parent == 1) then {parent: {key: $parent}} else {} end)
            )}')"

        local created key
        if ! created="$(mutate_issue_create "$fields")"; then
            jira_sink::_log "sync_level_artifact: failed to create ${artifact} for ${level} (${identity_label})"
            return 1
        fi
        key="$(printf '%s' "$created" | jq -r '.key // ""' 2>/dev/null || printf '')"
        if [[ -z "$key" || "$key" == "null" ]]; then
            jira_sink::_log "sync_level_artifact: created ${artifact} has no key"
            return 1
        fi
        JIRA_SINK_LEVEL_DISPOSITION="created"
        printf '%s\n' "$created"
        return 0
    fi

    # PRESENT → diff the desired against the current; update only the delta so an
    # unchanged level performs ZERO writes (idempotency, FR-009/SC-017).
    local current
    if ! current="$(query_issue_full "$existing_key")"; then
        jira_sink::_log "sync_level_artifact: ${level} (${existing_key}) read unreadable; failing closed (rc 3)"
        return 3
    fi
    local cur_summary cur_description cur_labels cur_parent
    cur_summary="$(printf '%s' "$current" | jq -r '.summary // ""' 2>/dev/null || printf '')"
    cur_description="$(printf '%s' "$current" | jq -c '.description // null' 2>/dev/null || printf 'null')"
    cur_labels="$(printf '%s' "$current" | jq -c '.labels // []' 2>/dev/null || printf '[]')"
    cur_parent="$(printf '%s' "$current" | jq -r '.parent.key // ""' 2>/dev/null || printf '')"
    local cur_id
    cur_id="$(printf '%s' "$existing" | jq -r '(.[0].id // "")' 2>/dev/null || printf '')"

    local diff='{}'
    if [[ "$summary" != "$cur_summary" ]]; then
        diff="$(printf '%s' "$diff" | jq -c --arg s "$summary" '. + {summary: $s}')"
    fi
    local desired_desc_norm current_desc_norm
    desired_desc_norm="$(jira_sink::_normalize_adf "$description")"
    current_desc_norm="$(jira_sink::_normalize_adf "$cur_description")"
    if [[ "$desired_desc_norm" != "$current_desc_norm" ]]; then
        diff="$(printf '%s' "$diff" | jq -c --argjson d "$description" '. + {description: $d}')"
    fi
    if ! jira_sink::_labels_equal "$labels_json" "$cur_labels"; then
        diff="$(printf '%s' "$diff" | jq -c --argjson l "$labels_json" '. + {labels: $l}')"
    fi
    if (( set_parent == 1 )) && [[ "$parent_id" != "$cur_parent" ]]; then
        diff="$(printf '%s' "$diff" | jq -c --arg p "$parent_id" '. + {parent: {key: $p}}')"
    fi

    if [[ "$diff" != "{}" ]]; then
        local diff_payload
        diff_payload="$(printf '%s' "$diff" | jq -c '{fields: .}')"
        if ! mutate_issue_update "$existing_key" "$diff_payload"; then
            jira_sink::_log "sync_level_artifact: update for ${existing_key} (${level}) failed"
            return 1
        fi
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
