# Feature Specification: Jira Install + Seed Ceremony

**Feature Branch**: `008-install-seed-ceremony`

**Created**: 2026-06-17

**Status**: Draft

**Input**: User description: "Jira install + seed ceremony for spec-kit-jira-sync
— the adoption on-ramp. Today, after `specify extension add jira-sync`, the
operator must hand-edit the gitignored `jira-config.yml` and fill in the project
key, issue-type ids, status/transition ids, and the story-points field id by
hand. The Linear sibling ships `/speckit.linear.install` + `.seed` that resolve
all of this interactively and write it back. Close the gap."

## Why this is the adoption on-ramp

Installing the extension (`specify extension add jira-sync`) copies the bridge
into the consumer repo and registers its commands — but it does **not** bind the
bridge to a Jira project. The runtime binding
(`.specify/extensions/jira/jira-config.yml`: project key, issue-type ids, status
ids, transition ids, story-points field id) is the gitignored file the sink reads
on every reconcile (Principle V). Today the operator produces that file **by
hand**: copy `config-template.yml`, then read every id off Jira manually (or via
the Atlassian MCP) and paste it in. The README says exactly this — "you fill the
ids by hand."

The Linear sibling does not make its operators do that: `/speckit.linear.install`
resolves Team / Project / operator ids interactively and writes the binding, and
`/speckit.linear.seed` creates the lifecycle states + labels and captures every
id. The absence of the equivalent here is the **single biggest adoption-friction
gap** versus the sibling, and it stands directly in front of the community-catalog
launch: a new operator who runs `specify extension add jira-sync` hits a wall of
manual id-hunting before the bridge does anything.

This feature implements the **Install** and **Seed** steps that the constitution's
*Operational Workflow* already defines (they are specified there; this feature
builds them). It is **sink-side configuration resolution** — it does not touch the
vendor-neutral engine, so the 003 neutrality gate is unaffected.

## Clarifications

### Session 2026-06-17 (open decisions — leans recorded, resolve in /speckit-clarify)

Three design forks carry leans for `/speckit-clarify`:

- **(a) Resolution transport — MCP vs REST.** LEAN: the durable ids that get
  written are **REST-derived** (Basic-auth from `.env`, the same transport the
  sink already uses), so the binding is authoritative and reproducible (Principle
  V — no name-fallback). The Atlassian Remote MCP MAY be used as an optional
  *interactive* convenience (e.g. browsing projects), but never as the source of
  the written ids.
- **(b) Seed — create missing labels vs validate-only.** LEAN: Jira labels are
  created on first use by the reconcile writes themselves, so seed **validates +
  normalizes** the `phase:*` / `task-phase:N` label prefixes and **confirms** the
  status/transition mapping is reachable on the project's workflow, rather than
  pre-creating anything. (Jira workflow statuses/transitions are admin-scoped and
  out of scope to mutate.)
- **(c) Chaining — should install offer to run seed at the end.** LEAN: **yes** —
  install offers to run seed immediately (with a confirm), since the two are
  almost always run together; declining leaves seed as a separate explicit step.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Install resolves the binding instead of hand-editing YAML (Priority: P1) 🎯 MVP

An operator has run `specify extension add jira-sync` in their consumer repo and
has a gitignored `.env` with their Jira Basic-auth credential. They run the
install command. It verifies the credential authenticates, asks which Jira
project to bind (or accepts the project key), resolves the issue-type ids for
each mapped level, the lifecycle status ids and the transition ids that reach
them, and the story-points field id — and writes a complete
`.specify/extensions/jira/jira-config.yml`. The operator never reads an id off
Jira by hand.

**Why this priority**: This is the entire point — turning a wall of manual
id-hunting into one command. Without it there is no on-ramp.

**Independent Test**: In a fresh consumer repo with a valid `.env`, run install,
confirm a complete gitignored `jira-config.yml` is written with real ids, and that
`reconcile.sh --dry-run` then runs without the exit-2 "config missing/invalid"
halt.

**Acceptance Scenarios**:

1. **Given** a consumer repo with a valid `.env` and an existing Jira project,
   **When** install runs, **Then** it writes a complete gitignored
   `jira-config.yml` (project key + issue-type ids + status ids + transition ids
   + story-points field id) and reports what it resolved.
2. **Given** a freshly-installed binding, **When** `reconcile.sh --dry-run` runs,
   **Then** it does not halt with exit 2 (config missing/invalid) and previews
   writes normally.
3. **Given** an already-bound project, **When** install is re-run against the
   unchanged project, **Then** it re-resolves to the same ids and the written
   config is byte-identical (idempotent rebind, Principle V/II).

---

### User Story 2 - Seed validates the labels and lifecycle mapping (Priority: P1)

The operator runs the seed command once for the project. It ensures the required
`phase:*` and `task-phase:N` label conventions are correct, confirms the status +
transition mapping the lifecycle needs is reachable on the project's workflow, and
captures every relevant id into the binding. It is safe to re-run.

**Why this priority**: Seed is what makes the lifecycle mapping trustworthy — it
proves the statuses/transitions the bridge will drive actually exist on the
project's workflow before the first real reconcile, surfacing a misconfigured
workflow as an explicit, actionable failure rather than a mid-run surprise.

**Independent Test**: Run seed against a project; confirm it reports the
label/status/transition validation result and updates the binding; re-run and
confirm idempotent (no spurious change).

**Acceptance Scenarios**:

1. **Given** a bound project, **When** seed runs, **Then** it validates the
   `phase:*` / `task-phase:N` label conventions and confirms each lifecycle status
   + transition is reachable, capturing their ids into the binding.
2. **Given** a project whose workflow is missing a required status/transition,
   **When** seed runs, **Then** it fails closed (exit 2) and names exactly which
   lifecycle step cannot be reached, with remediation, writing no partial binding.
3. **Given** an already-seeded project, **When** seed is re-run unchanged, **Then**
   it produces no spurious change (idempotent).

---

### User Story 3 - Dependency verification with exact remediation (Priority: P2)

When a precondition is missing — no `.env`, a credential that does not
authenticate, a missing `jq`/`curl`/`git`, an unreadable project key — install
and seed do not best-effort silently. They stop, name precisely what is missing,
and print copy-paste remediation. They never write a partial binding.

**Why this priority**: Surface-don't-enforce (Principle VIII). A silent or
half-finished install is worse than no install — it produces a broken binding the
operator then has to debug. Loud, exact failure is the contract.

**Independent Test**: Remove/blank the `.env` (and separately, supply a bad
token), run install, and confirm it exits non-zero (2 for missing config inputs,
3 for an unreadable/forbidden Jira), names the missing piece + remediation, and
leaves the tree unchanged (no config written).

**Acceptance Scenarios**:

1. **Given** a missing or incomplete `.env`, **When** install runs, **Then** it
   exits 2, names the missing variable(s), prints the exact `.env` lines to add,
   and writes nothing.
2. **Given** a present but non-authenticating credential, **When** install runs,
   **Then** it exits 3 (Jira unreadable), names the auth failure, and writes
   nothing.
3. **Given** a missing runtime dependency (`jq`/`curl`/`git`), **When** install
   runs, **Then** it exits non-zero naming the missing tool and the install
   command to get it.

---

### Edge Cases

- **Run from the bridge's own checkout (source == target)**: install/seed are
  consumer-repo commands. If run from inside the bridge's own development checkout
  (where `specs/` are the bridge's own features, not the operator's), surface a
  clear halt rather than bind the bridge to a project — mirroring the install-time
  source-equals-target guard.
- **No project specified / multiple candidate projects**: if the operator's
  credential can see multiple projects and none is specified, install prompts
  (interactive) or requires an explicit project key (non-interactive) rather than
  guessing.
- **Existing hand-written binding present**: re-running install overwrites the
  resolved fields but MUST preserve any operator-authored non-resolved sections it
  does not own (e.g. a custom `mapping:` block from 002) — it rebinds ids, it does
  not clobber the operator's mapping choices. (To be confirmed in clarify/plan.)
- **Partial resolution failure mid-way**: if any required id cannot be resolved
  (e.g. the project has no story-points field), install fails closed and writes
  nothing rather than a half-binding — except where a field is legitimately
  optional, which it records as absent with a surfaced note.
- **Privacy**: the resolved binding contains real coordinates (project key, site,
  ids). It is written ONLY to the gitignored `jira-config.yml`; nothing real is
  echoed into a tracked file, a commit, or a captured log. The committed surface
  stays placeholder-only.
- **Idempotent config write**: a re-resolve that yields the same ids produces a
  byte-identical file (stable key order, no timestamp/nonce), so re-running is a
  visible no-op.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001 (Install command)**: The bridge MUST provide an install command
  (`speckit.jira.install` / `/speckit-jira-install`) — interactive, idempotent,
  run from the consumer repo — that resolves the Jira **project key**, the
  **issue-type ids** for each mapped level (epic/story/subtask, honoring a 002
  `mapping:` block if present), every lifecycle **status id** and the **transition
  ids** that reach them, and the **story-points field id**, and writes them into
  the gitignored `.specify/extensions/jira/jira-config.yml` (from the
  `config-template.yml` shape). Re-running re-resolves and overwrites the resolved
  binding (Principle V — rebind = re-run).
- **FR-002 (Resolution transport)**: The durable ids written to the binding MUST
  be resolved via the Jira REST API using the Basic-auth credential from the
  gitignored `.env` (the same transport the sink uses) — capturing every
  status/transition/field **id** at resolution time, never a name to be re-looked
  up later (Principle V, no name-fallback). The Atlassian Remote MCP MAY be used
  as an optional interactive convenience but MUST NOT be the source of the written
  ids (clarify a).
- **FR-003 (Seed command)**: The bridge MUST provide a seed command
  (`speckit.jira.seed` / `/speckit-jira-seed`) — one-shot-per-project, idempotent,
  safe to re-run — that validates/normalizes the `phase:*` and `task-phase:N`
  label conventions, confirms the lifecycle status + transition mapping is
  reachable on the project's workflow, and captures every id into the binding. It
  MUST NOT attempt to create or edit Jira workflow statuses/transitions
  (admin-scoped, out of scope); label creation is left to first reconcile use
  (clarify b).
- **FR-004 (Dependency verification — surface, don't enforce)**: Install MUST
  verify every dependency it touches — `.env` Basic-auth present and authenticates
  (a `myself` probe), `jq`/`curl`/`git` present, the target project key readable,
  and (if used) the Atlassian MCP reachable — and surface **exact copy-paste
  remediation** for any missing piece (Principle VIII). Silent best-effort install
  is forbidden.
- **FR-005 (Fail-closed exit codes)**: On a missing/unresolvable project-config
  input, install/seed MUST fail closed with **exit 2** (project-level config
  error); on an unreadable/forbidden Jira (bad token, auth/network), **exit 3** —
  consistent with the reconcile exit-code contract. A failed run MUST write **no
  partial binding**.
- **FR-006 (Privacy IX)**: The resolved binding (real project key, site, ids) MUST
  be written ONLY to the gitignored `jira-config.yml`. Install/seed MUST NOT echo
  a real coordinate into any tracked file, commit, or a log line that would be
  captured into the tracked tree. The committed surface stays placeholder-only
  (`config-template.yml`); after an install writes the gitignored config, the 006
  consumer-side privacy guard and `no-real-identifiers.bats` MUST still pass.
- **FR-007 (Source≠target guard)**: Install/seed MUST detect when run from the
  bridge's own checkout rather than a consumer repo and halt with a clear message,
  rather than bind the bridge to a project.
- **FR-008 (Idempotency, no sidecar)**: Re-running install or seed against an
  unchanged project MUST produce a byte-identical binding (stable key order, no
  timestamp/nonce) — a visible no-op. Install/seed MUST share the config-writing
  path and keep NO sidecar state (Principle II).
- **FR-009 (Manifest + registration)**: Both commands MUST be exposed through
  `extension.yml` (`speckit.jira.install`, `speckit.jira.seed`) alongside the
  existing push/status, with `commands/jira-install.md` + `commands/jira-seed.md`
  bodies and the dev-layout `.claude/commands/speckit-jira-{install,seed}.md`
  twins.
- **FR-010 (Docs)**: The README Install section MUST be updated so the manual
  "fill the ids by hand" caveat is replaced by "run `/speckit-jira-install`", and
  the corresponding roadmap item marked done. CONTRIBUTING/quickstart updated as
  needed.
- **FR-011 (Engine neutrality unaffected)**: Install/seed are sink-side
  configuration commands; they MUST NOT alter the vendor-neutral engine path — the
  003 neutrality gate stays green.
- **FR-012 (Existing-binding preservation)**: Re-running install MUST preserve
  operator-authored config sections it does not own (e.g. a 002 `mapping:` block),
  overwriting only the resolved id fields it is responsible for.
- **FR-013 (Install→seed chaining)**: Install SHOULD offer to run seed
  immediately on success (with a confirm); declining leaves seed as a separate
  explicit step (clarify c).

### Key Entities *(include if feature involves data)*

- **Resolved binding (`jira-config.yml`)**: the gitignored per-repo config the
  sink reads — project key, issue-type ids per level, lifecycle status ids,
  transition ids, story-points field id, label prefixes, optional `mapping:`. The
  artifact install/seed produce.
- **`.env` credential**: the gitignored Basic-auth input
  (`JIRA_BASE_URL`/`JIRA_EMAIL`/`JIRA_API_TOKEN`) install reads to resolve ids.
  Never written elsewhere.
- **`config-template.yml`**: the committed placeholder shape install copies from
  and the privacy guard's reference for "what the binding looks like with no real
  values."
- **Lifecycle mapping**: the set of (lifecycle phase → status id → transition id)
  triples seed confirms are reachable on the project's workflow.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From a fresh consumer repo with a valid `.env`, a single
  `/speckit-jira-install` run produces a complete gitignored `jira-config.yml`,
  after which `reconcile.sh --dry-run` runs without an exit-2 config halt — with
  zero manual id-editing by the operator.
- **SC-002**: `/speckit-jira-seed` validates the `phase:*`/`task-phase:N` labels
  and confirms every lifecycle status + transition is reachable, and is idempotent
  on re-run (no spurious change).
- **SC-003**: A missing/invalid `.env` causes install to fail closed (exit 2 for
  missing inputs, exit 3 for an unreadable Jira) with exact remediation and **zero
  bytes written** to any config, 100% of the time.
- **SC-004**: After any install/seed run, **no real identifier** appears in a
  tracked file — the 006 consumer-side privacy guard and
  `no-real-identifiers.bats` stay green.
- **SC-005**: Re-running install/seed against an unchanged project yields a
  byte-identical binding (a visible no-op).
- **SC-006**: The install/seed user experience matches the spec-kit-linear sibling
  on shape — a resolve-and-write install, a validate-and-capture seed, dependency
  verification with remediation, fail-closed posture — differing only in the
  vendor specifics (Jira REST ids/transitions vs Linear GraphQL UUIDs/states).
- **SC-007**: The 003 engine-neutrality gate stays green (install/seed add no
  vendor vocabulary to the engine path).

## Assumptions

- **The Jira project already exists.** Install binds to an existing project; it
  does not create or provision projects (out of scope).
- **The operator has a working `.env`.** The Basic-auth credential is the
  operator's responsibility (Principle VI); install reads it, never provisions it.
- **Jira workflow statuses/transitions are admin-scoped.** Seed validates and
  captures the lifecycle mapping; it does not mutate the project's workflow scheme.
- **Labels auto-create on first use.** Jira creates labels when first applied, so
  seed normalizes/validates prefixes rather than pre-creating labels (clarify b).
- **REST is the authoritative transport** for the written ids; MCP is an optional
  interactive aid (clarify a).
- **Reconcile's exit-code contract is the model** — install/seed reuse exit 2
  (config) / 3 (Jira unreadable) for a consistent operator mental model.
- **No new hosted backend/daemon/state** — install/seed are inline commands that
  read Jira + write one gitignored file (Architectural Constraints).
- **Constitution already defines Install + Seed** (Operational Workflow); this
  feature implements them with no amendment.

## Out of Scope

- Creating or editing Jira **workflow** schemes, statuses, or transitions
  (admin-scoped) — seed validates + captures, never mutates the workflow.
- The **GitHub Action / Layer E webhook** — this bridge registers no hooks
  (operator-driven, per `extension.yml`); install does not provision a webhook
  layer.
- **Auto-provisioning** Jira projects — the project must already exist.
- Changing the reconcile/engine behavior — install/seed only produce the binding
  the existing reconcile consumes.

## Open Questions — for /speckit-clarify

The three forks in Clarifications (Session 2026-06-17) carry strong leans:
(a) REST-authoritative resolution (MCP optional), (b) seed validates/normalizes
labels rather than pre-creating, (c) install offers to chain into seed. Resolve by
the leans unless one is genuinely contentious.
