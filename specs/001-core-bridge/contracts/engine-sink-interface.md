# Contract — engine ↔ sink interface

The vendor-neutral engine (copied) calls these; the fresh `jira_sink.sh` (and
`config.sh`) MUST provide them with these signatures and return shapes. This is
the seam the sibling proved; re-implementing it against REST is the bulk of this
feature. Keeping the names/shapes identical is what leaves the engine untouched.

## Read (idempotency + drift)

| Function | Returns | Fail-closed |
|----------|---------|-------------|
| `query_spec_issue <spec_label> <project>` | JSON array of matching Stories, newest first `[{id,key,status,updated,labels}]` | rc≠0 on unreadable |
| `query_subissue_for_phase <parent_id> <phase_label>` | JSON array of Subtasks | rc≠0 |
| `query_issue_blocks <issue_id>` | JSON array of linked issue ids | rc≠0 |
| `query_existing_comment_body <issue_id> <marker>` | `{id,body}` or empty | rc≠0 |
| `_fetch_drift_issue_json <feature_number>` | `{updated, status, labels}` or empty; **rc 3 = Jira unreadable** | yes (drift gate) |

## Write (mutations; honor `--dry-run`)

| Function | Returns |
|----------|---------|
| `mutate_issue_create <input_json>` | `{id,key}` of created issue |
| `mutate_issue_update <issue_id> <input_json>` | ok; **skip when input is `{}`** (idempotency) |
| `mutate_comment_create <issue_id> <body_adf>` | `{id}` |
| `transition_issue <issue_id> <target_status_id>` | ok; POSTs the transition whose `to` = target |

## Orchestrators (engine calls these per spec)

| Function | Role |
|----------|------|
| `ensure_repo_epic <repo_slug>` | find/create the per-repo Epic by `speckit-repo:<slug>`; return its id |
| `sync_spec_issue <feature_number> <short_name> <spec_dir> <phase> <epic_id>` | create/update the Story under the Epic; return Story id |
| `sync_task_phase_subissues <story_id> <feature_number> <spec_dir>` | create/update phase Subtasks; return `{phase→subtask_id}` |
| `sync_inter_phase_blocks <phase_map> <spec_dir>` | reconcile blocking links |
| `sync_clarify_comments <story_id> <spec_dir>` | post session comments at-most-once |

## Vendor lever (the only Jira-specific config call)

| Function | Returns |
|----------|---------|
| `config::get_status_transition <phase_token>` | target Jira `status-id` (+ optional explicit transition id) for that lifecycle phase |

(The sibling's `config::get_workflow_state_uuid`; renamed for Jira semantics —
status set via transition, not a stateId field.)

## Label resolution

| Function | Returns |
|----------|---------|
| `resolve_labels <names…>` | the same names — Jira labels are plain strings; near-passthrough (no UUID indirection). Policy: `speckit-spec:*`/`task-phase:*`/`speckit-repo:*` auto-applied; `phase:*` applied from the phase map. |

## Contract tests

Each function gets a bats unit test against the curl-shim: correct
request shape, idempotent no-op on unchanged input, and rc 3 propagation on an
unreadable response.
