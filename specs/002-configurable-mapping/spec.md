# Feature Specification: Configurable Artifact Mapping

**Feature Branch**: `002-configurable-mapping`

**Created**: 2026-06-03

**Status**: Draft

**Input**: User description: "Make the spec-kit→Jira artifact mapping operator-configurable instead of the hardcoded repo→Epic / spec→Story / phase→Subtask / task→checklist default, while keeping today's behavior as the frozen zero-config default. Real Jira projects vary (issue-type sets differ by board template; teams want fewer issues; some have Initiative, some don't). Add: per-level issue-type + relationship mapping with semantic validation; detection of the project's available issue types (a Kanban template has no Story); a 2-level checklist mode; an optional off-by-default Initiative super-level that degrades gracefully; an optional off-by-default status rollup so completion shows on the board; a back-compat alias layer; and a workstate-direct input seam so the sink can run without the spec-kit parser. Idempotency, drift-awareness, fail-closed reads, and privacy must hold in every mode. Build from specs/002-configurable-mapping/DESIGN-DRAFT.md; its §2 locked decisions are constraints and its §7 Q2–Q11 are the clarify questions."

## Clarifications

### Session 2026-06-03

- Q: When a configured Jira issue type is absent in the target project (e.g. Kanban has no Story), what happens? → A: Hard-error at config-load (fail-closed, no write), with an optional explicit per-level fallback (e.g. `on_absent: Story→Task`) as the only escape.
- Q: How is a workstate document accepted directly, skipping the parser? → A: A `--workstate` flag on the existing reconcile entrypoint taking a file path or `-` for stdin, validated against the pinned workstate schema on entry; the Initiative narrative source is gracefully absent in this mode.
- Q: Which relationships may be used as hierarchy (parent→child) links? → A: Only `parent` / `Epic-link` / `none` / `checklist`; `Blocks`/`Relates`/`Implements` are rejected as hierarchy links and `Epic-link` between two non-Epic levels is rejected — all hard-halt at config-load.
- Q: How does 2-level checklist mode stay zero-churn on re-run? → A: Key each checklist item by its workstate task id and byte-compare only the checklist sub-tree, writing the body only when that sub-tree changes (unrelated description edits do not trigger a rewrite).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A no-config upgrade changes nothing (Priority: P1)

An operator who already mirrors a repo into Jira upgrades to the version with
configurable mapping and changes no configuration. Their next reconcile produces
exactly the same Epic / Story / Subtask / checklist result as before — no new
issues, no rewritten fields, no surprises.

**Why this priority**: This is the safety promise and the regression anchor for
the whole feature. The flexibility is worthless if it silently changes existing
boards. Shipping just this slice (the alias layer that synthesizes today's
default mapping when none is configured) is already a viable, valuable release:
"upgrade safely, opt in later."

**Independent Test**: Run a reconcile with an existing pre-feature config (no
mapping block) and confirm the created/updated/skipped result is byte-identical
to the prior version's, including a zero-churn re-run.

**Acceptance Scenarios**:

1. **Given** a config with no mapping block, **When** the operator reconciles,
   **Then** the bridge mirrors repo→Epic, spec→Story, phase→Subtask, and
   tasks→an in-body checklist exactly as the shipped default does.
2. **Given** that same corpus already mirrored, **When** the operator reconciles
   again, **Then** zero writes occur (no duplicate issues, no rewritten fields).
3. **Given** an explicit mapping block that spells out today's default, **When**
   the operator reconciles, **Then** the result is identical to the no-block case.

---

### User Story 2 - Configure the mapping to fit my board, safely (Priority: P1)

An operator whose Jira project does not match the default shape chooses, per
spec-kit level, which Jira issue type it becomes and how it links to its parent.
Before anything is written, the bridge checks the chosen types against the
project's actual available issue types and refuses to start if a chosen type does
not exist there — so a board that has no "Story" type (common on Kanban) fails
loudly at configuration time instead of mis-mirroring.

**Why this priority**: This is the core value — the flexibility that makes the
bridge usable on boards the fixed default can't serve. The available-type check
is inseparable from it: without it, a configured-but-absent type would silently
corrupt the mirror (the exact failure the live dogfood hit on a Kanban project).

**Independent Test**: Configure a non-default per-level mapping and confirm the
mirror uses the configured types; then configure a type the project lacks and
confirm the run is rejected before any issue is created.

**Acceptance Scenarios**:

1. **Given** a config mapping spec→Epic, phase→Story, task→Task, **When** the
   operator reconciles, **Then** the bridge creates those issue types with the
   configured parent relationships.
2. **Given** a config that maps a level to an issue type absent from the target
   project, **When** the operator reconciles, **Then** the run stops at
   configuration validation with a clear error and writes nothing.
3. **Given** a config with a relationship that is nonsensical as a hierarchy link
   (e.g. a "blocks" link used to nest a child under a parent), **When** the
   operator reconciles, **Then** validation rejects it before any write.

---

### User Story 3 - A leaner board with checklist (2-level) mode (Priority: P2)

An operator who does not want dozens of child issues cluttering the board opts
into a mode where task phases and tasks collapse into a checklist rendered inside
the parent issue's body instead of becoming separate child issues.

**Why this priority**: A frequently requested simplification (the competitor's
main draw), but secondary to having a correct, validated mapping at all. It
depends on the existing in-body content-diff path, so it must preserve zero-churn
re-runs.

**Independent Test**: Configure 2-level mode and confirm no per-phase/per-task
child issues are created, the parent body carries the checklist, and a re-run
against unchanged tasks performs zero writes.

**Acceptance Scenarios**:

1. **Given** 2-level mode, **When** the operator reconciles, **Then** the spec
   issue carries an in-body checklist of the tasks and no Subtask/Task child
   issues are created.
2. **Given** an already-mirrored corpus in 2-level mode, **When** the operator
   reconciles again with no task changes, **Then** zero writes occur (the
   rendered checklist is byte-identical, so nothing is rewritten).
3. **Given** a task's completion toggles on disk, **When** the operator
   reconciles, **Then** only the affected issue's body updates, with no duplicate
   checklist and no unrelated rewrites.

---

### User Story 4 - Completion shows on the board (status rollup) (Priority: P2)

An operator turns on an optional rollup so that a phase whose tasks are all done
moves its issue to a "done" status, and a repo whose specs are all done moves its
top issue to "done" — so a finished feature reads as finished on the board
instead of sitting in "To Do".

**Why this priority**: Closes a real "looks undone when it's done" gap surfaced
by the dogfood, but it is additive and off by default, so it ranks below the core
mapping and the leaner-board mode.

**Independent Test**: With rollup on, complete all tasks in a phase and confirm
its issue moves to done; re-run and confirm no further transition fires.

**Acceptance Scenarios**:

1. **Given** rollup on and every task in a phase checked, **When** the operator
   reconciles, **Then** that phase's issue is transitioned to a done status.
2. **Given** rollup on and every spec complete, **When** the operator reconciles,
   **Then** the repo's top issue is transitioned to a done status.
3. **Given** a rolled-up board with unchanged completion, **When** the operator
   reconciles again, **Then** no transition fires (zero churn).
4. **Given** rollup left off (the default), **When** the operator reconciles,
   **Then** only the spec-level status is set, exactly as today.

---

### User Story 5 - Feed the bridge from workstate directly (Priority: P2)

A producer that is not a spec-kit tree (or a spec-kit tree that wants to skip the
parser) hands the bridge a workstate document — a file or piped on input — and
the bridge mirrors it to Jira without reading a `specs/` directory.

**Why this priority**: It unlocks non-spec-kit producers and is the clean seam
that lets the parser later move out, but the default spec-kit-tree path remains
the primary flow, so it is P2.

**Independent Test**: Run the bridge against a workstate document supplied as a
file and as piped input, and confirm the resulting mirror matches the one
produced from the equivalent `specs/` tree.

**Acceptance Scenarios**:

1. **Given** a valid workstate document supplied as a file, **When** the operator
   runs the bridge in workstate-direct mode, **Then** the mirror matches the
   `specs/`-tree projection of the same content.
2. **Given** a workstate document piped on standard input, **When** the operator
   runs the bridge, **Then** it mirrors the same way as from a file.
3. **Given** a malformed or unsupported workstate document, **When** the operator
   runs the bridge, **Then** it is rejected on entry with a clear error and
   writes nothing.

---

### User Story 6 - Optional narrative super-level above the spec (Priority: P3)

An operator turns on an optional narrative level above the spec — the human
"what are we building" requirement — which maps to a Jira Initiative where the
instance supports it, and otherwise folds onto the Epic with a grouping label
rather than failing.

**Why this priority**: A differentiating capability for teams that track at the
initiative level, but it is off by default, narrative-only, and depends on
instance capabilities — so it is the lowest-priority slice.

**Independent Test**: With the super-level on, run against an instance that
supports Initiative and confirm an Initiative is created; run against one that
does not and confirm the narrative folds onto the Epic with a grouping label and
no hard failure.

**Acceptance Scenarios**:

1. **Given** the super-level on and the instance supports Initiative, **When** the
   operator reconciles, **Then** an Initiative is created above the Epic and the
   narrative is populated only from the explicit source (never inferred).
2. **Given** the super-level on and the instance does not support Initiative,
   **When** the operator reconciles, **Then** the narrative folds onto the Epic
   behind a stable marker, repo grouping becomes a label, and the run succeeds.
3. **Given** the super-level off (the default), **When** the operator reconciles,
   **Then** no narrative level is created and behavior matches User Story 1.

### Edge Cases

- A mapping block specifies only some levels — unspecified levels fall back to
  the synthesized default (per-level inheritance), not an all-or-nothing error.
- The target project supports Initiative at first but the operator later loses
  that capability (or vice versa) — degradation/upgrade must re-home the narrative
  without churn.
- A task is renamed, reordered, or toggled in 2-level mode — the checklist must
  re-render without duplicating items or rewriting unrelated body content.
- workstate-direct input with no originating `spec.md` — the narrative source for
  the super-level is simply unavailable (graceful), not an error.
- A configured relationship is valid in isolation but invalid for the level
  boundary it is placed on (e.g. an Epic-link declared between two non-Epic
  levels) — rejected at validation.
- The drift anchor: even with the super-level on, the spec→Story unit remains the
  backward-drift anchor; the narrative level is not a new drift surface.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST keep today's shipped mapping (repo→Epic, spec→Story,
  phase→Subtask, task→in-body checklist, lifecycle phase→status) as the default
  behavior when no mapping configuration is present.
- **FR-002**: The system MUST synthesize that default mapping from the existing
  configuration keys via an alias layer, so configurations written before this
  feature keep working unchanged with no file rewrite or version bump.
- **FR-003**: The system MUST let an operator configure, per spec-kit level
  (repo, spec, phase, task), which Jira artifact the level projects to and the
  relationship that links it to its parent level.
- **FR-004**: The system MUST support, as opt-in alternatives to the default, a
  3-level mode (spec→Epic, phase→Story, task→Task) and a 2-level mode (phases and
  tasks collapse into an in-body checklist with no child issues).
- **FR-005**: The system MUST read the target project's available issue types and
  validate every configured artifact against that set at configuration-load time,
  before any write.
- **FR-006**: The system MUST treat a configured artifact whose issue type is
  absent from the target project as a configuration-level error and write nothing
  for the affected run, unless an explicit per-level fallback is configured.
- **FR-007**: The system MUST validate configured relationships against a
  matrix of allowed (level-boundary × relationship-type) combinations and reject
  semantically nonsensical hierarchy links (e.g. dependency-style links used to
  nest children) before any write.
- **FR-008**: The system MUST preserve idempotency in every mapping mode: a
  re-run against unchanged state performs zero observable writes, including in
  2-level mode where the in-body checklist MUST re-render byte-identically. The
  checklist MUST be kept stable by keying each item to its workstate task
  identity and comparing only the checklist sub-tree, so unrelated edits to the
  surrounding issue body do not trigger a rewrite.
- **FR-009**: Each created artifact MUST carry a stable, filesystem-derived
  identity (via labels) so re-runs match and update rather than re-create —
  including a defined identity key for levels that project to a standalone Task
  issue.
- **FR-010**: The system MUST preserve backward-drift detection on the spec-level
  work unit in every mode; an enabled narrative super-level MUST NOT become a new
  drift surface.
- **FR-011**: The system MUST offer an optional, off-by-default status rollup that
  transitions a phase's issue to a done status when all its tasks are complete and
  the repo's top issue to a done status when all specs are complete; with rollup
  off, only the spec-level status is set (today's behavior).
- **FR-012**: When status rollup is on, the system MUST transition an issue only
  when its computed completion state has actually changed, so a re-run against
  unchanged completion fires no transition.
- **FR-013**: The system MUST offer an optional, off-by-default narrative
  super-level above the spec that projects to a Jira Initiative where the instance
  supports it and degrades gracefully (fold the narrative onto the Epic behind a
  stable marker and carry repo grouping as a label) where it does not — never
  hard-failing because the instance lacks Initiative support.
- **FR-014**: The narrative for the super-level MUST be populated only from an
  explicit source (the spec's input description, or operator-supplied grouping) —
  never inferred or fabricated.
- **FR-015**: The system MUST accept a workstate document directly (as a file or
  on standard input) and mirror it without reading a `specs/` tree, producing the
  same projection as the equivalent tree-derived run.
- **FR-016**: The system MUST validate a directly-supplied workstate document on
  entry and reject a malformed or unsupported document fail-closed (no partial
  write).
- **FR-017**: All configuration validation (available types, relationship matrix,
  required ids for configured artifacts) MUST run before any write; any failure
  is a workspace-level error that writes nothing.
- **FR-018**: The mapping, detection, and validation behavior MUST live entirely
  in the Jira-specific sink and configuration layer; the vendor-neutral reconcile
  engine MUST remain free of mapping/Jira knowledge.
- **FR-019**: No real Jira coordinates, identifiers, names, sites, or tokens may
  appear in any tracked file; real values live only in the gitignored credential
  and binding files.

### Key Entities *(include if feature involves data)*

- **Mapping configuration**: An optional, additive block describing per-level
  artifact + parent-relationship choices, the optional narrative super-level
  (with its on/off state, degrade policy, and narrative source), and the optional
  status-rollup lever. Absent ⇒ the alias layer synthesizes the default.
- **workstate level**: The neutral structural units the mapping consumes — repo,
  spec, phase, task — independent of any spec-kit on-disk concept.
- **Available issue-type set**: The issue types the target project actually
  offers; the validation surface for configured artifacts.
- **Relationship-validation matrix**: The allow/reject table of
  (level-boundary × relationship-type) combinations that guards against corrupt
  Jira graphs.
- **Narrative source**: The explicit origin of the super-level narrative (spec
  input description or operator grouping); never an inference.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A no-config upgrade produces zero behavioral change — 100% of the
  existing default-mapping acceptance scenarios still pass, and a re-run is zero
  churn.
- **SC-002**: An operator can switch a board to a non-default mapping (e.g. a
  Kanban board with no Story type) entirely through configuration, with no code
  change.
- **SC-003**: 100% of runs whose configuration references an issue type the
  target project does not offer are stopped before any issue is created or
  modified (no partial mirrors).
- **SC-004**: Every non-default mode (3-level, 2-level, status rollup, narrative
  super-level, workstate-direct) re-runs against unchanged state with zero
  observable writes.
- **SC-005**: A directly-supplied workstate document produces a mirror identical
  to the one produced from the equivalent `specs/` tree.
- **SC-006**: With status rollup on, a fully-complete feature reads as complete on
  the board (its phase and top issues sit in a done status), and turning rollup
  off restores exactly today's status behavior.
- **SC-007**: An instance lacking Initiative support never causes a hard failure
  when the narrative super-level is on — the narrative always lands (folded onto
  the Epic) and the run succeeds.

## Assumptions

The following working defaults are taken from the design draft's leanings (see
`DESIGN-DRAFT.md` §7) so the spec is complete; none changes the locked decisions
in `DESIGN-DRAFT.md` §2. Four were **confirmed in the 2026-06-03 clarify session**
(see Clarifications above): Q2, Q7, Q8, Q10. The rest remain working defaults to
confirm or adjust in a later clarify pass or in `/speckit-plan`.

- **Clarify scope (Q1)**: The clarify session resolves the five blocking
  questions first (relationship matrix, Initiative degradation mechanics, 2-level
  keying, workstate-direct interface, absent-type policy) and carries the five
  non-blocking ones into plan.
- **Relationship matrix (Q2)**: **[confirmed 2026-06-03]** Hierarchy links are restricted to native parent /
  Epic-link / none / checklist; dependency-style links are rejected as hierarchy
  links; all rejections hard-halt at configuration load.
- **Project style (Q3)**: Classic-vs-team-managed (Epic-link vs native parent) is
  operator-declared in config, keeping validation offline; a runtime probe is a
  later enhancement.
- **Partial mapping (Q4)**: An incomplete mapping block inherits the synthesized
  default per unspecified level (not all-or-nothing).
- **Initiative degradation (Q5)**: Initiative availability is detected by probing
  issue-type metadata; when absent, the narrative folds into the Epic behind a
  stable marker and reuses the existing repo-grouping label, idempotently.
- **Initiative scope (Q6)**: Ships per-repo 1:1 (narrative ≈ spec); per-org
  grouping is a later config extension.
- **2-level keying (Q7)**: **[confirmed 2026-06-03]** Each checklist item is keyed by its workstate task
  identity; the checklist sub-tree is compared for byte equality and written only
  when it changes.
- **workstate-direct interface (Q8)**: **[confirmed 2026-06-03]** Exposed as a flag on the existing
  reconcile entrypoint (a file path, or `-` for standard input), validated
  against the pinned workstate schema on entry; the narrative source is treated as
  gracefully absent in this mode.
- **Identity + provenance (Q9)**: A task-identity label prefix is added for
  Task-projected levels; the read-only-mirror provenance header renders as a
  single stable marker line above the checklist.
- **Absent-type policy (Q10)**: **[confirmed 2026-06-03]** Detect available types via metadata probe;
  hard-error at configuration load when a configured artifact has no matching
  type, with an optional per-level fallback as the explicit opt-in escape.
- **Status rollup (Q11)**: Ships off by default; phase-complete → phase issue
  done and all-specs-done → top issue done; target statuses reuse the existing
  status/transition configuration; transitions fire only when computed completion
  changes (forward and backward) to stay idempotent.
- **Dependencies**: Builds on the shipped 001 core bridge (its create / idempotent
  update / drift / fail-closed paths), the published workstate schema, and the
  gitignored credential + binding files; targets a single Jira project per run.
- **Out of scope** (per `DESIGN-DRAFT.md` §6): extracting the parser into a
  standalone producer, bidirectional sync, any change to the default mapping or to
  the 001 acceptance behavior, and auto-discovery of issue-type ids for new
  artifacts.
