# Feature Specification: Engine Orchestration Unification

**Feature Branch**: `003-engine-orchestration-unification`

**Created**: 2026-06-08

**Status**: Draft

**Input**: User description: "Engine orchestration unification — the in-repo,
behavior-preserving prerequisite for the engine extraction (feature 003). Wire
the mapping-driven projection (sync_level_artifact + link_to_parent) into the
engine's per-spec orchestration, replacing the 001-era hardcoded orchestrators,
so the engine half of reconcile.sh becomes vendor-neutral and lift-ready — with
zero behavioral change (the 347-test suite + all six mapping modes + live
dogfood stay byte-for-byte identical). Build from EXTRACTION-PLAN.md and the
deferred tasks T055/T056. Out of scope: the multi-repo carve-out, the
iso_to_epoch fix-at-source, any rename."

## Clarifications

### Session 2026-06-08

- Q: Physical scope — split the engine into its own file/repo now, or make it
  vendor-neutral in place? → A: **Vendor-neutral IN PLACE, no physical file/repo
  split in this feature.** Establish a clean, *enforced* logical engine↔sink seam
  so the eventual physical lift is near-mechanical and done **once** (directly to
  the shared repo in the carve-out feature), rather than splitting files twice.
- Q: What happens to the 001-era orchestrators (`ensure_repo_epic` /
  `sync_spec_issue` / `sync_task_phase_subissues`) once the generic projection
  drives all levels? → A: **Delete them once unused** — migrate their behavior
  (disposition tally, spec→Story drift anchor, status transitions, repo-Epic
  find-or-create) into the generic projection, leaving no second Jira-shaped path.
- Q: Is the engine's vendor-neutrality (SC-003 / US2) an enforced gate or a
  documented criterion? → A: **An enforced committed test gate** — a static audit
  over the enumerated engine-orchestration functions that FAILS CI if any Jira
  issue-type id, artifact-name literal (Epic / Story / Subtask / Task), or
  relationship term leaks in.

## User Scenarios & Testing *(mandatory)*

This feature is an **internal re-platforming** of the reconcile engine's
orchestration. Its two audiences are (a) the **operator**, who must observe **no
change whatsoever** — every mirror, every re-run, every exit code is identical;
and (b) the **maintainer preparing the engine extraction**, who needs the engine
half of `reconcile.sh` to be genuinely vendor-neutral so it can be lifted into a
shared library without dragging Jira-shaped orchestration with it. The existing
test suite and the live dogfood are the behavioral oracle.

### User Story 1 - The operator sees no change (behavior-preserving unification) (Priority: P1) 🎯 MVP

The engine's per-spec orchestration is re-platformed so that every artifact level
(repo, spec, phase, task, and the optional Initiative super-level) is projected
through the single mapping-driven projection path instead of the 001-era
per-level orchestrators. From the operator's seat nothing changes: the same
issues are created, the same fields updated, the same links and comments made,
the same statuses transitioned, the same run summary printed, the same exit
codes returned — in every one of the six mapping modes.

**Why this priority**: This is the whole feature and its safety promise. A
re-platforming that changed observable behavior would be a regression, not a
refactor. The existing 347-test suite plus the live dogfood are the regression
anchor; if they stay green and unchanged, the unification is correct.

**Independent Test**: Run the complete existing unit + integration suite, and a
live re-reconcile of the already-mirrored board in each mode, against the
re-platformed orchestration. Every test passes **unchanged** (no test edited to
accommodate a behavior change), and every live re-run is zero churn.

**Acceptance Scenarios**:

1. **Given** the default (no-`mapping:`) configuration, **When** the engine
   reconciles a fresh corpus through the unified orchestration, **Then** it
   creates exactly the same artifacts (repo Epic, spec Story, per-phase Subtasks,
   in-body task checklist) with the same issue types, identity labels, parent
   links, and statuses as the pre-change 001 path — byte-for-byte.
2. **Given** any already-mirrored corpus in any of the six modes, **When** the
   operator reconciles again, **Then** zero writes occur (0 created / 0 updated /
   0 link / 0 transition) — identical to the pre-change zero-churn behavior.
3. **Given** the full existing test suite, **When** it runs against the
   re-platformed orchestration, **Then** every test passes with no test
   modified to accommodate a behavioral difference (only additive tests allowed).

---

### User Story 2 - The engine is vendor-neutral and lift-ready (Priority: P1)

The maintainer needs to lift the reconcile engine into a shared, sink-agnostic
library. After unification, the engine's orchestration path drives only neutral
level iteration and sink calls — it carries **no** Jira issue-type identifiers,
no Jira artifact-name literals (Epic / Story / Subtask / Task), and no
relationship vocabulary (parent / Epic-link / checklist). All of that knowledge
lives behind the sink and config layers, where it belongs.

**Why this priority**: This is the *purpose* of the feature — the unblocking
criterion for the subsequent multi-repo extraction. Without it, an extracted
engine would still embed the default 3-level Jira call shape, making the lift a
rewrite rather than a move.

**Independent Test**: The enforced committed neutrality gate (FR-012) — a static
audit over the enumerated engine-orchestration functions — passes: zero Jira
issue-type ids, zero artifact-name literals, and zero relationship-vocabulary
references in the engine path; every such concept is resolved behind the sink +
config seam, and CI fails if one leaks back in.

**Acceptance Scenarios**:

1. **Given** the re-platformed orchestration, **When** its source is audited for
   vendor-specific tokens (issue-type ids, artifact names, relationship terms),
   **Then** none appear in the engine orchestration path; they appear only in the
   sink and config layers.
2. **Given** the unified orchestration, **When** a level resolves to any
   configured artifact or relationship, **Then** the engine learns the
   projection result through neutral sink calls and dispositions, never by
   inspecting Jira-specific values itself.

---

### User Story 3 - A non-default board shape is idempotent end-to-end (Priority: P2)

An operator who has configured a non-default mapping (a custom phase/operator
label set and a configured parent relationship) reconciles, then reconciles
again, and the second run performs zero writes across every parent-bearing
level — the full-stack idempotency guarantee, proven end-to-end through the
wired engine rather than only at the sink-unit level.

**Why this priority**: The 002 sink-level tests proved `sync_level_artifact` /
`link_to_parent` are zero-churn in isolation; this closes the loop by proving the
*engine-driven* full stack is zero-churn for a non-default shape — the
behavior most likely to regress when the orchestration changes.

**Independent Test**: Configure a non-default label/parent mapping, reconcile to
create the mirror, then re-run and assert 0 created / 0 updated / 0 parent-write
across every level.

**Acceptance Scenarios**:

1. **Given** a configured non-default label set and parent relationship,
   **When** the engine mirrors the corpus through the unified orchestration,
   **Then** each level projects to its configured artifact with its configured
   labels and parent link.
2. **Given** that same corpus already mirrored, **When** the operator reconciles
   again, **Then** zero creates, zero field updates, and zero parent writes occur
   across every parent-bearing level (full-stack SC-004 analogue).

---

### Edge Cases

- **A level resolving to the `checklist` sentinel (2-level mode)**: the unified
  orchestration creates no child issue for that level and renders the in-body
  checklist instead — identical to today.
- **The repo (top) level**: has no parent (relationship `none`); the unified
  path must not attempt a parent link for it.
- **The Initiative super-level**: continues to probe-then-create-or-degrade above
  the repo level with identical behavior (create where the type exists, degrade
  onto the Epic where it does not), never hard-failing.
- **A fail-closed read mid-projection** (an unreadable lookup at any level): the
  run fails closed exactly as before — no partial write, the same exit code.
- **The `--workstate` direct-input path**: the per-item orchestration is unified
  the same way as the per-spec path, with `spec_input` gracefully absent.
- **A Task-projected level**: matched/updated by its task-identity label, so a
  re-run updates rather than re-creates — unchanged.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The engine MUST project every configured level (repo, spec, phase,
  task, and the optional Initiative super-level) through the mapping-driven
  projection (`sync_level_artifact` + `link_to_parent`, plus the existing
  2-level checklist / status-rollup / Initiative wiring), replacing the 001-era
  per-level orchestrators in the per-spec driver. The 001-era orchestrators
  (`ensure_repo_epic` / `sync_spec_issue` / `sync_task_phase_subissues`) MUST be
  **deleted once unused** — their behavior (disposition tally, spec→Story drift
  anchor, status transitions, repo-Epic find-or-create) migrates into the generic
  projection, leaving no second Jira-shaped path (Clarifications 2026-06-08).
- **FR-002**: The re-platformed orchestration MUST produce identical observable
  Jira writes — the same creates, field updates, links, comments, and
  transitions, with the same payloads, identity labels, and parents — to the
  pre-change behavior, across all six mapping modes (default 3-level, configured
  per-level mapping, 2-level checklist, status rollup, Initiative super-level,
  workstate-direct). The existing test suite and live dogfood are the oracle.
- **FR-003**: The engine MUST preserve the per-level disposition tally
  (created / updated / skipped / failed) that drives the run summary, unchanged.
- **FR-004**: The engine MUST preserve the spec→Story backward-drift anchor, the
  cross-spec dependency links, and the clarify comments exactly as today.
- **FR-005**: The 2-level checklist, status-rollup, and Initiative super-level
  behaviors MUST be byte-for-byte identical after unification (off by default
  where they were off by default).
- **FR-006**: The engine orchestration path MUST carry no Jira/issue-type/
  relationship knowledge — issue-type ids, artifact-name literals (Epic / Story /
  Subtask / Task), and relationship vocabulary live ONLY behind the sink and
  config layers (the lift-readiness criterion; the vendor-neutral boundary,
  strengthened).
- **FR-007**: Idempotency (zero-churn re-run), drift-awareness on the spec→Story
  unit, and fail-closed reads MUST hold in every mode, including the new
  full-stack non-default-shape test (0 created / 0 updated / 0 parent-write on
  re-run).
- **FR-008**: Both entrypoints — the `specs/`-tree per-spec path and the
  `--workstate` direct-input per-item path — MUST be unified onto the same
  mapping-driven orchestration.
- **FR-009**: The default (no-`mapping:`) mode MUST remain byte-for-byte
  identical to the shipped 001 behavior — the frozen regression anchor.
- **FR-010**: The change MUST be a pure internal re-platforming with no
  operator-facing surface change: no new config keys, no new flags, identical CLI
  usage and exit codes.
- **FR-011**: No real Jira coordinates or PII may appear in any tracked file
  (Privacy IX); the privacy guard stays green.
- **FR-012**: The vendor-neutral boundary MUST be guarded by an **enforced
  committed test** — a static audit over the enumerated engine-orchestration
  functions that fails CI if any Jira issue-type id, artifact-name literal
  (Epic / Story / Subtask / Task), or relationship-vocabulary term appears in the
  engine path (Clarifications 2026-06-08). The audited surface is enumerated in
  the plan; the gate makes SC-003 self-checking and prevents lift-readiness from
  silently regressing.
- **FR-013**: This feature performs **no physical file or repo split**: the
  engine orchestration becomes vendor-neutral where it lives, behind a clean,
  enforced logical engine↔sink seam. The physical lift into a shared repo is
  deferred to the carve-out feature (Clarifications 2026-06-08).

### Key Entities *(include if feature involves data)*

- **Level**: a neutral structural unit the engine iterates — repo, spec, phase,
  task, plus the optional Initiative super-level above repo. The engine knows
  levels and their parent ordering; it does not know their Jira artifact types.
- **Projection**: the sink operation that creates/updates a level's configured
  artifact and links it to its parent by the configured relationship, returning a
  neutral disposition.
- **Orchestration path**: the engine's neutral per-spec / per-item driver that
  iterates levels and invokes projections — the surface that must become
  vendor-neutral and lift-ready.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of the existing unit + integration tests pass **unchanged**
  against the re-platformed orchestration — no test edited to accommodate a
  behavioral difference; only additive tests are introduced.
- **SC-002**: A live re-reconcile of the already-mirrored board is 0 created /
  0 updated (zero churn) in every mapping mode — identical to the pre-change
  behavior.
- **SC-003**: A static audit of the engine orchestration path finds **zero**
  Jira issue-type ids, **zero** artifact-name literals, and **zero**
  relationship-vocabulary references — all such concepts resolve behind the sink
  + config seam. This audit is an **enforced committed test** (FR-012), not a
  one-time manual check, so the boundary cannot silently regress.
- **SC-004**: The new full-stack non-default-shape idempotency test asserts
  0 created / 0 updated / 0 parent-write across every parent-bearing level on a
  re-run.
- **SC-005**: The default-mode projection is byte-identical to the 001 baseline
  (the regression anchor holds: same artifact counts, types, labels, parents,
  statuses).

## Assumptions

- The sink primitives `sync_level_artifact` and `link_to_parent` (shipped and
  unit + integration tested in feature 002) are the projection mechanism this
  feature **wires**, not re-implements.
- "Identical observable writes" is measured against the existing tests' assertions
  (request method + URL + payload shape + counts) and the live zero-churn result —
  not against the engine's internal call order. Re-platforming may change *how*
  the projection is driven, never *what* reaches Jira.
- The 001-era orchestrators (`ensure_repo_epic` / `sync_spec_issue` /
  `sync_task_phase_subissues`) are **deleted once unused** (resolved in
  Clarifications 2026-06-08); their behavior migrates into the generic projection.
  No second Jira-shaped path remains.
- This feature does **no physical file/repo split** (resolved in Clarifications
  2026-06-08); the engine becomes vendor-neutral in place behind an enforced
  logical seam, and the physical lift is the carve-out feature's job.
- The Initiative super-level and status rollup keep their existing (already
  level-aware) wiring; unification need not relocate them so long as behavior is
  identical.
- The multi-repo carve-out (shared engine repo, `source-speckit` producer,
  backporting `spec-kit-linear`), the `git_helpers::iso_to_epoch` fix-at-source,
  and any rename are **out of scope** — deferred to the subsequent extraction
  feature; the per-sink timestamp normalization is retained for now.
- The behavioral oracle (the 347-test suite + the live dogfood board) is current
  and trustworthy as of the 002 merge.
