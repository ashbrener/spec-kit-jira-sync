# Tasks: Jira Install + Seed Ceremony

**Feature**: 008-install-seed-ceremony | **Branch**: `008-install-seed-ceremony`

**Input**: plan.md, research.md (R1–R11), data-model.md (VR-1..VR-9),
contracts/install-seed.md (C-1..C-12), spec.md (FR-001..FR-013, SC-001..SC-007)

**Strategy**: Strict TDD (tests before impl). Install/seed are **sink-side**
config-resolution commands — they reuse `jira_rest::get` (transport) +
`mapping::detect_available_types` (issue-type probe), and the only shared-module
change is an additive `config::write_binding` (the reader gains a writer). The
engine path is untouched (003 neutrality stays green). All tests run **offline**
via `tests/helpers/jira-shim.bash` (shimmed REST responses) and prove
byte-identical idempotent writes + fail-closed-no-write. Privacy IX is a hard gate.

**Conventions**: `[P]` = parallelizable (disjoint files, no incomplete dep).
Tests precede their implementation. Tick `[ ]`→`[X]` as completed. No new exit
code — reuse 2 (config/missing inputs) + 3 (Jira unreadable).

---

## Phase 1: Setup

- [X] T001 [P] Create `src/install.sh` skeleton: vendor-aware sink header (state: sink-side config resolution, not engine — reuses jira_rest + config), `set -euo pipefail`, `# shellcheck source=` wiring for `jira_rest.sh` + `config.sh` + `summary.sh`, and empty stubs `install::{main,parse_args,guard_source_target,dependency_report,resolve,promote_exit}`.
- [X] T002 [P] Create `src/seed.sh` skeleton: same header/sourcing shape, stubs `seed::{main,parse_args,validate_labels,confirm_reachability,promote_exit}`.
- [X] T003 [P] Register the two commands in `extension.yml` `provides.commands`: `speckit.jira.install` → `commands/jira-install.md`, `speckit.jira.seed` → `commands/jira-seed.md`, each with a one-line description (mirror the push/status entries).
- [X] T004 [P] Stub `commands/jira-install.md` + `commands/jira-seed.md` (agent-executed bodies, frontmatter mirroring `commands/jira-push.md`: `name:`, `description:`, `arguments:`) and the dev-layout twins `.claude/commands/speckit-jira-{install,seed}.md`. Bodies filled in US1/US2.

**Checkpoint**: `bash -n src/install.sh src/seed.sh` parses; `yamllint -d relaxed`
passes on `extension.yml`; the two commands appear in the manifest.

---

## Phase 2: Foundational (blocks all user stories)

**TDD — write each test first, watch it fail, then implement.**

### `config::write_binding` (the new writer — VR-5, VR-6)

- [X] T005 Test in `tests/unit/config_write.bats` (new): given resolved values (project_key + issue_types.{epic,story,subtask} + 6 phase_status ids), `config::write_binding` into a fresh temp path copies `config-template.yml` shape and substitutes every placeholder; assert the written file `config::load`s back to exactly those ids (round-trip). (C-1 unit half)
- [X] T006 Test (same file) **byte-stable idempotency (C-3/VR-5)**: call `config::write_binding` twice with the same resolved values into the same path; assert the two outputs are **byte-identical** (no timestamp/nonce; `cmp` clean).
- [X] T007 Test (same file) **operator-block preservation (C-4/VR-6)**: seed the target with a config that has an operator-authored `mapping:` (non-default) + `attribution:` + `remode:` block; run `config::write_binding` with new resolved ids; assert the resolved id fields changed but the `mapping:`/`attribution:`/`remode:` blocks are **byte-for-byte unchanged**.
- [X] T008 Implement `config::write_binding <path> <resolved-kv…>` in `src/config.sh`: fresh path absent ⇒ copy `config-template.yml`; then per-line awk/sed within block scope substitute `project_key`, each `issue_types.*`, each `phase_status.*`, and the optional story-points field into their placeholder positions; existing path ⇒ substitute only the resolved id fields, leaving `mapping:`/`attribution:`/`remode:` and all untouched lines verbatim. Stable key order, no timestamp/nonce; write via temp file + `mv` (atomic); target the gitignored path only. No vendor vocabulary beyond the Jira config field names already in `config.sh`.

### `install::guard_source_target` (FR-007 / C-7)

- [X] T009 [P] Test in `tests/unit/install.bats` (new): with the target repo root == the bridge's own extension source root, `install::guard_source_target` returns non-zero (exit-2 intent); with distinct roots, returns 0.
- [X] T010 Implement `install::guard_source_target` in `src/install.sh`: canonicalize the extension source root and the target repo root (`cd … && pwd -P`) and compare; additionally flag when the target `specs/` are the bridge's own; equal ⇒ `summary::add error` + `promote_exit 2` + return non-zero, before any probe/write.

### Dependency report + exit promotion (FR-004 / FR-005)

- [X] T011 Test in `tests/unit/install.bats`: `install::dependency_report` — (a) all-present (shimmed `myself` 200, jq/curl/git present, project readable) ⇒ rc 0, no error rows; (b) missing a `JIRA_*` var ⇒ rc maps to exit 2 with a row naming the var + remediation; (c) shimmed `myself` 401/403 ⇒ rc maps to exit 3 (Jira unreadable). Assert **no config is written** in the failing cases.
- [X] T012 Implement `install::dependency_report` in `src/install.sh`: per-check `✓`/`⚠`/`✗` rows via `summary::add` — `.env` has `JIRA_BASE_URL`/`JIRA_EMAIL`/`JIRA_API_TOKEN`; authenticate via a `GET myself` probe (`jira_rest::get myself`); `jq`/`curl`/`git` present; the target project key readable (`GET project/<key>`). Any `✗` ⇒ exact copy-paste remediation + fail closed (exit 2 for missing local inputs/tools, exit 3 for an unreadable/forbidden Jira). Writes nothing.
- [X] T013 Implement `install::promote_exit` (and reuse the pattern for `seed::promote_exit`) in `src/install.sh`/`src/seed.sh`: monotonic escalation mirroring `reconcile::promote_exit` (2 terminal-ish over 3 over 1 over 0).

**Checkpoint**: `bats tests/unit/config_write.bats` green; the guard + dep-report
units green; nothing writes on a failed precondition.

---

## Phase 3: User Story 1 — install resolves the binding (P1) 🎯 MVP

**Goal**: a fresh consumer repo + valid `.env` ⇒ `/speckit-jira-install` writes a
complete gitignored `jira-config.yml`; `reconcile.sh --dry-run` then runs without
an exit-2 config halt — zero manual id-editing. **Independent test**: shimmed
resolve → complete binding → dry-run clean.

### Tests first

- [X] T014 [P] [US1] Test `install::resolve` in `tests/unit/install.bats`: with shimmed `GET project/<key>` (issueTypes), `GET project/<key>/statuses` (a To Do / In Progress / Done set with statusCategory), and `GET field` (a story-points field), assert it captures `issue_types.{epic,story,subtask}` ids, a default phase→status map for the 6 lifecycle phases by statusCategory (new→specifying/planning, indeterminate→tasking/implementing, done→ready_to_merge/merged), and the story-points field id — all as **ids** (C-2), into in-memory resolution state.
- [ ] T015 [US1] Integration test `tests/unit/install_us1.bats` (new, curl-shim): run `install::main` (non-interactive, `--project PROJ --phase-status …` or shimmed defaults) end-to-end; assert a complete `jira-config.yml` is written to the gitignored path (project_key + issue-type ids + 6 phase_status ids), and that `reconcile.sh --dry-run` then runs **without exit 2** (config complete). (C-1)
- [ ] T016 [US1] Test (same file) **story-points absent (C-11)**: shim `GET field` with no story-points field; assert `install::main` still succeeds (exit 0), records the field as absent with a surfaced note, and writes a complete binding (the absent optional field is not fatal).
- [ ] T017 [US1] Test (same file) **idempotent (C-3 e2e)**: run `install::main` twice against the same shimmed project; assert the second run's `jira-config.yml` is byte-identical to the first.

### Implementation

- [X] T018 [US1] Implement `install::resolve` in `src/install.sh`: REST-only via `jira_rest::get` — reuse `mapping::detect_available_types` for project + `issue_types.{epic,story,subtask}` (and task/initiative only if a `mapping:` level needs them); `GET project/<key>/statuses` → group by `statusCategory` → propose the default phase→status map for the 6 lifecycle phases, operator confirms/adjusts interactively or via `--phase-status <phase>=<statusName|id>` (non-interactive); capture the chosen **status id** per phase; leave `transitions: {}`; `GET field` best-effort for the story-points id (record absent-note when missing). An unmappable phase in non-interactive mode ⇒ `promote_exit 2` naming it. Populate in-memory resolution state only.
- [X] T019 [US1] Implement `install::parse_args` + `install::main` wiring in `src/install.sh`: parse `--project`, `--non-interactive`, repeated `--phase-status <p>=<s>`, `--with-seed`/`--no-seed`; orchestrate `guard_source_target` → `dependency_report` → `resolve` → **`config::write_binding` once** (resolve-in-memory, write-once — no partial binding on any earlier failure). Exit via `install::promote_exit`.
- [ ] T020 [US1] Fill `commands/jira-install.md` (+ `.claude/commands/speckit-jira-install.md` twin): agent-executed body — `cd "$(git rev-parse --show-toplevel)" && set -a && source .env && set +a && bash src/install.sh <flags>`; report the resolved project key, issue-type ids, the 6 phase→status mappings, and the story-points field (or its absence); explain exit 2 (config/missing inputs) vs 3 (Jira unreadable); on success **offer to run seed** unless `--no-seed` (FR-013).

**Checkpoint**: `bats tests/unit/install_us1.bats` green; a shimmed install writes a
complete binding, reconcile-dry-run is clean, re-run is byte-identical.

---

## Phase 4: User Story 2 — seed validates the lifecycle (P1)

**Goal**: `/speckit-jira-seed` validates the `phase:*`/`task-phase:N` labels +
confirms every lifecycle status/transition is reachable; idempotent; never mutates
the workflow.

- [ ] T021 [US2] Test `tests/unit/seed_us2.bats` (new, curl-shim) **validate + reachability (C-8)**: with a bound config + shimmed `GET project/<key>/statuses` covering all 6 `phase_status` ids, run `seed::main`; assert it validates the `phase:*`/`task-phase:N` prefixes, confirms each phase_status reachable, and that a re-run is a **byte-identical no-op** on the config.
- [ ] T022 [US2] Test (same file) **unreachable status (C-9)**: shim `GET project/<key>/statuses` missing one configured `phase_status` id; assert `seed::main` fails closed (**exit 2**) naming exactly which lifecycle step is unreachable, and **no partial binding** is written.
- [ ] T023 [US2] Implement `seed::validate_labels` in `src/seed.sh`: read `labels.{spec_prefix,repo_prefix,phase_prefix,lifecycle_prefix,task_prefix}`; confirm the `phase:*`/`task-phase:N` prefixes are well-formed/normalized; never pre-create labels (they auto-create on first reconcile use).
- [ ] T024 [US2] Implement `seed::confirm_reachability` + `seed::main` in `src/seed.sh`: for each of the 6 `phase_status` ids, `GET project/<key>/statuses` confirms the status exists + a representative transition reaches it; capture/confirm ids via `config::write_binding`; **never** mutate the workflow. Fail closed (`promote_exit 2`) naming the unreachable lifecycle step; resolve-in-memory then write-once (no partial). Idempotent byte-identical no-op on a healthy project.
- [ ] T025 [US2] Fill `commands/jira-seed.md` (+ `.claude/commands/speckit-jira-seed.md` twin): agent-executed body — export `.env`, run `bash src/seed.sh <flags>`; report the label-prefix validation, per-phase reachability, and any exit-2 fail-closed naming the unreachable step.

**Checkpoint**: `bats tests/unit/seed_us2.bats` green.

---

## Phase 5: User Story 3 — dependency verification / fail-closed (P2)

**Goal**: missing precondition ⇒ fail closed, exact remediation, zero bytes
written.

- [ ] T026 [US3] Test `tests/unit/install_us3.bats` (new, curl-shim) **C-5**: missing/blank `.env` (no `JIRA_*`) ⇒ `install::main` exits 2, the summary names the missing var(s) + the exact `.env` lines to add, and **no `jira-config.yml` is written** (assert the path does not exist / is unchanged).
- [ ] T027 [US3] Test (same file) **C-6**: present but non-authenticating credential (shim `myself` 401/403) ⇒ exit 3 (Jira unreadable), named, **zero bytes written**.
- [ ] T028 [US3] Test (same file) **C-7 e2e**: run `install::main` with the target == the bridge checkout ⇒ exit 2 (source==target), nothing written.
- [ ] T029 [US3] Implement any remaining fail-closed wiring in `src/install.sh` so T026–T028 pass: the dependency report + guard run **before** resolve; the single `config::write_binding` is reached only after all preconditions pass (structural no-partial-write). (Most logic already in T010/T012/T019 — this task closes the gaps the tests reveal.)

**Checkpoint**: `bats tests/unit/install_us3.bats` green; every failure writes zero
bytes.

---

## Phase 6: Polish & Cross-Cutting

- [ ] T030 [P] Privacy (C-10): extend `tests/unit/no-real-identifiers.bats` to assert any new committed fixture (shimmed REST response bodies under `tests/fixtures/jira_responses/…`, the command bodies) is placeholder-only (no real site/key/id/email); and add a test that after a (shimmed) `install::main` writes the gitignored `jira-config.yml`, `git ls-files` does NOT include it (the written path is gitignored) so the 006 consumer-side guard + this guard stay green.
- [ ] T031 [P] Neutrality (C-12): run `bats tests/unit/engine_vendor_neutral.bats` and confirm green — install/seed are NOT in the audited engine-function list and add no vendor vocabulary to any audited engine function (they are sink/config-side). No change expected; this is a guard-confirmation task.
- [ ] T032 [P] Docs: update `config-template.yml`'s "Auto-discovery … is a later feature; for now you fill them in by hand" note → "run `/speckit-jira-install` to resolve these automatically"; update the README **Install** section so "you fill the ids by hand" → "run `/speckit-jira-install`" and mark the auto-resolve roadmap item done; update `quickstart.md` references as needed.
- [ ] T033 [P] Add a `CHANGELOG.md` `[Unreleased]` entry: "Jira install + seed ceremony — `/speckit-jira-install` REST-resolves the binding (project key, issue-type ids, lifecycle phase→status maps, story-points field) and writes the gitignored config; `/speckit-jira-seed` validates the labels + confirms the lifecycle mapping is reachable. Fail-closed (exit 2/3), idempotent, Privacy IX."
- [ ] T034 Run the **full CI gate** locally (CI parity): `shellcheck --shell=bash --severity=style src/*.sh`, `yamllint -d relaxed .github/workflows/ci.yml` (+ `extension.yml` if linted), `npx --yes markdownlint-cli2 "specs/**/*.md" "*.md"`, `bats --recursive tests/unit`. All green.
- [ ] T035 Open the PR into `main` (branch `008-install-seed-ceremony`): title `feat(install): Jira install + seed ceremony — resolve the binding (no more hand-editing)`; body cites FR-001..FR-013, the REST-authoritative/seed-validates design, Privacy IX + 003 neutrality, "implements the constitution's Operational-Workflow Install+Seed — no amendment". Confirm the full bats matrix + neutrality + privacy gates green in CI.

---

## Dependencies & ordering

- **Phase 1 (T001–T004)** → **Phase 2 (T005–T013)** → **US1 (T014–T020)**.
- **US2 (T021–T025)** depends on `config::write_binding` (T008) + the resolve/
  transport foundation; independent of US3.
- **US3 (T026–T029)** depends on US1's `install::main` wiring (T019) — it tests its
  fail-closed gates.
- **Phase 6** after US1–US3. T034 (full gate) precedes T035 (PR).

## Parallel execution examples

- **Phase 1**: T001 ∥ T002 ∥ T003 ∥ T004 (disjoint files).
- **Phase 2**: `config_write.bats` tests (T005–T007) are sequential within that
  file; T009 (`install.bats` guard test) is ∥ to the config_write work.
- **US1 tests**: T014 (`install.bats`) ∥ the `install_us1.bats` group (T015–T017).
- **Phase 6**: T030 ∥ T031 ∥ T032 ∥ T033 (distinct files), then T034 → T035.

## MVP scope

**US1 (Phase 1 + 2 + 3)** is the shippable MVP: `/speckit-jira-install` resolves +
writes the binding, ending the hand-edit. US2 (seed validation) + US3
(fail-closed/remediation) land in the same PR for the full ceremony.

## Implementation strategy

Strict TDD: `config::write_binding` (the riskiest new piece — byte-stability +
operator-block preservation) is test-first in Phase 2. The curl-shim integration
tests (T015–T017, T021–T022, T026–T028) are the SC-001/SC-003/SC-005 proofs —
complete-binding, byte-identical-idempotent, fail-closed-zero-write. Install/seed
stay sink-side; the engine + neutrality gate are untouched (T031). Privacy IX
(T030) gates the fixtures + the gitignored-write assertion. No new exit code, no
amendment.
