---
name: speckit.jira.push
description: Reconcile (push) the consumer repo's specs → Jira — idempotent, drift-aware, fail-closed; the only path that mutates Jira
arguments:
  - name: all
    description: reconcile every spec in the repo (the default when no spec selector is given)
    optional: true
  - name: spec
    description: feature number (e.g., 003) to reconcile only that spec
    optional: true
  - name: dry-run
    description: plan every mutation and log it, but issue none
    optional: true
  - name: on-drift
    description: "abort|proceed — non-interactive backward-drift disposition. Default (unset) is proceed-and-warn: write the disk state and record a WARNING. `abort` skips drifted specs with a WARNING instead of writing. No effect when no drift fires."
    optional: true
---

# `/speckit.jira.push`

## Summary

Sync the consumer repo's filesystem spec state into Jira by running the
reconcile engine. Do NOT ask the user to run anything in their terminal — you
execute it via the Bash tool and report the result.

**Direction**: one-way, filesystem → Jira. The filesystem is the source of
truth; Jira is a read-only mirror.
**Semantics**: idempotent (zero-churn on unchanged state).
**Authority**: drift-aware — any worktree may write a spec's Jira state; before
each write the engine computes a backward-drift signal and disposes of it per
`--on-drift` (default proceed-and-warn).

Arguments the user passed (may be empty): `$ARGUMENTS`

## Rules for building the command

- If **no arguments** were given, default to **`--all`** (reconcile every spec).
- Otherwise pass the user's flags through verbatim (`--spec NNN`, `--dry-run`,
  `--on-drift=abort|proceed`).
- The sink does **not** load `.env` itself, so export the Jira Basic-auth
  credentials (`JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`) **when a `.env`
  is present**. This command auto-fires from the `after_*` lifecycle hooks too,
  so a missing `.env` must NOT break the run — reconcile still runs and exits
  with its own clean message.

Run exactly this (substituting the resolved flags for `<FLAGS>`):

```bash
cd "$(git rev-parse --show-toplevel)" && { [ -f .env ] && { set -a; source .env; set +a; }; } ; bash src/reconcile.sh <FLAGS>
```

The `.env` is sourced **only if present** (note the `;` before reconcile, not an
`&&`): reconcile always runs, so an auto-fired hook with no creds degrades to a
clean exit-2/3 warning instead of a broken `&&` chain.

## Report back concisely

- created / updated / skipped counts and any backward-drift WARNINGs,
- whether it was a dry-run (no mutations) or a real write,
- if it exited non-zero, frame it as a **gentle warning** (this push may have
  auto-fired from a lifecycle hook — the spec-kit command itself still
  succeeded; the mirror just couldn't run this time):
  - exit `2` = missing or invalid `jira-config.yml` → run `/speckit-jira-install`
    to bind this repo (or check `.env` is present and exported);
  - exit `3` = Jira unreadable → check the `JIRA_API_TOKEN` in `.env`,
    auth/network, or whether the issue was deleted.
  Never present a hook-fired failure as alarming or as a blocker.

This is the Jira-REST reconcile engine — the Atlassian MCP is not involved (the
sync is direct REST by design). The filesystem is the source of truth; Jira is a
read-only mirror.

## Auto-sync hook health (self-healing)

The reconcile now self-reports the health of its own six `after_*` auto-sync
hooks (feature 012). Reinstalling with
`specify extension add jira --from <zip> --force` **silently strips** those
hooks from `.specify/extensions.yml`, so auto-sync stops firing. When hooks are
missing, this push emits **one** named WARNING (`… auto-sync hook(s) not
registered … run /speckit-jira-install to restore auto-sync`); at a real
terminal it also offers a single `y/N` to re-register them all at once. The
restore path is **`/speckit-jira-install`** (or accept the interactive offer).
The check is non-blocking and never mutates Jira — relay the warning as-is
without alarm.
