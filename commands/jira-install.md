---
name: speckit.jira.install
description: Resolve the per-repo Jira binding (project key, issue-type ids, phase→status map, story-points field) over REST and write the gitignored jira-config.yml — no more hand-editing ids
arguments:
  - name: project
    description: the Jira project key to bind (e.g., PROJ). Optional — prompted interactively when omitted
    optional: true
  - name: non-interactive
    description: never prompt; require every input (project key + phase mappings) via flags. For CI
    optional: true
  - name: phase-status
    description: "repeated <phase>=<statusName|id> to map a lifecycle phase onto a project status non-interactively (e.g. implementing=\"In Progress\")"
    optional: true
  - name: with-seed
    description: run the seed validation immediately after a successful install (skip the confirm prompt)
    optional: true
  - name: no-seed
    description: do not offer to run seed after install
    optional: true
---

# `/speckit.jira.install`

(Body filled in US1 — see commands/jira-install.md.)
