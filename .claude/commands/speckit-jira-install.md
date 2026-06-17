---
description: Resolve the per-repo Jira binding over REST and write the gitignored jira-config.yml — no more hand-editing ids
argument-hint: "[--project PROJ] [--non-interactive] [--phase-status <phase>=<status>]… [--with-seed | --no-seed]"
allowed-tools: Bash
---

Resolve this **spec-kit-jira-sync** consumer repo's Jira binding and write the
gitignored `.specify/extensions/jira/jira-config.yml` yourself — ending the
manual id-hunting. Run the resolver via the Bash tool and report what was
resolved; do NOT ask the user to run anything in their terminal.

It resolves over the Jira REST API (the same Basic-auth transport the sink uses,
never the MCP for written values): the project key, the issue-type ids
(Epic/Story/Subtask), a default lifecycle phase→status map (each of the 6 phases
onto an existing project status, defaulted by status category), and the
story-points field id (best-effort — absent is fine). Every written value is an
**id** captured at resolution (Principle V).

Arguments the user passed (may be empty): `$ARGUMENTS`

Rules for building the command:

- **Project key**: use `--project NNN` if given; otherwise ask the operator for
  their Jira project key (the prefix in any issue key, e.g. `PROJ-123`).
- **Phase→status**: the resolver defaults the map by status category; override a
  phase with `--phase-status <phase>=<statusName|id>` (repeatable).
- The sink does **not** load `.env`, so export `JIRA_BASE_URL`, `JIRA_EMAIL`,
  `JIRA_API_TOKEN` first. Pass `--non-interactive` through for CI.

Run exactly this (substituting the resolved flags for `<FLAGS>`, always
including `--project <KEY>`):

```bash
cd "$(git rev-parse --show-toplevel)" && set -a && source .env && set +a && bash src/install.sh <FLAGS>
```

After it runs, report back concisely:

- the bound project key, the resolved issue-type ids, the 6 phase→status
  mappings, the story-points field id (or its absence — not an error),
- that the gitignored `jira-config.yml` was written (a re-run is byte-identical),
- if it exited non-zero, the meaning + likely fix: exit `2` = a missing input
  (no `.env` var, no/unknown project key, an unmappable phase, or run from the
  bridge's own checkout); exit `3` = Jira unreadable (bad token, auth/network, or
  the project key isn't visible to the credential).

On a successful install, unless the user passed `--no-seed`, **offer to run
`/speckit-jira-seed`** now (they are almost always run together — seed confirms
the lifecycle mapping is reachable before the first reconcile). `--with-seed`
runs it without asking.

The binding is resolved over direct Jira REST; the Atlassian MCP is only an
optional aid for browsing projects, never the source of the written ids. Real
coordinates land ONLY in the gitignored config (Principle IX).
