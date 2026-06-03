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

## Dogfood findings (live Jira)

Findings from a LIVE-Jira dogfood of the bridge (mirroring this repo into a real
Jira project) — defects the mock never reproduced.

- ✅ **RESOLVED — `/search/jql` returned keyless/fieldless stubs → board
  duplicated every run** (fixed, commits `1e4cf30` + merge `fcc0bca`). The modern
  `GET /rest/api/3/search/jql` endpoint omits `.key` and `.fields` from each issue
  UNLESS a `fields` param is sent. The sink called it with `?jql=` only, so every
  idempotency lookup got unusable stubs, never matched existing issues, and
  RE-CREATED the whole board on each run. Fix: `jira_rest::search_jql` now requests
  `&fields=summary,status,updated,labels,parent&maxResults=100`. Locked with a
  deterministic unit test + a faithful keyless integration fixture.
  MOCK-FIDELITY LESSON: the curl-shim returned hand-written fixtures WITH
  keys+fields, so idempotency always passed in tests — the bug only existed against
  real Jira.
- ✅ **RESOLVED — empty ADF description churned every run** (fixed, commit
  `f9e876c`). Jira drops empty paragraphs on store: the empty Story body we POST as
  `{doc:[{paragraph,content:[]}]}` reads back as `{doc:content:[]}`. `_normalize_adf`
  only sorted/compacted, so desired != current forever → the spec issue's
  description was rewritten every reconcile (Updated:1; violates SC-017 zero-write
  idempotency). Fix: strip content-less paragraph nodes on both sides before
  comparing. +2 regression tests.
- ✅ **RESOLVED — one-time convergence update on a fresh create** (commit
  `3b5859d`). After a fresh mirror the FIRST re-run performed exactly one
  description write on the spec issue before reaching stable zero-churn. Root
  cause (pinned via diff-key logging): right after a fresh CREATE, Jira returns
  the issue description as `null` until a later write settles it, so an empty
  Story body read back `null` while desired normalized to `{doc:content:[]}` —
  one write per fresh create (SC-017 zero-write edge). Fix: `_normalize_adf` now
  collapses all semantically-empty forms (null, empty-content doc, empty-paragraph
  doc) to one canonical value; the first re-run after a fresh create is now
  zero-churn. Verified live (create → re-run = 0/0) + regression test. The mock
  never reproduced it (it returned a populated description) — another mock-fidelity
  gap the dogfood exposed.
- ⏭️ **DEFERRED to feature-002 — two design findings.** Issue types differ by board
  template (the mapping must DETECT available types, not assume Story); and status
  rollup so the Epic/Subtasks reflect completion. Both are being folded into
  `specs/002-configurable-mapping/DESIGN-DRAFT.md` — cross-reference it here.

## Engine debt — fix at the engine-extraction / hardening step

- 🔧 **`git_helpers::iso_to_epoch` misparses fractional-second ISO timestamps**
  on BSD/macOS (e.g. Jira's `…000+0000`). US3 worked around it SINK-SIDE by
  normalizing the timestamp before it reaches the engine, so drift/recency works
  today. The shared `git_helpers` (copied from spec-kit-linear) should be
  hardened at the source when the engine is extracted, so any producer feeding
  fractional-second timestamps parses robustly. Until then every sink must
  normalize — a latent trap (flagged by the US3 agent).
