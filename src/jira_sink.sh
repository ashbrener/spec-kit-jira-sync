#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# src/jira_sink.sh — the Jira WRITER half of the reconcile bridge (the SINK).
#
# ORIGIN: STUB. The vendor-neutral engine (src/reconcile.sh, adapted-from
#   spec-kit-linear @ 7dbe6bd) calls this fixed interface; the sibling proved
#   the seam against Linear's GraphQL writer. This file replaces that writer
#   with Jira REST implementations — but as a STUB to be implemented in US1.
#   Every function the engine calls is defined here with the names + return
#   shapes from specs/001-core-bridge/contracts/engine-sink-interface.md, so
#   the engine is sourceable and the pure drift machinery is testable TODAY.
#
# Stub contract (until US1 lands the real REST impls):
#   * WRITES (mutate_*, transition_issue, sync_* orchestrators, ensure_repo_epic,
#     resolve_labels) log "not implemented (US1)" to stderr and return a clear
#     non-zero rc (1) — EXCEPT under DRY_RUN, where a write is a no-op SUCCESS
#     (rc 0) so a --dry-run engine pass converges without touching Jira.
#   * READS (_fetch_drift_issue_json, query_*) return the FAIL-CLOSED rc 3 so
#     the engine degrades safely: the drift gate treats rc 3 as "tracker
#     unreadable" and, under --on-drift=abort, refuses the write rather than
#     risk clobbering a state it never read (engine-sink-interface.md §Read,
#     research D1/D6). They emit no stdout (the engine treats empty as absent
#     only on rc 0; rc 3 short-circuits before that).
#
# Sourcing: jira_rest.sh (auth + retry/backoff transport) and adf.sh
# (Markdown→ADF body rendering) are pulled in here so the real US1 impls drop
# straight in without touching the engine. The `# shellcheck source=`
# directives document the API surface for IDE-side shellcheck.
#
# PRIVACY (Principle IX): this stub holds NO real Jira coordinates. The
# project key, issue-type ids, status/transition ids, and label prefixes all
# come from the gitignored jira-config.yml via config::*; the base URL + token
# live only in the gitignored .env and are read solely by jira_rest.sh.
# =============================================================================

# NOTE: no `set -euo pipefail` here — this module is SOURCED by reconcile.sh
# (which already sets the shell options) and by the contract bats suites. A
# nested `set -e` would change the caller's option state on source.

# shellcheck source=./jira_rest.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jira_rest.sh"
# shellcheck source=./adf.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/adf.sh"

# -----------------------------------------------------------------------------
# Stub helpers
# -----------------------------------------------------------------------------

# jira_sink::_unimplemented <fn>
#   Common diagnostic for an unimplemented WRITE. Logs to stderr (never
#   stdout — stdout is reserved for the id/JSON the engine reads on success)
#   and returns rc 1 (a clear non-zero, distinct from the read fail-closed
#   rc 3). Under DRY_RUN the caller short-circuits to a no-op success BEFORE
#   reaching here, so this only fires on a real (non-dry-run) write attempt.
jira_sink::_unimplemented() {
    local fn="${1:-jira_sink}"
    printf 'spec-kit-jira: sink: %s not implemented (US1)\n' "$fn" >&2
    return 1
}

# jira_sink::_unreadable <fn>
#   Common diagnostic for an unimplemented READ. Returns the FAIL-CLOSED
#   rc 3 (engine-sink-interface.md: "rc 3 = Jira unreadable") so the engine's
#   drift gate degrades safely instead of treating the stub's silence as
#   "issue absent". No stdout.
jira_sink::_unreadable() {
    local fn="${1:-jira_sink}"
    printf 'spec-kit-jira: sink: %s not implemented (US1) — failing closed (rc 3)\n' "$fn" >&2
    return 3
}

# jira_sink::_dry_run
#   Return 0 iff the engine is in --dry-run mode. Reads DRY_RUN (the sink's
#   contract name, kept in sync with ARG_DRY_RUN by the engine's parse_args).
jira_sink::_dry_run() {
    [[ "${DRY_RUN:-0}" == "1" ]]
}

# =============================================================================
# Read (idempotency + drift)  — engine-sink-interface.md §Read
#
# All reads fail closed (rc 3) until US1 lands the JQL/REST queries. rc 3
# propagates through the engine's drift gate; a non-fail-closed silence here
# would let an --on-drift=abort run overwrite a state we never proved isn't
# ahead (research D1, the #02 hardening the engine preserves).
# =============================================================================

# query_spec_issue <spec_label> <project>
#   Returns a JSON array of matching Stories, newest first
#   `[{id,key,status,updated,labels}]`. rc≠0 (3) on unreadable.
#   US1: JQL `labels = "<spec_label>" AND project = "<project>"`, ordered by
#   updated DESC (research D4).
query_spec_issue() {
    jira_sink::_unreadable query_spec_issue
}

# query_subissue_for_phase <parent_id> <phase_label>
#   Returns a JSON array of Subtasks. rc≠0 (3) on unreadable.
#   US1: JQL `parent = <parent_id> AND labels = "<phase_label>"`.
query_subissue_for_phase() {
    jira_sink::_unreadable query_subissue_for_phase
}

# query_issue_blocks <issue_id>
#   Returns a JSON array of linked issue ids (the current `blocks` set).
#   rc≠0 (3) on unreadable. US1: read issuelinks, filter type=Blocks outward.
query_issue_blocks() {
    jira_sink::_unreadable query_issue_blocks
}

# query_existing_comment_body <issue_id> <marker>
#   Returns `{id,body}` of the first comment whose body carries <marker>, or
#   empty. rc≠0 (3) on unreadable. US1: GET comments, match the marker prefix.
query_existing_comment_body() {
    jira_sink::_unreadable query_existing_comment_body
}

# _fetch_drift_issue_json <feature_number>
#   The drift gate's read. Returns `{updated, status, labels}` (the freshest
#   `speckit-spec:NNN` match, scoped to this repo's project) or empty when the
#   issue is genuinely absent; **rc 3 = Jira unreadable** (transport / errors
#   / malformed) so the engine fails closed under --on-drift=abort.
#
#   The engine's compute_drift consumes ONLY `updatedAt`, `state.type`, and
#   the `phase:*` labels, so the US1 impl must shape its JSON to those fields
#   (the engine is tracker-neutral about the rest). Until then: fail closed.
_fetch_drift_issue_json() {
    jira_sink::_unreadable _fetch_drift_issue_json
}

# =============================================================================
# Write (mutations)  — engine-sink-interface.md §Write
#
# All writes honour DRY_RUN with a no-op success; otherwise they log
# "not implemented (US1)" and return rc 1.
# =============================================================================

# mutate_issue_create <input_json>
#   Returns `{id,key}` of the created issue. US1: POST /rest/api/3/issue.
mutate_issue_create() {
    if jira_sink::_dry_run; then
        printf 'spec-kit-jira: sink: DRY-RUN mutate_issue_create (no-op)\n' >&2
        # Synthesize a stable placeholder so downstream engine logic that
        # depends on the returned id keeps working in dry-run (mirrors the
        # sibling's dry-run create shape).
        printf '{"id":"dry-run-issue-id","key":"DRY-0"}\n'
        return 0
    fi
    jira_sink::_unimplemented mutate_issue_create
}

# mutate_issue_update <issue_id> <input_json>
#   ok; **skip when input is `{}`** (idempotency — the empty-diff no-op the
#   engine's probe produces). US1: PUT /rest/api/3/issue/<id>.
mutate_issue_update() {
    local issue_id="${1:-}" input_json="${2:-}"
    : "${issue_id:-}"
    # Idempotency: an empty diff is a no-op success regardless of dry-run, so
    # the engine's zero-churn reconcile stays a verifiable observation.
    if [[ "$input_json" == "{}" ]] \
        || printf '%s' "$input_json" | jq -e 'length == 0' >/dev/null 2>&1; then
        return 0
    fi
    if jira_sink::_dry_run; then
        printf 'spec-kit-jira: sink: DRY-RUN mutate_issue_update %s (no-op)\n' "$issue_id" >&2
        return 0
    fi
    jira_sink::_unimplemented mutate_issue_update
}

# mutate_comment_create <issue_id> <body_adf>
#   Returns `{id}`. US1: POST /rest/api/3/issue/<id>/comment with an ADF body.
mutate_comment_create() {
    if jira_sink::_dry_run; then
        printf 'spec-kit-jira: sink: DRY-RUN mutate_comment_create (no-op)\n' >&2
        printf '{"id":"dry-run-comment-id"}\n'
        return 0
    fi
    jira_sink::_unimplemented mutate_comment_create
}

# transition_issue <issue_id> <target_status_id>
#   ok; POSTs the transition whose `to` = target (research D6: Jira has no
#   "set status" write — transitions are the only path; the observed board
#   uses global transitions so a single POST suffices). US1: GET transitions,
#   select to==target, POST /rest/api/3/issue/<id>/transitions.
transition_issue() {
    local issue_id="${1:-}"
    if jira_sink::_dry_run; then
        printf 'spec-kit-jira: sink: DRY-RUN transition_issue %s (no-op)\n' "$issue_id" >&2
        return 0
    fi
    jira_sink::_unimplemented transition_issue
}

# =============================================================================
# Orchestrators  — engine-sink-interface.md §Orchestrators
#
# The engine calls these once per spec; each owns its find-or-create/update +
# idempotency diff against the reads above, wiring the mutate_*/transition_*
# primitives. Stubbed until US1.
# =============================================================================

# ensure_repo_epic <repo_slug>
#   Find/create the per-repo Epic by `speckit-repo:<slug>`; return its id
#   (research D5: the Epic is a sink projection of workstate.source.repo, not
#   a workstate item). US1: JQL by repo label, create if absent.
ensure_repo_epic() {
    if jira_sink::_dry_run; then
        printf 'spec-kit-jira: sink: DRY-RUN ensure_repo_epic (no-op)\n' >&2
        printf 'dry-run-epic-id\n'
        return 0
    fi
    jira_sink::_unimplemented ensure_repo_epic
}

# sync_spec_issue <feature_number> <short_name> <spec_dir> <phase> <epic_id>
#   Create/update the Story under the Epic; return Story id. US1: drives the
#   bridge-owned ADF body + status transition, idempotent via the
#   speckit-spec:NNN label.
sync_spec_issue() {
    if jira_sink::_dry_run; then
        printf 'spec-kit-jira: sink: DRY-RUN sync_spec_issue (no-op)\n' >&2
        printf 'dry-run-story-id\n'
        return 0
    fi
    jira_sink::_unimplemented sync_spec_issue
}

# sync_task_phase_subissues <story_id> <feature_number> <spec_dir>
#   Create/update phase Subtasks; return `{phase→subtask_id}`. US1: one
#   Subtask per `## Phase N`, body rendered as an ADF taskList (research D3).
sync_task_phase_subissues() {
    if jira_sink::_dry_run; then
        printf 'spec-kit-jira: sink: DRY-RUN sync_task_phase_subissues (no-op)\n' >&2
        printf '{}\n'
        return 0
    fi
    jira_sink::_unimplemented sync_task_phase_subissues
}

# sync_inter_phase_blocks <phase_map> <deps>
#   Reconcile blocking links between phase Subtasks. <phase_map> is the
#   JSON object from sync_task_phase_subissues; <deps> is the engine's
#   newline-separated `<from>\t<to>` edge list. US1: idempotent
#   get-blocks → diff → create issuelink delta.
sync_inter_phase_blocks() {
    if jira_sink::_dry_run; then
        printf 'spec-kit-jira: sink: DRY-RUN sync_inter_phase_blocks (no-op)\n' >&2
        return 0
    fi
    jira_sink::_unimplemented sync_inter_phase_blocks
}

# sync_clarify_comments <story_id> <spec_dir>
#   Post session comments at-most-once (idempotent via a leading marker).
#   US1: per `### Session YYYY-MM-DD`, query_existing_comment_body then
#   mutate_comment_create only on a miss.
sync_clarify_comments() {
    if jira_sink::_dry_run; then
        printf 'spec-kit-jira: sink: DRY-RUN sync_clarify_comments (no-op)\n' >&2
        return 0
    fi
    jira_sink::_unimplemented sync_clarify_comments
}

# =============================================================================
# Label resolution  — engine-sink-interface.md §Label resolution
# =============================================================================

# resolve_labels <names…>
#   Echo the same names — Jira labels are plain strings; near-passthrough (no
#   UUID indirection, unlike the sibling's Linear labelId resolver). Policy:
#   `speckit-spec:*`/`task-phase:*`/`speckit-repo:*` are auto-applied;
#   `phase:*` is applied from the phase map. This is the ONE interface
#   function that is genuinely complete at stub time — Jira's free-string
#   labels need no resolution — so it is a real passthrough, not a stub error.
#   Echoes a JSON array of the (non-empty) names for a clean engine boundary.
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
