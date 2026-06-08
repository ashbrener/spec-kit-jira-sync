# Contract — `mapping:` configuration block

The new, optional `mapping:` block layers over the existing `issue_types`,
`labels`, and `phase_status` keys (their meaning is unchanged from 001
`data-model.md` §2). It describes, per `workstate` level, the Jira **artifact**
to project to and the **relationship** that links the level to its parent. This
contract governs `config.sh`: the schema, the alias layer, the relationship
matrix, available-type detection, and the config-load validation order
(FR-002–FR-007, FR-017, FR-018). All values here are placeholders (Privacy IX).

## Schema

```yaml
jira:
  mapping:                       # NEW — optional. Absent => alias-synthesized default.
    initiative:                  # OPTIONAL narrative super-level above Epic. OFF by default.
      enabled: false
      artifact: "Initiative"     # Jira Premium / Advanced-Roadmaps primitive
      on_absent: "degrade"       # degrade => fold onto Epic + repo label (never hard-fail)
      source: "spec_input"       # spec.md "Input:" line; NEVER inferred
    project_style: "team-managed"  # team-managed (native parent) | classic (Epic-link). Q3.
    levels:
      repo:   { artifact: "Epic",      relationship_to_parent: "none" }
      spec:   { artifact: "Story",     relationship_to_parent: "parent" }
      phase:  { artifact: "Subtask",   relationship_to_parent: "parent" }
      task:   { artifact: "checklist", relationship_to_parent: "checklist" }
    status_rollup:               # OPTIONAL. OFF by default. Q11.
      enabled: false
```

### Field reference

| Path | Type | Required | Default |
|------|------|----------|---------|
| `mapping` | map | no | absent ⇒ alias layer synthesizes the block below |
| `mapping.initiative.enabled` | bool | no | `false` |
| `mapping.initiative.artifact` | string | no | `"Initiative"` |
| `mapping.initiative.on_absent` | enum `degrade` | no | `"degrade"` |
| `mapping.initiative.source` | enum `spec_input` | no | `"spec_input"` |
| `mapping.project_style` | enum `team-managed`\|`classic` | no | `"team-managed"` |
| `mapping.levels.<level>.artifact` | string (issue-type name or `checklist`) | yes when the level is present | per default below |
| `mapping.levels.<level>.relationship_to_parent` | enum (see matrix) | yes when the level is present | per default below |
| `mapping.levels.<level>.on_absent` | string (fallback issue-type name) | no | none ⇒ hard-error if `artifact` absent |
| `mapping.status_rollup.enabled` | bool | no | `false` |

`<level>` ∈ `{repo, spec, phase, task}` (plus `initiative` as the super-level).
`artifact` vocabulary: any project-available issue-type name, or the non-issue
`checklist` sentinel. `relationship_to_parent` vocabulary: `parent`,
`Epic-link`, `Relates`, `Blocks`, `Implements`, `none`, `checklist`.

## Alias layer (absent `mapping:` ⇒ synthesize today's default)

When `mapping:` is **absent**, the loader synthesizes the default block above
(`repo→Epic`, `spec→Story`, `phase→Subtask`, `task→checklist`,
initiative/rollup off) from the existing `issue_types` / `labels` /
`phase_status` keys. No file rewrite, no version bump (FR-002).

- **Back-compat guarantee**: a pre-feature config loads **byte-for-byte
  unchanged** and projects identically to the prior version (US1, SC-001).
- **Partial block (Q4)**: when `mapping:` is present but a level is unspecified,
  that level **inherits the synthesized default per level** — partial is valid,
  not an all-or-nothing error (FR-002 edge case).
- **Equivalence**: an explicit block that spells out the default is equivalent to
  the absent case (US1 scenario 3).

## Relationship-validation matrix (Q2 — hard allow/reject)

Hierarchy (parent → child) links are restricted to genuine nesting primitives.
Every reject is a **hard-halt at config-load, before any write** (FR-007).

| `relationship_to_parent` | Allowed as hierarchy link | Notes |
|--------------------------|---------------------------|-------|
| `parent` | allow | native parent (team-managed) |
| `Epic-link` | allow **only** when the child level projects to a non-Epic and the parent projects to `Epic` | reject between two non-Epic levels |
| `none` | allow | top level (no parent link) |
| `checklist` | allow | non-issue; level renders into the parent body |
| `Blocks` | **reject** | cross-spec dependency, not nesting |
| `Relates` | **reject** | cross-spec dependency, not nesting |
| `Implements` | **reject** | cross-spec dependency, not nesting |

Additional hard rejects: a level whose `artifact: "checklist"` paired with any
`relationship_to_parent` other than `checklist`; an `Epic-link` declared where
the parent level's artifact is not `Epic`.

## Available-issue-type detection + absent-type policy (Q10)

1. **Detect** the target project's available issue types via an issue-type
   metadata probe (FR-005).
2. **Validate** every configured `artifact` (every level, plus `initiative` when
   enabled) against that detected set, at config-load, before any write.
3. **Absent-type policy** (FR-006): a configured `artifact` with no matching
   available type is a **hard-error at config-load** (fail-closed, writes
   nothing) — **unless** that level declares an explicit `on_absent: "<type>"`
   fallback whose value IS in the available set, which is the only escape. An
   `on_absent` whose fallback is itself absent is also a hard-error.

`checklist` is a render sentinel, not an issue type, and is exempt from the
available-type probe.

## Config-load validation order (all BEFORE any write)

Validation is a single fail-closed gate; any failure is a **workspace-level
configuration error → exit 2**, writing nothing for the run (FR-017,
Principle VIII). Order:

1. **Parse** the `mapping:` block (or synthesize the default via the alias
   layer); apply per-level inheritance for unspecified levels.
2. **Required-id check**: each configured `artifact` that projects to an issue
   has its required `issue_types.<...>` id present (e.g. a Task-projected level
   needs `issue_types.task`; an enabled `initiative` needs `issue_types.initiative`).
3. **Relationship matrix** (Q2): reject every nonsensical hierarchy link.
4. **Available-type probe + validation** (Q10): reject any configured artifact
   absent from the detected set, honoring a valid per-level `on_absent` fallback.

Only after all four pass does the sink perform any projection or mutation.

## Contract tests

- Absent `mapping:` ⇒ synthesized default equals the explicit default block
  (alias equivalence).
- A pre-feature config loads unchanged and projects byte-identically (US1).
- A partial block inherits the default on unspecified levels.
- Each matrix reject (`Blocks`/`Relates`/`Implements` as hierarchy, `Epic-link`
  between two non-Epic levels) hard-halts at config-load with exit 2, no write.
- A configured artifact absent from the probed set hard-errors (exit 2); a valid
  `on_absent` fallback is honored; an invalid fallback still hard-errors.
