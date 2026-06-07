---
description: "Task list for 002-configurable-mapping"
---

# Tasks: Configurable Artifact Mapping

**Input**: Design documents from `/specs/002-configurable-mapping/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: INCLUDED — the constitution makes tests the gate (Principle VIII) and
each contract (`mapping-config.md`, `workstate-input.md`,
`engine-sink-interface-002.md`) defines bats obligations. Test tasks precede the
implementation they cover within each phase (the 001 pattern).

**Organization**: by user story (US1–US6 from spec.md) so each is an
independently testable increment. This feature is an **additive extension** of
the shipped 001 core bridge — all mapping / detection / validation lives in the
Jira sink + config layer; the vendor-neutral engine half of `reconcile.sh` is
untouched except for the `--workstate` input source (FR-018).

## Format: `[ID] [P?] [Story?] Description with file path`

- **[P]**: parallelizable (different file, no dependency on an incomplete task)
- **[USx]**: the user story a task serves (story phases only)

---

## Phase 1: Setup

- [x] T001 [P] Add the feature's empty fixture trees for the new modes: `tests/fixtures/jira_responses/issuetype_meta/` (available-type probe responses) and `tests/fixtures/workstate/direct/` (workstate-direct inputs), placeholders only
- [x] T002 [P] Add a committed placeholder `config-template.yml` `mapping:` block (initiative/levels/status_rollup, all defaults) mirroring `contracts/mapping-config.md` — no real coordinates

---

## Phase 2: Foundational (blocking prerequisites for ALL stories)

**Purpose**: the `mapping:` block parse, the alias-layer default synthesis, and
the config-load validation framework — these underpin every story. All in
`src/config.sh`; unit tests first. Every validation rule is fail-closed at
config-load (exit 2), before any write.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T003 [P] Unit test `tests/unit/mapping_parse.bats` — parse the `mapping:` block from `jira-config.yml` (initiative / project_style / levels / status_rollup) per `contracts/mapping-config.md` schema; malformed enum values (`on_absent`≠`degrade`, `source`≠`spec_input`) are config errors (exit 2)
- [x] T004 [P] Unit test `tests/unit/mapping_alias.bats` — absent `mapping:` synthesizes the default block (repo→Epic, spec→Story, phase→Subtask, task→checklist, initiative/rollup off); a pre-feature config loads byte-for-byte unchanged; an explicit default block equals the synthesized one (alias equivalence, FR-002, US1 scenario 3)
- [x] T005 [P] Unit test `tests/unit/mapping_inherit.bats` — a partial `mapping:` block (only some levels specified) inherits the synthesized default per unspecified level (Q4); not an all-or-nothing error
- [x] T006 [P] Unit test `tests/unit/mapping_validate.bats` — the config-load validation order (parse → required-id → relationship matrix → available-type) runs as a single fail-closed gate; any failure exits 2 and writes nothing (FR-017, `mapping-config.md` §validation order)
- [x] T007 Implement `mapping::parse` in `src/config.sh` — parse the `mapping:` block into the loaded config; validate `initiative.on_absent`=`degrade`, `initiative.source`=`spec_input`, `project_style`∈`{team-managed,classic}` (fail-closed, exit 2)
- [x] T008 Implement `mapping::synthesize_default` + alias layer in `src/config.sh` — emit the default block when `mapping:` is absent; apply per-level inheritance for unspecified levels (Q4); add the new `labels.task_prefix` (`speckit-task:`) default (Q9)
- [x] T009 Implement `mapping::resolve_level` in `src/config.sh` — return `{artifact, relationship_to_parent, on_absent?}` for a given level from the loaded (or aliased) block (engine-sink-interface-002 §mapping-driven projection)
- [x] T010 Implement the config-load validation framework `mapping::validate` in `src/config.sh` — single fail-closed gate ordering required-id, relationship-matrix, and available-type checks; collects to a workspace-level config error (exit 2) before any write (FR-017)

**Checkpoint**: the `mapping:` block parses, aliases to today's default, inherits
per level, and validates fail-closed — the foundation every story builds on.

---

## Phase 3: User Story 1 — A no-config upgrade changes nothing (P1) 🎯 MVP

**Goal**: An absent or explicit-default `mapping:` reproduces 001 behavior
byte-for-byte — the regression anchor for the whole feature.

**Independent test**: Reconcile a pre-feature config (no `mapping:` block) over
the mock and confirm the created/updated/skipped result is byte-identical to
001's, including a zero-churn re-run.

- [x] T011 [P] [US1] Integration test `tests/integration/us1_default_equivalence.bats` — a config with no `mapping:` block mirrors repo→Epic / spec→Story / phase→Subtask / task→in-body checklist exactly as the shipped 001 default; assert created counts + issue shapes match the 001 baseline (spec scenario 1)
- [x] T012 [P] [US1] Integration test `tests/integration/us1_default_zerochurn.bats` — re-run the already-mirrored default corpus; assert zero writes (0 created / 0 updated, Epic reused), and that an explicit default `mapping:` block produces the identical result to the no-block case (spec scenarios 2–3, SC-001)
- [x] T013 [US1] Wire `src/jira_sink.sh` projection through `mapping::resolve_level` for the default-aliased path so the existing 001 `ensure_repo_epic` / `sync_spec_issue` / `sync_task_phase_subissues` calls route via the mapping layer without behavior change (FR-001, FR-018)
- [x] T014 [US1] Confirm `src/reconcile.sh` orchestration loads + aliases the `mapping:` block before the write loop and passes it to the sink; default path unchanged from 001 (regression anchor)

**Checkpoint**: US1 delivers the safety promise — upgrade safely, opt in later.

---

## Phase 4: User Story 2 — Configure the mapping to fit my board, safely (P1)

**Goal**: Mapping-driven per-level projection with available-issue-type
detection, the relationship-validation matrix, and the absent-type policy — all
fail-closed at config-load.

**Independent test**: Configure a non-default per-level mapping (e.g. spec→Epic,
phase→Story, task→Task) and confirm the mirror uses the configured types; then
configure a type the project lacks and confirm the run is rejected before any
issue is created.

- [x] T015 [P] [US2] Unit test `tests/unit/available_types.bats` — `mapping::detect_available_types` probes issue-type metadata (curl-shim, `issuetype_meta/` fixtures) and returns the project's available-type set; a Kanban template fixture ships Task/Epic/Subtask with NO Story (Q10, FR-005)
- [x] T016 [P] [US2] Unit test `tests/unit/relationship_matrix.bats` — every matrix reject hard-halts at config-load (exit 2, no write): `Blocks`/`Relates`/`Implements` as a hierarchy link, `Epic-link` between two non-Epic levels, and `checklist` paired with a non-`checklist` relationship (Q2, FR-007, `mapping-config.md` matrix)
- [x] T017 [P] [US2] Unit test `tests/unit/absent_type_policy.bats` — a configured artifact absent from the probed set hard-errors (exit 2, no write); a valid per-level `on_absent` fallback is honored; an `on_absent` whose fallback is itself absent still hard-errors (Q10, FR-006)
- [x] T018 [P] [US2] Unit test `tests/unit/sync_level_artifact.bats` — `sync_level_artifact` creates/updates the configured issue type under the parent via the configured relationship; `link_to_parent` applies `parent`/`Epic-link` and no-ops for `none`/`checklist`; idempotent match by identity label (engine-sink-interface-002 §projection)
- [x] T019 [US2] Implement `mapping::detect_available_types` in `src/config.sh` — issue-type-metadata probe via `src/jira_rest.sh`; fail-closed read returns rc 3; result feeds `mapping::validate` (FR-005, Q10)
- [x] T020 [US2] Implement the relationship-validation matrix in `src/config.sh` (`mapping::validate_relationships`) — offline allow/reject per `mapping-config.md`, resolving Epic-link parent-is-Epic checks from the loaded levels; hard-halt exit 2 (Q2, Q3 operator-declared `project_style`)
- [x] T021 [US2] Implement the absent-type policy in `src/config.sh` (`mapping::validate_available`) — reject configured artifacts absent from the probed set, honoring a valid `on_absent` fallback; `checklist` sentinel exempt; hard-error exit 2 otherwise (FR-006, FR-017)
- [x] T022 [US2] Implement `sync_level_artifact` + `link_to_parent` in `src/jira_sink.sh` — mapping-driven create/update of the configured artifact with the configured relationship; Task-projected levels match/update by `task_prefix` identity label (Q9, FR-009)
- [x] T023 [US2] Wire `src/reconcile.sh` so config-load validation (relationship matrix + available-type probe) runs before the write loop; a failure aborts the run with exit 2 and writes nothing (FR-017, fail-closed)
- [x] T024 [US2] Integration test `tests/integration/us2_configured_mapping.bats` — a spec→Epic / phase→Story / task→Task config mirrors the configured types with the configured parent relationships (spec scenario 1), AND a re-run against the unchanged corpus asserts **zero churn** (0 created / 0 updated) — the 3-level arm of SC-004 (analyze Next-Action #3)
- [x] T025 [US2] Integration test `tests/integration/us2_absent_type_failclosed.bats` — a config mapping a level to a project-absent type is rejected at config-load with a clear error and zero writes; a nonsensical hierarchy relationship is likewise rejected before any write (spec scenarios 2–3, SC-003)

**Checkpoint**: US2 delivers the core value — safe, validated, board-fitting
mapping with fail-closed detection.

---

## Phase 5: User Story 3 — A leaner board with checklist (2-level) mode (P2)

**Goal**: Phases + tasks collapse into an in-body checklist (no child issues),
rendered via a keyed sub-tree byte-diff so re-runs are zero-churn (Q7).

**Independent test**: Configure 2-level mode and confirm no per-phase/per-task
child issues are created, the parent body carries the checklist, and a re-run
against unchanged tasks performs zero writes.

- [x] T026 [P] [US3] Unit test `tests/unit/checklist_subtree.bats` — `render_checklist_subtree` keys each item by its workstate task id with stable byte ordering; a single stable provenance marker line renders above the sub-tree (Q9) without perturbing the byte compare (`adf.sh`)
- [x] T027 [P] [US3] Unit test `tests/unit/checklist_diff.bats` — `diff_checklist_subtree` byte-compares ONLY the checklist sub-tree (not the full body); `sync_body_checklist` skips the write when `unchanged`; a reorder / completion-toggle / rename re-renders keyed items with no duplication and no unrelated-edit rewrite (Q7, FR-008)
- [x] T028 [US3] Implement `render_checklist_subtree` in `src/adf.sh` — isolated, byte-stable ADF taskList fragment keyed by workstate task id, with the stable provenance marker line above it (Q7, Q9)
- [x] T029 [US3] Implement `diff_checklist_subtree` + `sync_body_checklist` in `src/jira_sink.sh` — sub-tree byte-compare; write the body only when the sub-tree changed; `checklist`-sentinel levels create no child issue (engine-sink-interface-002 §2-level render)
- [x] T030 [US3] Wire 2-level mode in `src/reconcile.sh` orchestration — when the phase/task levels resolve to `checklist`, render into the parent spec body instead of creating Subtask/Task children
- [x] T031 [US3] Integration test `tests/integration/us3_checklist_zerochurn.bats` — 2-level mode creates no Subtask/Task children and carries the in-body checklist; a re-run with no task changes performs zero writes (byte-identical sub-tree); toggling one task's completion updates only the affected issue's body with no duplicate checklist (spec scenarios 1–3, SC-004)

**Checkpoint**: US3 delivers the leaner-board mode with the zero-churn guarantee
intact.

---

## Phase 6: User Story 4 — Completion shows on the board (status rollup) (P2)

**Goal**: An off-by-default rollup transitions a phase's issue to done when all
its tasks are complete and the repo's top issue to done when all specs are
complete; idempotent (transition only on changed completion, Q11).

**Independent test**: With rollup on, complete all tasks in a phase and confirm
its issue moves to done; re-run and confirm no further transition fires.

- [x] T032 [P] [US4] Unit test `tests/unit/rollup_completion.bats` — `rollup::compute_completion` returns `complete` when all phase tasks are checked (phase level) or all specs are done (repo/top level), else `partial` (Q11)
- [x] T033 [P] [US4] Unit test `tests/unit/rollup_idempotent.bats` — `rollup::transition_if_changed` transitions ONLY when computed completion ≠ prior (forward and backward); unchanged completion fires no transition; rollup off sets only the spec-level status (today's behavior) (Q11, FR-012)
- [x] T034 [US4] Implement `rollup::compute_completion` in `src/jira_sink.sh` — phase completion from task checks, repo/top completion from spec states (engine-sink-interface-002 §status rollup)
- [x] T035 [US4] Implement `rollup::transition_if_changed` in `src/jira_sink.sh` — reuse the 001 `transition_issue` / `config::get_status_transition` levers; fire only on a real completion-state change (FR-011, FR-012)
- [x] T036 [US4] Wire rollup into `src/reconcile.sh` orchestration — gated on `mapping.status_rollup.enabled`; off by default leaves only the spec-level status set
- [x] T037 [US4] Integration test `tests/integration/us4_rollup.bats` — rollup on: a fully-checked phase transitions to done, an all-specs-done repo transitions its top issue to done, a re-run on unchanged completion fires no transition; rollup off sets only the spec-level status (spec scenarios 1–4, SC-006)

**Checkpoint**: US4 closes the "looks undone when it's done" gap, idempotently.

---

## Phase 7: User Story 5 — Feed the bridge from workstate directly (P2)

**Goal**: A `--workstate <file|->` seam on the reconcile entrypoint mirrors a
supplied workstate document without reading a `specs/` tree, schema-validated on
entry, producing the same projection as the equivalent tree (Q8).

**Independent test**: Run the bridge against a workstate document supplied as a
file and as piped input and confirm the resulting mirror matches the one produced
from the equivalent `specs/` tree.

- [x] T038 [P] [US5] Unit test `tests/unit/workstate_direct_entry.bats` — `--workstate <file>` and `--workstate -` (stdin) both validate the document against the pinned `workstate` schema on entry; a malformed / schema-invalid / unpinned-`schema_version` document is rejected fail-closed (exit 2, no write); `--workstate` with `--spec`/`--all` is a config error (exit 2) (Q8, FR-016, `workstate-input.md`)
- [x] T039 [US5] Implement the `--workstate <file|->` arg parse in `src/reconcile.sh` — mutually exclusive with `--spec`/`--all`; route the input source to `src/workstate.sh` instead of the parser; all other 001 flags retain their meaning (Q8, FR-015)
- [x] T040 [US5] Implement workstate-direct ingestion + on-entry schema validation in `src/workstate.sh` — read from file or stdin, validate against the pinned `workstate.schema.json` (Draft 2020-12), reject malformed/unsupported fail-closed; treat `spec_input` as gracefully absent in this mode (FR-016, narrative source absent)
- [x] T041 [US5] Integration test `tests/integration/us5_workstate_parity.bats` — a valid workstate file mirrors identically to the equivalent `specs/`-tree projection (same artifacts, labels, relationships, idempotent re-run); the same document piped on stdin mirrors identically; a malformed document is rejected on entry with exit 2 and zero writes (spec scenarios 1–3, SC-005)

**Checkpoint**: US5 exposes workstate as a first-class input (Principle X
strengthened), unblocking non-spec-kit producers.

---

## Phase 8: User Story 6 — Optional narrative super-level above the spec (P3)

**Goal**: An off-by-default Initiative super-level that creates an Initiative
where the instance supports it and folds the narrative onto the Epic with a
grouping label where it does not — never hard-failing (Q5).

**Independent test**: With the super-level on, run against an instance that
supports Initiative and confirm an Initiative is created; run against one that
does not and confirm the narrative folds onto the Epic with a grouping label and
no hard failure.

- [ ] T042 [P] [US6] Unit test `tests/unit/initiative_probe.bats` — `initiative::probe_available` returns `present`/`absent` from the issue-type metadata probe; `ensure_initiative` creates the Initiative (narrative only from the explicit `spec_input` source, never inferred) when present (Q5, FR-014)
- [ ] T043 [P] [US6] Unit test `tests/unit/initiative_degrade.bats` — `initiative::degrade_onto_epic` folds the narrative onto the Epic behind a stable marker and carries repo grouping via the reused `repo_prefix` label when absent; never hard-fails; re-runs in the degraded state are zero-churn and a later re-home onto a real Initiative is churn-free (Q5, FR-013, SC-007)
- [ ] T044 [US6] Implement `initiative::probe_available` + `ensure_initiative` in `src/jira_sink.sh` — gated on `mapping.initiative.enabled`; require `issue_types.initiative` only when present; populate narrative only from the explicit `spec_input` source (FR-013, FR-014)
- [ ] T045 [US6] Implement `initiative::degrade_onto_epic` in `src/jira_sink.sh` — stable-marker fold onto the Epic + reused `repo_prefix` grouping label; idempotent degrade↔re-home; `spec→Story` stays the sole backward-drift anchor (FR-010, Q5)
- [ ] T046 [US6] Wire the Initiative super-level into `src/reconcile.sh` orchestration — when enabled, probe then create-or-degrade above the repo Epic; `spec_input` gracefully absent in `--workstate` mode (Q8 edge case)
- [ ] T047 [US6] Integration test `tests/integration/us6_initiative.bats` — super-level on + Initiative present ⇒ an Initiative is created above the Epic; on + absent ⇒ narrative folds onto the Epic behind a marker, repo grouping becomes a label, run succeeds; super-level off ⇒ behavior matches US1 (spec scenarios 1–3, SC-007)

**Checkpoint**: US6 delivers the differentiating initiative level with graceful
degradation.

---

## Phase N: Polish & Cross-Cutting

- [ ] T048 [P] shellcheck `--severity=style` clean across all touched `src/*.sh`; fix findings
- [ ] T049 [P] yamllint `-d relaxed` clean on the updated `config-template.yml` + any workflow change
- [ ] T050 [P] markdownlint-clean across `specs/002-configurable-mapping/**/*.md` (`npx markdownlint-cli2`)
- [ ] T051 [P] Extend `tests/unit/no-real-identifiers.bats` coverage over the new fixtures (`issuetype_meta/`, `workstate/direct/`, the template `mapping:` block); confirm placeholders only (FR-019, Privacy IX)
- [ ] T052 [P] Update `CHANGELOG.md` (Unreleased: configurable artifact mapping — alias default, per-level mapping + validation, 2-level checklist, status rollup, workstate-direct, initiative super-level)
- [ ] T053 [P] Validate `specs/002-configurable-mapping/quickstart.md` against the shipped behavior (modes, validation, workstate-direct) and correct any drift
- [ ] T054 Run the exact CI locally via `scripts/check.sh` (shellcheck + yamllint + markdownlint + bats unit) and fix to green before pushing
- [ ] T055 [later] Wire `sync_level_artifact` + `link_to_parent` into the engine orchestration in `src/reconcile.sh` (`process_spec`), replacing the 001-era hardcoded `ensure_repo_epic` / `sync_spec_issue` / `sync_task_phase_subissues` call path with the mapping-driven projection for ALL configured levels. TRACKED DEFERRAL: US2 (T022) ships `sync_level_artifact`/`link_to_parent` as the proven, unit+integration-tested mapping-driven projection, but the engine still drives the 001 orchestrators — a DELIBERATE phase boundary (the engine half of `reconcile.sh` stays vendor-neutral and is not part of US2's sink-scoped change). Out of US2 scope; do NOT wire it within US2.
- [ ] T056 [later] End-to-end live-reconcile zero-churn test of a NON-DEFAULT label/parent shape (a configured phase/operator label set + a configured parent relationship) driven through the wired engine (T055), asserting a re-run is 0 created / 0 updated / 0 PUT across every parent-bearing level — the full-stack analogue of the sink-level F1/F3/F4 zero-churn assertions added in the adversarial-review hardening.

---

## Dependencies & completion order

- **Setup (T001–T002)** → **Foundational (T003–T010)** block everything.
- **US1 (T011–T014)** depends only on Foundational → it is the regression-anchor
  MVP and ships alone.
- **US2 (T015–T025)** depends on Foundational (parse + alias + validation
  framework) and extends the sink projection; independent of US3–US6.
- **US3 (T026–T031)** depends on Foundational + the sink projection (US2's
  `sync_level_artifact` for the non-checklist parent); reuses the 001 content-diff
  path.
- **US4 (T032–T037)** depends on Foundational + the 001 transition levers;
  independent of US3/US5/US6.
- **US5 (T038–T041)** depends on Foundational + the `workstate.sh`/`reconcile.sh`
  seam; the projection it asserts is whatever US1/US2 produce.
- **US6 (T042–T047)** depends on Foundational + the repo-Epic path (US1); the
  lowest-priority slice.
- **Polish (T048–T054)** last.

Story order: US1 → US2 → (US3 ∥ US4 ∥ US5) → US6.

## Parallel execution examples

- Foundational tests: T003, T004, T005, T006 (separate test files) run together
  before implementing T007–T010 (all in `src/config.sh`, sequential).
- US2 tests: T015, T016, T017, T018 (separate test files) run together before the
  `src/config.sh`/`src/jira_sink.sh` implementations.
- US3/US4/US5 are orthogonal (`adf.sh`+checklist vs rollup vs `workstate.sh`
  seam) and can proceed in parallel once Foundational + US2 land.
- Implementation tasks in the same `src/config.sh` or `src/jira_sink.sh` are
  sequential (same file); cross-file `[P]` tasks are not.

## Implementation strategy

- **MVP = Phase 1 + 2 + US1** (T001–T014): the alias-layer regression anchor —
  prove the no-config upgrade changes nothing, byte-for-byte.
- Then layer US2 (the core configurable mapping + fail-closed validation),
  followed by US3 (2-level), US4 (rollup), US5 (workstate-direct) in any order,
  and finally US6 (initiative super-level).
- Tests precede implementation within each phase; the curl-shim keeps every unit
  and integration test offline. Idempotency / drift / fail-closed / privacy are
  threaded through every story. Run `scripts/check.sh` before every push.
