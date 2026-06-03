# Phase 1 Data Model — Configurable Mapping

Entities for the additive `mapping:` config block, the neutral `workstate`
levels it consumes, the detected available-issue-type set, the
relationship-validation matrix, the label prefixes, and the narrative source.
This is a DATA model — shapes + rules, not implementation. No real coordinates;
all ids are placeholders (`<KEY>`, `<id>`, `<status-id>`) resolved only in the
gitignored config (Principle IX). Every validation rule below runs **fail-closed
at config-load, before any write** unless noted otherwise.

## 1. `mapping:` config block (additive over existing keys)

An OPTIONAL block layered over the existing `issue_types` / `labels` /
`phase_status` keys (which keep their 001 meaning). Absent ⇒ the alias layer
synthesizes the DEFAULT block below, reproducing today's behavior byte-for-byte
(FR-001, FR-002). Present ⇒ each specified level overrides; unspecified levels
inherit the synthesized default per level (Q4 inheritance, not all-or-nothing).

### Synthesized DEFAULT block (what the alias layer emits when `mapping:` absent)

```yaml
jira:
  project_key: "<KEY>"
  issue_types:
    epic: "<id>"
    story: "<id>"
    subtask: "<id>"
    # task: "<id>"        # required ONLY when a level projects to a Task issue
    # initiative: "<id>"  # required ONLY when the initiative super-level is on
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
    task_prefix: "speckit-task:"          # NEW (Q9) — Task-projected level identity

  # NEW — optional. Absent => alias layer synthesizes exactly this default.
  mapping:
    initiative:
      enabled: false                      # OFF by default (FR-013)
      artifact: "Initiative"              # Jira Premium / Advanced Roadmaps only
      on_absent: "degrade"                # degrade => fold onto Epic + repo label
      source: "spec_input"                # spec.md "Input:" line; NEVER inferred
    levels:
      repo:
        artifact: "Epic"
        relationship_to_parent: "none"    # or "parent" when initiative is on
      spec:
        artifact: "Story"
        relationship_to_parent: "parent"  # Story under repo Epic
      phase:
        artifact: "Subtask"
        relationship_to_parent: "parent"  # Subtask of the spec Story
      task:
        artifact: "checklist"             # ADF taskList in the parent body
        relationship_to_parent: "checklist"
    status_rollup:
      enabled: false                      # OFF by default (Q11, FR-011)
```

### Fields

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `mapping` | block | (synthesized) | absent ⇒ alias layer emits the default |
| `mapping.initiative.enabled` | bool | `false` | super-level on/off (FR-013) |
| `mapping.initiative.artifact` | string | `"Initiative"` | Premium-only primitive |
| `mapping.initiative.on_absent` | enum | `"degrade"` | `degrade` is the only policy |
| `mapping.initiative.source` | enum | `"spec_input"` | explicit origin only (FR-014) |
| `mapping.levels.<level>.artifact` | string | per default | issue type or `checklist` sentinel |
| `mapping.levels.<level>.relationship_to_parent` | enum | per default | hierarchy link kind |
| `mapping.levels.<level>.on_absent` | string | _(unset)_ | optional per-level fallback (Q10) |
| `mapping.status_rollup.enabled` | bool | `false` | rollup lever (Q11) |

`<level>` ∈ `{repo, spec, phase, task}`. `relationship_to_parent` vocabulary:
`parent`, `Epic Link`, `Relates`, `Blocks`, `Implements`, `none`, `checklist`.

### Validation rules (all fail-closed at config-load)

- A `mapping:` block with only some levels is VALID; unspecified levels inherit
  the synthesized default per level (Q4). Not an all-or-nothing error.
- `mapping.initiative.on_absent` MUST be `degrade` (the only supported policy);
  any other value is a config error.
- `mapping.initiative.source` MUST be `spec_input` (never inferred; FR-014).
- Each `levels.<level>.artifact` is checked against the available-issue-type set
  (§3) — except the `checklist` sentinel, which projects no issue.
- Each `relationship_to_parent` is checked against the relationship matrix (§4).
- An artifact that resolves to a standalone Task issue REQUIRES `issue_types.task`
  and a `task_prefix` identity (§5); a missing required id is a config error.
- `initiative.enabled: true` REQUIRES `issue_types.initiative` only when the
  instance supports Initiative; absence is handled by `on_absent: degrade`, not a
  config error (FR-013).

### State / lifecycle notes

- The synthesized default and an explicit default block MUST be equivalent
  (alias-layer round-trip; FR-002, US1 scenario 3).
- Initiative degrade→upgrade re-home MUST be idempotent: folding the narrative
  onto the Epic (degraded) and later re-homing it onto a real Initiative produces
  zero churn on unchanged content (Q5, FR-008), keyed by the stable marker (§6)
  and the reused `repo_prefix` label.
- `status_rollup` transitions fire ONLY on a real completion-state change
  (forward and backward); unchanged completion ⇒ no transition (Q11, FR-012).

## 2. workstate levels (neutral units the mapping consumes)

The mapping consumes the four neutral `workstate` structural units, NOT spec-kit
on-disk concepts — keeping the parser↔sink seam clean (FR-018, §5).

| Level | workstate origin | Default artifact | Default link to parent |
|-------|------------------|------------------|------------------------|
| `repo` | `source.repo` | Epic | `none` (or `parent` under initiative) |
| `spec` | `item` (kind=spec) | Story | `parent` (under repo Epic) |
| `phase` | `item.children[]` (kind=task) | Subtask | `parent` (under spec Story) |
| `task` | `children[].extensions.tasks[]` | checklist | `checklist` (in-body render) |

- Levels are ordinal: `repo > spec > phase > task` (parent → child). The optional
  `initiative` super-level sits above `repo` when enabled.
- `spec→Story` is the backward-drift anchor in EVERY mode; an enabled initiative
  super-level is narrative-only and is NOT a new drift surface (FR-010).
- In workstate-direct mode the same four levels are read from the supplied
  document (validated on entry against the pinned schema; FR-015, FR-016) — the
  projection matches the equivalent `specs/`-tree run.

## 3. Available-issue-type set (detected validation surface)

The set of issue types the TARGET project actually offers, detected via an
issue-type-metadata probe at config-load (Q10). The validation surface for every
configured `artifact`.

| Field | Type | Notes |
|-------|------|-------|
| `available_types[]` | set of strings | detected names, e.g. `Epic`, `Task`, `Subtask` |
| (per probe) | — | a Kanban template ships `Task/Epic/Subtask` — NO `Story` |

### Validation rules (fail-closed at config-load, before any write)

- Every configured `levels.<level>.artifact` (excluding the `checklist`
  sentinel) MUST appear in `available_types[]` (FR-005).
- A configured artifact absent from `available_types[]` is a workspace-level
  config error that writes nothing for the run (FR-006, FR-017, SC-003) —
  UNLESS a per-level `on_absent` fallback names an available substitute (e.g.
  `Story → Task`), the only declared escape (Q10).
- `Initiative` availability is detected the same way; absence routes to
  `on_absent: degrade` rather than a hard error (FR-013), distinct from the
  hard-error path for other levels.

## 4. Relationship-validation matrix (allow/reject table)

The concrete allow/reject table of (level-boundary × relationship type) that
guards against a corrupt Jira graph (Q2, FR-007). All rejections HARD-HALT at
config-load, before any write — no warn-and-continue.

| Relationship | As a hierarchy (parent→child) link | Notes |
|--------------|-----------------------------------|-------|
| `parent` (native) | ALLOW | team-managed native nesting |
| `Epic Link` | ALLOW only when parent is an Epic | classic / company-managed |
| `none` | ALLOW | top level (e.g. repo Epic, or spec Epic in 3-level) |
| `checklist` | ALLOW | non-issue sentinel; in-body ADF render |
| `Blocks` | REJECT | dependency semantics, not nesting |
| `Relates` | REJECT | dependency semantics, not nesting |
| `Implements` | REJECT | dependency semantics, not nesting |

### Boundary-specific rejections

- `Epic Link` declared between two NON-Epic levels ⇒ REJECT (the parent must be
  an Epic for an Epic-link to be a legal hierarchy link).
- `Blocks` / `Relates` / `Implements` used as ANY hierarchy link ⇒ REJECT (they
  are cross-spec dependency links, not nesting).
- Classic vs team-managed style (which decides `Epic Link` vs native `parent`) is
  operator-declared in config (Q3), so the matrix resolves fully OFFLINE at
  config-load with no network round-trip.

## 5. Label prefixes

The existing 001 prefixes PLUS the new `task_prefix` (Q9) for Task-projected
levels. Each prefix yields a stable, filesystem-derived identity label so re-runs
match-and-update rather than re-create (FR-009).

| Field | Default | Identity for |
|-------|---------|--------------|
| `labels.spec_prefix` | `"speckit-spec:"` | spec-level issue (`<NNN>`) |
| `labels.repo_prefix` | `"speckit-repo:"` | repo-level issue / degraded grouping (`<slug>`) |
| `labels.phase_prefix` | `"task-phase:"` | phase-level issue (`<N>`) |
| `labels.lifecycle_prefix` | `"phase:"` | lifecycle-status grouping |
| `labels.task_prefix` | `"speckit-task:"` | NEW — Task-projected level (`<task-id>`) |

### Label validation / lifecycle notes

- `task_prefix` is REQUIRED to be present (synthesized by the alias layer) and
  is the identity key whenever a level projects to a standalone Task issue
  (3-level mode); without it such issues could not be re-matched (FR-009).
- `task_prefix` MUST NOT collide with `spec_prefix` / `phase_prefix` — a distinct
  prefix keeps re-match unambiguous.
- In the degraded initiative path, repo grouping reuses `repo_prefix` (never a
  new prefix), keeping identity continuity for the idempotent re-home (§1, Q5).

## 6. Narrative source (explicit spec-input origin)

The explicit origin of the initiative super-level's narrative — NEVER inferred or
fabricated (FR-014).

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `source` | enum | `"spec_input"` | the only supported value |
| origin | string | spec.md `**Input**:` line | per-repo 1:1 (Q6) |

### Narrative validation / lifecycle notes

- `source` MUST be `spec_input`; any other value is a config error (FR-014).
- In workstate-direct mode there is no originating `spec.md`, so the narrative
  source is GRACEFULLY ABSENT — the initiative narrative is simply unavailable,
  not an error (Q8, edge case). Degradation/grouping still hold.
- Per-org 1:many grouping is out of scope for this feature (Q6); the source ships
  per-repo 1:1.
