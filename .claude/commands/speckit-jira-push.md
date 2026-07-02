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

After it runs, report back concisely:

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

This is the same Jira-REST reconcile engine the `/speckit.jira.push` consumer
surface wraps — the Atlassian MCP is not involved (the sync is direct REST by
design). The filesystem is the source of truth; Jira is a read-only mirror.

Auto-sync hook health (feature 012): the reconcile self-reports the health of
its six `after_*` auto-sync hooks. Reinstalling with
`specify extension add jira --from <zip> --force` **silently strips** them from
`.specify/extensions.yml`, so auto-sync stops firing. On a stripped set this
push emits one named WARNING and (at a real terminal) offers a single `y/N` to
re-register them all; the restore path is **`/speckit-jira-install`**. It is
non-blocking and never writes to Jira — relay the warning without alarm.
