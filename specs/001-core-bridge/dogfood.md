# Dogfood — Provision the Jira Binding and Mirror This Repo

A short, ordered guide to provision the bridge binding and run the
**self-dogfood**: this repo mirrors its OWN `specs/` into a Jira project, the
same way an adopting spec-kit repo would.

Privacy first (Principle IX): real values live ONLY in the gitignored `.env`,
`.specify/extensions/jira/jira-config.yml`, and `tests/.private-deny`. The
privacy guard (`tests/unit/no-real-identifiers.bats`) scans the tracked tree and
gates CI, so a leaked site / project / account id / token fails the build. Every
committed file (this one included) uses neutral placeholders only.

Auto-discovery note: the seed/install step that captures these ids for you is a
**later feature**. For now the config is filled by hand — or read off the
project interactively via the Atlassian MCP — as steps 1-2 describe.

## 1. Create or choose a Jira project

Pick an existing Jira project, or create a new one. You can do this by hand in
the Jira UI, or via the Atlassian MCP (`createJiraIssue` works against an
existing project; use the UI or your admin tooling to create the project
itself). Note its **project key** (the prefix in every issue key, e.g.
`PROJ-123`) — you will need it in step 2.

## 2. Resolve the binding config (gitignored)

Copy the committed template to the gitignored resolved location and fill in the
ids for your project:

```bash
mkdir -p .specify/extensions/jira
cp config-template.yml .specify/extensions/jira/jira-config.yml
```

Then edit `.specify/extensions/jira/jira-config.yml` and replace every
placeholder. Each field's inline comment names where its id comes from; in
short:

- `project_key` — Project settings -> Details, or any issue key.
- `issue_types.{epic,story,subtask}` — the project's issue-type **ids** (numeric,
  not names): Project settings -> Issue types, or the Atlassian MCP
  `getJiraProjectIssueTypesMetadata`.
- `phase_status.<phase>` — the target **status ids** from the project's
  workflow (all six lifecycle phases: `specifying`, `planning`, `tasking`,
  `implementing`, `ready_to_merge`, `merged`): Project settings -> Workflows, or
  the Atlassian MCP.
- `transitions` — leave as `{}` unless the workflow has more than one transition
  reaching a status; a transition id comes from an issue's available transitions
  (`GET /rest/api/3/issue/{key}/transitions`, or the MCP
  `getTransitionsForJiraIssue`).
- `labels.*` — operator-chosen label prefixes; the template defaults are fine.

This resolved file is gitignored and never committed (Principle IX).

## 3. Complete the gitignored `.env`

A new workspace means new coordinates. Create or update the gitignored `.env`
with your Jira Cloud Basic-auth credentials:

```bash
JIRA_BASE_URL=https://<your-site>.atlassian.net
JIRA_EMAIL=<you@example.com>
JIRA_API_TOKEN=<atlassian-api-token>   # never commit; .env is gitignored
```

The token + email live only here; `config.sh` never reads secrets, and they
never enter `jira-config.yml` or any tracked file (Principles VI / IX).

## 4. Dry run, inspect, then a guarded live run

Plan the run with no writes and read the planned Epic / Stories / Subtasks:

```bash
src/reconcile.sh --all --dry-run
```

The dry run reports every intended create / update / transition / comment for
this repo's own specs without touching Jira — one Epic for the repo, a Story per
spec under `specs/`, and a Subtask per task phase. Inspect that summary.

When it looks right, drop `--dry-run` for a live run; use the drift guard so a
human-advanced issue is never overwritten:

```bash
src/reconcile.sh --all --on-drift=abort
```

Exit codes: `0` ok · `1` warnings (incl. drift) · `3` a spec failed closed ·
`2` config error.
