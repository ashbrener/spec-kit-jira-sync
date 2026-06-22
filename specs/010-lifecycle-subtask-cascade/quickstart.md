# Quickstart: Lifecycle→Subtask Cascade + Flexible Phase Headers

Two board-correctness fixes, both automatic:

## Merged specs now mark their phases done

When a spec reaches **ready-to-merge or merged**, every phase Subtask under it is
moved to the done status on the next reconcile — so a merged Story no longer sits
over a column of "To Do" subtasks. This works in the **default config** (you don't
need to turn on status rollup).

- Idempotent: a board already correct gets zero writes.
- Forward-only: if a spec moves *back* from ready-to-merge, subtasks aren't
  un-done unless you've enabled the (opt-in) checkbox rollup.
- In-progress specs are unchanged.

## Flexible phase headers

Phase headers no longer have to be `## Phase 1: Name`. These now work too:

```markdown
## Phase A — Foundations
## Phase 1 — Setup
## Phase 10: Polish
```

The index can be a number or a single letter, and the separator can be a colon,
hyphen, or dash. Previously, letter/dash headers produced **no** subtasks at all;
now each phase gets its Subtask (`task-phase:A`, `task-phase:1`, …). Existing
`## Phase N: Name` specs are unaffected.

## No config, no churn

No new settings. Specs already shown correctly don't change. The fix derives
everything from `tasks.md` + the lifecycle — deterministic, no AI.
