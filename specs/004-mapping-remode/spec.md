# Feature Specification: Mapping Re-mode / Orphan Pruning

**Feature Branch**: `004-mapping-remode`

**Created**: 2026-06-08

**Status**: Draft

**Input**: User description: "Mapping re-mode / orphan pruning for
spec-kit-jira-sync (feature 004). When an operator changes the mapping config, a
guarded opt-in resync prunes the bridge-owned artifacts the new mapping no longer
wants and regenerates the new shape, so operators can flip mappings back and
forth and converge on the right per-project shape without orphans. Fail-safe
scoping (only bridge-owned, never operator-created), opt-in + dry-run +
confirmation guard, idempotency, fail-closed reads. Introduces controlled
destruction — a deliberate departure from the non-destructive-mirror principle —
flagged for a scoped constitutional exception. Sequenced after feature 003;
implementation lands on 003's unified orchestration. Open questions (destruction
model, orphan identification, guard surface, default-reconcile orphan warning,
fate of human comments) carried into /speckit-clarify."

## Why this is a careful feature

Every capability shipped so far treats Jira as a **non-destructive, one-way,
regenerable mirror** of the source-of-truth specs — the bridge only ever creates
or updates, never removes. This feature is the first to **remove** bridge-owned
artifacts, so its value is gated entirely on two safety properties: it must
remove **only** what the bridge itself created, and it must **never** act
destructively without an explicit, previewed, confirmed instruction. The
underlying insight that makes destruction acceptable: bridge-owned *content* is
fully regenerable from the specs, so it needs no backup; the only non-regenerable
data is human collaboration added directly on the issues.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Switch mapping modes cleanly (Priority: P1) 🎯 MVP

An operator changes the mapping configuration — for example spec→Story becomes
spec→Epic, or a 3-level mapping becomes a 2-level checklist, or the Initiative
super-level is toggled — and runs the guarded re-mode. The board ends up as a
clean mirror of the **new** mapping: the bridge-owned artifacts the new mapping
no longer wants are removed, the new-shape artifacts are present, and no stale
artifacts from the prior shape remain.

**Why this priority**: This is the capability and its whole reason for existing —
it lets operators experiment with the mapping per project and converge on the
shape that fits, instead of accumulating orphans on every change.

**Independent Test**: Mirror a corpus under one mapping, change the mapping,
run the re-mode, and confirm the board contains exactly the new-shape bridge-owned
artifacts and zero artifacts from the old shape.

**Acceptance Scenarios**:

1. **Given** a board mirrored under spec→Story (3-level), **When** the operator
   changes the mapping to a 2-level checklist and runs the re-mode, **Then** the
   per-phase Subtask issues are removed, the spec issue carries the in-body
   checklist, and no orphaned Subtasks remain.
2. **Given** a board mirrored under spec→Story, **When** the operator changes
   spec to project to Epic and runs the re-mode, **Then** the old Story is removed
   and the spec is mirrored as an Epic with the same identity, with no duplicate.
3. **Given** the re-mode has completed, **When** the operator runs an ordinary
   reconcile, **Then** zero writes occur — the new shape is a stable mirror.

---

### User Story 2 - Operator work is never destroyed (fail-safe scoping) (Priority: P1)

The single most important property: the re-mode prunes **only** bridge-owned
artifacts (those carrying the bridge's identity labels) and **never** touches an
operator-created issue — not even one sitting under the same Epic, sharing a
similar summary, or otherwise resembling a bridge artifact. If the bridge cannot
prove an artifact is its own, it leaves it alone.

**Why this priority**: Destruction is only acceptable if it cannot reach the
operator's own work. A scoping error here destroys real, non-regenerable work —
the worst possible failure mode — so this property is the gate on the whole
feature.

**Independent Test**: Populate a board with a mix of bridge-owned issues and
operator-created issues (including some deliberately placed under the same parent
or given lookalike summaries), run a re-mode, and confirm every operator-created
issue is untouched while only bridge-owned orphans are pruned.

**Acceptance Scenarios**:

1. **Given** a board containing bridge-owned orphans and operator-created issues
   under the same Epic, **When** the operator runs a re-mode, **Then** only the
   bridge-owned orphans are pruned and every operator-created issue is untouched.
2. **Given** an issue that does not carry the bridge's identity labels, **When**
   a re-mode runs, **Then** that issue is never pruned, relabeled, or modified —
   regardless of its summary, parent, or type.

---

### User Story 3 - Destruction is previewed and confirmed (the guard) (Priority: P1)

Before any artifact is removed, the operator sees a precise preview of exactly
what would be pruned and what would be regenerated, and destruction proceeds only
after an explicit confirmation. The ordinary reconcile never prunes — pruning is
a separate, deliberate operation.

**Why this priority**: A destructive operation with no preview or confirmation is
unacceptable for a tool that writes to a shared board. The guard is what makes
the destruction safe to invoke.

**Independent Test**: Invoke the re-mode without confirmation and confirm it only
previews (zero destructive writes); invoke the ordinary reconcile and confirm it
never prunes; invoke the re-mode with confirmation and confirm it prunes exactly
the previewed set.

**Acceptance Scenarios**:

1. **Given** a mapping change that would prune artifacts, **When** the operator
   runs the re-mode without confirming, **Then** the bridge previews the exact
   prune + regenerate set and performs zero destructive writes.
2. **Given** the previewed set, **When** the operator confirms, **Then** exactly
   that set is pruned and regenerated — nothing more.
3. **Given** the ordinary (non-re-mode) reconcile, **When** it runs in any mode,
   **Then** it performs zero destructive operations.

---

### User Story 4 - Experiment freely, idempotently (Priority: P3)

An operator flips the mapping back and forth across several shapes to find the
one that fits the project. Each re-mode converges the board to the current
mapping, and a re-mode invoked when nothing has actually changed prunes nothing
and writes nothing.

**Why this priority**: This is the experimentation experience the feature exists
to enable, but it rides on US1–US3; once those hold, free experimentation falls
out as a property rather than separate machinery.

**Independent Test**: Apply mapping A, re-mode; apply mapping B, re-mode; reapply
mapping A, re-mode — each time the board mirrors the applied mapping exactly; then
re-mode again with no change and confirm zero writes.

**Acceptance Scenarios**:

1. **Given** a board mirrored under mapping A, **When** the operator switches to
   mapping B and re-modes, then back to A and re-modes, **Then** the board faithfully
   mirrors whichever mapping is currently applied, with no residue from the other.
2. **Given** a board already mirroring the current mapping, **When** the operator
   runs a re-mode, **Then** nothing is pruned and nothing is written (zero churn).

---

### Edge Cases

- **A level flips issue→checklist**: the old per-item child issues become orphans
  and are pruned; the checklist appears in the parent body.
- **A level flips checklist→issue** (reverse): the in-body checklist is removed
  from the parent and the per-item child issues are created.
- **A level changes issue type** (e.g. Story→Epic): the old-type issue is pruned
  and the new-type issue created under the same identity — no duplicate, no
  in-place retype assumed (cross-hierarchy retype is not guaranteed by the
  target).
- **The Initiative super-level toggles**: between a real Initiative issue and the
  degraded-onto-Epic narrative; the no-longer-wanted form is cleaned up.
- **An orphan carries human comments / links / attachments**: handled per the
  destruction model resolved in clarify; the operator is warned before such an
  issue is pruned.
- **An unreadable Jira read mid-re-mode**: the re-mode fails closed — it aborts
  before any destructive write; no partial destruction on an unreadable read.
- **An operator manually applied a bridge identity label to their own issue**:
  that issue is, by definition of the identity contract, opted into bridge
  management — a documented consequence of the identity model.
- **Partial failure mid-prune** (some removals succeed, some fail): surfaced (no
  silent failure); a re-run completes the re-mode (resumable / idempotent).
- **No actual shape change**: the re-mode prunes nothing and writes nothing.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide an explicit, opt-in re-mode operation —
  distinct from the ordinary reconcile — that prunes the bridge-owned artifacts
  the current mapping no longer projects and regenerates the new-shape artifacts,
  leaving the board a clean mirror of the current mapping.
- **FR-002**: Pruning MUST be restricted to **bridge-owned** artifacts (those
  carrying the bridge's identity labels). The system MUST NEVER prune, relabel, or
  otherwise modify an operator-created issue. When ownership cannot be proven, the
  artifact is left untouched (fail-safe default).
- **FR-003**: The re-mode MUST be preview-first: before any destructive write it
  MUST present the exact set of artifacts to be pruned and regenerated, and MUST
  require an explicit confirmation before performing any destructive write.
- **FR-004**: The ordinary (non-re-mode) reconcile MUST remain non-destructive —
  it MUST NOT prune in any mapping mode.
- **FR-005**: The re-mode MUST be fail-closed: an unreadable Jira read MUST abort
  the operation before any destructive write — never a partial destruction on an
  unreadable read.
- **FR-006**: After a re-mode, the resulting new-shape mirror MUST be idempotent —
  a subsequent ordinary reconcile performs zero writes; a re-mode invoked with no
  actual shape change MUST prune nothing and write nothing.
- **FR-007**: The re-mode MUST correctly handle every mapping mode-transition:
  issue→checklist and checklist→issue at any level, an issue-type change at any
  level, and the Initiative super-level toggling between a real Initiative and the
  degraded-onto-Epic narrative.
- **FR-008**: The system MUST report, for each re-mode, what was pruned, what was
  regenerated, and what was skipped — observability parity with the reconcile
  summary, so no removal is silent.
- **FR-009**: A partial failure during pruning (some removals fail) MUST be
  surfaced (no silent success) and MUST be completable by a re-run (resumable).
- **FR-010**: Backward-drift on a to-be-pruned bridge-owned issue (a human edited
  it in Jira) MUST be surfaced before that issue is pruned, so the operator is
  warned that human-edited content is being removed.
- **FR-011**: The destruction MUST follow a defined destruction model
  (resolved in clarify — see Open Questions); whatever the model, FR-002 scoping
  and FR-003 preview/confirm hold.
- **FR-012**: No real Jira coordinates or PII may appear in any tracked file
  (Privacy IX); the privacy guard stays green.
- **FR-013**: This feature introduces **controlled destruction**, a deliberate
  departure from the project's non-destructive-mirror principle. It MUST be
  recorded as a **scoped constitutional exception/amendment** (bridge-owned +
  opt-in + preview + confirm + fail-closed), NOT a silent behavior change. The
  ordinary mirror remains non-destructive; destruction is confined to the
  explicit, guarded re-mode.

### Key Entities *(include if feature involves data)*

- **Bridge-owned artifact**: a Jira issue carrying the bridge's identity labels,
  created and managed by the bridge — the only kind of artifact a re-mode may
  remove.
- **Orphan**: a bridge-owned artifact the current mapping no longer projects —
  residue from a prior mapping shape.
- **Desired-shape set**: the set of artifacts the current mapping projects from
  the specs (the target state of a re-mode).
- **Re-mode operation**: the explicit, guarded prune-and-regenerate action that
  converges the board's bridge-owned artifacts to the desired-shape set.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After a re-mode following a mapping change, 100% of stale
  bridge-owned artifacts from the prior shape are removed and the board contains
  exactly the new-shape bridge-owned artifacts — zero orphans remain.
- **SC-002**: Across a board mixing bridge-owned and operator-created issues, a
  re-mode modifies **zero** operator-created issues (0 pruned, 0 relabeled, 0
  edited) — the fail-safe scoping guarantee.
- **SC-003**: 100% of destructive writes are preceded by a preview and an explicit
  confirmation — no artifact is ever removed without both.
- **SC-004**: The ordinary reconcile performs **zero** destructive operations in
  every mapping mode.
- **SC-005**: After a re-mode, an ordinary reconcile is zero-churn, and a re-mode
  with no shape change performs zero writes.
- **SC-006**: An unreadable Jira read during a re-mode results in **zero**
  destructive writes (fail-closed).
- **SC-007**: Every supported mode-transition (issue↔checklist, issue-type change,
  Initiative toggle) leaves the board a faithful mirror of the new mapping, with
  no residue from the prior shape.

## Assumptions

- This feature is **sequenced after feature 003** (engine orchestration
  unification): the desired-shape projection is computed through 003's unified,
  mapping-driven path, so a re-mode reuses one projection rather than diverging
  per mode. The spec is foundation-agnostic; the implementation lands on 003.
- **Bridge ownership = the identity labels.** An issue carrying the bridge's
  `speckit-*` identity labels is bridge-owned; one without them is the operator's.
  A human who manually applies an identity label opts that issue into bridge
  management (a documented consequence of the identity contract).
- Bridge-owned **content** is regenerable from the source-of-truth specs and needs
  no backup; only human collaboration added directly on issues (comments, manual
  links, attachments, hand-set statuses) is non-regenerable — which is why the
  destruction model (below) matters.
- The bridge remains a **one-way mirror**; nothing here introduces bidirectional
  sync. The specs stay the source of truth.
- **Out of scope**: the engine extraction / carve-out; non-Jira sinks;
  bidirectional sync; pruning or modifying operator-created issues; auto-pruning
  in the default reconcile (re-mode is always explicit).

### Open Questions (to resolve in /speckit-clarify)

These are carried forward deliberately — not resolved in this spec — because they
are the high-impact design choices the clarify pass exists to pin:

1. **Destruction model**: archive / supersede (preserve the human layer) vs
   hard-delete (cleanest board; safe given content regenerates) vs relabel/detach
   (least destructive) — and whether it is operator-selectable per project. No
   single reasonable default; this is the primary clarify question.
2. **Orphan identification**: how the to-be-pruned set is computed — the leading
   approach is diffing the desired-shape bridge-owned set against the existing
   bridge-owned set on the board.
3. **Guard surface**: the exact invocation (flag name), whether preview/dry-run is
   the default, and how confirmation works on a **non-interactive / CI** run
   (leading lean: an explicit confirm flag; never auto-confirm destruction).
4. **Default-reconcile orphan warning**: whether the ordinary non-destructive
   reconcile should WARN when it detects orphans from a prior mapping (without
   pruning them) — leading lean: yes, warn (helpful and non-destructive).
5. **Fate of human comments/links** on a pruned issue under each destruction
   model — follows from question 1.
