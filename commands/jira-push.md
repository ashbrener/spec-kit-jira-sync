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
  credentials (`JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`) first.

Run exactly this (substituting the resolved flags for `<FLAGS>`):

```bash
cd "$(git rev-parse --show-toplevel)" && set -a && source .env && set +a && bash src/reconcile.sh <FLAGS>
```

## Report back concisely

- created / updated / skipped counts and any backward-drift WARNINGs,
- whether it was a dry-run (no mutations) or a real write,
- if it exited non-zero, the error and the likely fix (exit `2` = missing or
  invalid `jira-config.yml`; exit `3` = Jira unreadable — bad token in `.env`,
  auth/network, or a deleted issue).

This is the Jira-REST reconcile engine — the Atlassian MCP is not involved (the
sync is direct REST by design). The filesystem is the source of truth; Jira is a
read-only mirror.
