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

## Routed forward
- ⏭️ **[P1] `_fetch_drift_issue_json`: shape the drift read for the comparator**
  (status / phase labels / updated, exactly as `compute_drift` expects). → **US3**
  (drift read + recency) — that phase wires the real drift read.
- ⏭️ **[P2] Propagate transition transport failures** (currently logged to stderr,
  not summary-visible). → **US5** (observable failure).
- ⏭️ **[P2] Propagate failed Subtask creates** (currently `continue`d with a log,
  not surfaced in the summary). → **US5** (observable failure).
