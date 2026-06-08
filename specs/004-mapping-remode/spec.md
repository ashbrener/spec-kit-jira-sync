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

## Clarifications

### Session 2026-06-08

- Q: Destruction model when pruning bridge-owned orphans? → A:
  **Operator-selectable, default hard-delete.** Because the content is
  regenerable from the source-of-truth specs, hard-delete is the default (cleanest
  board); archive/supersede (preserving the human layer) is available as a
  per-project option.
- Q: Safety guard for the destructive re-mode? → A: **Destructive by default
  behind the explicit `--remode` flag; `--remode --dry-run` previews.** There is
  no separate confirmation step. The destruction is gated only by the deliberate
  opt-in flag — the operator accepted the residual scoping-bug risk in exchange
  for a faster experimentation loop. (Consequence: fail-safe scoping, US2, is now
  the **sole** load-bearing safety net and gets the heaviest adversarial coverage.)
- Q: How is the to-be-pruned (orphan) set identified? → A: **Diff the
  desired-shape bridge-owned set against the existing bridge-owned set on the
  board, scoped by the `speckit-*` identity labels.** The labels are the manifest;
  unlabelled (operator) issues are structurally excluded from the prune set.
- Q: Should the ordinary (non-re-mode) reconcile warn on detected orphans? → A:
  **Yes — warn and suggest `--remode`, but never prune.** The default reconcile
  stays non-destructive; it surfaces stale-shape drift so the operator isn't
  surprised.

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

### User Story 3 - Destruction is opt-in and previewable (the guard) (Priority: P1)

The destructive re-mode is reachable **only** through an explicit `--remode`
flag; the ordinary reconcile never prunes. Before committing, the operator can
preview the exact prune + regenerate set with `--remode --dry-run`. Once
`--remode` is invoked without `--dry-run`, it acts — it prunes and regenerates
without a further confirmation step (the operator accepted this in exchange for a
faster experimentation loop; see Clarifications 2026-06-08). The explicit opt-in
flag is the deliberate boundary between the safe mirror and the destructive
re-mode.

**Why this priority**: The opt-in flag plus an accurate dry-run preview are the
guard. With no separate confirmation and a default of hard-delete, this guard
plus the fail-safe scoping of US2 are the only things standing between a
mapping experiment and the board — so the explicit boundary and a faithful
preview are essential.

**Independent Test**: Run the ordinary reconcile and confirm it never prunes;
run `--remode --dry-run` and confirm it previews the exact set with zero writes;
run `--remode` and confirm it prunes + regenerates exactly the set the dry-run
previewed — nothing more.

**Acceptance Scenarios**:

1. **Given** the ordinary (non-`--remode`) reconcile, **When** it runs in any
   mapping mode, **Then** it performs zero destructive operations.
2. **Given** a mapping change that would prune artifacts, **When** the operator
   runs `--remode --dry-run`, **Then** the bridge previews the exact prune +
   regenerate set and performs zero writes.
3. **Given** that previewed set, **When** the operator runs `--remode` (without
   `--dry-run`), **Then** exactly that set is pruned and regenerated — the
   preview faithfully matched the action.

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
- **FR-003**: The destructive re-mode MUST be reachable ONLY via an explicit
  `--remode` flag; the ordinary reconcile MUST NOT prune. `--remode --dry-run`
  MUST preview the exact prune + regenerate set with zero writes, and that
  preview MUST faithfully match what a subsequent `--remode` does. There is no
  separate confirmation step — the explicit opt-in flag is the gate
  (Clarifications 2026-06-08).
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
- **FR-011**: The destruction model is **operator-selectable, defaulting to
  hard-delete** (bridge content is regenerable from the specs); archive/supersede
  — preserving the human layer (comments/links) — is the per-project alternative.
  Whatever the model, FR-002 scoping holds (Clarifications 2026-06-08).
- **FR-014**: The ordinary (non-`--remode`) reconcile MUST WARN when it detects
  bridge-owned orphans from a prior mapping shape — listing them and suggesting
  `--remode` — but MUST NOT prune them (Clarifications 2026-06-08).
- **FR-015**: Orphans MUST be identified by diffing the desired-shape bridge-owned
  set against the existing bridge-owned set on the board, scoped by the
  `speckit-*` identity labels — so unlabelled (operator) issues are structurally
  excluded from the prune set. With the destructive-by-default guard and default
  hard-delete, this label-scoping is the **sole load-bearing safety net** and
  MUST carry adversarial test coverage (Clarifications 2026-06-08).
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
- **SC-003**: Destructive writes occur ONLY under the explicit `--remode` flag
  (never in the ordinary reconcile), and a `--remode --dry-run` preview matches
  exactly the artifacts a subsequent `--remode` prunes/regenerates (preview
  fidelity).
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

### Open Questions — RESOLVED in clarify (Session 2026-06-08)

All five are now pinned (see the Clarifications section above):

1. **Destruction model** → operator-selectable, **default hard-delete**;
   archive/supersede available per project (FR-011).
2. **Orphan identification** → diff desired-shape vs existing bridge-owned set,
   scoped by `speckit-*` identity labels (FR-015).
3. **Guard surface** → destructive by default behind the explicit `--remode`
   flag; `--remode --dry-run` previews; no separate confirmation (FR-003).
4. **Default-reconcile orphan warning** → yes, warn + suggest `--remode`, never
   prune (FR-014).
5. **Fate of human comments/links** → follows from the destruction model: lost on
   hard-delete (the default), preserved under the archive option (FR-011).
