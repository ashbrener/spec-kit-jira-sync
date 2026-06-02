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

## Resolved by the US2 review-fold (`27ef556`)

- ✅ **[P1] `ensure_repo_epic`: stop creating an Epic after an unreadable lookup.**
  Now fails closed (rc 3) on a non-zero lookup; `process_spec` surfaces it as an
  error row + promotes exit 3 (observable; the per-spec loop ignores the return).

## Resolved by US3 (drift read, `2df14f6`)

- ✅ **[P1] `_fetch_drift_issue_json`: shape the drift read for the comparator** —
  the sink now emits the engine's contract (`updatedAt` ISO-normalized,
  `labels.nodes[].name`, `state.type`); drift now fires for Jira (us3_drift gate).

## Resolved by US5-impl (observable failure + US4 hardening)

- ✅ **[P2] Propagate transition transport failures** — a real transition POST
  failure now sets `JIRA_SINK_SPEC_TRANSITION_FAILED`; the engine surfaces a
  warned row + promotes the exit (the benign "no transition available" rc-0 case
  stays silent). Covered by `us5_failclosed.bats` case (5).
- ✅ **[P2] Propagate failed Subtask creates** — a failed Subtask create/update
  now records a `failed` per-phase disposition; the engine surfaces an error row
  + promotes the exit. Covered by `us5_failclosed.bats` case (6).
- ✅ **[US4 P1] process_spec swallowed US4 rc via `|| true`** — the
  `sync_inter_phase_blocks` / `sync_clarify_comments` calls now capture each rc;
  a failure adds an error row + promotes (3 for an unreadable rc 3, else ≥1)
  without aborting the spec.
- ✅ **[US4 P2] comment pagination** — `query_existing_comment_body` walks all
  comment pages, so a marker beyond page 1 is found (no duplicate comment).
- ✅ **[US4 P2] link dedup by (rel,target)** — `query_issue_blocks` retains link
  TYPE + direction; `sync_inter_phase_blocks` dedups by (type,target) so an
  unrelated link type no longer wrongly skips the dep, and updates the baseline
  mid-run so duplicate dep bullets POST `/issueLink` only once per run.

## Deferred (acceptable — converges on a 2nd reconcile)

- ⏭️ **[P2] Forward dependency in the same `--all` sweep** — spec A depends on
  spec B whose Story is created LATER in the same run, so B's key is absent when
  A's links reconcile → the link is skipped this run. The engine is idempotent /
  re-runnable, so the next reconcile creates it. Left as an explicit code comment
  in `sync_inter_phase_blocks` (the `target_key` absent branch).

## Engine debt — fix at the engine-extraction / hardening step

- 🔧 **`git_helpers::iso_to_epoch` misparses fractional-second ISO timestamps**
  on BSD/macOS (e.g. Jira's `…000+0000`). US3 worked around it SINK-SIDE by
  normalizing the timestamp before it reaches the engine, so drift/recency works
  today. The shared `git_helpers` (copied from spec-kit-linear) should be
  hardened at the source when the engine is extracted, so any producer feeding
  fractional-second timestamps parses robustly. Until then every sink must
  normalize — a latent trap (flagged by the US3 agent).
