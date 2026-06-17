---
name: speckit.jira.seed
description: Validate the phase:* / task-phase:N labels and confirm every lifecycle status is reachable on the project's workflow — never mutates the workflow; idempotent
arguments:
  - name: dry-run
    description: validate + confirm reachability and report, but write no binding
    optional: true
---

# `/speckit.jira.seed`

## Summary

The lifecycle **trust gate**. Seed proves the statuses the bridge will drive
actually exist on the project's workflow BEFORE the first real reconcile, and
validates the label conventions. You (the agent) run it via the Bash tool and
report; do NOT ask the user to run anything in their terminal.

**What it does** (clarify b — validate + capture, never mutate): validates the
`phase:*` / `task-phase:N` (and spec/repo) label prefixes are well-formed (Jira
labels auto-create on first reconcile use — seed never pre-creates them);
confirms every one of the 6 configured `phase_status` ids is reachable on the
project's workflow (`GET project/<key>/statuses`); and captures/confirms the ids
into the binding. It **never** creates labels and **never** mutates the
admin-scoped workflow statuses/transitions.

Run seed AFTER `/speckit-jira-install` has written the binding.

Arguments the user passed (may be empty): `$ARGUMENTS`

## Rules for building the command

- Pass `--dry-run` through if the user only wants to validate (write nothing).
- The sink does **not** load `.env`, so export the Jira Basic-auth credentials
  (`JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`) first.

Run exactly this (substituting any resolved flags for `<FLAGS>`):

```bash
cd "$(git rev-parse --show-toplevel)" && set -a && source .env && set +a && bash src/seed.sh <FLAGS>
```

## Report back concisely

- the label-prefix validation result,
- the per-phase reachability (each of the 6 lifecycle phases → its status id,
  reachable or not),
- that seed is idempotent (a healthy re-run is a byte-identical no-op),
- if it exited **2**, the exact lifecycle step that is unreachable + the
  remediation (re-run `/speckit-jira-install`, or
  `--phase-status <phase>=<statusName|id>`, to map that phase onto an existing
  status); if **3**, Jira was unreadable (bad token in `.env` or the project's
  workflow isn't visible to the credential).

Seed reads the project's workflow over direct Jira REST and never mutates it.
The binding is written ONLY to the gitignored config (Principle IX).
