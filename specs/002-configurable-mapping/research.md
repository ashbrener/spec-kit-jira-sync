# Phase 0 Research: Configurable Artifact Mapping

**Feature**: `002-configurable-mapping`

**Date**: 2026-06-03

This document records the Phase 0 research decisions for feature 002. Ten
mapping questions (Q2-Q11) from `DESIGN-DRAFT.md` §7 are formalized below. Four
(Q2, Q7, Q8, Q10) were resolved in the 2026-06-03 clarify session and are
recorded as settled. Six (Q3, Q4, Q5, Q6, Q9, Q11) sit at their documented
design-draft defaults and are formalized here as research Decisions.

The §2 locked decisions of the design draft (frozen default mapping, opt-in
3-level / 2-level modes, off-by-default Initiative super-level, configurable
relationships behind a validation matrix, alias-layer back-compat) are
constraints, not questions, and are not re-litigated here.

## Technical context

- **Language / runtime**: Bash, targeting the CI matrix (bash 4.4 and bash 5.2).
  No new runtime dependencies are introduced.
- **External tooling**: `jq` for JSON/ADF shaping and `curl` for the Jira REST
  calls — both already in use by the 001 core bridge; nothing new is added.
- **Testing**: `bats` over the curl-shim mock (no live Jira in CI), plus
  `shellcheck` (style severity), `yamllint` (relaxed), and `markdownlint-cli2`
  for the docs gate, and workstate schema validation of any directly-supplied
  workstate document against the pinned schema.
- **Architectural boundary**: all mapping, detection, and validation logic lives
  in the Jira-specific **sink + config layer** (per FR-018); the vendor-neutral
  reconcile **engine stays free of mapping/Jira knowledge**.
- **Unresolved NEEDS CLARIFICATION**: there are **none**. The four clarify-session
  questions are resolved and the six deferred questions are formalized at their
  documented defaults below; nothing remains blocking for `/speckit-plan`.

## Q2 — Relationship-validation matrix

- **Decision**: Hierarchy (parent to child) links are restricted to `parent`
  (native), `Epic-link`, `none`, and the non-issue `checklist` sentinel.
  Dependency-style links (`Blocks`, `Relates`, `Implements`) are rejected when
  used as hierarchy links, and `Epic-link` declared between two non-Epic levels
  is rejected. Every rejection hard-halts at configuration load, before any write.
- **Rationale**: The validation matrix is the fail-closed guard (Principle VIII)
  that the whole feature leans on — arbitrary relationship wiring can produce a
  corrupt Jira graph, so the matrix rejects semantically nonsensical combinations
  before any mutation (FR-007, FR-017). Restricting to native/Epic-link/none/
  checklist keeps the allowed set to genuine hierarchy primitives.
- **Alternatives considered**: Allowing `Blocks`/`Relates`/`Implements` as
  hierarchy links (rejected — these are cross-spec dependency semantics, not
  nesting, and would mis-shape the issue graph); warn-and-continue on a bad combo
  (rejected — violates fail-closed; a warning still permits a corrupt write).

## Q3 — Project-style detection (classic Epic-link vs team-managed native parent)

- **Decision**: The project style (classic/company-managed needing the `Epic-link`
  custom field vs team-managed using native `parent`) is **operator-declared in
  config**. A runtime project-metadata probe to auto-detect or cross-validate the
  style is deferred as a later enhancement.
- **Rationale**: Declaring the style in config keeps relationship validation fully
  **offline-validatable and fail-closed** — the matrix (Q2) can resolve and reject
  links at config-load with no network round-trip, consistent with the
  constitution's fail-closed differentiator and FR-007/FR-017. It also avoids
  adding a probe dependency on the critical config-load path.
- **Alternatives considered**: Probe project metadata at runtime to infer the
  style (rejected for now — couples config validation to a live call and a
  network failure mode); hybrid declare-in-config-then-validate-against-a-probe
  (deferred as the later enhancement on top of the declared default).

## Q4 — Partial mapping block (per-level inheritance)

- **Decision**: A `mapping:` block that specifies only some levels is valid;
  unspecified levels **inherit the synthesized default per level**. A partial
  block is not an all-or-nothing validation error.
- **Rationale**: Per-level inheritance is consistent with the §2e additive /
  optional alias philosophy and the FR-002 alias layer — configurations stay
  additive, an operator overrides only the levels they care about, and the safe
  default fills the rest. This directly satisfies the spec edge case
  ("unspecified levels fall back to the synthesized default, not an
  all-or-nothing error") while preserving the FR-001 frozen default on untouched
  levels.
- **Alternatives considered**: All-or-nothing — require every level whenever
  `mapping:` is present (rejected — hostile to the additive/opt-in model, forces
  operators to restate the frozen default verbatim just to override one level,
  and increases the chance of accidental divergence from today's behavior).

## Q5 — Initiative degradation mechanics (detection + landing spot + idempotent re-home)

- **Decision**: Initiative availability is **detected by probing issue-type
  metadata** for the `Initiative` type. When absent, the narrative **folds onto
  the Epic behind a stable marker** (a description region delimited by a stable
  marker, not a free prepend) and **repo grouping is carried by reusing the
  existing repo-grouping label** (`repo_prefix`), never a new prefix. Degradation
  is **idempotent**: a later upgrade to an Initiative-capable instance can re-home
  the narrative onto a real Initiative without churn, and re-runs in the degraded
  state produce zero writes.
- **Rationale**: "Never hard-fail on standard Jira" is a shipped promise (FR-013,
  SC-007), so detection must gate the write path on a non-Premium instance. The
  stable marker and reused label make the fold idempotent (Principles II/III,
  FR-008) and let the re-home stay zero-churn — the constitution's
  idempotent + drift-aware differentiator holds in the degraded mode. The narrative
  is populated only from the explicit source (FR-014), never inferred.
- **Alternatives considered**: Catch the Initiative create error at runtime
  instead of probing (rejected — a post-write failure is not fail-closed and
  leaves a partial mirror); operator config flag for availability (rejected as the
  primary mechanism — drifts from instance reality, though probe results can be
  cached); free description prepend with a new label prefix (rejected — a
  marker-less prepend is not safely re-homeable and a new prefix breaks
  idempotent identity continuity).

## Q6 — Initiative scope (per-repo 1:1 vs per-org)

- **Decision**: The narrative super-level ships **per-repo 1:1** (narrative ≈
  spec), matching `source: "spec_input"`. Per-org 1:many operator grouping is
  deferred as a later config extension.
- **Rationale**: Per-repo 1:1 matches the explicit `spec_input` narrative source
  (FR-014, narrative never inferred) and keeps the binding co-located with the
  repo it mirrors, which preserves the spec→Story drift anchor (FR-010) without
  introducing a cross-repo grouping surface. The super-level is off by default
  (FR-013), so shipping the 1:1 shape first unblocks the feature without
  foreclosing the per-org extension.
- **Alternatives considered**: Per-org 1:many grouping (deferred — moves where the
  binding lives and complicates `spec_input` resolution across multiple repos;
  valuable but additive); supporting both shapes via config from day one
  (rejected for the first ship — doubles the binding/identity surface before the
  off-by-default level has demonstrated demand).

## Q7 — 2-level checklist keying and diffing

- **Decision**: Each checklist item is **keyed by its workstate task identity**.
  The rendered checklist is diffed by **byte-comparing only the checklist
  sub-tree** (not the full issue body), and the body is written **only when that
  sub-tree changes** — unrelated edits to the surrounding description do not
  trigger a rewrite. Reorder, completion-toggle, and rename are handled by
  re-rendering keyed items so no item is duplicated.
- **Rationale**: Idempotency in non-default modes is the constitutional
  differentiator (Principles II/III); 2-level mode lives in the parent issue body
  as ADF, so it must re-render byte-identically for the content diff to be empty
  (FR-008). Keying by workstate task identity and isolating the sub-tree compare
  is what makes "zero churn on re-run" and "only the affected issue updates" hold
  (US3 acceptance scenarios), via the existing 001 update/content-diff path.
- **Alternatives considered**: Key by task text (rejected — a rename would
  duplicate or orphan items); key by ordinal position (rejected — a reorder would
  churn every item); full-body byte compare (rejected — an unrelated description
  edit would force a checklist rewrite, breaking the zero-churn promise).

## Q8 — Workstate-direct input interface

- **Decision**: Workstate-direct input is exposed as a **`--workstate` flag on the
  existing reconcile entrypoint**, taking a file path or `-` for stdin. The
  document is **validated against the pinned workstate schema on entry**, and a
  malformed or unsupported document is rejected fail-closed (no partial write). In
  this mode the `spec_input` narrative source is treated as **gracefully absent**
  (the Initiative narrative is simply unavailable, not an error).
- **Rationale**: §5 commits the sink to run one stage later (`workstate → jira`,
  skipping the parser) so non-spec-kit producers can feed it (FR-015). A flag on
  the existing entrypoint reuses the reconcile surface rather than forking a
  subcommand, and on-entry schema validation enforces fail-closed acceptance
  (FR-016, Principle VIII). Treating `spec_input` as gracefully absent matches the
  edge case where no originating `spec.md` exists.
- **Alternatives considered**: A separate subcommand (rejected — duplicates the
  reconcile surface and its flags for one input variation); accepting the document
  without schema validation (rejected — violates fail-closed and risks a partial
  mirror from a malformed input); erroring when `spec_input` is unavailable in
  this mode (rejected — the narrative source is optional and off by default, so
  its absence must be graceful, not a hard failure).

## Q9 — Task-identity label prefix + 2-level provenance header

- **Decision**: A **`task_prefix` label** (e.g. `speckit-task:`) is added to the
  `labels` block as the stable identity key for levels that project to a
  standalone `Task` issue (3-level mode), sibling to `speckit-spec:` /
  `speckit-repo:` / `task-phase:`. In 2-level mode the read-only-mirror provenance
  header is rendered as a **single stable ADF marker line above the checklist
  sub-tree**.
- **Rationale**: FR-009 requires a defined identity key for any level projecting
  to a standalone Task issue so re-runs match and update rather than re-create —
  a dedicated label prefix gives that filesystem-derived identity. A single stable
  marker line keeps the Principle I read-only-mirror provenance present without
  visually dominating the issue and without perturbing the byte-identical
  checklist round-trip the Q7 idempotency contract depends on (FR-008).
- **Alternatives considered**: Reuse an existing prefix for Task-projected levels
  (rejected — collides with spec/phase identity and breaks unambiguous re-match);
  omit the provenance header in 2-level mode (rejected — Principle I requires the
  read-only-mirror marker); a multi-line or banner-style header (rejected — risks
  visual domination and complicates the stable byte-identical sub-tree compare).

## Q11 — Status rollup rules + off-by-default + idempotency

- **Decision**: Status rollup ships as an **optional lever, OFF by default**. When
  on: all tasks in a phase complete → that phase's issue transitions to a done
  status; all specs in the repo complete → the repo's top issue transitions to a
  done status. Target statuses **reuse the existing status / transition
  configuration**. Transitions fire **only when the computed completion state has
  actually changed** (forward and backward), so a re-run against unchanged
  completion fires no transition. With rollup off, only the spec-level status is
  set — exactly today's behavior.
- **Rationale**: Off-by-default preserves today's shipped behavior as the
  regression anchor (FR-001, §2a) so a no-config upgrade changes nothing
  (US1/SC-001). Firing a transition only on a real completion-state change keeps
  the rollup idempotent (FR-012, Principles II/III) — the constitution's
  idempotent + drift-aware differentiator holds in this additive mode (US4
  zero-churn re-run). Reusing the existing transition config avoids a parallel
  status surface.
- **Alternatives considered**: Rollup on by default (rejected — would change
  existing boards on upgrade, breaking the FR-001 frozen-default safety promise);
  a separate rollup status block (rejected — duplicates the existing
  status/transition config and creates two sources of truth); roll up forward only,
  never transitioning back (rejected — a regressed completion state would leave a
  stale "done", so idempotency must cover backward transitions too).

## Q10 — Absent-type policy (detection + fail-closed + per-level fallback)

- **Decision**: The target project's available issue types are **detected via an
  issue-type-metadata probe**. The system **hard-errors at configuration load**
  when a configured artifact has no matching available type, writing nothing for
  the run, **unless an explicit per-level `on_absent` fallback** (e.g.
  `Story → Task`) is configured as the opt-in escape. Validation runs at
  config-load, before any write.
- **Rationale**: The live-Jira dogfood proved issue types differ by board template
  (a Kanban simplified template ships Task/Epic/Subtask with no Story), so a
  configured-but-absent type would silently corrupt the mirror — the exact failure
  the dogfood hit. Hard-erroring at config-load before any write is the fail-closed
  guard (FR-005, FR-006, FR-017, Principle VIII), and the optional per-level
  fallback gives operators an explicit, declared escape (SC-003: no partial
  mirrors).
- **Alternatives considered**: Warn-and-skip the affected level (rejected —
  produces a silent partial mirror, the opposite of fail-closed); implicit
  fall-back to some available type without operator opt-in (rejected — guesses the
  operator's intent and can mis-shape the board); operator-declared available-type
  list instead of a probe (rejected as the primary mechanism — drifts from the
  live project, though it mirrors the Q3 declare-vs-probe tension and could back a
  later offline mode).
