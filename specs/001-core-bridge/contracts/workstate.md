# Contract — consumed `workstate` fields

The bridge's internal interchange is the neutral `workstate` format
(`schema/workstate.schema.json` in the workstate-schema repo). The parser
PRODUCES it; the sink CONSUMES only it (Principle X / FR-003, FR-020). This
lists the floor subset this feature actually relies on.

## Document level

| Field | Use |
|-------|-----|
| `schema_version` | must be present; validated |
| `source.system` | expected `"spec-kit"` |
| `source.repo` | → repo Epic slug (`speckit-repo:<slug>`) |
| `items[]` | each a spec |

## Item level (kind = `spec`)

| Field | Use | Required |
|-------|-----|----------|
| `id` | stable idempotency key (`NNN-short-name`) | yes |
| `title` | Story summary | yes |
| `kind` | `"spec"` | — |
| `state` | lifecycle token → status (via config map) | yes |
| `body` | Story description (Markdown → ADF) | no |
| `labels[]` | applied verbatim (+ derived `speckit-spec:NNN`) | no |
| `item_source.path` | provenance / spec dir | no |
| `item_source.last_commit_iso` | recency key for drift | no (drift needs it) |
| `links[]` (`rel`,`target`) | issue links | no |
| `notes[]` (`body`,`timestamp_iso`) | comments | no |
| `children[]` (kind=`task`) | phase Subtasks | no |

## Child level (kind = `task`, a task phase)

| Field | Use |
|-------|-----|
| `id` | Subtask idempotency (`task-phase:N`) |
| `title` | Subtask summary (`Phase N — …`) |
| `state` | informs Subtask done/in-progress |
| `extensions.tasks[]` (`text`,`done`) | ADF taskList rows (floor-safe extension) |

## Rules

- The sink MUST ignore any `extensions` key it does not understand (FR-020) —
  it depends on no Jira-specific side channel.
- Every parser-emitted document MUST validate against the schema before any
  write (test/CI gate, D9).
- **If a needed concept cannot be expressed on the floor, that is a SIGNAL**
  (Principle X): record it as a candidate schema floor-change request rather
  than smuggling it through a private channel. (None found so far — the per-repo
  Epic is a sink projection of `source.repo`, no schema change needed.)
