---
description: Validate the phase:* / task-phase:N labels and confirm every lifecycle status is reachable on the project's workflow — never mutates; idempotent
argument-hint: "[--dry-run]"
allowed-tools: Bash
---

The lifecycle **trust gate** for the **spec-kit-jira-sync** repo. Seed proves the
statuses the bridge will drive actually exist on the project's workflow BEFORE
the first real reconcile, and validates the label conventions. Run it via the
Bash tool and report; do NOT ask the user to run anything in their terminal.

What it does (validate + capture, never mutate): validates the `phase:*` /
`task-phase:N` (and spec/repo) label prefixes are well-formed (Jira labels
auto-create on first reconcile use — seed never pre-creates them); confirms every
one of the 6 configured `phase_status` ids is reachable on the project's workflow
(`GET project/<key>/statuses`); and captures/confirms the ids into the binding.
It never creates labels and never mutates the admin-scoped workflow.

Run seed AFTER `/speckit-jira-install` has written the binding.

Arguments the user passed (may be empty): `$ARGUMENTS`

Rules for building the command:

- Pass `--dry-run` through if the user only wants to validate (write nothing).
- The sink does **not** load `.env`, so export `JIRA_BASE_URL`, `JIRA_EMAIL`,
  `JIRA_API_TOKEN` first.

Run exactly this (substituting any resolved flags for `<FLAGS>`):

```bash
cd "$(git rev-parse --show-toplevel)" && set -a && source .env && set +a && bash src/seed.sh <FLAGS>
```

After it runs, report back concisely:

- the label-prefix validation result,
- the per-phase reachability (each of the 6 lifecycle phases → its status id),
- that seed is idempotent (a healthy re-run is a byte-identical no-op),
- if it exited `2`, the exact unreachable lifecycle step + remediation (re-run
  `/speckit-jira-install`, or `--phase-status <phase>=<statusName|id>`); if `3`,
  Jira was unreadable.

Seed reads the project's workflow over direct Jira REST and never mutates it. The
binding is written ONLY to the gitignored config (Principle IX).
