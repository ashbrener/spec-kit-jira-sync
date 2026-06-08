# DESIGN-DRAFT — Feature 002: Configurable Mapping

> **STATUS: DRAFT.** This is a pre-spec design note to FEED a later
> `/speckit-specify` cycle for feature **002-configurable-mapping**. It is NOT a
> formal `spec.md` and does NOT pre-empt the spec-kit workflow (specify →
> clarify → plan → tasks → implement). It captures scope + the decisions locked
> in the design session so the eventual spec can be written quickly and
> faithfully. Privacy (Principle IX): placeholders only — no real Jira
> coordinates, names, ids, sites, or tokens anywhere in this file.
>
> Inputs folded in: `HANDOFF-competitive-model.md` (the competitive dig + the
> 4 model upgrades, incl. the §4 OPTIONAL Initiative/L0 super-level and the §14
> workstate-direct addendum), `specs/001-core-bridge/data-model.md` §2 (current
> `jira-config.yml` schema), `config-template.yml` (current committed config),
> and `.specify/memory/constitution.md` v1.0.0 (the idempotent / drift-aware /
> fail-closed differentiator).

## 1. Goal

Make the `workstate`→Jira mapping **configurable** — steal the direct
competitor's flexible domain model (`mbachorik/spec-kit-jira`) and layer it onto
our safe, tested engine — **WITHOUT changing the shipped, validated default
behavior** proven by US1–US3 of 001-core-bridge.

The competitor exposes a flexible artifact/relationship model but has no engine
(no idempotency, no drift, no fail-closed). We invert that: we already have the
safe engine; this feature gives it their flexibility. Net positioning: their
flexible model + our safe engine = strict domination, with the zero-config path
unchanged.

The mapping layer is **vendor-neutral in spirit but Jira-resolved in fact**: it
lives in the sink + config (per the constitution's "engine stays vendor-neutral"
constraint), never in the shared reconcile engine.

## 2. Locked decisions

These were locked in the design session and are NOT open for re-litigation in
`/speckit-clarify` (the clarify questions in §7 are narrower):

- **(a) The DEFAULT is frozen.** Absent any new config, the mapping stays
  exactly today's shipped behavior:
  `repo→Epic`, `spec→Story`, `phase→Subtask`, `task→ADF checklist` in the
  Subtask body. US1–US3 MUST keep passing unchanged. The default is a
  regression anchor, not a starting point to "improve".

- **(b) Alternate hierarchies are OPTIONS, opt-in only:**
  - A **3-level** mode: `spec→Epic`, `phase→Story`, `task→Task` (individual
    task issues instead of an ADF checklist).
  - A **2-level** mode: tasks/phases collapse into an **ADF checklist rendered
    in the parent issue body** (no per-task or per-phase child issues). Many
    teams do not want dozens of child issues cluttering the board.

- **(c) OPTIONAL Initiative super-level above Epic** (the L0 narrative level,
  HANDOFF §4). Jira-side primitive is **Initiative**, which is **Jira Premium /
  Advanced Roadmaps only**. It MUST **degrade gracefully** when absent: on a
  free/standard instance, fold the narrative onto the Epic and demote
  repo-grouping to a label — never hard-fail because Initiative is unavailable.
  Ships **OFF by default**. When on, the narrative is populated from
  `spec.md`'s `**Input**: User description` line (narrative ≈ spec 1:1) or
  operator-supplied grouping (1:many) — **NEVER inferred or fabricated**.

- **(d) Relationship types are configurable** per level boundary: native
  `parent` vs `Epic-link` vs `Relates` / `Blocks` / `Implements` / `none`.
  A **VALIDATION matrix** MUST reject semantically nonsensical combinations
  (e.g. `Blocks` used as the hierarchy link, or `Epic-link` declared between
  two non-Epic levels) at config-load time — fail-closed, before any write.
  Arbitrary relationship wiring can produce a corrupt Jira graph; the validator
  is the guard.

- **(e) Config back-compat is an ALIAS layer, not a migration.** No file
  rewrite, no version bump of the user's config. When `mapping:` is ABSENT, the
  loader **synthesizes today's default mapping** from the existing
  `issue_types` / `labels` / `phase_status` keys. Old configs keep working
  byte-for-byte; new keys are additive and optional.

## 3. Proposed config shape

A new **`mapping:`** block is layered OVER the existing `issue_types`, `labels`,
and `phase_status` keys (which keep their current meaning from
`data-model.md` §2). The `mapping:` block describes, per `workstate` level, the
Jira **artifact** to project to and the **relationship** to its parent level.
The defaults below **reproduce today's behavior exactly** — so a config with no
`mapping:` block and a config with this explicit block are equivalent.

```yaml
jira:
  project_key: "<KEY>"
  issue_types:
    epic: "<id>"
    story: "<id>"
    subtask: "<id>"
    # task: "<id>"        # only required when a level projects to a Task issue
    # initiative: "<id>"  # only required when the Initiative super-level is ON
  phase_status:
    specifying: "<status-id>"
    planning: "<status-id>"
    tasking: "<status-id>"
    implementing: "<status-id>"
    ready_to_merge: "<status-id>"
    merged: "<status-id>"
  transitions: {}
  labels:
    spec_prefix: "speckit-spec:"
    repo_prefix: "speckit-repo:"
    phase_prefix: "task-phase:"
    lifecycle_prefix: "phase:"

  # NEW — optional. Absent => alias layer synthesizes exactly this default.
  mapping:
    # The OPTIONAL narrative super-level above Epic. OFF by default.
    initiative:
      enabled: false
      artifact: "Initiative"        # Jira Premium-only primitive
      on_absent: "degrade"          # degrade => fold onto Epic + repo label
      source: "spec_input"          # spec.md "Input:" line; NEVER inferred
    levels:
      repo:
        artifact: "Epic"
        relationship_to_parent: "none"      # or "parent" when initiative is on
      spec:
        artifact: "Story"
        relationship_to_parent: "parent"    # Story under repo Epic
      phase:
        artifact: "Subtask"
        relationship_to_parent: "parent"    # Subtask of the spec Story
      task:
        artifact: "checklist"               # ADF taskList in the parent body
        relationship_to_parent: "checklist" # not an issue; embedded render
```

**3-level example** (opt-in; `spec→Epic / phase→Story / task→Task`):

```yaml
  mapping:
    levels:
      spec:
        artifact: "Epic"
        relationship_to_parent: "none"
      phase:
        artifact: "Story"
        relationship_to_parent: "Epic-link"   # or "parent" on team-managed
      task:
        artifact: "Task"
        relationship_to_parent: "parent"
```

**2-level example** (opt-in; phases collapse, tasks become a checklist in the
parent body):

```yaml
  mapping:
    levels:
      spec:
        artifact: "Story"
        relationship_to_parent: "parent"
      phase:
        artifact: "checklist"                  # collapse into parent body
        relationship_to_parent: "checklist"
      task:
        artifact: "checklist"
        relationship_to_parent: "checklist"
```

Relationship vocabulary to support: `parent` (native), `Epic-link` (classic /
company-managed), `Relates`, `Blocks`, `Implements`, `none`, plus the
non-issue `checklist` render sentinel.

**Available-issue-type detection (live-Jira dogfood finding).** Issue types
differ by board/template: a team-managed **Scrum** project ships
Epic/Story/Task/Subtask/Bug, but the **Kanban** simplified template ships only
**Task/Epic/Subtask — NO Story**. The sink today assumes
`issue_types.{epic,story,subtask}` exist; dogfooding against a Kanban project
forced the spec slot to map to **Task** because no Story type was present.
Configurable mapping therefore MUST NOT assume a fixed Epic/Story/Subtask set.
It MUST (1) **read the target project's available issue types**, (2) **validate**
each configured `artifact` against that available set at config-load time, and
(3) define explicit behavior when a configured type (e.g. "Story") is **absent**
in the target project. The validation joins the §4 fail-closed config check (it
runs before any write); the absent-type behavior is enumerated in §7 Q10.

## 4. Invariants to preserve

The constitutional differentiator — **idempotent + drift-aware + fail-closed** —
MUST hold in **every** mapping mode, not just the default:

- **Idempotency (Principles II, III).** A re-run against unchanged state is zero
  observable churn in ALL modes. In **checklist (2-level) mode** the
  tasks/phases live in the parent issue body as ADF: a re-run MUST re-render
  **byte-identical ADF** so the content diff is empty and no field write fires.
  This depends on the **US2 update path** (the description/ADF update + content
  diff already built for 001-core-bridge). The checklist must NOT duplicate, and
  the parent issue must NOT be rewritten when nothing changed.

- **Idempotent identity per mode.** Each created artifact still derives stable
  identity from filesystem-evident keys via labels (`speckit-spec:NNN`,
  `speckit-repo:<slug>`, `task-phase:N`). When a level projects to a Task issue
  (3-level), that issue needs its OWN stable label key so re-runs match it
  rather than re-create — define the task-identity label prefix as part of this
  feature.

- **Drift (Principle IV).** Backward-drift detection (phase-ordinal + recency)
  is computed on the drift-anchored work-unit. **`spec→Story` stays the
  drift anchor** even when the Initiative super-level is on; the super-level is
  narrative, not a new drift surface.

- **Status rollup is idempotent (live-Jira dogfood finding).** Today only the
  spec-level issue (Story/Task) receives a lifecycle status; the per-repo Epic
  and per-phase Subtasks stay "To Do", so a 100%-complete feature still looks
  undone on the board — per-task done-ness lives only inside the ADF checklist.
  This feature adds an **OPTIONAL mapping lever (OFF by default)** to roll
  completion up to issue status: e.g. all tasks in a phase checked → that
  phase's Subtask → Done; all specs done → the repo Epic → Done. When the lever
  is on, the rollup MUST stay **idempotent**: a re-run against unchanged
  completion fires **no transition** (no re-transition churn), and the rollup
  only transitions an issue whose computed completion state has actually
  changed. The exact rollup rules and the OFF-by-default default are the §7 Q11
  question.

- **Fail-closed (Principle VIII).** Config validation runs BEFORE any write. A
  nonsensical relationship combo, a missing required issue-type id for a
  configured artifact, an unsupported artifact name, or a **configured artifact
  whose issue type does not exist in the target project's available types**
  (the live-Jira dogfood finding — e.g. mapping a level to "Story" on a Kanban
  project that ships no Story type) is a **workspace-level configuration error**.
  Validation against the project's detected available issue types runs at
  config-load, before any write; the resolution policy when a configured type is
  absent (hard-error vs warn-and-skip vs fall-back) is the §7 Q10 question — not
  a silent skip, not a per-spec warning, until that policy is set.

## 5. workstate-direct input seam (HANDOFF §14 / addendum)

Fold in the source-decoupling seam now, because the mapping layer is the natural
place it surfaces:

- **The sink MUST be runnable from a `workstate` JSON file or stdin**, not only
  from a `specs/` tree. The pipeline must be startable one stage later
  (`workstate → jira`, skipping the parser) so any non-spec-kit producer
  (product-mem, etc.) can feed it. This is cheap because `workstate` is already
  the internal contract (Principle X) — it is just exposing the seam.

- **Keep parser ↔ sink cleanly separable.** No Jira concern leaks into the
  parser; no spec-kit concern leaks into the sink. The mapping config consumes
  `workstate` levels (`repo` / `spec` / `phase` / `task`), NOT spec-kit
  on-disk concepts — which keeps the boundary clean for the eventual
  `source-speckit` carve-out (the post-Jira engine-extraction step). The
  `spec_input` narrative source for the Initiative level is the one spec-kit
  coupling; it MUST be a clearly-bounded source adapter, not a parser leak into
  the sink.

- **Do NOT extract `source-speckit` in this feature.** The carve-out is the
  post-Jira shared step; here we only make it a future *move*, not a *rewrite*
  (origin-header the parser files; keep the seam clean).

## 6. Out of scope (for 002)

- Extracting the parser into a standalone `source-speckit` repo (post-Jira).
- Bidirectional sync / Jira→filesystem flow (out of scope indefinitely,
  Principle I).
- Any change to the shipped default mapping or to US1–US3 behavior.
- Auto-discovery of issue-type ids for new artifacts (that is the seed/install
  feature's job; here they are consumed, not resolved).

## 7. Clarify questions

This section enumerates **every** question that must be resolved (or explicitly
deferred) before opening a `/speckit-specify` cycle. Each item is an answerable
question with its candidate options and the proposed default/leaning that the
draft already implies (drawn from §2 locked decisions, §3 config, and the §5
workstate-direct seam — no new product direction is introduced here). Items are
tagged **[blocking]** (must be answered before specify) or **[non-blocking]**
(may take the proposed default and be revisited during clarify/plan).

LOCKED (NOT clarify questions — listed only to bound the session): the frozen
default mapping (§2a), the existence of 3-level and 2-level opt-in modes (§2b),
the existence of an OFF-by-default Initiative super-level that degrades when
absent (§2c), relationship types being configurable behind a validation matrix
(§2d), and config back-compat as an alias layer not a migration (§2e). Do NOT
re-open these; the questions below are narrower.

### 7.1 Scope of the clarify session

- **Q1 [blocking] — How many questions is the clarify session, and which ones?**
  The inventory flagged this as under-specified (is it ~5 or ~25?). The real set
  is the **ten** questions enumerated in §7.2–§7.5 below: Q2–Q11 (Q10 and Q11
  added from the live-Jira dogfood — available-issue-type detection and status
  rollup). A standard `/speckit-clarify` pass caps at ~5 targeted questions, so
  this set MUST be split. **Proposed leaning:** answer the five **[blocking]**
  items (Q2, Q5, Q7, Q8, Q10) in the first clarify pass and carry the five
  **[non-blocking]** items (Q3, Q4, Q6, Q9, Q11) into plan/a second pass.
  Options: (a) one combined session taking all ten; (b) blocking-first split as
  proposed; (c) defer all non-blocking items to plan. Default: (b).

### 7.2 Mapping model and relationships

- **Q2 [blocking] — What is the exact relationship-validation matrix?** Define
  the allow/reject table of (level-boundary × relationship-type) combinations,
  and which combos warn vs hard-halt. (e.g. is `Blocks` ever legal as a
  hierarchy link, or only as a cross-spec dependency link?) Vocabulary to cover
  per §3: `parent`, `Epic-link`, `Relates`, `Blocks`, `Implements`, `none`,
  `checklist`. **Leaning** (per §2d, fail-closed): hierarchy links restricted to
  `parent` / `Epic-link` / `none` / `checklist`; `Blocks` / `Relates` /
  `Implements` rejected as hierarchy links; `Epic-link` rejected between two
  non-Epic levels — all rejections hard-halt at config-load, before any write.
  Blocking because the matrix is the fail-closed guard the whole feature leans
  on.

- **Q3 [non-blocking] — `Epic-link` vs native `parent` detection.** How does the
  bridge know a project is classic/company-managed (needs the `Epic-link`
  custom field) vs team-managed (native `parent`)? Options: (a) probe project
  metadata at runtime; (b) require the operator to declare project style in
  config; (c) hybrid — declare in config, validate against a probe. **Leaning:**
  (b) declare-in-config (keeps the sink offline-validatable and fail-closed),
  with (c) as a later enhancement. Non-blocking: a config-declared default
  unblocks specify.

- **Q4 [non-blocking] — Mixed/partial `mapping:` block.** If `mapping:` is
  present but only some levels are specified, do unspecified levels inherit the
  synthesized default, or is a partial block a validation error
  (all-or-nothing)? Options: (a) inherit default per-level; (b) all-or-nothing
  validation error. **Leaning:** (a) per-level inheritance, consistent with the
  §2e additive/optional alias philosophy. Non-blocking: defaulting to inherit is
  safe and revisitable.

### 7.3 Initiative / L0 super-level, degradation, and identity

- **Q5 [blocking] — How does the L0/Initiative super-level degrade on
  non-Premium Jira (Advanced Roadmaps absent)?** §2c locks the policy
  (`on_absent: "degrade"` → fold narrative onto the Epic, demote repo-grouping
  to a label, never hard-fail), but the mechanics are open: (i) how is
  Premium/Advanced-Roadmaps availability **detected** — probe issue-type
  metadata for the `Initiative` type, catch the create error, or an operator
  config flag? (ii) when degraded, **where** does the narrative land on the Epic
  (description prepend vs a dedicated ADF block) and **which label** carries the
  repo grouping (reuse `repo_prefix` per §3 `labels`, or a new prefix)?
  (iii) must degradation be **idempotent** so a later upgrade to Premium can
  re-home the narrative onto a real Initiative without churn? **Leaning:**
  detect via issue-type metadata probe; degrade by folding narrative into the
  Epic description behind a stable marker and reusing the existing `repo_prefix`
  label. Blocking because "never hard-fail on standard Jira" is a shipped
  promise and the detection path gates every write on a non-Premium instance.

- **Q6 [non-blocking] — Initiative scope: per-repo or per-org?** Is the
  super-level configured per-repo (1:1, narrative ≈ spec) or per-org (1:many
  operator grouping)? This changes where the binding lives and how the
  `spec_input` source (§3, "NEVER inferred") is resolved. Options: (a) per-repo
  1:1; (b) per-org 1:many; (c) support both via config. **Leaning:** ship (a)
  per-repo 1:1 first (matches `source: "spec_input"`), leave (b) as a config
  extension. Non-blocking: it is OFF by default (§2c), so specify can proceed
  with the 1:1 shape.

### 7.4 Idempotency, identity keys, and provenance

- **Q7 [blocking] — Does 2-level checklist mode preserve idempotency under real
  use, and how is the checklist diffed/keyed?** §4 requires byte-identical ADF
  re-render with zero field writes via the US2 update path, but the keying is
  open: (i) what is the **stable key** for each checklist item so re-runs match
  rather than duplicate — `task` id, the task text, or an embedded marker? (ii)
  how is the rendered ADF **diffed** — full-body byte compare, or an isolated
  checklist sub-tree compare so unrelated description edits don't trigger a
  rewrite? (iii) how are item reorder / completion-toggle / rename handled
  without churn? **Leaning** (per §4): key each item by its `workstate` `task`
  id, compare the checklist ADF sub-tree for byte equality, and only write when
  that sub-tree changes. Blocking because idempotency in non-default modes is
  the constitutional differentiator and the inventory flagged it as
  under-verified.

- **Q8 [blocking] — Is the parser bypassable: lock the workstate-direct input
  interface.** §5 commits the sink to run from a `workstate` JSON file or stdin
  (skipping the parser) so a non-spec-kit producer can feed it. The **interface
  is open and must be locked before specify:** (i) invocation surface — a flag
  (e.g. `--workstate <file>` / `--workstate -` for stdin) on the existing
  reconcile entrypoint, or a separate subcommand? (ii) which `workstate` schema
  version is accepted and is it validated on entry (fail-closed on a bad
  document)? (iii) does the `spec_input` narrative source (the one spec-kit
  coupling, §5) degrade cleanly when the input is workstate-direct and no
  `spec.md` exists — Initiative narrative simply unavailable, not an error?
  **Leaning** (per §5): add a `--workstate` flag on the reconcile entrypoint
  (file or `-` for stdin), validate against the pinned `workstate` schema on
  entry, and treat `spec_input` as gracefully absent in workstate-direct mode.
  Blocking because §5 calls it a contract to expose now and an unlocked surface
  blocks the test obligations in §8.

- **Q9 [non-blocking] — Task-issue identity label + 2-level provenance header.**
  Two coupled identity/provenance details: (i) when a level projects to a `Task`
  issue (3-level), what is the **task-identity label prefix** so re-runs match
  rather than re-create (§4 requires defining one; sibling to
  `speckit-spec:` / `speckit-repo:` / `task-phase:` in §3 `labels`)?
  (ii) in 2-level mode the mirrored checklist shares the parent body with the
  description — how is the Principle I read-only-mirror provenance header
  rendered so the round-trip stays byte-identical (Q7) without visually
  dominating the issue? **Leaning:** add a `task_prefix` (e.g. `speckit-task:`)
  to the `labels` block; render the provenance header as a single stable ADF
  marker line above the checklist sub-tree. Non-blocking: sensible defaults
  exist and both fold into the Q7 idempotency tests.

### 7.5 Live-Jira dogfood findings: issue-type detection and status rollup

- **Q10 [blocking] — When a configured issue type is absent in the target
  project, does the mapping hard-error, warn-and-skip, or fall back to an
  available type (and which)?** The live-Jira dogfood proved issue types differ
  by board/template: a team-managed **Scrum** project ships
  Epic/Story/Task/Subtask/Bug, but the **Kanban** simplified template ships only
  **Task/Epic/Subtask — NO Story**, forcing the spec slot to map to **Task**
  (§3). So the mapping MUST (1) read the target project's available issue types,
  (2) validate the configured `artifact` per level against that set, and (3)
  define behavior when a configured type is absent. Open: (i) is the absent-type
  outcome **hard-error** (fail-closed per §4), **warn-and-skip** that level, or
  **fall back** to an available type — and if fall-back, which type and is the
  substitution per-level configurable (e.g. `on_absent: "Task"`)? (ii) how is
  the available-type set **detected** — probe project issue-type metadata, or an
  operator-declared list in config (mirroring the Q3 declare-vs-probe choice)?
  (iii) is the validation purely config-load-time, or re-checked against the
  live project before each run? **Leaning** (per §4 fail-closed): detect via an
  issue-type-metadata probe, hard-error at config-load when a configured
  artifact has no matching available type, with an OPTIONAL per-level
  `on_absent` fall-back (e.g. `Story → Task`) as the explicit opt-in escape.
  Blocking because absent-type behavior gates every write on any non-Scrum
  template and the default Story-bearing assumption is already known to break on
  Kanban.

- **Q11 [non-blocking] — Should status rollup be a config lever (off by
  default), and what are the rollup rules?** Today only the spec-level issue
  (Story/Task) gets a lifecycle status; the per-repo Epic and per-phase Subtasks
  stay "To Do", so a 100%-complete feature still reads as undone on the board
  (per-task done-ness lives only inside the ADF checklist — §4). Open: (i) is
  rollup an **OPTIONAL lever, OFF by default**, preserving today's behavior as
  the regression anchor (§2a)? (ii) what are the exact **rules** — e.g. all
  tasks in a phase checked → that phase's Subtask → Done; all specs done → the
  repo Epic → Done — and are the target statuses drawn from the existing
  `phase_status` / `transitions` config or a new rollup block? (iii) how does
  rollup stay **idempotent** (§4) so a re-run fires no transition when
  completion is unchanged, and how are partially-complete or regressed states
  handled (transition back to "In Progress"/"To Do", or roll up forward only)?
  **Leaning** (per §4): ship rollup OFF by default as an additive lever;
  phase-complete → Subtask Done and all-specs-done → Epic Done; reuse the
  existing transition config for target statuses; transition only when the
  computed completion state changes, forward-and-backward, to stay idempotent.
  Non-blocking unless rollup is judged MVP: it is OFF by default and additive,
  so specify can proceed without it and it folds into the §8 idempotency tests.

## 8. Test obligations (to seed `/speckit-tasks` later)

- Default mapping (no `mapping:` block) reproduces US1–US3 outcomes exactly.
- An explicit default `mapping:` block is equivalent to the absent case (alias
  layer).
- 3-level override creates Epic/Story/Task with correct relationships.
- 2-level checklist mode: parent body renders the ADF checklist; **re-run is
  zero churn** (byte-identical ADF; no field write).
- Relationship-validation matrix: a nonsensical combo halts fail-closed before
  any write.
- Initiative super-level ON + Premium present → Initiative created; ON + absent
  → degrades to Epic + repo label (no hard fail).
- `workstate`-direct input: sink runs from a `workstate` JSON file and from
  stdin, producing the same projection as the `specs/`-tree path.
- Available-issue-type detection (Q10): a configured artifact absent from the
  target project's available types is caught at config-load (e.g. mapping a
  level to "Story" on a Kanban project that ships no Story type), and the chosen
  absent-type policy (hard-error / warn-skip / configured fall-back) is honored
  before any write.
- Status rollup (Q11), when the lever is ON: a phase whose tasks are all checked
  rolls its Subtask → Done and an all-specs-done repo rolls its Epic → Done;
  **re-run is zero churn** (no transition fired when completion is unchanged).
