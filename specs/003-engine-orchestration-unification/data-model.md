# Data Model — Engine Orchestration Unification

No persisted data (Principle II: no engine-side state cache). The "model" here is
the set of **neutral in-memory concepts** the unified engine loop manipulates —
the vocabulary that must stay free of Jira specifics (FR-006).

## Neutral concepts

### Level

A structural unit the engine iterates. Ordinal parent → child:
`initiative?` → `repo` → `spec` → `phase[*]` → `task[*]`.

| Field | Type | Notes |
|---|---|---|
| `name` | enum `repo`\|`spec`\|`phase`\|`task`\|`initiative` | the ONLY level vocabulary the engine knows |
| `parent` | Level name or none | `repo` has no parent; `spec`→`repo`; `phase`→`spec`; `task`→`phase` |

The engine knows level names + ordering. It does **not** know each level's Jira
artifact type — that resolves behind the sink (`mapping::resolve_level` +
`sync_level_artifact`).

### Payload (neutral level payload)

Composed by `compose_payload(level, item)` from the workstate item + config label
prefixes. The sink-neutral shape (extends the 002 `input_json`):

```json
{ "summary": "<issue summary>",
  "body": "<markdown body>",
  "labels": ["<phase/operator labels>"],
  "state": "<lifecycle state, when the level carries one>" }
```

- `summary` / `body` / `labels` as in the 002 engine-sink-interface contract.
- `state` is NEW: the lifecycle state (e.g. `implementing`/`merged`) for levels
  that drive a status transition (the spec level). The SINK maps `state` → the
  Jira status/transition; the engine only passes the neutral token.

### Identity label

`compose_identity(level, item)` → the stable identity label for find-or-match,
built from config label prefixes only (neutral strings):
`repo`→`<repo_prefix><slug>`, `spec`→`<spec_prefix><NNN>`,
`phase`→`<phase_prefix><n>`, a Task-projected level→`<task_prefix>…`.

### Disposition

The neutral verdict the sink returns per projection, tallied for the run summary:
`created` | `updated` | `skipped` | `failed`. Unchanged from today; the engine
records it per level without inspecting any Jira value.

## Per-level payload composition rules (the equivalence-critical part)

These reproduce, byte-for-byte, what the 001 orchestrators emitted:

| Level | summary | labels | body | state |
|---|---|---|---|---|
| `repo` | the repo Epic summary `ensure_repo_epic` used | `[repo_label]` | (none / as today) | — |
| `spec` | `"<NNN> — <title>"` | `([spec_label, phase:<state>] + item.labels) \| unique` | spec body markdown (+ in-body checklist in 2-level) | the merge-aware lifecycle state (drives the Story transition; preserves the merged-not-Done fix) |
| `phase` | the phase child title | `[phase_label]` | the phase's tasks as an ADF taskList | — |
| `task` (checklist sentinel) | — (no issue) | — | rendered in the parent body | — |
| `initiative` (when enabled) | as today (ensure_initiative / degrade) | `[repo_label]` | the explicit `spec_input` narrative | — |

## Invariants (validation rules)

- The composer references ONLY workstate fields + config label prefixes — never a
  Jira issue-type id, artifact name, or relationship term (FR-006).
- A `checklist`-sentinel level composes no standalone issue (renders in the parent
  body) — unchanged.
- The spec→Story unit remains the sole backward-drift anchor (FR-004).
- Every level's emitted request (create/update/link/transition payload) is
  identical to the pre-unification 001 path (FR-002 / SC-005), proven by the
  unchanged test suite.
