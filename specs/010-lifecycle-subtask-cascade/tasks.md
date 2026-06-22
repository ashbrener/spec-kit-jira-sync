# Tasks: Lifecycle→Subtask Board Cascade + Phase-Parser Broadening

**Feature**: 010-lifecycle-subtask-cascade | **Branch**: `010-lifecycle-subtask-cascade`

**Input**: plan.md, research.md (R1–R8), data-model.md (VR-1..VR-9),
contracts/cascade-parser.md (C-1..C-12), spec.md (FR-001..FR-011, SC-001..SC-006)

**Strategy**: Strict TDD. Board-correctness bug fix in the engine/parser; the sink
is **reused unchanged** (`rollup::transition_if_changed` / `rollup::done_status_id`).
Parser tests are pure filesystem; cascade tests use the `tests/helpers/jira-shim.bash`
curl-shim. **Lock the numeric-colon regression anchor (C-9) first** so the parser
broadening can't churn existing specs. No new sink fn, no schema/mapping change, no
new exit code (reuse 1/3), no constitution amendment (plan ruled).

**Conventions**: `[P]` = parallelizable (disjoint files). Tests precede impl.
Tick `[ ]`→`[X]` as completed.

---

## Phase 1: Setup

- [ ] T001 [P] Create `tests/unit/phase_parser.bats` (new) sourcing `src/parser.sh`, with a helper writing a small `tasks.md` into a `mktemp -d` (dir named `010-<slug>` so `parser::short_name` resolves). Case bodies land in Phase 2.
- [ ] T002 [P] Create `tests/unit/cascade_phases.bats` (new) sourcing the engine + `tests/helpers/jira-shim.bash`, with a helper to stand up a minimal merged-spec fixture + shimmed Subtask status reads/transitions. Case bodies land in Phase 4.

---

## Phase 2: Parser broadening (US2 foundational — regression anchor FIRST)

**Bug 2 fix. The numeric-colon byte-identical anchor is written and locked before
any broadening (FR-007/SC-005).**

- [ ] T003 [US2] Test (C-9, regression anchor) in `tests/unit/phase_parser.bats`: assert `parser::task_phases` on `## Phase 1: Setup` + `## Phase 10: Polish` emits exactly `1\tSetup` / `10\tPolish` — capture the **pre-feature** awk output inline as the oracle and assert equality. Run/observe it pass against the CURRENT parser **before** T005 changes it (locks zero-churn).
- [ ] T004 [US2] Test (C-8) in `tests/unit/phase_parser.bats`: `## Phase A — Foundations` ⇒ `A\tFoundations`; `## Phase 1 — Setup` (em-dash, no colon) ⇒ `1\tSetup`; `## Phaser: x` ⇒ NOT matched (no phase); a mixed file (`## Phase 1: …` + `## Phase A — …`) ⇒ both detected. (Fails until T005.)
- [ ] T005 [US2] Broaden the three phase-header awk sites in `src/parser.sh` — `parser::task_phases` (~204), `parser::tasks_in_phase` (~249), the unphased-task scan (~365): match a `## Phase` prefix + index `[0-9A-Za-z]+` + a boundary (separator/space/EOL — so `## Phaser` does not match); capture `idx` = the leading `[0-9A-Za-z]+` string token; derive `name` from the remainder via `sub(/^[^A-Za-z0-9]+/, "", name)` (strips spaces + `:`/`-`/en-dash/em-dash bytes, locale-stable — no embedded multibyte char) then trailing-trim. `## Phase N: Name` stays byte-identical (T003 green).
- [ ] T006 [US2] Test (C-10) in `tests/unit/cascade_phases.bats` or a parser-integration bats: a letter-indexed phase (`## Phase A — …`) ⇒ its tasks attach to phase `A` and its Subtask is matched by the `task-phase:A` identity (exercises the string-keyed extraction). (Fails until T007.)
- [ ] T007 [US2] String-key the four numeric-only child-id extractions `[match("[0-9]+$")?][0].string` at `src/reconcile.sh:1237, 1248, 1309, 2656` to the phase-index token (generalize `[0-9]+$` → `[0-9A-Za-z]+$`, or parse the exact `task-phase:`/child-id suffix), so letter-indexed phases join their tasks + Subtask consistently at all four sites + the phase_map join.

**Checkpoint**: `bats tests/unit/phase_parser.bats` green — numeric-colon byte-identical
(T003), letter/em-dash detected (T004), letter phases attach (T006).

---

## Phase 3: Cascade — the neutral pass (US1 foundational)

- [ ] T008 [US1] Implement `reconcile::cascade_phases <item_json> <phase_map_json> <feature_number>` in `src/reconcile.sh` (**vendor-neutral** — no Atlassian vocabulary; reuse the sink): for each `<phase_index>\t<subtask_key>` in `phase_map`, read current status via `query_issue_full`; unreadable ⇒ `summary::add error` + `reconcile::promote_exit 3` + **return non-zero (abort — no partial cascade)**; else `done=$(rollup::done_status_id)`; if `done` empty ⇒ `summary::add warn "spec N: merged status unmapped — phase Subtasks not cascaded"` + return 0 (fail-soft); else `prior=(current==done?complete:partial)`; `rollup::transition_if_changed key "complete" prior` → `transitioned` ⇒ `summary::add updated "spec N: phase <idx> Subtask cascaded to done (merged)"`; rc 1 ⇒ `summary::add error` + `promote_exit 1`. (May share the per-subtask loop with `rollup_phases`; `cascade` forces `computed=complete`.)

---

## Phase 4: Cascade dispatch + behavior (US1)

**Bug 1 fix. The terminal cascade is always-on; non-terminal behavior is unchanged.**

- [ ] T009 [US1] Replace the `status_rollup`-gated `reconcile::rollup_phases` calls at `src/reconcile.sh:2316` and `:2455` with the phase-status **dispatch**: `if [[ "$lifecycle_phase" == ready_to_merge || "$lifecycle_phase" == merged ]]` ⇒ `reconcile::cascade_phases …` (ALWAYS, ungated); `elif reconcile::status_rollup_enabled` ⇒ `reconcile::rollup_phases …` (today's ratio path); `else` nothing. Confirm `lifecycle_phase` is in scope at both sites (it is threaded through the per-spec flow).
- [ ] T010 [US1] Test (C-1) in `tests/unit/cascade_phases.bats` (curl-shim): a `merged` spec with `status_rollup` OFF (default) ⇒ every phase Subtask is transitioned to the merged status; assert the shim recorded a transition POST per Subtask and **no** transition for unrelated issues.
- [ ] T011 [US1] Test (C-2): re-run the same merged board (Subtasks already at the merged status in the shim) ⇒ **zero** transitions (idempotent — `transition_if_changed` noop).
- [ ] T012 [US1] Test (C-5): a `ready_to_merge` spec ⇒ same cascade as `merged` (children → merged status).
- [ ] T013 [US1] Test (C-6): a Subtask status read returns unreadable mid-cascade ⇒ exit 3, and **no** transition was POSTed for any Subtask of that spec (no partial cascade).
- [ ] T014 [US1] Test (C-7): `phase_status.merged` unmapped (config without it) ⇒ a `warn` row, the run continues (exit 0/non-3), no transition attempted.

**Checkpoint**: `bats tests/unit/cascade_phases.bats` — C-1/C-2/C-5/C-6/C-7 green.

---

## Phase 5: Non-terminal unchanged (US3)

- [ ] T015 [US3] Test (C-3): a non-terminal spec (`implementing`) with `status_rollup` OFF ⇒ **no** subtask-status transition (byte-identical to today — the dispatch's `else` branch).
- [ ] T016 [US3] Test (C-4): a non-terminal spec with `status_rollup` ON ⇒ the ratio rollup runs exactly as today (existing `rollup_phases` behavior unchanged).

**Checkpoint**: non-terminal behavior provably unchanged.

---

## Phase 6: Polish & Cross-Cutting

- [ ] T017 [P] Neutrality (C-11): run `bats tests/unit/engine_vendor_neutral.bats` — green. `reconcile::cascade_phases` carries no Atlassian vocabulary (the transition lives in the sink's `rollup::transition_if_changed`); add it to the audited `reconcile::*` list ONLY if it stays clean, else confirm it's covered. Fix any leakage by keeping vendor terms in the sink.
- [ ] T018 [P] Privacy (C-12): extend `tests/unit/no-real-identifiers.bats` to cover the new fixtures (`phase_parser.bats`/`cascade_phases.bats` inline fixtures + any `tests/fixtures/` additions) — placeholder-only (`PROJ`, `example.atlassian.net`, fabricated ids, neutral phase names like `## Phase A — Foundations`); no real coordinate.
- [ ] T019 [P] Docs: add a short note to `README.md` (the "what lands in Jira" / status section) — merging a spec cascades its phase Subtasks to done (default config), and phase headers accept numeric or single-letter indices with `:`/`-`/dash separators. Add a `CHANGELOG.md` `[Unreleased]` entry (Fixed: stranded subtasks on merge; letter/dash phase headers).
- [ ] T020 Run the **full CI gate** locally (CI parity): `shellcheck --shell=bash --severity=style src/*.sh`, `yamllint -d relaxed .github/workflows/ci.yml`, `npx --yes markdownlint-cli2 "specs/**/*.md" "*.md"`, `bats --recursive tests/unit`. All green.
- [ ] T021 Open the PR into `main` (branch `010-lifecycle-subtask-cascade`): title `fix(board): cascade lifecycle→subtask status on merge + broaden phase headers`; body cites the two bugs (line-cited), the neutral-decision/sink-reuse seam, FR-001..FR-011, the Constitution Check ruling (no amendment), Privacy IX + 003 neutrality, "rides v0.4.0; sk-linear parser port is a follow-up". Confirm the full bats matrix + neutrality + privacy gates green in CI.

---

## Dependencies & ordering

- **Phase 1 (T001–T002)** → **Phase 2 parser (T003–T007, anchor T003 first)** →
  **Phase 3 cascade fn (T008)** → **Phase 4 dispatch+tests (T009–T014)** →
  **Phase 5 (T015–T016)** → **Phase 6**.
- T007 (string-keying) depends on T005 (the parser produces letter tokens); T006
  proves the join. T009 (dispatch) depends on T008 (cascade fn).
- T020 (full gate) precedes T021 (PR).

## Parallel execution examples

- **Phase 1**: T001 ∥ T002 (distinct new bats files).
- **Phase 2**: parser awk (T005) and the reconcile string-keying (T007) touch
  different files but T007 depends on T005's tokens — keep ordered; the bats cases
  (T003/T004) are in one file (sequential).
- **Phase 6**: T017 ∥ T018 ∥ T019 (distinct files), then T020 → T021.

## MVP scope

**US2 (parser) + US1 (cascade)** together are the fix: letter/dash specs get
subtasks, and merged specs mark them done. US3 is the no-regression guard. All land
in one PR riding v0.4.0.

## Implementation strategy

Strict TDD; the **numeric-colon byte-identical anchor (T003)** is written and locked
**first**. The cascade **reuses** the sink's `rollup::transition_if_changed`
(`computed=complete`) — no new sink function, 003 seam preserved. Fail-closed on an
unreadable read (exit 3, no partial), fail-soft on an unmapped status. Non-terminal
behavior is provably unchanged (T015/T016). No schema/mapping/exit-code change, no
amendment.
