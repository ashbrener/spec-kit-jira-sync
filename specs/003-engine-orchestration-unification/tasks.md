---
description: "Task list for 003-engine-orchestration-unification"
---

# Tasks: Engine Orchestration Unification

**Input**: Design documents from `/specs/003-engine-orchestration-unification/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md,
contracts/engine-sink-interface-003.md

**Tests**: This is a **behavior-preserving refactor**, so the test strategy is
unusual: the **existing 347-test suite is the equivalence oracle** and MUST pass
**UNCHANGED** after every step (no test edited to accommodate a behavior
difference — SC-001). Only **two** new tests are added: the FR-012 neutrality
gate (US2) and the T056 full-stack non-default-shape zero-churn test (US3).
"Equivalence" = identical observable writes (method + URL + payload + counts),
not identical internal call order (research.md Decision 3).

**Organization**: by user story (US1–US3 from spec.md). US1 (the unification +
its equivalence) is the MVP; US2 (the enforced neutral surface) and US3 (the
full-stack idempotency proof) build on it.

## Format: `[ID] [P?] [Story?] Description with file path`

- **[P]**: parallelizable (different file, no dependency on an incomplete task)
- **[USx]**: the user story a task serves (story phases only)

---

## Phase 1: Setup

- [x] T001 Establish the equivalence baseline: run `bats --recursive tests/unit tests/integration` and record the green count (347, modulo the env-only `config.bats` default-path test) as the regression anchor; capture the curl-shim request log for one default run and one configured-mapping run (the byte-level equivalence reference the refactor must reproduce). No code change.

---

## Implementation progress — RESUME HERE (US1)

**Foundational COMPLETE** (T001–T006), all green + committed:

- Baseline: 347 green (clean-checkout). After Foundational: **359 green** (347 + 12
  new: compose_identity 4, compose_payload 4, sync_level_artifact_absorb 4).
- `b66c0d5` — neutral composers in `src/reconcile.sh`
  (`ordered_levels`/`compose_identity`/`compose_payload`/`parent_projected_id` +
  `_RECONCILE_LEVEL_IDS` cache). Vendor-neutral (workstate + config labels only).
- `b775c69` — `sync_level_artifact` (`src/jira_sink.sh`) absorbs, **gated-additive**
  on the neutral input fields (002 callers pass `{summary,body}` → unchanged):
  `.tasks`→in-body taskList, `.body`→markdown ADF, neither→**omit description**
  (repo Epic), `.state`→lifecycle status transition on a real change only
  (`JIRA_SINK_LEVEL_TRANSITION_FAILED` channel added).

**Next: T007 — wire `process_spec` (then `process_workstate_item`) onto the loop.**
The cleanest seam is to rewrite the WRAPPERS `reconcile::sync_spec_issue` +
`reconcile::sync_task_phase_subissues` to drive `compose_*` + `sync_level_artifact`
(repo→spec→phase) instead of `ensure_repo_epic`/`sync_spec_issue`/
`sync_task_phase_subissues`, populating `_RECONCILE_LEVEL_IDS[repo|spec]` for
`parent_projected_id`. Keep `process_spec`'s disposition-file + drift + links/
comments + rollup wiring as-is.

**⚠️ The one gotcha to solve in T007 (the reason this is a fresh focused task):**
in **2-level mode**, today's `sync_spec_issue` composes prose+checklist in a
**single** create. Routing the spec level through `sync_level_artifact` + a
post-call `sync_body_checklist` would do **two** writes on a fresh create and
break `us3_checklist_zerochurn` ("checklist in one create"). So
`sync_level_artifact` must absorb `sync_spec_issue`'s **full 2-level path**
(prose+checklist at create; sub-tree reconcile at update) — extend it the same
gated-additive way (detect 2-level via the phase level resolving to `checklist`).
Verify per-level: wire repo → run full suite green; wire spec (3-level) → green;
add 2-level absorption → `us3*` green; wire phase → green; then delete the 001
orchestrators (T010) and confirm the suite is still **byte-for-byte unchanged**.

**Second gotcha — found in a repo-level wiring spike (reverted to stay green):**
`ensure_repo_epic` is **find-or-create-ONLY** — for an existing Epic it returns
the key from the SEARCH and does NO field reconcile + NO `query_issue_full` GET.
`sync_level_artifact`, by contrast, always reads the existing issue (GET) and
diffs/updates fields. Routing repo through it added an Epic GET + a potential
field PUT that the 001 path never did — which fails the us2 fixtures (no Epic GET
stubbed) and breaks byte-equivalence (us2 "manual status edit" 322/323, us3
toggle 329). **Fix in T007:** give the repo level a find-or-create-only mode
(skip the present-path read+diff when the level is `repo`, or pass a
`reconcile_fields:false`-style flag) so it matches `ensure_repo_epic` exactly.
The compose helpers + the spike confirmed the repo create payload itself is
byte-identical (omit_description) — only the existing-Epic read/reconcile differs.

### T007 progress — repo + spec levels WIRED (green), phase level pending

Committed + green (359/359):

- `859c984` — **repo level** wired via `sync_level_artifact(repo,…,find_only=1)`
  (the find-or-create-only 5th arg fixes the first gotcha).
- `1ca4387` — **spec level** wired, including the **2-level single-create
  absorption** (the second gotcha is SOLVED): `compose_payload(spec)` carries the
  neutral flattened `checklist_tasks` in 2-level mode; `sync_level_artifact`
  composes prose+sub-tree in one create and reconciles the sub-tree via
  `sync_body_checklist` on update. us3 stays byte-identical.

**Phase level — third gotcha (wire reverted to keep green; investigate next):**
routing phase Subtasks through `sync_level_artifact(phase)` **re-created** the
Subtasks on a zero-churn re-run (`created=2`, broke us1_default_zerochurn 295–298,
us1_merged_transition 304, us2_idempotent 320–323). The 001 sink found phase
Subtasks via `query_subissue_for_phase` (**parent**-scoped: `parent="<story>" AND
labels=...`), whereas `sync_level_artifact` searches via `query_spec_issue`
(**project**-scoped: `labels=... AND project=...`). Both URLs contain the
`task-phase%3A1` label so the shim glob matches either — yet the existing Subtask
wasn't matched, so a request-level trace is needed to pin the exact divergence
(likely the search scope or the `&fields=` shape). **Fix candidate:** give
`sync_level_artifact` a parent-scoped identity search for child levels (mirror
`query_subissue_for_phase`) when a parent_id is present, verified against
us2_idempotent + us1_default_zerochurn. After phase is green: delete the 001
orchestrators (T010), add the neutrality gate (T012/US2), and T056 (T014/US3).

---

## Phase 2: Foundational (blocking prerequisites for the unification)

**Purpose**: the neutral seam primitives (engine) + the extended projection
(sink) that the level loop depends on. All emit byte-identical requests to the
001 path, so the existing suite stays green.

**⚠️ CRITICAL**: US1 wiring cannot begin until this phase is complete.

- [x] T002 [P] Unit test `tests/unit/compose_payload.bats` — `reconcile::compose_payload <level> <item>` produces the byte-exact neutral `{summary,body,labels,state?}` per the data-model rules for repo/spec/phase/task (matches what the 001 orchestrators emitted), referencing ONLY workstate fields + config label prefixes (no Jira tokens).
- [x] T003 [P] Unit test `tests/unit/compose_identity.bats` — `reconcile::compose_identity <level> <item>` yields the stable identity label per level from the config label prefixes (`repo_prefix`/`spec_prefix`/`phase_prefix`/`task_prefix`), matching today's identity labels exactly.
- [x] T004 Implement the neutral engine helpers in `src/reconcile.sh`: `ordered_levels`, `compose_identity`, `compose_payload`, `parent_projected_id` — pure, vendor-neutral (workstate + config labels only). Make T002/T003 green.
- [x] T005 Extend `sync_level_artifact` in `src/jira_sink.sh` to absorb the 001 behavior behind the sink seam: (a) apply the lifecycle status transition when `input_json.state` maps to a status (reuse `config::get_status_transition` + `transition_issue`, only on a real status change — preserves the merged-not-Done fix); (b) compose the in-body 2-level checklist via the shipped `sync_body_checklist` when the level's child resolves to the `checklist` sentinel; (c) accept the neutral per-level payload so create/update payloads are byte-identical to the 001 path.
- [x] T006 [P] Unit test `tests/unit/sync_level_artifact_absorb.bats` — the extended `sync_level_artifact` fires the status transition only on a real change (zero-churn otherwise) and composes the 2-level checklist identically to the US3 path; idempotent re-run is zero writes.

**Checkpoint**: the neutral primitives + extended projection exist and are unit-proven; the existing suite still passes (nothing wired yet).

---

## Phase 3: User Story 1 — The operator sees no change (P1) 🎯 MVP

**Goal**: re-platform `process_spec` + `process_workstate_item` onto the neutral
level loop, delete the 001 orchestrators, with byte-for-byte equivalence.

**Independent test**: the full existing suite passes UNCHANGED and a live
re-reconcile in each mode is zero churn.

- [x] T007 [US1] Wire `reconcile::process_spec` in `src/reconcile.sh` onto the neutral level loop — iterate `ordered_levels`, drive `sync_level_artifact` + `link_to_parent` per level via `compose_identity`/`compose_payload`/`parent_projected_id`, preserving the per-level disposition tally, the spec→Story drift anchor, and the cross-spec-links/clarify-comments/rollup wiring. Replace the `ensure_repo_epic` / `sync_spec_issue` / `sync_task_phase_subissues` call path.
- [x] T008 [US1] Run the FULL suite (`bats --recursive tests/unit tests/integration`) — every test passes UNCHANGED. Diff the curl-shim request log against the T001 baseline; reconcile any byte difference until it is zero (the equivalence gate for the specs/-tree path).
- [x] T009 [US1] Wire `reconcile::process_workstate_item` onto the same neutral loop; run the full suite UNCHANGED + diff the workstate-direct request log against baseline (zero difference).
- [x] T010 [US1] Delete the now-unused 001 orchestrators (`ensure_repo_epic`, `sync_spec_issue`, `sync_task_phase_subissues`) from `src/jira_sink.sh` and their reconcile wrappers if unused; run the full suite UNCHANGED (proves they were truly dead). `shellcheck --severity=style src/*.sh` clean.
- [ ] T011 [US1] Live-dogfood equivalence: re-reconcile the already-mirrored board in each mode (default 3-level, 2-level checklist, status rollup, Initiative degrade, workstate-direct) and confirm **0 created / 0 updated** (zero churn) — SC-002, the real-world equivalence proof.

**Checkpoint**: US1 delivers the unification with proven zero behavior change — the MVP.

---

## Phase 4: User Story 2 — The engine is vendor-neutral and lift-ready (P1)

**Goal**: enforce that the engine orchestration path carries no Jira knowledge.

**Independent test**: the committed neutrality gate passes over the enumerated
engine functions.

- [x] T012 [US2] Implement the neutrality gate `tests/unit/engine_vendor_neutral.bats` — extract the bodies of the enumerated engine-orchestration functions (per `contracts/engine-sink-interface-003.md` §3: `process_spec`, `process_workstate_item`, `ordered_levels`, `compose_identity`, `compose_payload`, `parent_projected_id`, `rollup_phases`, `rollup_repo_epic`, `sync_initiative`) and FAIL if any contains a Jira issue-type id, an artifact-name literal (`Epic`/`Story`/`Subtask`/`Task`/`Initiative` as a value), or a relationship term (`Epic-link`; `parent`/`checklist` as a Jira relationship value). Whitelist the neutral level names + config label-prefix keys.
- [x] T013 [US2] Resolve every violation the gate surfaces — move any residual Jira token out of the engine path and behind the sink/config — until `engine_vendor_neutral.bats` is green AND the full suite still passes UNCHANGED.

**Checkpoint**: US2 makes lift-readiness self-enforcing; the engine cannot silently re-acquire Jira knowledge.

---

## Phase 5: User Story 3 — Non-default board shape is idempotent end-to-end (P2)

**Goal**: prove the engine-driven full stack is zero-churn for a non-default shape.

**Independent test**: the new T056 integration test asserts 0/0/0 on a re-run.

- [ ] T014 [P] [US3] Integration test `tests/integration/us_fullstack_nondefault_zerochurn.bats` (T056) — a configured NON-DEFAULT mapping (a custom phase/operator label set + a configured parent relationship) mirrored through the wired engine, then re-run, asserts **0 created / 0 updated / 0 parent-write (PUT)** across every parent-bearing level (the full-stack analogue of the sink-level F1/F3/F4 zero-churn assertions; SC-004).

**Checkpoint**: US3 closes the full-stack idempotency loop for configured shapes.

---

## Phase 6: Polish & Cross-Cutting

- [ ] T015 [P] `shellcheck --severity=style src/*.sh` clean; fix any finding from the re-platforming.
- [ ] T016 [P] markdownlint-clean across `specs/003-engine-orchestration-unification/**/*.md` and any touched `*.md`.
- [ ] T017 [P] Update `CHANGELOG.md` (Unreleased: engine orchestration unification — internal re-platforming, no operator-observable change; engine path is now vendor-neutral, gate-enforced).
- [ ] T018 [P] Extend `tests/unit/no-real-identifiers.bats` only if new fixtures were added (T056's config) — confirm placeholders only (Privacy IX).
- [ ] T019 Run the exact CI locally via `scripts/check.sh` (shellcheck + yamllint + markdownlint + bats) and fix to green before pushing.
- [ ] T020 Final live-dogfood equivalence pass + a light holistic review (idempotency/drift/fail-closed unchanged in every mode), then open the `003 → main` PR.

---

## Dependencies & completion order

- **Setup (T001)** → **Foundational (T002–T006)** block the unification.
- **US1 (T007–T011)** depends on Foundational; it is the MVP (the unification +
  its byte-for-byte equivalence + the orchestrator deletion).
- **US2 (T012–T013)** depends on US1 (it audits the unified engine path).
- **US3 (T014)** depends on US1 (it drives the wired engine).
- **Polish (T015–T020)** last.

Story order: US1 → US2 → US3.

## Parallel execution examples

- Foundational unit tests T002, T003, T006 (separate files) run together before
  the `reconcile.sh`/`jira_sink.sh` implementations (T004, T005 — sequential,
  same files).
- US2's gate (T012) and US3's T056 (T014) touch different test files and can be
  authored in parallel once US1 lands.

## Implementation strategy

- **MVP = Phase 1 + 2 + US1** (T001–T011): the re-platforming proven equivalent —
  the whole point of the feature.
- The equivalence oracle is the **unchanged** existing suite; run it after EVERY
  step (T008/T009/T010/T013) and diff the curl-shim request log against the T001
  baseline. Any byte difference is a regression to fix, not a test to edit.
- Then US2 (enforce the neutral surface) and US3 (full-stack idempotency proof).
  Run `scripts/check.sh` before every push.
