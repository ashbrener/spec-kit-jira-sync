# Phase 1 Data Model: Lifecycle→Subtask Cascade + Phase-Parser Broadening

No persisted state, no schema change (Principle II/X). The "model" is the
phase-index token (now a string) and the per-spec phase-status dispatch over
existing entities.

## Entities

### Phase index token (now a string)

Parsed from a `## Phase <idx><sep><name>` header. `<idx>` ∈ numeric (`1`, `10`) or
single ASCII letter (`A`). Used as: the `task-phase:<idx>` identity label, the
Subtask title (`Phase <idx> — <name>`), and the join key between a phase, its
tasks, and its Subtask. **Was** treated as numeric in four jq extractions; now a
string end-to-end.

### Terminal lifecycle set

`{ready_to_merge, merged}` — the `lifecycle_phase` values (from
`parser::lifecycle_phase`) that trigger the cascade. Forward-only.

### Phase-status dispatch (per spec, per reconcile)

```text
lifecycle_phase ∈ {ready_to_merge, merged}  → cascade_phases   (always, ungated)
else status_rollup.enabled                  → rollup_phases     (ratio — today)
else                                         → (no subtask-status write — today's default)
```

### Cascade target

The **merged** status id (`rollup::done_status_id` = `config::get_status_transition
"merged"`). Each phase Subtask under a terminal spec is transitioned to it via
`rollup::transition_if_changed key "complete" prior` (idempotent).

## Functions (the seam — see contracts/cascade-parser.md)

| Function | Module | Neutral? | Change |
|---|---|---|---|
| `parser::task_phases` / `tasks_in_phase` / unphased-scan | `src/parser.sh` | yes | broaden header regex + string index/name capture |
| `reconcile::cascade_phases` | `src/reconcile.sh` | yes (engine decision) | NEW — force each phase Subtask to done for a terminal spec |
| `reconcile::rollup_phases` | `src/reconcile.sh` | yes | unchanged logic; may share the per-subtask loop helper |
| phase-status dispatch (at `reconcile.sh:2316, 2455`) | `src/reconcile.sh` | yes | terminal→cascade / else→rollup-if-enabled |
| numeric child-id extraction (`reconcile.sh:1237,1248,1309,2656`) | `src/reconcile.sh` | yes | string-key the index token |
| `rollup::transition_if_changed` / `rollup::done_status_id` | `src/jira_sink.sh` | no (Jira) | **reused unchanged** (the transition + status map) |

The cascade **decision** (terminal ⇒ children done) is vendor-neutral in
`reconcile.sh`; the **transition** is the sink's existing `transition_if_changed`.
003 seam preserved.

## Validation rules

- **VR-1 (FR-001/SC-001)**: terminal spec + rollup OFF ⇒ every phase Subtask
  transitioned to the merged status.
- **VR-2 (FR-002/SC-003)**: non-terminal spec ⇒ subtask-status behavior identical to
  today (ratio rollup iff enabled; else no write).
- **VR-3 (FR-001/SC-004)**: terminal spec re-run unchanged ⇒ zero subtask
  transitions (idempotent).
- **VR-4 (FR-004)**: unreadable subtask read ⇒ exit 3, no partial cascade; unmapped
  merged status ⇒ warn + skip (fail-soft).
- **VR-5 (FR-005/SC-002)**: `## Phase A — …` / `## Phase 1 — …` ⇒ one phase per
  header (correct index token + name); subtasks created.
- **VR-6 (FR-007/SC-005)**: `## Phase N: Name` ⇒ byte-identical parse (index, name,
  label, title) to pre-feature.
- **VR-7 (FR-006)**: letter-indexed phases attach their tasks + match their Subtask
  (all four index extractions string-keyed).
- **VR-8 (FR-009/SC-006)**: cascade decision carries no Jira vocab (003 gate green);
  fixtures placeholder-only (`no-real-identifiers.bats` green).
- **VR-9 (FR-011)**: artifact mapping unchanged (phase → Subtask) — no MAJOR.
