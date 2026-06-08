# Quickstart — Engine Orchestration Unification

This feature is an **internal re-platforming**: from the operator's seat there is
**nothing new to do and nothing changes**. Every command, flag, output, and exit
code is identical to before.

## For the operator: no change

```bash
src/reconcile.sh --all                 # same mirror as before, every mode
src/reconcile.sh --all --dry-run       # same preview
src/reconcile.sh --workstate ws.json   # same workstate-direct projection
```

All six mapping modes (default 3-level, configured per-level, 2-level checklist,
status rollup, Initiative super-level, workstate-direct) behave byte-for-byte as
they did before — same issues created, fields updated, links, transitions, and
run summary. A re-run is still zero churn.

## For the maintainer: what actually changed

- The engine's per-spec / per-item driver is now a **neutral level loop** that
  drives one projection (`sync_level_artifact` + `link_to_parent`) for every
  level; the 001-era orchestrators (`ensure_repo_epic` / `sync_spec_issue` /
  `sync_task_phase_subissues`) are **gone**.
- The engine orchestration path carries **no** Jira issue-type / artifact-name /
  relationship knowledge — verified by a committed gate.

## Verify it (the equivalence gates)

```bash
# 1. The whole existing suite must pass UNCHANGED (the equivalence oracle).
bats --recursive tests/unit tests/integration

# 2. The engine path is vendor-neutral (the new committed gate).
bats tests/unit/engine_vendor_neutral.bats

# 3. Full-stack non-default shape is zero-churn through the wired engine (T056).
bats tests/integration/us_fullstack_nondefault_zerochurn.bats

# 4. Lints + privacy (CI parity).
shellcheck --severity=style src/*.sh
bats tests/unit/no-real-identifiers.bats
```

Then the live-dogfood backstop: re-reconcile the already-mirrored board in each
mode and confirm 0 created / 0 updated (zero churn) — identical to pre-change.
