# Feature Specification: Lifecycle→Subtask Board Cascade + Phase-Parser Broadening

**Feature Branch**: `010-lifecycle-subtask-cascade`

**Created**: 2026-06-22

**Status**: Draft

**Input**: User description (operator-reported, dogfound on a real board; the same
two bugs the Linear sibling has, verified line-cited against this repo's `main`):
"Merging a spec flips the Story to Merged but strands its phase Subtasks in To Do;
and letter/em-dash phase headers (`## Phase A — …`) produce no subtasks at all."

## The two bugs (line-cited against `main`)

**Bug 1 — No lifecycle→subtask cascade.** Lifecycle (`merged`→Done) drives **only
the spec Story** status (`src/reconcile.sh:1071-1075`). A phase Subtask's status is
touched **only** by the opt-in status rollup `reconcile::rollup_phases`
(`src/reconcile.sh:1293`), gated on `mapping.status_rollup.enabled`
(`src/reconcile.sh:1290`) — **OFF by default** (`config-template.yml:195`) — and it
is checkbox-**ratio** based (children→parent), not lifecycle. There is **no
parent→child terminal cascade**. So merging a spec leaves every phase Subtask
behind; in the default config (rollup off) subtasks get **no status sync at all**,
sitting permanently in the project default (e.g. To Do).

**Bug 2 — Brittle phase parser.** `parser::task_phases` matches
`/^## Phase [0-9]+:/` (`src/parser.sh:204, 249, 365`) — it requires a **numeric
index AND a trailing colon**. So `## Phase A — Name` (letter + em-dash) parses to
**zero** subtasks; even `## Phase 1 — Name` (numeric, em-dash, no colon) fails. Two
on-board failure modes coexist: numeric-colon specs → subtasks created but stranded
(Bug 1); letter/em-dash specs → no subtasks at all. `parser.sh` carries the
`# ORIGIN: copied from spec-kit-linear` header, so the parser fix is the same diff
to port to the sibling.

This feature fixes both so the board faithfully reflects the source-of-truth
lifecycle. It is a **board-correctness bug fix** intended to ride the imminent
v0.4.0 release.

## Clarifications

### Session 2026-06-22

All three forks resolved by their leans (none contentious):

- Q: (a) Cascade trigger set — `{merged}` only, or `{ready_to_merge, merged}`? →
  A: **`{ready_to_merge, merged}`** (by ready-to-merge the phases are implemented
  and the PR is up; matches the Linear fix). Accepted, documented limitation: if
  lifecycle later moves *back* from `ready_to_merge`, the cascade will not un-set
  children to active unless the ratio rollup is on (the merge/ready signal is
  treated as forward-only authority).
- Q: (b) Constitution — does the always-on lifecycle→subtask-status cascade need a
  MINOR amendment? → A: **No amendment.** It enforces the constitution's existing
  intent (the board mirrors lifecycle — stranded subtasks violate "lifecycle state
  → spec-Issue status"), and feature 002's status rollup already established Layer-D
  subtask-status writes without an amendment. **The plan's Constitution Check is the
  formal ruling point**; a MINOR (v1.1.0→v1.2.0) bump is the fallback only if the
  gate reads the Architectural-Constraints "lifecycle → spec-Issue status" line as
  exclusive.
- Q: (c) Letter-index scope/ordering? → A: **numeric + single ASCII letter (A–Z)**;
  order numerics first, then letters, lexically; the `task-phase:A` identity label
  is acceptable. Multi-character/arbitrary tokens stay out of scope.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Merging a spec marks its phases done, not stranded (Priority: P1) 🎯 MVP

An operator finishes and merges a spec. On the next reconcile, the spec's Story
goes to Merged **and every phase Subtask under it is moved to Done** — the board
shows the whole spec complete, instead of a Merged story sitting over a column of
To Do subtasks. This holds in the default configuration (status rollup off).

**Why this priority**: This is the visible board defect operators hit. A merged
feature whose phases still read "To Do" makes the board untrustworthy.

**Independent Test**: In a throwaway board (curl-shim), reconcile a merged
numeric-phase spec with `status_rollup` off; assert the Story is Merged AND each
phase Subtask is transitioned to the done status; re-run and assert zero further
transitions (idempotent).

**Acceptance Scenarios**:

1. **Given** a spec whose lifecycle is `merged` and `status_rollup` is off (the
   default), **When** the bridge reconciles, **Then** every bridge-owned phase
   Subtask is transitioned to the done status (the status `merged` maps to), even
   though no checkbox-ratio rollup ran.
2. **Given** that same merged spec reconciled again with no disk change, **When**
   the bridge runs, **Then** it performs **zero** subtask transitions (idempotent —
   transition only on a real status change).
3. **Given** a subtask read that is unreadable mid-cascade, **When** the bridge
   runs, **Then** it fails closed (exit 3) and applies **no partial** cascade.

---

### User Story 2 - Letter / em-dash phase headers produce subtasks (Priority: P1)

A spec author wrote phase headers as `## Phase A — Foundations` (letter index,
em-dash) or `## Phase 1 — Setup` (numeric, em-dash, no colon). The bridge now
recognizes these and creates a phase Subtask for each, instead of silently
producing none.

**Why this priority**: Letter/em-dash headers produce a *silent zero-subtask*
board — the operator sees a Story with no phases and no error. Equally untrustworthy.

**Independent Test**: Parse a `tasks.md` with `## Phase A — …` / `## Phase 1 — …`
headers; assert one phase per header is detected with the correct index token and
name; reconcile and assert one Subtask per phase is created and identified by its
`task-phase:<idx>` label.

**Acceptance Scenarios**:

1. **Given** a `tasks.md` using `## Phase A — Name` headers, **When** the bridge
   parses it, **Then** it detects one phase per header (index `A`, name `Name`),
   and reconcile creates the corresponding Subtasks.
2. **Given** a `tasks.md` using `## Phase 1 — Name` (em-dash, no colon), **When**
   the bridge parses it, **Then** the phase is detected (was previously missed).
3. **Given** a letter-indexed phase that is then merged, **When** the bridge
   reconciles, **Then** its Subtasks are created **and** cascaded to Done (US1 +
   US2 together).

---

### User Story 3 - Non-terminal specs are unchanged (Priority: P2)

A spec still in progress (not terminal) reconciles exactly as it does today: the
opt-in ratio rollup governs subtask status when enabled, and nothing touches
subtask status when it is off. The cascade does not fire.

**Why this priority**: The fix must not disturb in-progress boards or the existing
rollup behavior — only the terminal case changes.

**Independent Test**: Reconcile a spec in `implementing` with rollup off → no
subtask transitions; with rollup on → ratio behavior unchanged from today.

**Acceptance Scenarios**:

1. **Given** a non-terminal spec with `status_rollup` off, **When** the bridge
   reconciles, **Then** no phase Subtask status is written (today's behavior).
2. **Given** a non-terminal spec with `status_rollup` on, **When** the bridge
   reconciles, **Then** subtask status follows the checkbox ratio exactly as today.

---

### Edge Cases

- **Cascade precedence over ratio**: for a terminal spec, the cascade forces Done
  even if the checkbox ratio is < 100% (the merge is the authority); the cascade
  takes precedence over the ratio rollup.
- **Rollup on + terminal**: the cascade (Done) wins; no conflicting ratio write.
- **Lifecycle regresses from `ready_to_merge`** (if that trigger is chosen): the
  cascade won't un-set children to active unless the ratio rollup is on — a known
  edge documented under decision (a).
- **No subtasks** (spec with zero phases, or all phases below the parser): the
  cascade is a no-op (nothing to transition).
- **Mixed numeric + letter phases** in one spec: each is matched by its own index
  token; tasks attach to the right phase (string-keyed index).
- **A phase whose target done-status is unmapped/absent**: surfaced as a warning;
  the cascade skips that transition rather than erroring the run (fail-soft on a
  missing mapping, fail-closed only on an unreadable read).
- **Idempotency**: a board already correct produces zero transitions; the parser
  change does not alter identity labels for existing numeric-colon phases (no churn
  for today's specs).
- **Privacy**: new fixtures are placeholder-only.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001 (Terminal cascade)**: When a spec's resolved lifecycle phase is
  **terminal** — `ready_to_merge` or `merged` (resolved 2026-06-22) — the bridge
  MUST transition every bridge-owned phase
  Subtask to the done status (the status the `merged` lifecycle phase maps to),
  regardless of the tasks.md checkbox ratio and regardless of
  `status_rollup.enabled`. Idempotent (transition only on a real status change).
- **FR-002 (Precedence)**: The terminal cascade MUST take precedence over the ratio
  rollup. For a non-terminal lifecycle, subtask-status behavior MUST be unchanged
  from today (ratio rollup if enabled; otherwise no subtask-status writes).
- **FR-003 (Effective by default)**: The cascade MUST fire in the default
  configuration (NOT gated on `status_rollup.enabled`), because the defect manifests
  in the default config. This is a one-time, desirable board correction on next
  reconcile (Principle I — lifecycle/filesystem is the source of truth).
- **FR-004 (Fail-closed, no partial cascade)**: An unreadable subtask read during
  the cascade MUST fail closed (exit 3) with no partial cascade applied; a merely
  *unmapped* done-status MUST be surfaced as a warning and skipped (fail-soft),
  never a silent no-op.
- **FR-005 (Phase-parser broadening)**: `parser::task_phases`, `tasks_in_phase`,
  and the unphased-task scan MUST recognize phase headers with non-numeric indices
  (single ASCII letters) AND non-colon separators (`:`, em-dash `—`, en-dash `–`,
  hyphen `-`) — e.g. `## Phase A — Name`, `## Phase 1 — Name` — in addition to
  today's `## Phase N: Name`. The phase index is a **string token**.
- **FR-006 (String-keyed index pipeline)**: All downstream phase-index handling
  MUST be string-keyed so letter-indexed phases match their tasks and Subtasks —
  specifically the numeric-only child-id extraction at `src/reconcile.sh:1237,
  1248, 1309, 2656` MUST be generalized to the new index token.
- **FR-007 (Backward-compatible parsing)**: A `## Phase N: Name` (numeric + colon)
  spec MUST parse identically to today and produce the same `task-phase:N` identity
  labels and Subtask titles — no churn for existing specs.
- **FR-008 (Idempotency / determinism)**: On an unchanged board the cascade and the
  parser produce zero spurious transitions and identical parse output every run
  (Principle II).
- **FR-009 (Vendor-neutral seam)**: The decision "a terminal spec's phases are
  done" is vendor-neutral and MUST live in the engine/parser; the actual Subtask
  transition is Jira-specific and lives in the sink (reuse the existing
  transition path). `parser.sh` stays neutral; the 003 engine-neutrality gate MUST
  stay green.
- **FR-010 (Privacy IX)**: Any new fixture/example MUST be placeholder-only;
  `no-real-identifiers.bats` and the 006 consumer-side guard MUST stay green.
- **FR-011 (Mapping unchanged)**: The artifact mapping is unchanged (phase still →
  Subtask); this is a status + parsing fix, **not** a data-model mapping change
  (no MAJOR amendment).

### Key Entities *(include if feature involves data)*

- **Terminal lifecycle set**: the lifecycle phases that trigger the cascade —
  **`{ready_to_merge, merged}`** (resolved 2026-06-22), treated as forward-only.
- **Done status**: the Jira status the `merged` lifecycle phase maps to
  (`phase_status.merged`) — the cascade target for phase Subtasks.
- **Phase index token**: the per-phase identifier parsed from the header (numeric
  or single letter), used in the `task-phase:<idx>` identity label, the Subtask
  title, and task↔phase attachment. Now a string.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A merged numeric-phase spec with `status_rollup` off reconciles to a
  Merged Story **and** every phase Subtask Done — 100% of the time.
- **SC-002**: A `## Phase A — …` / `## Phase 1 — …` spec produces one Subtask per
  phase (previously zero), and a merged such spec cascades them to Done.
- **SC-003**: A non-terminal spec produces byte-identical subtask-status behavior
  to today (no cascade; ratio rollup only if enabled).
- **SC-004**: Re-running against an unchanged merged board performs zero subtask
  transitions (idempotent).
- **SC-005**: An existing `## Phase N: Name` spec parses identically — same phase
  count, index tokens, labels, and titles (no churn).
- **SC-006**: No real identifier in any tracked file the feature adds; the privacy
  + 003 neutrality gates stay green.

## Assumptions

- **The merge is the authority.** A merged spec's phases are complete for board
  purposes even if some tasks.md checkboxes are unticked; the cascade reflects the
  lifecycle, not the ratio (Principle I).
- **Done status = `phase_status.merged`.** The cascade target is the status the
  terminal lifecycle phase already maps to (the same one the rollup treats as
  done) — no new config field.
- **Single-letter indices suffice** for the observed real-world headers (decision
  c); arbitrary multi-char tokens are out of scope.
- **No mapping/schema change** — phase still → Subtask; the workstate child shape
  is unchanged except the index is treated as a string token.
- **Cross-bridge parity** — mirrors the Linear sibling's fix ranking; the parser
  fix is the same diff to port (a follow-up, not a dependency).

## Out of Scope

- The optional `--close-merged` one-shot batch sweep (the per-reconcile cascade
  covers the ongoing case; a deferred convenience).
- Changing the artifact mapping (phase → Subtask is unchanged).
- The cross-repo port into spec-kit-linear (a follow-up PR there).
- Multi-character / arbitrary phase index tokens (single letter + numeric only).

## Open Questions — RESOLVED (Clarifications, Session 2026-06-22)

All three forks are pinned above: (a) cascade trigger = **`{ready_to_merge,
merged}`** (forward-only); (b) **no constitution amendment** — the plan's
Constitution Check is the formal ruling point, MINOR v1.2.0 the fallback; (c)
**numeric + single ASCII letter** indices, numerics-then-letters order. No `[NEEDS
CLARIFICATION]` markers remain. Artifact mapping unchanged (no MAJOR).
