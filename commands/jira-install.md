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

## Summary

Resolve this consumer repo's Jira binding and write the gitignored
`.specify/extensions/jira/jira-config.yml` — ending the manual id-hunting. You
(the agent) run the resolver via the Bash tool and report what was resolved. Do
NOT ask the user to run anything in their terminal.

**What it resolves over the Jira REST API** (the same Basic-auth transport the
sink uses — never the MCP for written values, Principle V): the project key, the
issue-type ids (Epic/Story/Subtask), a default lifecycle **phase→status** map
(each of the 6 phases mapped onto a status that already exists on the project's
workflow, defaulted by status category), and the **story-points field** id
(best-effort — absent is fine). Every written value is an **id** captured at
resolution.

Arguments the user passed (may be empty): `$ARGUMENTS`

## Rules for building the command

- **Project key**: if the user passed `--project NNN` use it. Otherwise, ask the
  operator for their Jira project key (the short prefix in any issue key, e.g.
  `PROJ-123`). You MAY use the Atlassian MCP `getVisibleJiraProjects` to help the
  operator pick — but the resolver writes only REST-derived ids regardless.
- **Phase→status**: the resolver proposes a default mapping (To Do-category →
  `specifying`/`planning`, In Progress-category → `tasking`/`implementing`,
  Done-category → `ready_to_merge`/`merged`). To override a phase
  non-interactively, pass `--phase-status <phase>=<statusName|id>` (repeatable).
- The sink does **not** load `.env` itself, so export the Jira Basic-auth
  credentials (`JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`) first.
- Pass `--non-interactive` through when the user asked for CI / no-prompt.

Run exactly this (substituting the resolved flags for `<FLAGS>`, always
including `--project <KEY>`):

```bash
cd "$(git rev-parse --show-toplevel)" && set -a && source .env && set +a && bash src/install.sh <FLAGS>
```

## Report back concisely

- the bound **project key**, the resolved **issue-type ids**, the 6
  **phase→status** mappings, and the **story-points field** id (or that it was
  absent — not an error),
- that the gitignored `jira-config.yml` was written (and that a re-run is a
  byte-identical no-op),
- if it exited non-zero, the meaning + likely fix: exit **2** = a missing input
  (no `.env` var, no/unknown project key, an unmappable lifecycle phase, or run
  from the bridge's own checkout); exit **3** = Jira unreadable (bad token in
  `.env`, auth/network, or the project key isn't visible to the credential).

## Offer to run seed (FR-013)

On a successful install, unless the user passed `--no-seed`, **offer to run
`/speckit-jira-seed`** now (install and seed are almost always run together — seed
confirms the lifecycle mapping is actually reachable on the project's workflow
before the first real reconcile). If they accept, run the seed command;
declining leaves seed as a separate explicit step. (`--with-seed` runs it
without asking.)

This resolves the binding over direct Jira REST — the Atlassian MCP is only an
optional interactive aid for browsing projects, never the source of the written
ids. Real coordinates are written ONLY to the gitignored config (Principle IX).
