# Quickstart: Hook Self-Healing

After this feature, spec-kit-jira **notices when its own auto-sync wiring goes
missing** and helps you put it back — so a silently-stripped hook set is loud, not
silent.

## Why you'd see it

The sanctioned update command strips the hooks:

```bash
specify extension add jira --from <release-zip> --force   # <-- wipes the after_* hooks
```

After that, auto-sync stops and the Jira board quietly drifts. This feature makes
that visible.

## What you'll see

**On a normal sync** (`/speckit-jira-push`), if hooks are missing:

```text
⚠ 3 auto-sync hook(s) not registered (after_plan after_tasks after_analyze);
  run /speckit-jira-install to restore auto-sync
```

The sync itself still completes — the warning never blocks it, and it appears at
most once per run.

**On a status check** (`/speckit-jira-status`, i.e. `reconcile --dry-run`) it's a
first-class line, in every state, and status **always exits 0**:

```text
Auto-sync hooks: all present
Auto-sync hooks: partial — missing: after_tasks — run /speckit-jira-install to restore
Auto-sync hooks: none registered — run /speckit-jira-install to restore auto-sync
Auto-sync hooks: could not verify (.specify/extensions.yml unreadable or malformed)
```

## Fixing it

- **The always-works path**: run `/speckit-jira-install` — it re-registers every
  missing hook idempotently (and preserves any you intentionally turned off).
- **The one-keystroke path** (only when you run the bridge **directly in a
  terminal**): the bridge offers to repair on the spot —

  ```text
  Re-register 3 missing auto-sync hook(s) now? [y/N]
  ```

  A `y` re-registers all missing hooks in place; Enter (default No) leaves them be.
  Because the slash commands run without a terminal, this prompt appears only for
  direct CLI use — the slash/CI/hook-fired paths are warn-only.

## Deliberately turning a hook off

Set a hook `enabled: false` in `.specify/extensions.yml`. The bridge treats it as
**intentional** — it's never reported "missing", never warned about, and the
self-heal never re-enables it.

## Guarantees

- **Non-blocking**: the warning/offer never fails your sync and never changes an
  exit code (status stays 0).
- **Consent-only mutation**: nothing is written to `.specify/extensions.yml` unless
  you say yes at a real terminal.
- **No Jira writes, local-only**: hook health is computed from your local
  `.specify/extensions.yml` — no board call.
