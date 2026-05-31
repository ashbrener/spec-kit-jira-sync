---
description: "Task list for 001-core-bridge"
---

# Tasks: Core Bridge — Mirror spec-kit Specs into Jira

**Input**: Design documents from `/specs/001-core-bridge/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: INCLUDED — the constitution makes tests the gate (Principle VIII) and
the brief mandates porting the bats suite. Test tasks precede the implementation
they cover within each phase.

**Organization**: by user story (US1–US5 from spec.md) so each is an
independently testable increment. Engine files are COPIED unchanged from the
sibling `~/Code/AI/speckit-linear/src/` with an origin-noting header (PLAN.md §3,
§11) — never rewritten.

## Format: `[ID] [P?] [Story?] Description with file path`

- **[P]**: parallelizable (different file, no dependency on an incomplete task)
- **[USx]**: the user story a task serves (story phases only)

---

## Phase 1: Setup

- [ ] T001 Create source/test skeleton: `src/`, `tests/unit/`, `tests/integration/`, `tests/helpers/`, `tests/fixtures/{specs,workstate,jira_responses}/` at repo root
- [ ] T002 [P] Add a CI-parity runner `scripts/check.sh` (shellcheck `--severity=style`, yamllint `-d relaxed`, markdownlint-cli2, bats) mirroring `.github/workflows/ci.yml`

---

## Phase 2: Foundational (blocking prerequisites for ALL stories)

**Engine copy (unchanged, origin-headed — PLAN.md §3):**

- [ ] T003 [P] Copy `~/Code/AI/speckit-linear/src/git_helpers.sh` → `src/git_helpers.sh` with an origin header (`# ORIGIN: copied unchanged from spec-kit-linear/src/git_helpers.sh @ <sha> — shared engine, pending extraction`)
- [ ] T004 [P] Copy `~/Code/AI/speckit-linear/src/summary.sh` → `src/summary.sh` with the same origin header
- [ ] T005 [P] Copy `~/Code/AI/speckit-linear/src/parser.sh` → `src/parser.sh` with origin header (reused reader; adapted to emit workstate in T007)
- [ ] T006 Extract + copy the ENGINE half of `~/Code/AI/speckit-linear/src/reconcile.sh` → `src/reconcile.sh` with origin header — keep `compute_drift`, `_phase_ordinal`, `_drift_verdict_field`, `_drift_disposition`, `_drift_prompt`, recency gate, lifecycle aggregation, `promote_exit`, arg/spec enumeration; replace every writer call with a sourced sink-interface call (stub for now)

**Adapted config + workstate contract:**

- [ ] T007 Implement `src/workstate.sh` — build schema-valid `workstate` items from `src/parser.sh` output (spec→item kind=spec, phase→children kind=task, tasks under `children[].extensions.tasks`); jq structural checks per `contracts/workstate.md`
- [ ] T008 Adapt `src/config.sh` to load/validate the gitignored `.specify/extensions/jira/jira-config.yml` per `data-model.md` §2 (project key, issue-type ids, `phase_status` map, label prefixes); a missing/invalid binding is a project-level config error (exit 2)
- [ ] T009 [P] Add the workstate schema-validation test gate `tests/unit/workstate_schema.bats` (validate emitted fixtures against `~/Code/AI/workstate-schema/schema/workstate.schema.json` via `python3 -m jsonschema`)

**Sink infrastructure (REST client, ADF, mock):**

- [ ] T010 Implement `src/jira_rest.sh` — thin curl+jq client: Basic auth from `.env`, `GET/POST/PUT`, JQL search; fail-closed read returns rc 3; per `contracts/jira-rest.md`
- [ ] T011 [P] Implement `src/adf.sh` — minimal Markdown→ADF (paragraphs, headings, bullet/ordered lists, `taskList`, code, links) + body truncation
- [ ] T012 Build the curl-shim test harness `tests/helpers/jira-shim.bash` — shadow `curl`, return fixture JSON keyed by method+URL, record requests for assertions (mirrors sibling; research D10)
- [ ] T013 [P] Seed base fixtures in `tests/fixtures/jira_responses/` (`myself_ok.json`, `search_absent.json`, `issue_create_ok.json`, `transitions.json`, `401.json`, `429.json`) and `tests/fixtures/specs/` (a placeholder multi-phase spec)

---

## Phase 3: User Story 1 — Mirror a project's specs into Jira (P1) 🎯 MVP

**Goal**: One reconcile turns a repo's specs into an Epic + Stories + per-phase Subtasks.
**Independent test**: Run reconcile over the mock; assert an Epic, a Story per spec (correct status + labels), and a Subtask per phase with a taskList.

- [ ] T014 [P] [US1] Unit test `tests/unit/epic.bats` — `ensure_repo_epic` finds existing Epic by `speckit-repo:<slug>` else creates one (curl-shim)
- [ ] T015 [P] [US1] Unit test `tests/unit/sync_spec_issue.bats` — Story created under Epic with summary, ADF description, `speckit-spec:NNN` + `phase:*` labels, and status set via transition
- [ ] T016 [P] [US1] Unit test `tests/unit/subtasks.bats` — `sync_task_phase_subissues` creates one Subtask per phase with an ADF `taskList` matching `tasks.md`
- [ ] T017 [US1] Implement `mutate_issue_create` / `mutate_issue_update` in `src/jira_sink.sh` (POST/PUT `/issue`; skip update when diff is `{}`)
- [ ] T018 [US1] Implement `config::get_status_transition` (in `src/config.sh`) + `transition_issue` (in `src/jira_sink.sh`) — resolve target status id, POST the matching transition (global-transition fast path, research D6)
- [ ] T019 [US1] Implement `resolve_labels` in `src/jira_sink.sh` (passthrough names; auto-apply `speckit-spec:*`/`task-phase:*`/`speckit-repo:*`)
- [ ] T020 [US1] Implement `ensure_repo_epic` in `src/jira_sink.sh` (find/create Epic by repo label; return id)
- [ ] T021 [US1] Implement `sync_spec_issue` in `src/jira_sink.sh` (Story under Epic; description via `src/adf.sh`; labels; status via `transition_issue`)
- [ ] T022 [US1] Implement `sync_task_phase_subissues` in `src/jira_sink.sh` (Subtasks + ADF taskList; parent linkage)
- [ ] T023 [US1] Wire the create path in `src/reconcile.sh` orchestration (enumerate specs → workstate → ensure_repo_epic → sync_spec_issue → sync_task_phase_subissues → summary)
- [ ] T024 [US1] Integration test `tests/integration/us1_fresh.bats` — fresh reconcile over the mock creates Epic + Stories + Subtasks; summary reports correct created counts

**Checkpoint**: US1 delivers the MVP — a working fresh mirror.

---

## Phase 4: User Story 2 — Re-run safely with zero churn (P2)

**Goal**: Re-running against unchanged input performs zero writes.
**Independent test**: Run twice; assert the second run writes nothing and reuses the Epic.

- [ ] T025 [P] [US2] Unit test `tests/unit/queries.bats` — `query_spec_issue` / `query_subissue_for_phase` / `query_existing_comment_body` JQL lookups (curl-shim)
- [ ] T026 [US2] Implement `query_spec_issue`, `query_subissue_for_phase`, `query_existing_comment_body` in `src/jira_sink.sh` (JQL by label/parent, newest-first)
- [ ] T027 [US2] Implement idempotent diffing in the `sync_*` paths (compute current-vs-desired; emit empty update `{}` → skip) in `src/jira_sink.sh`
- [ ] T028 [US2] Integration test `tests/integration/us2_idempotent.bats` — second unchanged run = 0 created / 0 updated, Epic reused; a manually-edited status is corrected back to disk

---

## Phase 5: User Story 3 — Drift-aware write authority (P2)

**Goal**: When Jira is ahead of disk, surface a warning and honor proceed/abort; never silently clobber.
**Independent test**: Make the mock's issue phase/recency ahead of disk; assert a drift WARNING and that `--on-drift` is honored.

- [ ] T029 [P] [US3] Unit test `tests/unit/drift.bats` — `_fetch_drift_issue_json` returns status/updated/labels (rc 3 on unreadable) and feeds the engine's `compute_drift`
- [ ] T030 [US3] Implement `_fetch_drift_issue_json` in `src/jira_sink.sh` (read-only; rc 3 when Jira unreadable — the fail-closed signal)
- [ ] T031 [US3] Wire the engine's `compute_drift` + `_drift_disposition` + `--on-drift=proceed|abort` into `src/reconcile.sh` (per-spec, before write)
- [ ] T032 [US3] Emit named backward-drift WARNING rows (spec, disk phase, Jira phase, firing signal) via `src/summary.sh` in `src/reconcile.sh`
- [ ] T033 [US3] Integration test `tests/integration/us3_drift.bats` — phase-ahead drift, recency drift, and abort-leaves-Jira-unchanged

---

## Phase 6: User Story 4 — Lifecycle and content updates propagate (P3)

**Goal**: Spec evolution (phase, tasks, clarifications, deps) reflects in Jira; untouched fields unchanged.
**Independent test**: Mutate a mirrored spec on disk; assert only the changed attributes update.

- [ ] T034 [P] [US4] Unit test `tests/unit/comments_links.bats` — `sync_clarify_comments` dedup by marker; `sync_inter_phase_blocks` issue links
- [ ] T035 [US4] Implement `mutate_comment_create` + `sync_clarify_comments` (ADF body, marker-prefix dedup, at-most-once) in `src/jira_sink.sh`
- [ ] T036 [US4] Implement `query_issue_blocks` + `sync_inter_phase_blocks` (POST `/issueLink`; reconcile, no duplicates) in `src/jira_sink.sh`
- [ ] T037 [US4] Implement update-on-change in `src/reconcile.sh` (status transition on phase change; new Subtask on new phase; checklist refresh)
- [ ] T038 [US4] Integration test `tests/integration/us4_updates.bats` — phase change transitions, new-phase Subtask added, clarification comment not duplicated on re-run

---

## Phase 7: User Story 5 — Fail-closed and always observable (P3)

**Goal**: Unreadable Jira / exhausted retries → no writes, clear error, non-zero exit; every run emits a structured summary.
**Independent test**: Simulate unreadable Jira and sustained 429; assert zero writes for the affected spec and accurate summary + exit code.

- [ ] T039 [P] [US5] Unit test `tests/unit/failclosed.bats` — rc 3 read → no write + error row; 429 exhaustion → fail closed; missing `spec.md` → warning, others still mirrored
- [ ] T040 [US5] Implement fail-closed propagation in `src/reconcile.sh` (rc 3 from any read aborts that spec's write, records an error row, continues other specs)
- [ ] T041 [US5] Implement bounded 429/5xx backoff (honor `Retry-After`, jittered exponential, capped, default 5 tries → fail closed) in `src/jira_rest.sh`
- [ ] T042 [US5] Wire the structured summary + monotonic exit-code escalation (`promote_exit`: 0<1<3<2) in `src/reconcile.sh` + `src/summary.sh`
- [ ] T043 [US5] Integration test `tests/integration/us5_failclosed.bats` — unreadable Jira (no writes), 429 exhaustion (fail closed), missing `spec.md` (warn + continue)

---

## Phase 8: Polish & Cross-Cutting

- [ ] T044 [P] `--dry-run` preview parity test `tests/unit/dryrun.bats` — preview reports the same actions a live run performs, writes nothing
- [ ] T045 [P] shellcheck `--severity=style` clean across all `src/*.sh`; fix findings
- [ ] T046 [P] Extend `tests/fixtures/` privacy review; confirm `tests/unit/no-real-identifiers.bats` stays green over new fixtures (placeholders only)
- [ ] T047 [P] Author `config-template.yml` (committed placeholder mirror of `jira-config.yml`) and a `README.md` (placeholders only)
- [ ] T048 [P] Update `CHANGELOG.md` (Unreleased: core bridge — parser→workstate→jira-sink reconcile)
- [ ] T049 Run the exact CI locally via `scripts/check.sh` (shellcheck + yamllint + markdownlint + bats unit) and fix to green before pushing

---

## Dependencies & completion order

- **Setup (T001–T002)** → **Foundational (T003–T013)** block everything.
- **US1 (T014–T024)** depends only on Foundational → it is the MVP and ships alone.
- **US2 (T025–T028)** depends on US1 (needs created issues to re-find).
- **US3 (T029–T033)** depends on Foundational + US1's read path; independent of US2.
- **US4 (T034–T038)** depends on US1 (Story/Subtasks exist) + US2's query layer.
- **US5 (T039–T043)** depends on Foundational + US1 write path; cross-cuts all.
- **Polish (T044–T049)** last.

Story order: US1 → (US2 ∥ US3) → US4 → US5.

## Parallel execution examples

- Foundational: T003, T004, T005 (distinct engine files) run together; T009, T011, T013 are `[P]`.
- US1 tests: T014, T015, T016 (separate test files) run together before implementing T017–T023.
- Each story's `[P]` unit test can be written in parallel with peers; implementation tasks in the same `src/jira_sink.sh` are sequential (same file).

## Implementation strategy

- **MVP = Phase 1 + 2 + US1** (T001–T024): a working fresh mirror, demoable and
  testable on its own.
- Then layer US2 (idempotency) and US3 (drift) — the trust properties — followed
  by US4 (updates) and US5 (fail-closed/observability).
- Tests precede implementation within each phase; the curl-shim keeps every unit
  and integration test offline. Run `scripts/check.sh` before every push.
