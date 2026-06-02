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
  `parent` vs `Epic Link` vs `Relates` / `Blocks` / `Implements` / `none`.
  A **VALIDATION matrix** MUST reject semantically nonsensical combinations
  (e.g. `Blocks` used as the hierarchy link, or `Epic Link` declared between
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
        relationship_to_parent: "Epic Link"   # or "parent" on team-managed
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

Relationship vocabulary to support: `parent` (native), `Epic Link` (classic /
company-managed), `Relates`, `Blocks`, `Implements`, `none`, plus the
non-issue `checklist` render sentinel.

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

- **Fail-closed (Principle VIII).** Config validation runs BEFORE any write. A
  nonsensical relationship combo, a missing required issue-type id for a
  configured artifact, or an unsupported artifact name is a **workspace-level
  configuration error** that halts the run with copy-paste remediation — not a
  silent skip, not a per-spec warning.

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

## 7. Open questions for `/speckit-clarify`

1. **Relationship-validation matrix:** what is the exact allow/reject table of
   (level-boundary × relationship-type) combinations? Which combos warn vs hard
   halt? (e.g. is `Blocks` ever legal as a hierarchy link, or only as a
   cross-spec dependency link?)
2. **`Epic Link` vs native `parent` detection:** how does the bridge know
   whether a project is classic/company-managed (needs the `Epic Link` custom
   field) vs team-managed (native `parent`)? Probe the project metadata at
   runtime, or require the operator to declare project style in config?
3. **Initiative scope:** is the Initiative super-level configured **per-repo**
   or **per-org**? (1:1 narrative≈spec vs 1:many operator grouping changes
   where the binding lives.)
4. **Default when a configured issue type is absent** in the project (e.g.
   `Task` chosen for the task level but the project has no Task type): hard
   halt with remediation, or degrade to the next mode (e.g. fall back to
   checklist)? The Initiative level already specifies `degrade`; should other
   levels?
5. **Mixed/partial mapping:** if `mapping:` is present but only some levels are
   specified, do unspecified levels inherit the synthesized default, or is a
   partial `mapping:` block a validation error (all-or-nothing)?
6. **ADF checklist provenance header in 2-level mode:** Principle I requires
   mirrored checklists to carry a read-only-mirror header. In 2-level mode the
   checklist lives in the parent body alongside the issue description — how is
   the header rendered so the round-trip stays byte-identical (idempotency)
   without visually dominating the issue?

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
