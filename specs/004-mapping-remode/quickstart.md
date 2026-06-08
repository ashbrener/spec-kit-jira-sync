# Quickstart: Mapping Re-mode / Orphan Pruning

The re-mode lets you change a project's mapping shape and clean up the artifacts
the old shape left behind — so you can experiment and converge on the right shape
without the board accumulating orphans.

> ⚠️ **Re-mode is the bridge's only destructive operation.** It removes
> bridge-owned issues. It is reachable *only* via `--remode`; the ordinary
> reconcile never prunes. Always preview with `--remode --dry-run` first.

## The safety contract (read once)

- Re-mode prunes **only bridge-owned artifacts** — issues carrying the bridge's
  `speckit-*` identity labels. It **never** touches an issue you created, even one
  under the same Epic or with a similar summary. If ownership can't be proven, the
  issue is left alone.
- Destruction defaults to **hard-delete** (bridge content is regenerable from your
  specs, so it needs no backup). Switch to **archive** in config if you want to
  preserve comments/links added on the issues.
- An unreadable Jira read **aborts** the re-mode before anything is deleted.

## 1. You changed the mapping

Say a project was mirrored 3-level (spec → Story → per-phase Subtasks) and you
switch it to a 2-level checklist (phases become an in-body checklist on the Story).
A plain reconcile now *warns* you:

```bash
bash src/reconcile.sh --all
# … WARN: 2 bridge-owned orphans from a prior mapping shape detected
#         (task-phase:1, task-phase:2). Run --remode to prune + regenerate.
```

It does **not** prune — it only surfaces the drift.

## 2. Preview the re-mode

```bash
bash src/reconcile.sh --remode --dry-run --all
# PLAN (dry-run, zero writes):
#   prune:       PROJ-123 (task-phase:1), PROJ-124 (task-phase:2)
#   regenerate:  PROJ-122 (speckit-spec:001) — checklist added to body
#   keep:        PROJ-100 (speckit-repo:<slug>), PROJ-122 (speckit-spec:001)
```

The preview is the exact set the real run will act on — same computation, writes
gated off.

## 3. Run it

```bash
set -a && source .env && set +a
bash src/reconcile.sh --remode --all
# pruned 2 · regenerated 1 · kept 2
```

The old Subtasks are gone, the Story carries the in-body checklist, and the board
is a clean mirror of the new mapping.

## 4. Confirm it's stable

```bash
bash src/reconcile.sh --all
# created 0 · updated 0 · skipped N   (zero churn — the new shape is stable)
```

## Flip back and forth freely

Apply mapping A, re-mode; apply B, re-mode; reapply A, re-mode — each time the
board mirrors whichever mapping is applied, with no residue from the other. A
re-mode when nothing changed prunes nothing and writes nothing.

## Choosing the destruction model

In `.specify/extensions/jira/jira-config.yml`:

```yaml
jira:
  remode:
    destruction: hard-delete   # default — cleanest board, human layer not preserved
    # destruction: archive     # preserve comments/links: transition off-board +
    #                          # detach identity labels (needs an archive status id)
```

`archive` requires an archive status **id** (Principle V — id, not name). If it's
unset, re-mode hard-errors with the exact remediation rather than silently
hard-deleting.

## If a human edited an issue that's about to be pruned

Re-mode surfaces a backward-drift WARNING naming that issue before removing it (so
hard-delete never silently discards human edits). Use `--on-drift=abort` to skip
pruning any drifted issue and leave it in place for you to review.

## What re-mode never does

- It never prunes in the ordinary reconcile (no `--remode` ⇒ no destruction).
- It never modifies an operator-created issue.
- It never writes back to your filesystem — your specs stay the source of truth.
