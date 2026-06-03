# Phase 1 Data Model — Core Bridge

Entities, their fields, the `workstate`↔Jira mapping, the consumed config shape,
and state transitions. No real coordinates — instance ids are config-resolved.

## 1. Entities

### Spec (on-disk, parser input)

| Field | Source | Notes |
|-------|--------|-------|
| `feature_number` | dir name `specs/NNN-*` | 3-digit; part of identity |
| `short_name` | dir name suffix | |
| `lifecycle_phase` | inferred from artifacts | engine vocabulary + ordinal |
| `title` | `spec.md` heading | |
| `body` | `spec.md` overview | truncated for the issue body |
| `task_phases[]` | `tasks.md` `## Phase N:` | each → Subtask |
| `task_phases[].tasks[]` | `tasks.md` checkboxes | `{text, done}` → ADF taskList |
| `sessions[]` | recorded clarify/decision notes | → comments |
| `dependencies[]` | cross-spec refs | → issue links |
| `last_commit_iso` | git log of `specs/NNN-*/` | recency key (never mtime) |

### Work-item record (`workstate`, the internal contract)

Produced by the parser, consumed by the sink. Floor subset actually used:

```jsonc
{
  "schema_version": "0.1.0",
  "source": { "system": "spec-kit", "repo": "<slug>", "generated_iso": "..." },
  "items": [
    {
      "id": "NNN-short-name",            // stable idempotency key
      "title": "…",
      "kind": "spec",
      "state": "implementing",            // lifecycle token (free string)
      "body": "… markdown …",
      "labels": ["speckit-spec:NNN"],
      "item_source": { "path": "specs/NNN-…/", "last_commit_iso": "…" },
      "links": [ { "rel": "depends_on", "target": "MMM-other" } ],
      "notes": [ { "timestamp_iso": "…", "body": "clarify session …" } ],
      "children": [
        { "id": "NNN-phase-1", "title": "Phase 1 — …", "kind": "task",
          "state": "done",
          "extensions": { "tasks": [ { "text": "…", "done": true } ] } }
      ]
    }
  ]
}
```

**Validation rule**: every emitted document MUST validate against
`workstate.schema.json` (Draft 2020-12) — the test/CI gate (D9). Per-task detail
rides under `children[].extensions.tasks` (floor-safe; sinks that don't read it
ignore it, per Principle X / FR-020).

### Jira projection (sink output)

| workstate | Jira | Identity (idempotency) |
|-----------|------|------------------------|
| `source.repo` | one **Epic** per repo | label `speckit-repo:<slug>` |
| `item` (kind=spec) | **Story** under the Epic | label `speckit-spec:NNN` |
| `item.state` | Story **status** (via transition) + `phase:*` label | config `phase→status` map |
| `item.children[]` (kind=task) | **Subtask** of the Story | parent + label `task-phase:N` |
| `children[].extensions.tasks` | ADF **taskList** in Subtask body | content diff |
| `item.notes[]` | **comments** | marker prefix → at-most-once |
| `item.links[]` | **issue links** | (rel, target) → at-most-once |
| `item.labels` | Jira labels | name-equality |

### Drift signal (engine-computed, per spec)

| Field | Meaning |
|-------|---------|
| `phase_drift` | Jira phase ordinal strictly > disk phase ordinal |
| `recency_drift` | Jira issue `updated` newer than `last_commit_iso` beyond skew |
| `fired` | `phase_drift OR recency_drift` |
| `disposition` | `proceed` / `abort` (override flag, TTY prompt, or default) |

### Run summary (engine-emitted)

Counts `{created, updated, skipped}` + arrays of `{warnings[], errors[]}` rows,
each naming the spec and the reason. Drives the process exit code via monotonic
escalation (`promote_exit`: 0 < 1 < 3 < 2).

## 2. Consumed config (`jira-config.yml`, gitignored)

Produced by the later seed/install feature; **consumed** here. Shape (values are
placeholders — real ids live only in the gitignored copy):

```yaml
jira:
  project_key: "<KEY>"
  issue_types:
    epic: "<id>"
    story: "<id>"
    subtask: "<id>"
  # lifecycle phase -> target status id (set via a transition POST)
  phase_status:
    specifying:      "<status-id>"
    planning:        "<status-id>"
    tasking:         "<status-id>"
    implementing:    "<status-id>"
    ready_to_merge:  "<status-id>"
    merged:          "<status-id>"
  # optional explicit transition ids; else resolved dynamically by target status
  transitions: {}
  labels:
    spec_prefix: "speckit-spec:"
    repo_prefix: "speckit-repo:"
    phase_prefix: "task-phase:"
    lifecycle_prefix: "phase:"
```

`config.sh` loads + validates this; a missing/unreadable binding is a
project-level configuration error that halts the run (Principle VIII), distinct
from a per-spec failure.

## 3. State transitions (lifecycle → Jira status)

Disk lifecycle phase (engine ordinal order) maps to a configured Jira status,
reached by a transition POST (D6):

```text
specifying → planning → tasking → implementing → ready_to_merge → merged
   (To Do categories)      (In Progress categories)         (Done category)
```

- The phase→status map is config-supplied, not hard-coded (spec Assumption).
- Backward-drift = the Jira status' phase ordinal is strictly ahead of the
  disk phase ordinal → surfaced, not blocked (Principle IV).
- The exact status names/ids are per-instance and live only in the gitignored
  config; this document names only the standard Jira status *categories*.

## 4. Identity & uniqueness rules

- A spec's Story is unique per `speckit-spec:NNN` within the project; >1 match
  is a configuration defect (surfaced, not auto-merged) — spec Edge Case.
- The repo Epic is unique per `speckit-repo:<slug>`; reused across runs, never
  duplicated (FR-021).
- A phase Subtask is unique per (parent Story, `task-phase:N`).
- Comments and links are deduped by a stable marker / (rel,target) so re-runs
  add nothing (FR-007, FR-008).
