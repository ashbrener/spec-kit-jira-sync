---
description: Reconcile (push) this repo's specs → Jira — the sync engine, in-session, no CLI needed
argument-hint: "[--all | --spec NNN] [--dry-run] [--on-drift=abort|proceed]"
allowed-tools: Bash
---

Sync the **spec-kit-jira-sync** repo's filesystem spec state into Jira by running
the reconcile engine yourself. Do NOT ask the user to run anything in their
terminal — you execute it via the Bash tool and report the result.

Arguments the user passed (may be empty): `$ARGUMENTS`

Rules for building the command:

- If **no arguments** were given, default to **`--all`** (reconcile every spec).
- Otherwise pass the user's flags through verbatim (`--spec NNN`, `--dry-run`,
  `--on-drift=abort|proceed`).
- The sink does **not** load `.env` itself, so export the Jira Basic-auth
  credentials (`JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`) first.

Run exactly this (substituting the resolved flags for `<FLAGS>`):

```bash
cd "$(git rev-parse --show-toplevel)" && set -a && source .env && set +a && bash src/reconcile.sh <FLAGS>
```

After it runs, report back concisely:

- created / updated / skipped counts and any backward-drift WARNINGs,
- whether it was a dry-run (no mutations) or a real write,
- if it exited non-zero, the error and the likely fix (exit `2` = missing or
  invalid `jira-config.yml`; exit `3` = Jira unreadable — bad token in `.env`,
  auth/network, or a deleted issue).

This is the same Jira-REST reconcile engine the `/speckit.jira.push` consumer
surface wraps — the Atlassian MCP is not involved (the sync is direct REST by
design). The filesystem is the source of truth; Jira is a read-only mirror.
