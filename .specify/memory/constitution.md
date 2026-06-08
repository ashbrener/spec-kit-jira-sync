<!--
SYNC IMPACT REPORT
==================
Version change: 1.0.0 → 1.1.0  (MINOR — scoped controlled-destruction carve-out)
Ratification date: 2026-05-31 | Last amended: 2026-06-08

Origin: adapted from the shipped spec-kit-linear Constitution v2.0.0. The proven
engine principles (filesystem-source-of-truth, reconcile-never-event-push,
layered idempotency, drift-aware write-authority, surface-don't-enforce) are
carried over UNCHANGED in spirit; only vendor mechanics (Linear GraphQL/UUIDs/
Linear MCP → Jira REST/IDs/Atlassian MCP) are re-expressed. spec-kit-linear's
spec/FR cross-references and its 1.0.0→2.0.0 amendment history are NOT inherited
— this repo establishes its own spec history. Principle IV ships drift-aware at
v1.0.0 (no branch-gate phase ever existed here).

Added (first-class for THIS repo, beyond the inherited set):
  IX. No Real Identifiers In The Tracked Tree (Privacy)
  X.  workstate Is The Internal Contract

v1.1.0 amendment (2026-06-08, feature 004 — mapping re-mode / orphan pruning):
  Principle I gains a SCOPED controlled-destruction carve-out. The ordinary
  mirror stays strictly non-destructive; an explicit, opt-in re-mode operation
  MAY remove bridge-owned artifacts (those carrying the `speckit-*` identity
  labels) the current mapping no longer projects. The carve-out is bounded by
  four MUSTs (flag-only / bridge-owned-only / dry-run-previewable / fail-closed)
  and is cross-referenced in the Architectural Constraints. This is MINOR: no
  principle is removed, the data-model mapping is unchanged, both layers remain —
  a new scoped constraint is ADDED. Rationale: feature 004 research R9.

Templates / dependent docs to keep in sync:
  ✅ .specify/templates/{spec,plan,tasks,checklist}-template.md — generic.
  ⛳ commands/*.md, README.md, CONTRIBUTING.md — when written they MUST reflect
     the principles below (especially IX privacy and the re-mode carve-out).

Follow-up TODOs: feature 004's plan Constitution Check gates on THIS v1.1.0.
-->

# spec-kit-jira-sync Constitution

The non-negotiable principles that govern how the spec-kit ↔ Jira bridge is
built, installed, and operated. Every functional requirement in this repo's
specs MUST trace to one of these principles, and every spec MUST be checked
against them before `/speckit-plan` lands.

This repo has a second mandate beyond shipping a Jira bridge: it is the
**independent second consumer** that proves the neutral `workstate` format
(Principle X). A from-scratch Jira sink that eats the same `workstate` a
different tool produces is the validation that the format is not secretly
shaped to one vendor.

## Core Principles

### I. Filesystem Is The Single Source of Truth

The filesystem under each consumer repo's `specs/NNN-feature/` is canonical.
Jira is a unidirectional, read-only mirror. The bridge MUST NOT write back to
the filesystem in response to any Jira change. Operator-side mutations in Jira
(transitions, edited labels, comments) are not a control surface; the next
reconcile overwrites them.

**Rationale**: Two-way sync between a git-versioned markdown corpus and a
hosted issue tracker is a conflict-resolution tar-pit. Pinning one direction
keeps the bridge small, predictable, recoverable, and survivable across Jira
outages or site migrations.

**Rules**:
- Reconcile MUST be the only write path into Jira.
- Jira → filesystem flow is OUT OF SCOPE indefinitely.
- Task-phase checklists mirrored into Jira MUST carry a header noting they are
  read-only mirrors of `tasks.md`.

**Controlled-destruction carve-out (v1.1.0, amended 2026-06-08)**:
The mirror is non-destructive **except** through an explicit, opt-in **re-mode**
operation, which MAY remove (hard-delete or archive) **bridge-owned** artifacts —
those carrying the `speckit-*` identity labels — when the current mapping no
longer projects them (the orphans a prior mapping shape left behind). Bridge-owned
*content* is fully regenerable from the source-of-truth specs, which is what makes
its removal acceptable. The carve-out is bounded by four MUSTs:
- **Flag-only**: reachable ONLY via an explicit flag (e.g. `--remode`); NEVER
  auto-fired on a hook. The ordinary reconcile (including every `after_*` hook)
  stays strictly non-destructive and only *warns* on detected orphans.
- **Bridge-owned-only**: it MUST NEVER prune, relabel, or modify an
  operator-created issue. When ownership cannot be proven (no identity label), the
  artifact is left untouched (fail-safe default).
- **Dry-run-previewable**: a dry-run MUST preview the exact prune + regenerate set
  with zero writes, byte-faithful to what the real run does.
- **Fail-closed**: an unreadable Jira read MUST abort the operation before any
  destructive write — never a partial destruction on an unreadable read.
This carve-out does not reopen Jira → filesystem flow; the bridge remains a
one-way mirror and the specs remain the source of truth.

### II. Reconcile, Never Event-Push

Every invocation — hook-fired or manual — reads full filesystem state and
pushes whatever Jira needs to match. The bridge MUST NOT track per-event
diffs, MUST NOT maintain a filesystem-side cache of "what Jira last saw", and
MUST be safe to re-run any number of times against unchanged state with zero
observable churn.

**Rationale**: Event-diff systems break on missed events, replays,
out-of-order delivery, and partial failures. A reconciler converges from any
starting state — the only architecture that survives operator interrupts and
forgotten manual edits without a corruption story.

**Rules**:
- Hook-triggered, manual, and CI-triggered sync MUST share one code path and
  produce identical outcomes.
- Stable identity for every mirrored entity MUST derive from filesystem-evident
  keys (feature number, task code, branch name, seeded status/transition id) —
  never from a local sidecar file.
- Unchanged-state reconcile MUST be observable as zero field writes, zero
  transition POSTs, zero comment posts, zero link rewrites.

### III. Layered Idempotency (D + E)

The bridge ships two cooperating layers, each independently idempotent and
each individually sufficient for correctness:

- **Layer D — Reconciliation.** Synchronous, filesystem-driven, runs in the
  operator's session. Owns labels, comments, subtasks, description blocks,
  project status, and merged-state detection (via `gh` with git-only fallback).
- **Layer E — Webhook.** A GitHub Action installed per consumer repo. Owns
  real-time status flips on PR open / ready / merge. Drives the spec Issue's
  status (a transition POST) ONLY.

Layer boundaries are absolute. Layer E MUST NOT touch labels, comments,
subtasks, or description blocks. Cross-layer writes to the same Jira attribute
are a defect, not an optimisation.

**Rationale**: Webhooks deliver low-latency UX but break when Actions are
disabled or secrets rotate. Reconcilers guarantee correctness but are only as
fresh as their last run. Both, with strict write-domain separation, give
responsive UX without sacrificing recoverability.

**Rules**:
- Either layer alone MUST keep Jira converging.
- A repo lacking Layer E (Actions disabled, install declined) MUST still be
  fully correct via Layer D alone (only real-time latency is lost).
- Layer E silent-failure modes (rotated token, deleted secret) are acceptable
  PROVIDED Layer D reconciles on its next run. The bridge MUST NOT report
  webhook health out-of-band.

### IV. Write-Authority Follows The Filesystem (Drift-Aware)

For any given spec, the authority for what Jira should reflect is the
**filesystem state of the invoking worktree** (Principle I). ANY worktree MAY
write a spec's Jira state — the branch name is a HEURISTIC for "who has the
latest", not a gate. The worktree holding the most recent commit touching
`specs/NNN-feature/` holds the freshest state; that commit timestamp (a
filesystem-evident key per Principle II, never raw file mtime) identifies the
canonical-right-now worktree.

The bridge MUST detect **backward-drift** and SURFACE it, but MUST NOT block
the write. Backward-drift is when Jira's recorded lifecycle phase is strictly
further along than the disk-inferred phase, OR Jira's issue `updated` is newer
than the spec directory's last commit beyond a clock-skew tolerance. On
backward-drift, an interactive session prompts the operator to proceed
(overwrite Jira from disk) or abort; a non-interactive session
proceeds-and-warns unless an override flag selects abort. The operator
decides — the bridge surfaces, it does not enforce (Principle VIII).

**Rationale**: Tying write authority to a `<NNN>-...` feature branch is too
strict for legitimate workflows — merged specs (feature branch deleted),
retroactive adoption, and squash-merge / trunk-based teams developing on `main`
all need to write from non-feature branches. The filesystem is already the
source of truth; the branch name is evidence about recency, not a substitute
for the evidence itself. When heuristic and evidence disagree, trust the
evidence and let the operator decide.

**Rules**:
- Branch name MUST NOT gate spec-level writes.
- The backward-drift signal MUST be computed per spec from (a) lifecycle-phase
  ordering (Jira phase vs disk-inferred phase) and (b) recency (spec-dir
  last-commit time vs Jira issue `updated`, with a clock-skew tolerance);
  either firing raises the warning.
- Recency MUST derive from the spec-directory git-commit timestamp, never raw
  mtime, because mtime does not survive clone / checkout / worktree creation.
- Backward-drift MUST be surfaced as a named WARNING row on every reconcile
  where Jira is ahead, naming the spec, the disk-inferred phase, Jira's phase,
  and which signal(s) fired. It MUST NOT block: interactive prompts
  proceed/abort; non-interactive proceeds-and-warns unless `--on-drift=abort`.
  An operator abort leaves Jira unchanged.
- Reconcile MUST still SURFACE a spec's current Jira state from any worktree
  without requiring a write.
- Layer E is exempt: the PR head ref already implies authority.

### V. ID-Based Binding, Per-Repo Config

Every Jira identifier the bridge depends on — project key, issue-type ids,
status ids, transition ids, the story-points field id — is resolved once and
stored in a per-repo config. Runtime lookups MUST use stable ids (and the
project key), never operator-editable display names. Re-running install
regenerates the binding; no per-operator global state is required to drive
sync.

**Rationale**: Jira UI names (statuses, fields) are operator-editable;
name-based lookups make the bridge fragile to cosmetic edits. Ids are stable
for the resource's lifetime; the only failure mode is hard deletion, which the
bridge surfaces as an explicit error rather than silent drift.

**Rules**:
- The resolved binding (`.specify/extensions/jira/jira-config.yml`) holds real
  coordinates and is GITIGNORED (Principle IX). Only a placeholder
  `config-template.yml` is committed.
- The seed/install step MUST capture every status id, transition id, and the
  story-points field id at resolution time and write them to config; no
  post-resolution name-fallback is allowed.
- The GitHub Action MUST read ids from config (or repo variables) at runtime,
  never resolve by name.
- Per-operator global config (`~/.config/`, env-only bindings beyond the
  gitignored `.env` secret) is forbidden; rebinding a repo means re-running
  install.

### VI. Credentials At The Edges, Never Committed

Jira Cloud authenticates via Basic auth (`email:api_token`). The bridge MUST
keep that token out of every tracked file. Interactive exploration MAY use the
Atlassian Remote MCP (OAuth); the sink, seed step, and GitHub Action use the
Basic-auth token. Long-lived credentials are permitted ONLY at the edges and
ONLY from non-committed sources.

**Rationale**: API tokens on operator workstations and in CI are a perpetual
rotation and exfiltration risk. Containing them to a gitignored `.env` locally
and a repo secret in CI — never the tree, never global — bounds the blast
radius.

**Rules**:
- The token + email MUST live only in a gitignored `.env` locally
  (`JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`) and a repo secret in CI;
  never committed, never globalised.
- The GitHub Action MUST read its credentials from repo secrets; the bridge
  MUST NOT provision those secrets programmatically.
- Tests and fixtures MUST use placeholder credentials; the privacy guard
  (Principle IX) fails CI on a committed token shape.

### VII. Memory-Just-Works, Escape Hatches Beside It

At `specify extension add jira` time the bridge MUST auto-register every
relevant `after_*` hook (`after_specify`, `after_clarify`, `after_plan`,
`after_tasks`, `after_implement`, `after_analyze`) with `optional: false`.
Default UX: run a spec-kit command, Jira updates. On-demand commands
(`speckit.jira.push`, `.pull`, `.status`) ship as **escape hatches** for
recovery, ad-hoc inspection, and incident response — NOT as the primary path.

**Rationale**: A bridge whose primary UI is "remember to run sync" drifts and
gets abandoned. Auto-firing on every lifecycle transition is what earns the
bridge its toolchain slot.

**Rules**:
- Hook auto-registration MUST be `optional: false` at install. Operators MAY
  disable individual hooks by editing `.specify/extensions.yml`; the bridge
  MUST honour `enabled: false` and MUST NOT silently re-enable on reinstall.
- On-demand commands MUST be functionally equivalent to the hook-fired path
  (Principle II).
- Documentation MUST present the auto-sync flow first; on-demand commands
  appear in a recovery section, never in the quickstart.

### VIII. Surface, Don't Enforce — Observable Failure

The bridge warns the operator about gaps (missing `spec.md`, malformed tasks,
deleted Jira resources, unauthenticated MCP, absent `gh`) but never "fixes" the
operator's workflow or filesystem unilaterally. Every reconcile MUST emit a
structured summary (counts created/updated, named warnings). Every Action run
MUST log its decisions. The bridge MUST NOT appear to succeed when it has
silently skipped work.

This principle also fixes terminology: the bridge uses canonical spec-kit
vocabulary. Task groupings are `## Phase N: <Name>` (per the tasks template),
never "wave / W0 / W1". When spec-kit terms collide (lifecycle "phase" vs
task-grouping "phase"), the bridge disambiguates by context ("lifecycle phase"
/ "task phase") and never invents new words.

**Rationale**: Operators install this bridge into their working toolchain;
silent mutation, auto-PR creation, or hidden failures make the bridge an
adversary rather than a mirror. Loud, structured failure is the contract that
lets the operator trust the bridge enough to leave its hooks `optional: false`.

**Rules**:
- Reconcile MUST process every spec it can and only halt for workspace-level
  configuration errors.
- Install MUST verify every dependency it touches (MCP wiring, auth, `gh`,
  runtime) and surface exact copy-paste remediation for missing pieces. Silent
  best-effort install is forbidden.
- Vocabulary in code, comments, command names, Jira labels, and docs MUST
  match canonical spec-kit terms (`task-phase:N` labels, `Phase N — <Name>`
  subtask titles).
- Auto-creation/un-drafting of PRs and any other write to the operator's
  git/GitHub state are OUT OF SCOPE and MUST NOT be added without amending this
  principle.

### IX. No Real Identifiers In The Tracked Tree (Privacy)

This is a public repo. No real identifier may EVER enter a tracked file: not a
company / workspace / project name, a person's name or email, a Jira Cloud
site, an account id, a cloudId / UUID, and above all not a live Atlassian API
token. Real coordinates live ONLY in gitignored files (`.env`,
`jira-config.yml`, `tests/.private-deny`).

**Rationale**: The repo doubles as a public proof of the `workstate` format;
leaking the operator's Jira coordinates or a token into history is
unrecoverable and a security incident.

**Rules**:
- Every committed example, fixture, spec, and doc MUST use neutral placeholders.
- The privacy guard (`tests/unit/no-real-identifiers.bats`) MUST gate CI: it
  scans the tracked tree for shape-based leaks (e.g. the Atlassian token
  prefix) plus operator literals loaded from the gitignored
  `tests/.private-deny`. It MUST contain zero real values itself.
- Code comments, commit messages, and PR-tracked artifacts MUST NOT embed real
  names, emails, ids, or UUIDs — not even fragmented across concatenation.

### X. workstate Is The Internal Contract

The bridge's internal interchange is the neutral `workstate` format
(`schema/workstate.schema.json` in the workstate-schema repo). The parser
PRODUCES schema-valid `workstate`; the jira-sink CONSUMES only `workstate`.
The bridge MUST NOT invent a parallel Jira-shaped internal model.

**Rationale**: This repo exists partly to prove `workstate` by being an
independent second consumer. A bespoke internal shape would defeat that proof
and re-couple the engine to one vendor.

**Rules**:
- Parser output MUST validate against the committed `workstate` schema; the
  build gates on it.
- The jira-sink MUST read only documented `workstate` fields; unknown
  `extensions` keys MUST be ignored, never depended on.
- If `workstate` cannot cleanly express something the bridge needs, that is a
  SIGNAL: record it for a possible floor change to the schema — do NOT silently
  work around it with a private side-channel.

## Architectural Constraints

The data-model mapping is constitutional; amending it is a MAJOR bump:
consumer repo → Jira Project; spec → Jira Issue (Epic or Story); task phase →
subtask; tasks → checklist items in the subtask body; non-task artifacts →
spec-Issue comments; lifecycle state → spec-Issue status (set via a transition
POST) + `phase:*` label.

Layer responsibility boundaries (Principle III) are constitutional. Layer E
drives ONLY the spec Issue's status; Layer D owns everything else.

The bridge MUST NOT introduce a hosted backend, an operator-side daemon, or a
database. State lives in three places only: the consumer repo's filesystem,
Jira itself, and the GitHub Action's per-invocation environment.

The drift/reconcile engine is shared with spec-kit-linear (copied here per a
labeled, temporary debt; see PLAN.md §11). It MUST stay vendor-neutral — Jira
specifics live in the sink and config, never in the engine — so the two copies
can later be extracted into one.

The **re-mode** controlled-destruction carve-out (Principle I, v1.1.0) is
constitutional: destruction is confined to the explicit, opt-in re-mode, scoped to
bridge-owned (identity-labelled) artifacts, dry-run-previewable, and fail-closed.
The orphan **diff** (which bridge-owned artifacts the current mapping no longer
projects) is vendor-neutral and lives in the engine; the **prune mechanic**
(hard-delete vs archive) is Jira-specific and lives in the sink — preserving the
engine/sink seam above. Widening destruction beyond this scope (e.g. into the
ordinary reconcile, or onto operator-created issues) is a MAJOR amendment.

## Operational Workflow

**Install** (per consumer repo): `specify extension add jira` → resolve the
Jira project key, issue-type ids, status + transition ids, and story-points
field id → write the gitignored `jira-config.yml` → register `after_*` hooks
with `optional: false` → offer the GitHub Action and guide `JIRA_EMAIL` +
`JIRA_API_TOKEN` secret provisioning → verify every touched dependency
(Principle VIII) and report status.

**Seed** (one-shot per Jira project): ensure required `phase:*` and
`task-phase:*` labels exist, confirm the status/transition mapping the
lifecycle needs, capture every id, and write them into config. Safe to re-run.

**Sync**: auto on every `after_*` hook; available on-demand via
`speckit.jira.push`. Idempotent. Writes from any worktree (Principle IV,
drift-aware); on backward-drift it surfaces a warning and — interactively —
prompts proceed/abort, but never blocks the write outright.

**Recovery**: on-demand commands (`speckit.jira.push`, `.pull`, `.status`) are
the documented path for missed hooks, drift inspection, and post-incident audit.

## Governance

This constitution supersedes all other practices and informal conventions in
the `spec-kit-jira-sync` project. Where this constitution and any other document
(SEED-BRIEF.md, PLAN.md, README) conflict, this constitution wins.

**Compliance**: every PR touching the bridge MUST be reviewed for compliance.
`/speckit-plan`'s Constitution Check gate is the formal enforcement point —
plans that violate a principle MUST be revised or trigger an amendment before
implementation begins.

**Amendments**: any amendment MUST (a) update this file, (b) propagate to
dependent templates per the Sync Impact Report header, (c) bump the version per
semver below, (d) be committed in a PR whose description names the principle(s)
added, removed, or redefined.

**Versioning**:
- **MAJOR**: backward-incompatible changes — removing a principle, redefining
  the data-model mapping, eliminating a layer.
- **MINOR**: adding a principle, materially expanding guidance, adding a new
  constitutional constraint.
- **PATCH**: clarifications, wording, typo fixes.

**Version**: 1.1.0 | **Ratified**: 2026-05-31 | **Last Amended**: 2026-06-08
