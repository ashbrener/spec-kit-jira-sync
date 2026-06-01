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
# Stub helpers (still used by the US4 functions left as stubs)
# -----------------------------------------------------------------------------

# jira_sink::_unimplemented <fn>
#   Common diagnostic for an unimplemented WRITE. Logs to stderr (never
#   stdout — stdout is reserved for the id/JSON the engine reads on success)
#   and returns rc 1 (a clear non-zero, distinct from the read fail-closed
#   rc 3). Under DRY_RUN the caller short-circuits to a no-op success BEFORE
#   reaching here, so this only fires on a real (non-dry-run) write attempt.
jira_sink::_unimplemented() {
    local fn="${1:-jira_sink}"
    printf 'spec-kit-jira: sink: %s not implemented (US4)\n' "$fn" >&2
    return 1
}

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
    printf 'spec-kit-jira: sink: %s\n' "$*" >&2
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

# query_issue_blocks <issue_id>  — US4 stub (issue links).
#   Returns a JSON array of linked issue ids. Left fail-closed until US4 so the
#   block-link reconcile is never driven from an unimplemented read.
query_issue_blocks() {
    printf 'spec-kit-jira: sink: query_issue_blocks not implemented (US4) — failing closed (rc 3)\n' >&2
    return 3
}

# query_existing_comment_body <issue_id> <marker>  — US4 stub (comments).
query_existing_comment_body() {
    printf 'spec-kit-jira: sink: query_existing_comment_body not implemented (US4) — failing closed (rc 3)\n' >&2
    return 3
}

# _fetch_drift_issue_json <feature_number>
#   The drift gate's read. Locate the freshest spec Story (`speckit-spec:NNN`,
#   scoped to this repo's project) and echo `{status, labels, updated}`, or
#   EMPTY (rc 0) when the issue is genuinely ABSENT. rc 3 ONLY on a real
#   unreadable read.
#
#   A brand-new spec is ABSENT, not unreadable: the engine fails closed on
#   rc 3, so absent MUST be rc 0 + empty output or no spec would ever get
#   created on a fresh reconcile.
#
#   The engine's compute_drift consumes only `.updatedAt`, `.state.type`, and
#   the `phase:*` labels (Linear-shaped). For US1 the fresh path returns absent;
#   shaping the present-issue JSON into that schema is left minimal here (the
#   real drift recency mapping is US3).
_fetch_drift_issue_json() {
    local feature_number="${1:-}"
    local spec_prefix project label
    # Config getters halt (exit 2) on a missing key; in a fresh reconcile config
    # is already loaded + validated, so these resolve. Guard defensively so a
    # contract test that forgot to load config fails closed rather than exits.
    spec_prefix="$(config::get labels.spec_prefix 2>/dev/null || true)"
    project="$(config::get project_key 2>/dev/null || true)"
    if [[ -z "$spec_prefix" || -z "$project" ]]; then
        return 3
    fi
    label="${spec_prefix}${feature_number}"

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

    # Present: shape the freshest match into the engine's drift schema. The JQL
    # ordered newest-first, so element 0 is freshest.
    printf '%s' "$issues" | jq -c '
        .[0] as $i
        | {
            updated: ($i.fields.updated // null),
            status:  ($i.fields.status // null),
            labels:  ($i.fields.labels // [])
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

# mutate_comment_create <issue_id> <body_adf>  — US4 stub (comments).
mutate_comment_create() {
    if jira_sink::_dry_run; then
        jira_sink::_log "DRY-RUN mutate_comment_create (no-op)"
        printf '{"id":"dry-run-comment-id"}\n'
        return 0
    fi
    jira_sink::_unimplemented mutate_comment_create
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
    epic_type="$(config::get issue_types.epic)"
    label="${repo_prefix}${repo_slug}"

    # Find-or-create: an existing Epic with the repo label is reused (idempotent).
    local existing existing_key
    if existing="$(query_spec_issue "$label" "$project")"; then
        existing_key="$(printf '%s' "$existing" | jq -r '(.[0].key // "")' 2>/dev/null || printf '')"
        if [[ -n "$existing_key" && "$existing_key" != "null" ]]; then
            printf '%s\n' "$existing_key"
            return 0
        fi
    fi
    # (rc≠0 from query is unreadable; we still attempt a create below in US1's
    # fresh path — a present Epic would have been returned above.)

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
#   Compose a Story under the repo Epic from the workstate item: summary
#   `NNN — <title>`, description via adf::from_markdown(body), labels
#   (speckit-spec:NNN + phase:<state> + item labels), parent = epic key. Create
#   it (US1 fresh path) then set status via config::get_status_transition +
#   transition_issue. Echo the Story key.
#
#   The engine drives this from workstate::item_for_spec (see reconcile.sh
#   process_spec wiring), so the title/state/body/labels all come off the item.
sync_spec_issue() {
    local item_json="${1:-}" epic_key="${2:-}"

    local project story_type spec_prefix lifecycle_prefix
    project="$(config::get project_key)"
    story_type="$(config::get issue_types.story)"
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

    # Assemble the create payload. parent links the Story under the repo Epic.
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

    # Set the Story's status to match the lifecycle phase via a transition. A
    # missing transition is surfaced (Principle VIII), never fatal.
    local status_transition
    if status_transition="$(config::get_status_transition "$state" 2>/dev/null)"; then
        transition_issue "$key" "$status_transition" || \
            jira_sink::_log "sync_spec_issue: transition for ${key} (phase ${state}) did not apply"
    fi

    printf '%s\n' "$key"
}

# sync_task_phase_subissues <story_key> <item_json>
#   For each workstate child (a task phase), create a Subtask under the Story:
#   issue_types.subtask, parent = Story key, label task-phase:N, body rendered
#   as an ADF taskList from child.extensions.tasks (research D3). Echo the
#   `{phase_index → subtask_key}` map as JSON for downstream block reconcile.
sync_task_phase_subissues() {
    local story_key="${1:-}" item_json="${2:-}"

    local project subtask_type phase_prefix
    project="$(config::get project_key)"
    subtask_type="$(config::get issue_types.subtask)"
    phase_prefix="$(config::get labels.phase_prefix)"

    # Build the phase→subtask map incrementally. Children are processed in order.
    local map='{}'
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
        local fields
        fields="$(jq -cn \
            --arg project "$project" \
            --arg itype "$subtask_type" \
            --arg parent "$story_key" \
            --arg summary "$child_title" \
            --argjson description "$description" \
            --arg label "$phase_label" \
            '{fields:{
                project:     {key: $project},
                issuetype:   {id: $itype},
                parent:      {key: $parent},
                summary:     $summary,
                description: $description,
                labels:      [$label]
            }}')"

        local created key
        if ! created="$(mutate_issue_create "$fields")"; then
            jira_sink::_log "sync_task_phase_subissues: failed to create Subtask for phase ${phase_index}"
            continue
        fi
        key="$(printf '%s' "$created" | jq -r '.key // ""' 2>/dev/null || printf '')"
        if [[ -n "$key" && "$key" != "null" ]]; then
            map="$(printf '%s' "$map" | jq -c --arg p "$phase_index" --arg k "$key" '. + {($p): $k}')"
        fi
    done

    printf '%s\n' "$map"
}

# sync_inter_phase_blocks <phase_map> <deps>  — US4 stub (issue links).
sync_inter_phase_blocks() {
    if jira_sink::_dry_run; then
        jira_sink::_log "DRY-RUN sync_inter_phase_blocks (no-op)"
        return 0
    fi
    jira_sink::_unimplemented sync_inter_phase_blocks
}

# sync_clarify_comments <story_id> <spec_dir>  — US4 stub (comments).
sync_clarify_comments() {
    if jira_sink::_dry_run; then
        jira_sink::_log "DRY-RUN sync_clarify_comments (no-op)"
        return 0
    fi
    jira_sink::_unimplemented sync_clarify_comments
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
