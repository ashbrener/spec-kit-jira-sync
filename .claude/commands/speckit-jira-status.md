---
description: Read-only sync status / drift preview — disk vs Jira; never mutates
argument-hint: "[--all | --spec NNN]"
allowed-tools: Bash
---

Report sync status / drift between the **spec-kit-jira-sync** repo's filesystem
spec state and Jira. This is **READ-ONLY**: it runs the reconcile engine in
`--dry-run`, which plans every write but issues **none**, so it mutates neither
Jira nor the filesystem. Execute it yourself via the Bash tool and summarize; do
NOT ask the user to run anything in their terminal.

Arguments the user passed (may be empty): `$ARGUMENTS`

Rules for building the command:

- If **no arguments** were given, default to **`--all`** (preview every spec).
- Otherwise pass the user's spec selectors through verbatim (`--spec NNN`).
- ALWAYS force **`--dry-run`** — this command is the read-only status surface and
  must never issue a write, regardless of the user's arguments.
- The sink does **not** load `.env` itself, so export the Jira Basic-auth
  credentials (`JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`) first.

Run exactly this (substituting the resolved selectors for `<SELECTORS>`):

```bash
cd "$(git rev-parse --show-toplevel)" && set -a && source .env && set +a && bash src/reconcile.sh <SELECTORS> --dry-run
```

After it runs, summarize concisely:

- per-spec what **would** be created / updated / transitioned,
- any backward-drift (Jira ahead of disk),
- any fail-closed / unreadable specs,
- if it exited non-zero, the error and the likely fix (exit `2` = missing or
  invalid `jira-config.yml`; exit `3` = Jira unreadable — bad token in `.env`,
  auth, or network).

The filesystem is the source of truth; Jira is a read-only mirror, and this
command never writes to either.

The dotted `/speckit.jira.status` is the spec-kit branding; the in-harness
command identifier is hyphenated (`speckit-jira-status`).
