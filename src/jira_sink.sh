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

# sync_level_artifact <level> <identity_label> <parent_id> <input_json>
#   Mapping-driven create/update of the level's CONFIGURED issue type under
#   <parent_id>, matched/updated by <identity_label> (idempotent, FR-009).
#   <input_json> is `{summary, body}` (the sink-neutral level payload). Echoes
#   `{id,key}` of the issue (empty for a checklist sentinel). Records the verdict
#   on JIRA_SINK_LEVEL_DISPOSITION. rc 3 on an unreadable lookup (fail-closed).
sync_level_artifact() {
    local level="${1:-}" identity_label="${2:-}" parent_id="${3:-}" input_json="${4:-}" find_only="${5:-0}" reconcile_parent="${6:-1}"

    JIRA_SINK_LEVEL_DISPOSITION=""
    JIRA_SINK_LEVEL_TRANSITION_FAILED=0

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
            --argjson omit_desc "$omit_description" \
            '{fields:(
                {
                    project:     {key: $project},
                    issuetype:   {id: $itype},
                    summary:     $summary,
                    labels:      $labels
                }
                + (if ($omit_desc == 1) then {} else {description: $description} end)
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
