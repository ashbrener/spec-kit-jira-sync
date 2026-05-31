# Feature Specification: Core Bridge — Mirror spec-kit Specs into Jira

**Feature Branch**: `001-core-bridge`

**Created**: 2026-05-31

**Status**: Draft

**Input**: User description: "spec-kit-jira core bridge — mirror a spec-kit project's specs into Jira (Layer D reconcile only). Parser reads specs/NNN-*/, infers lifecycle phase, emits neutral workstate JSON; jira-sink consumes workstate and writes Jira issues/subtasks/status/labels/comments/links. Idempotent, drift-aware, fail-closed. Out of scope: seed/install, pull, status, the GitHub Action (Layer E)."

## Clarifications

### Session 2026-05-31

- Q: How should a spec and its task phases map onto Jira's issue hierarchy? → A: repo → Epic, spec → Story, task phase → Subtask. A single per-repository Epic groups all of that repo's spec Stories.
- Q: For the core spec, how is the "merged" lifecycle state determined? → A: Inferred purely from on-disk artifacts; pull-request/merge detection via `gh` is deferred to a later spec.
- Q: How should the bridge handle Jira API rate limits (HTTP 429)? → A: Respect the `Retry-After` header with bounded exponential backoff, then fail-closed for that spec and report it.
- Q: Should this core spec populate Jira's Story Points field? → A: No — Story Points are out of scope for the core mirror, deferred until the estimate's on-disk source is defined.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Mirror a project's specs into Jira (Priority: P1)

An operator working in a spec-kit repository runs one reconcile command. Every
feature under `specs/NNN-feature/` appears in the configured Jira project as a
Story — all grouped under a single per-repository Epic — with a status that
reflects the spec's current lifecycle phase, a label identifying the spec, and a
Subtask for each task phase. The operator did not create or update any Jira
issue by hand.

**Why this priority**: This is the entire reason the tool exists — turning the
on-disk spec corpus into a live Jira mirror with no manual data entry. Without
it, nothing else has value. It is the minimum shippable slice.

**Independent Test**: Point the tool at a repository containing one or more
specs and an authenticated Jira binding, run reconcile, and confirm each spec
is represented by a correctly-titled Story under the repo Epic with the expected
status, label, and per-phase Subtasks.

**Acceptance Scenarios**:

1. **Given** a repo with a spec at lifecycle phase "implementing" and two task
   phases, **When** the operator runs reconcile, **Then** Jira contains one
   Story for that spec — linked under the repository's Epic — whose status maps
   to "implementing", carrying the spec's identifying label, with two Subtasks
   (one per task phase).
2. **Given** a spec whose `tasks.md` lists individual tasks under each phase,
   **When** reconcile runs, **Then** each phase Subtask's body contains a
   checklist of that phase's tasks marked done/not-done to match the file.
3. **Given** a repo with three specs, **When** reconcile runs, **Then** all
   three are mirrored as Stories under one shared repository Epic in a single
   invocation and a structured summary reports the counts created.

---

### User Story 2 - Re-run safely with zero churn (Priority: P2)

The operator runs reconcile again against an unchanged spec corpus. Nothing in
Jira changes: no duplicate Epic, no duplicate Stories, no rewritten fields, no
new comments, no re-applied labels. The summary reports zero modifications.

**Why this priority**: A mirror that thrashes on every run is untrustworthy and
noisy (notifications, audit churn). Idempotency is what lets the operator wire
reconcile into hooks and run it freely.

**Independent Test**: Run reconcile twice against the same unchanged repo;
assert the second run performs zero writes and leaves every issue's
modified-timestamp untouched.

**Acceptance Scenarios**:

1. **Given** a spec already mirrored, **When** reconcile runs again with no
   on-disk change, **Then** the summary reports 0 created / 0 updated, the
   existing repository Epic is reused (not duplicated), and no Jira field shows
   a new modified-timestamp.
2. **Given** an operator manually edited a mirrored Story's status in Jira,
   **When** reconcile runs and disk is authoritative for that spec, **Then**
   the bridge restores the disk-derived status and reports the correction.

---

### User Story 3 - Drift-aware write authority (Priority: P2)

When the Jira side is further along than the on-disk spec (its lifecycle status
is ahead, or its last update is newer than the spec directory's last commit),
the bridge does not silently overwrite. It surfaces a named warning identifying
the spec and the conflicting signals. Interactively it asks the operator to
proceed or abort; non-interactively it proceeds and warns unless told to abort.

**Why this priority**: Silent clobbering of a tracker that someone else
advanced is the most damaging failure a mirror can have. Surfacing drift (not
enforcing a gate) is the safety property that makes the bridge trustworthy
across branches, worktrees, and teammates.

**Independent Test**: Arrange a spec whose Jira Story is at a later phase than
disk, run reconcile, and assert a backward-drift warning is emitted and the
configured disposition (proceed/abort) is honored.

**Acceptance Scenarios**:

1. **Given** a spec at "planning" on disk but "Done" in Jira, **When**
   reconcile runs non-interactively without an abort override, **Then** a
   backward-drift WARNING names the spec, both phases, and the firing signal,
   and the write proceeds.
2. **Given** the same drift **When** reconcile runs with the abort override,
   **Then** no write occurs for that spec and Jira is left unchanged.
3. **Given** a spec whose Jira Story was updated more recently than the spec
   directory's last commit beyond the clock-skew tolerance, **When** reconcile
   runs, **Then** the recency signal fires the same drift warning.

---

### User Story 4 - Lifecycle and content updates propagate (Priority: P3)

The operator advances a spec (e.g., moves from planning to implementing, ticks
tasks complete, adds a task phase, records a clarification). The next reconcile
updates only what changed: the Story's status transitions, Subtasks and their
checklists update, new clarifications appear as comments, and cross-spec
dependencies appear as issue links.

**Why this priority**: A static first-mirror is half a tool. Reflecting ongoing
spec evolution is what keeps Jira a faithful, low-latency view of the work.

**Independent Test**: Mirror a spec, change its on-disk state (phase, tasks,
clarifications, dependency), reconcile, and assert each change is reflected in
Jira while untouched attributes are not rewritten.

**Acceptance Scenarios**:

1. **Given** a mirrored spec moved from "planning" to "implementing" on disk,
   **When** reconcile runs, **Then** the Story's status transitions to the
   mapped value and no unrelated field is modified.
2. **Given** a new task phase added to `tasks.md`, **When** reconcile runs,
   **Then** a new Subtask is created for it and existing Subtasks are unchanged.
3. **Given** a clarification session recorded on disk, **When** reconcile runs,
   **Then** it appears once as a comment and is not duplicated on later runs.

---

### User Story 5 - Fail-closed and always observable (Priority: P3)

When the bridge cannot reliably read the Jira side (authentication failure,
network error, deleted resource, sustained rate-limiting), it does not guess and
does not wipe. It halts the affected write, leaves Jira untouched, and reports a
precise, actionable error. Every run ends with a structured summary; the bridge
never appears to succeed while having silently skipped work.

**Why this priority**: Trust depends on the bridge being loud and safe under
failure. Fail-closed plus observable summaries are the contract that lets the
operator leave reconcile running on hooks.

**Independent Test**: Simulate an unreadable Jira side and assert no writes
occur, the affected spec is reported as an error, and the process exit status
reflects the failure.

**Acceptance Scenarios**:

1. **Given** the Jira binding is unreadable for a spec, **When** reconcile
   runs, **Then** no write is attempted for that spec and the summary names it
   as an error with remediation guidance.
2. **Given** a spec directory missing `spec.md`, **When** reconcile runs,
   **Then** that spec is reported as a warning and every other processable spec
   is still mirrored.
3. **Given** repeated HTTP 429 responses beyond the retry bound, **When**
   reconcile runs, **Then** the bridge stops retrying, fails closed for the
   affected spec, and reports it rather than hanging.

### Edge Cases

- A spec directory exists but has no `tasks.md`: the spec is mirrored with no
  Subtasks; a warning notes the absence; no error.
- A task phase is later removed from `tasks.md`: the corresponding Subtask is
  reported (not silently abandoned); deletion of operator data is out of scope
  and surfaced rather than performed.
- The repository Epic already exists from a prior run: it is reused, never
  duplicated; if it was deleted in Jira, its absence is surfaced and a new one
  is created.
- A spec is mirrored, then its directory is deleted on disk: the orphaned Story
  is surfaced in the summary, not auto-deleted.
- Two specs claim the same identifying key: reported as a configuration defect,
  not silently merged.
- The clock skew between the local machine and Jira is within tolerance: the
  recency drift signal does not fire on that basis alone.
- Jira returns HTTP 429: the bridge honors `Retry-After` with bounded backoff;
  it does not bypass throttling or retry unbounded.
- The neutral intermediate representation fails schema validation: the run
  halts for that spec with a clear schema error rather than writing partial data.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The bridge MUST enumerate every feature directory under `specs/`
  in a single reconcile invocation and process each independently.
- **FR-002**: The bridge MUST infer each spec's lifecycle phase from its
  on-disk artifacts (presence/content of `spec.md`, `plan.md`, `tasks.md`, and
  recorded sessions), without requiring operator annotation. Lifecycle inference
  (including the "merged" phase) MUST rely only on on-disk artifacts; detecting
  merge state from a pull-request service (e.g., `gh`) is out of scope for this
  feature.
- **FR-003**: The bridge MUST represent each spec internally as a neutral,
  vendor-agnostic work-item record that conforms to the published `workstate`
  schema, and MUST validate that record against the schema before writing.
- **FR-004**: The bridge MUST mirror each spec as exactly one Jira Story,
  identified idempotently by a stable, filesystem-derived key (never a local
  sidecar file), so re-runs locate the same Story rather than creating a
  duplicate.
- **FR-005**: The bridge MUST mirror each task phase of a spec as a Subtask of
  that spec's Story, and MUST render the phase's individual tasks as a
  done/not-done checklist in the Subtask body matching `tasks.md`.
- **FR-006**: The bridge MUST set each spec Story's status to the value its
  lifecycle phase maps to (via the project's configured status mapping) and
  MUST apply the spec's identifying label and lifecycle `phase:*` label.
- **FR-007**: The bridge MUST mirror recorded clarification/decision sessions as
  comments and cross-spec dependencies as issue links, each created at most once.
- **FR-008**: Reconcile MUST be idempotent: a run against unchanged on-disk
  state MUST perform zero writes and produce zero observable change in Jira.
- **FR-009**: The bridge MUST detect backward-drift per spec from (a) lifecycle
  ordering (Jira phase strictly ahead of disk phase) and (b) recency (Jira
  Story last-updated newer than the spec directory's last git commit beyond a
  clock-skew tolerance); either signal firing raises a drift warning.
- **FR-010**: Recency comparison MUST derive the spec's on-disk timestamp from
  its git commit history, never from raw filesystem modification time.
- **FR-011**: On backward-drift the bridge MUST surface a named WARNING (spec,
  disk phase, Jira phase, firing signal) and MUST NOT block the write by
  default: interactive sessions prompt proceed/abort; non-interactive sessions
  proceed-and-warn unless an abort override is supplied. An abort leaves Jira
  unchanged.
- **FR-012**: The bridge MUST surface a spec's current Jira state from any
  working copy without requiring a write.
- **FR-013**: The bridge MUST fail closed: if the Jira side cannot be reliably
  read for a spec, it MUST NOT attempt a write for that spec and MUST report
  the failure.
- **FR-014**: The bridge MUST continue processing every other spec when one
  spec fails, and MUST halt the whole run only for project-level configuration
  errors.
- **FR-015**: Every reconcile MUST emit a structured summary (counts created /
  updated / skipped, plus named warnings and errors) and MUST NOT report
  success when work was silently skipped.
- **FR-016**: The bridge MUST offer a preview mode that reports every write it
  would make without performing any, for safe inspection before a live run.
- **FR-017**: The bridge MUST read its Jira credentials only from a
  non-committed local secret source and MUST NOT require or accept credentials
  embedded in tracked files.
- **FR-018**: All committed examples, fixtures, and documentation for this
  feature MUST use neutral placeholder identifiers; no real Jira coordinate,
  account, site, or token may appear in any tracked file.
- **FR-019**: The bridge MUST NOT write back to the filesystem, create or
  modify pull requests, or mutate any operator git/GitHub state as part of
  reconcile.
- **FR-020**: The internal work-item record MUST be the only contract the Jira
  writer consumes; the writer MUST ignore intermediate-representation fields it
  does not understand rather than depend on a Jira-specific side channel.
- **FR-021**: The bridge MUST ensure a single Epic exists per consumer
  repository and link every spec Story under it, idempotently — reusing the
  existing Epic on re-runs and never creating a duplicate.
- **FR-022**: On HTTP 429 (rate limiting) the bridge MUST respect the
  `Retry-After` header and retry with bounded exponential backoff; once the
  bound is exceeded it MUST fail closed for the affected spec and report it,
  never retrying unbounded.
- **FR-023**: The bridge MUST NOT write Jira's Story Points field in this
  feature; story-point population is deferred to a later feature once the
  estimate's on-disk source is defined.

### Key Entities *(include if feature involves data)*

- **Spec**: One feature under `specs/NNN-feature/`. Has an identity (feature
  number + short name), an inferred lifecycle phase, a body, task phases, tasks,
  recorded sessions, dependencies, and a last-commit timestamp.
- **Work-item record (`workstate`)**: The neutral, schema-validated intermediate
  produced from a Spec and consumed by the Jira writer. Carries id, title, kind,
  state, body, labels, children (task phases), notes, links, and provenance.
- **Repository Epic**: A single Jira Epic per consumer repository that groups
  all of that repo's spec Stories. Reused across runs; identified idempotently.
- **Mirrored Story**: The Jira representation of a Spec — a Story (under the
  repository Epic) with a status, labels, Subtasks (per task phase), comments
  (sessions), and links (dependencies).
- **Drift signal**: A per-spec determination that the mirror is ahead of disk,
  derived from lifecycle ordering and commit-recency comparison.
- **Run summary**: The structured, per-run record of what was created, updated,
  skipped, warned, or errored.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can mirror an entire repository's specs into Jira with
  a single command and zero manual issue creation.
- **SC-002**: Re-running reconcile against an unchanged corpus produces zero
  modifications — verifiable as zero new modified-timestamps across all mirrored
  issues, and the repository Epic is reused rather than duplicated.
- **SC-003**: 100% of specs that can be parsed are mirrored in a run; specs that
  cannot be parsed are reported in the summary, never silently dropped.
- **SC-004**: In 100% of cases where the mirror is ahead of disk, a backward-
  drift warning is surfaced and no silent overwrite occurs.
- **SC-005**: When the Jira side is unreadable for a spec, the number of writes
  performed for that spec is zero, and the run's exit status reflects the
  failure.
- **SC-006**: Zero real Jira coordinates, accounts, sites, or tokens appear in
  any committed file at any point (enforced by an automated privacy check).
- **SC-007**: An operator can preview every intended change without writing,
  and the preview's reported actions match what a subsequent live run performs.
- **SC-008**: Under Jira API throttling, the bridge respects `Retry-After` and
  either completes or fails closed within a bounded number of retries — it never
  hangs unbounded on 429 responses.

## Assumptions

- **Hierarchy mapping**: The mirror is three issue types deep — a single
  per-repository **Epic** groups all of that repo's specs; each spec is a
  **Story** under that Epic; each task phase is a **Subtask** of the spec Story
  (tasks render as a checklist in the Subtask body).
- **Status mapping is configured, not hard-coded**: The lifecycle-phase →
  Jira-status mapping (and the transitions used to reach each status) is
  resolved per project and supplied via configuration; this feature consumes
  that mapping and does not define a fixed status vocabulary.
- **Merge detection is disk-only here**: "merged" and all other lifecycle phases
  are inferred from on-disk artifacts; pull-request/merge detection via `gh` is
  deferred to a later feature.
- **Story Points deferred**: This feature does not populate Jira's Story Points
  field; it is revisited once the estimate's on-disk source is defined.
- **Binding exists**: A resolved per-project Jira binding (project + the
  status/transition/field identifiers and a credential) is already present;
  producing that binding (seed/install) is a separate feature.
- **Authoritative direction**: The filesystem is the single source of truth;
  Jira is a read-only mirror. Operator edits in Jira are not a control surface
  and are overwritten by the next reconcile (subject to drift surfacing).
- **Engine is shared and vendor-neutral**: The drift/recency/idempotency engine
  is the same one proven in the sibling tool; Jira specifics live only in the
  writer and configuration.
- **Out of scope**: seed/install ergonomics, the read-only pull and status
  commands, `gh`-based PR/merge detection, Story Points population, and the
  real-time GitHub Action (Layer E) status flips — each is a later feature.
- **Privacy**: This is a public repository; all examples and fixtures use
  placeholder identifiers and real secrets live only in non-committed files.
