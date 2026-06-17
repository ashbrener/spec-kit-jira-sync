---
name: speckit.jira.seed
description: Validate the phase:* / task-phase:N labels and confirm every lifecycle status is reachable on the project's workflow — never mutates the workflow; idempotent
arguments:
  - name: dry-run
    description: validate + confirm reachability and report, but write no binding
    optional: true
---

# `/speckit.jira.seed`

(Body filled in US2 — see commands/jira-seed.md.)
