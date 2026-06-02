# Review debt — codex findings from the US1 MVP review

Source: cross-model (codex / gpt-5.5) review of the US1 MVP create path
(base `12875f1`, `.reviews/2026-06-01-071442-001-core-bridge.json`). Recovered
after the session pivoted to the competitive handoff; tracked here so findings
survive compaction and get folded at the right phase. Status updated as folded.

## Resolved by US2 (idempotent re-run, `efe3af8`)
- ✅ **[P1] Reuse an existing Story before creating another** — `sync_spec_issue`
  is now query-first (create / diff-update / skip).
- ✅ **[P1] Reuse existing phase Subtasks** — same for `sync_task_phase_subissues`.
- ✅ **[P2] Reject search responses without an `issues` array** — `_search_issues`
  now returns rc 3 (unreadable) on a malformed/empty body.

## Resolved by the US2 review-fold (this commit)
- ✅ **[P1] `ensure_repo_epic`: stop creating an Epic after an unreadable lookup.**
  Now fails closed (rc 3) on a non-zero lookup; `process_spec` surfaces it as an
  error row + promotes exit 3 (observable; the per-spec loop ignores the return).

## Resolved by US3 (drift read, `2df14f6`)
- ✅ **[P1] `_fetch_drift_issue_json`: shape the drift read for the comparator** —
  the sink now emits the engine's contract (`updatedAt` ISO-normalized,
  `labels.nodes[].name`, `state.type`); drift now fires for Jira (us3_drift gate).

## Still routed to US5 (observable failure)
- ⏭️ **[P2] Propagate transition transport failures** (logged to stderr, not
  summary-visible).
- ⏭️ **[P2] Propagate failed Subtask creates** (`continue`d with a log, not
  surfaced in the summary).

## Engine debt — fix at the engine-extraction / hardening step
- 🔧 **`git_helpers::iso_to_epoch` misparses fractional-second ISO timestamps**
  on BSD/macOS (e.g. Jira's `…000+0000`). US3 worked around it SINK-SIDE by
  normalizing the timestamp before it reaches the engine, so drift/recency works
  today. The shared `git_helpers` (copied from spec-kit-linear) should be
  hardened at the source when the engine is extracted, so any producer feeding
  fractional-second timestamps parses robustly. Until then every sink must
  normalize — a latent trap (flagged by the US3 agent).
