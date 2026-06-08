---
description: "Task list for feature 004 — mapping re-mode / orphan pruning"
---

# Tasks: Mapping Re-mode / Orphan Pruning

**Input**: Design documents from `/specs/004-mapping-remode/`

**Prerequisites**: plan.md, spec.md, research.md (R1–R9), data-model.md,
contracts/{remode-cli,engine-sink-prune}.md

**Tests**: TDD — test tasks precede their implementation. The fail-safe-scoping
suite (US2) is the heaviest, by design: it is the sole load-bearing safety net
under the destructive-by-default + hard-delete defaults.

**Foundation**: built on the merged 003 neutral level loop
(`reconcile::compose_identity` / `compose_payload` / `ordered_levels` /
`sync_level_artifact`). The **engine/sink seam** is preserved: the neutral
orphan-diff lives in `src/reconcile.sh`; the prune mechanic + descendant reads
live in `src/jira_sink.sh`. The 003 neutrality gate
(`tests/unit/engine_vendor_neutral.bats`) MUST stay green.

**Equivalence/safety oracle**: the existing 365-test suite (003 behavior
unchanged) + the new adversarial US2 suite + the idempotent-flip US4 suite.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (disjoint files, no dependency on an incomplete task)
- **[Story]**: US1–US4 (user-story phases only)

---

## Phase 1: Setup & the gating constitutional amendment

> ⛔ **T001 is a hard gate.** No destructive code (T010+ prune path) may land
> before the amendment is committed (Governance: a principle departure must be
> amended before implementation).

- [x] T001 [GATE] Amend `.specify/memory/constitution.md` **v1.0.0 → v1.1.0**: add the scoped controlled-destruction carve-out to Principle I (re-mode MAY remove bridge-owned artifacts; opt-in flag only, never hook-fired; bridge-owned only; dry-run-previewable; fail-closed; ordinary reconcile stays non-destructive), cross-reference it in Architectural Constraints, update the Sync Impact Report header, and bump the version line. Use the R9 amendment text from `research.md`. (MINOR — a new scoped constraint, not a removal/redefinition.)
- [x] T002 [P] Add the `remode.destruction` config surface to `config-template.yml` (default `hard-delete`; documented `archive` alt with an archive-status-id slot) and a `config::get remode.destruction` accessor path; placeholders only (Privacy IX).
- [x] T003 [P] Add re-mode test fixtures + helper: bridge-owned and operator-issue JSON response fixtures (descendant searches, a deletable issue, an archive transition) under `tests/fixtures/jira_responses/` and any shared setup in `tests/helpers/` — **placeholder coordinates only** (Privacy IX).

**Checkpoint**: amendment committed; config + fixtures available.

---

## Phase 2: Foundational — shared primitives (blocks all user stories)

> The orphan-diff, the predicate, the enumerator, the prune mechanic, and the
> `--remode` flag are needed by every story. TDD: tests (T004–T007) first.

- [x] T004 [P] Unit test `tests/unit/bridge_owned_predicate.bats`: `jira_sink::is_bridge_owned` is true iff a label begins with a configured identity prefix (`repo/spec/phase/task_prefix`); `lifecycle_prefix` (`phase:*`) does NOT qualify; an operator issue with no identity label is false (FR-002/FR-015, research R3).
- [x] T005 [P] Unit test `tests/unit/compute_orphans.bats`: `reconcile::compute_orphans` returns `O = E \ D` by identity label — empty `E` ⇒ ∅; `D == E` ⇒ ∅ (no-change); a level dropped from the mapping ⇒ its identities appear in `O`; the checklist sentinel contributes no issue identity to `D` (research R1).
- [x] T006 [P] Unit test `tests/unit/prune_artifact.bats`: `jira_sink::prune_artifact` — `hard-delete` issues `DELETE /issue/{key}`; `archive` transitions to the configured status id AND strips identity labels; `archive` with no configured status id hard-errors (rc 2); under `ARG_DRY_RUN` it issues **zero** writes (research R5, contract I-3).
- [x] T007 [P] Unit test `tests/unit/remode_args.bats`: `--remode` and `--remode --dry-run` parse into `ARG_REMODE`/`ARG_DRY_RUN`; `--remode` composes with `--spec`/`--all`/`--on-drift`; absence of `--remode` leaves `ARG_REMODE=0` (contract remode-cli).
- [x] T008 Implement `jira_sink::is_bridge_owned <labels_json>` in `src/jira_sink.sh` (pure, client-side; reads identity prefixes from config) — makes T004 green.
- [x] T009 Implement `jira_sink::enumerate_bridge_descendants <root_key>` in `src/jira_sink.sh`: parent-walk (Initiative/Epic → spec → phase) via the existing `parent = "<key>"` JQL pattern, filtered by `is_bridge_owned`; **rc 3 on any unreadable search** (fail-closed, contract I-2). Depends on T008.
- [x] T010 Implement `jira_sink::prune_artifact <key>` in `src/jira_sink.sh`: dispatch on `remode.destruction` (`hard-delete` → DELETE; `archive` → transition + strip identity labels; missing archive id → rc 2); honor `ARG_DRY_RUN`. **Gated behind T001.** Makes T006 green.
- [x] T011 Implement `reconcile::compute_orphans <repo_slug> <items…>` in `src/reconcile.sh`: build `D` via `reconcile::compose_identity` over the current mapping's issue-projecting levels; obtain `E` from `enumerate_bridge_descendants`; return `O = E \ D` as `{key,identity_label,level}`. **Vendor-neutral** — level names + label strings only. Depends on T005, T009.
- [x] T012 Implement `reconcile::remode <scope>` orchestrator + `--remode` wiring in `src/reconcile.sh`: read-phase (build `E`/`D`/`O`) → report plan → `--dry-run` stop → prune loop (delegates the mechanic to `prune_artifact`) → regenerate via the unchanged 003 projection. **Gated behind T001.** Depends on T007, T010, T011.
- [x] T013 Extend `tests/unit/engine_vendor_neutral.bats` to add `reconcile::compute_orphans` and `reconcile::remode` to the audited surface — assert no Jira issue-type / artifact-name / relationship token leaks into either (003 FR-012 stays green, contract I-4).

**Checkpoint**: primitives + orchestrator exist and are unit-green; neutrality
gate green. Re-mode is runnable end-to-end for the stories below.

---

## Phase 3: User Story 1 — Switch mapping modes cleanly (P1) 🎯 MVP

**Goal**: a re-mode after a mapping change leaves the board a clean mirror of the
new mapping — old-shape orphans gone, new shape present, zero residue.

**Independent test**: mirror a corpus under mapping A, change to mapping B,
re-mode, assert exactly B's bridge-owned artifacts and zero from A.

- [x] T014 [P] [US1] Integration test `tests/integration/remode_us1_switch_modes.bats`: 3-level → 2-level checklist — per-phase Subtasks pruned (2 DELETEs), the Story carries the in-body checklist, **0 orphaned Subtasks**, 0 operator issues touched, exit 0 (spec AS-1, edge issue→checklist). End-to-end through the curl-shim against a synthesized 3-level board.
- [x] T015 [P] [US1] Integration test `tests/integration/remode_us1_reverse.bats`: checklist → issue (reverse) — **C2 finding**: O = E\D = ∅ so NO prune call fires; the stale in-body checklist is removed by the REGENERATE description-overwrite on the KEPT spec Story (not by prune_artifact), and per-phase child issues are created (edge checklist→issue).
- [x] T016 [P] [US1] Integration test (in `remode_us1_switch_modes.bats`): issue-type change (spec Story → Epic) — the pure-label diff keeps the spec identity in D, so the spec issue is reconciled in place under the SAME identity with **no duplicate** and is never pruned; phase issues kept; operator issue untouched (spec AS-2, edge issue-type change). NOTE: a genuine cross-hierarchy retype (delete old type / create new) is a sink-type-aware capability the label-only engine diff cannot drive — documented in-test.
- [x] T017 [P] [US1] Integration test (in `remode_us1_switch_modes.bats`): Initiative super-level toggle — **DEFERRED (documented skip)**: the disabled Initiative and the repo Epic share the same repo identity label (`speckit-repo:<slug>`), distinguished ONLY by issue type. The vendor-neutral `compute_orphans` diff is label-only and cannot single the Initiative out without sink-type-awareness (the engine neutrality gate forbids issue-type literals in the diff). The C1 up-parent enumerator path exists in the sink; the diff-level distinction is the gap. Resolution = sink-side type-aware super-level handling (future work).
- [x] T018 [US1] Wire re-mode regeneration to the unchanged 003 projection and implement **FR-008 observability** in `reconcile::remode`: report pruned / regenerated / kept counts in the summary (no silent removal). Makes T014–T017 green. Depends on T012.
- [x] T019 [US1] Implement **FR-010** in the prune loop: before pruning a bridge-owned orphan, run the existing `reconcile::compute_drift`; on backward-drift surface a named WARNING (a human edited it); `--on-drift=abort` skips that issue. Test `tests/integration/remode_drift_before_prune.bats`. Depends on T018.

**Checkpoint**: US1 is the MVP — re-mode converges every mode-transition with
full observability and drift-before-delete safety.

---

## Phase 4: User Story 2 — Operator work is never destroyed (P1) — ADVERSARIAL

**Goal**: the re-mode prunes **only** bridge-owned artifacts and never touches an
operator-created issue — the gate on the whole feature.

**Independent test**: a board mixing bridge-owned and operator issues (some under
the same parent, some with lookalike summaries); after a re-mode every operator
issue is untouched and only bridge-owned orphans are pruned.

- [x] T020 [P] [US2] Adversarial integration `tests/integration/remode_us2_failsafe_scoping.bats`: an operator issue **under the same Epic** as bridge orphans — pruned set excludes it; it is unmodified (spec AS-1, SC-002).
- [x] T021 [P] [US2] Adversarial: an operator issue with a **lookalike summary / same type** as a bridge artifact — never pruned/relabeled/edited (spec AS-2).
- [x] T022 [P] [US2] Adversarial: an issue carrying **no identity label** — never pruned, relabeled, or modified regardless of summary, parent, or type (FR-002).
- [x] T023 [P] [US2] Adversarial: an operator who **manually applied a `speckit-*` identity label** — that issue is treated as bridge-owned (opted in), asserting the documented identity-contract consequence (spec Assumptions/edge).
- [x] T024 [P] [US2] Adversarial: a **stale prior-shape label family** (e.g. an old `speckit-subtask:` value the current mapping never mints) is still recognized as bridge-owned and pruned — prefix match, not exact match (research R3).
- [x] T025 [US2] Assert the **SC-002 counter** (0 operator issues pruned/relabeled/edited) in `reconcile::remode`; harden `is_bridge_owned` / `compute_orphans` if any of T020–T024 fail. Depends on T020–T024.

**Checkpoint**: fail-safe scoping proven adversarially — the load-bearing net holds.

---

## Phase 5: User Story 3 — Destruction is opt-in and previewable (P1)

**Goal**: destruction is reachable only via `--remode`; the ordinary reconcile
never prunes; `--remode --dry-run` previews the exact set with zero writes.

**Independent test**: ordinary reconcile never prunes; `--remode --dry-run`
previews with zero writes; `--remode` acts on exactly the previewed set.

- [x] T026 [P] [US3] Integration `tests/integration/remode_us3_guard.bats`: the ordinary (no-`--remode`) reconcile performs **zero** destructive operations in every mapping mode (SC-004, AS-1).
- [x] T027 [P] [US3] Integration: `--remode --dry-run` previews the exact prune + regenerate set and performs **zero** writes (FR-003, AS-2).
- [x] T028 [P] [US3] Integration: `--remode` (no `--dry-run`) prunes + regenerates **exactly** the set the dry-run previewed — preview fidelity (SC-003, AS-3); same-computation/gated-tail (research R4).
- [x] T029 [P] [US3] Integration `tests/integration/reconcile_orphan_warning.bats`: the ordinary reconcile **WARNS** on detected prior-shape orphans (lists them, suggests `--remode`) but prunes nothing (FR-014).
- [x] T030 [US3] Implement **FR-014** in the ordinary reconcile path: after projecting `D`, enumerate `E` and warn (warn-not-prune) when `E \ D ≠ ∅`, reusing the R2 enumerator on the reads already needed where possible. Makes T029 green. Depends on T011.

**Checkpoint**: the guard holds — explicit opt-in, faithful preview, non-destructive default.

---

## Phase 6: User Story 4 — Experiment freely, idempotently (P3)

**Goal**: flipping mappings converges every time; a no-change re-mode is zero-churn.

**Independent test**: A→B→A each mirrors the applied mapping; a re-mode with no
change writes nothing.

- [x] T031 [P] [US4] Integration `tests/integration/remode_us4_idempotent_flip.bats`: flip mapping A → B → A; each time the board faithfully mirrors the applied mapping with no residue from the other (AS-1, SC-007).
- [x] T032 [P] [US4] Integration: a re-mode with **no actual shape change** prunes nothing and writes nothing (VR-4, FR-006, AS-2, SC-005).
- [x] T033 [P] [US4] Integration `tests/integration/remode_partial_failure.bats`: **FR-009** — a partial prune failure is surfaced (warned counter, named issue) and a re-run completes the re-mode (resumable; recompute-from-live-state, research R7).
- [x] T034 [US4] Integration `tests/integration/remode_failclosed.bats` + orchestrator ordering: an unreadable read during the read-phase aborts with **zero** deletions (FR-005/SC-006/VR-2). Confirm no `prune_artifact` call precedes a successful full enumeration (contract I-2). Depends on T012.

**Checkpoint**: free experimentation + fail-closed + resumable — all four stories complete.

---

## Phase 7: Polish & cross-cutting

- [x] T035 [P] Document the `remode` config block in `config-template.yml` and cross-reference re-mode from `README.md` (recovery/experimentation section) + this feature's `quickstart.md`.
- [x] T036 [P] Privacy guard: confirm every new fixture/test uses placeholder coordinates; extend `tests/.private-deny` coverage if needed; `tests/unit/no-real-identifiers.bats` green (Privacy IX / FR-012).
- [x] T037 [P] `CHANGELOG.md`: add the `### Added` entry for the re-mode capability (note the controlled-destruction amendment v1.1.0).
- [x] T038 Run `scripts/check.sh` to green (shellcheck `--severity=style`, yamllint relaxed, markdownlint, full bats) with the dogfood config moved aside (clean-checkout parity); fix any lint.
- [x] T039 Confirm the **003 neutrality gate** still passes (engine path carries no Jira vocabulary after the orphan-diff additions) and the **existing 365-test suite is unchanged** (no behavior regression in the non-re-mode path).
- [x] T040 Open the `004 → main` PR after green; the PR description MUST name the amended principle (Governance) and link the constitution v1.1.0 change.

---

## Dependencies & execution order

- **T001 (amendment) gates the destructive path** — T010 and T012 (and everything depending on them) MUST NOT land before T001 is committed.
- **Phase 2 foundational** (T004–T013) blocks all user stories.
- **Within Phase 2**: tests T004–T007 [P] first; then T008 → T009 (sink reads), T010 (prune), T011 (neutral diff, needs T009) → T012 (orchestrator, needs T007+T010+T011) → T013 (neutrality gate).
- **User stories after foundational**: US1 (T014–T019) is the MVP; US2 (T020–T025), US3 (T026–T030), US4 (T031–T034) are each independently testable and can be tackled in priority order. US2's adversarial suite shares the predicate from T008 but adds no new production dependency, so US2 ↔ US3 are largely parallel once Phase 2 is done.
- **Polish** (T035–T040) last; T038/T039 are the CI gate before the T040 PR.

## Parallel execution examples

- **Phase 2 tests**: T004, T005, T006, T007 in parallel (four disjoint new test files).
- **US1 mode-transition tests**: T014, T015, T016, T017 in parallel (disjoint integration files) before T018 wires them green.
- **US2 adversarial**: T020–T024 in parallel (disjoint cases in/by file) before T025 hardens.
- **Polish**: T035, T036, T037 in parallel (docs / privacy / changelog — disjoint files).

## Implementation strategy

**MVP = Phase 1 + Phase 2 + US1 (T001–T019)**: a working, observable, drift-aware
re-mode that cleanly switches every mapping mode. US2 then *proves* the safety net
adversarially (highest priority after MVP because it gates the feature's
acceptability), US3 locks the guard, US4 adds the experimentation polish. Ship
incrementally; keep the full gate green at every checkpoint.
