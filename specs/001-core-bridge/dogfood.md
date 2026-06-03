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

Recommendation: for a spec mirror, prefer a **Kanban** board. A team-managed
**Scrum** board only renders issues that are in an ACTIVE SPRINT, so a
freshly-synced mirror's issues sit in the Backlog and the Board looks empty until
someone starts a sprint; a **Kanban** board shows every issue immediately. (Note
the Kanban simplified template lacks a Story type — Task / Epic / Subtask only —
so the spec maps to Task there; full configurable mapping is feature-002.)

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

## 5. Validation after a live run

Once the mirror exists, prove the engine's guarantees (SC-017: idempotent,
drift-aware, fail-closed) directly against your real Jira project. Each check
below is copy-pasteable and names the observable result to assert. Use your own
project key in place of `PROJ`, your board name in place of "your board", and
the live issue numbers (`PROJ-NNN`) the run printed.

1. **Dry-run parity (zero mutations).** Re-plan with no writes:

   ```bash
   src/reconcile.sh --all --dry-run
   ```

   Assert: the run prints the same planned-writes summary (planned creates /
   updates / comments / links) but issues **no** mutating request — no `POST`,
   `PUT`, or `DELETE` reaches Jira. Nothing changes in the UI; refresh your board
   and confirm no issue, field, comment, or link was touched. Exit code `0`.

2. **Idempotency (zero churn).** This is the single most important real-Jira
   proof. Run the live reconcile once against a fresh mirror and record the
   created counts:

   ```bash
   src/reconcile.sh --all          # fresh mirror — note created counts
   src/reconcile.sh --all          # immediately again — must be a no-op
   ```

   Assert: the **second** run's summary shows `0 created / 0 updated /
   0 comments / 0 links` (zero churn) and exits `0`. No issue key is
   re-created, no field is rewritten, no duplicate comment or link appears on
   the board. A converged mirror re-run is a pure no-op.

3. **Drift-aware (Jira ahead of disk, never silently overwritten).** In the
   Jira UI, advance exactly one mirrored Story — transition its status forward
   (e.g. move `PROJ-NNN` one column right on your board) or edit a mirrored
   field — then re-run:

   ```bash
   src/reconcile.sh --all
   ```

   Assert: a **named WARNING** surfaces for that spec (Jira ahead of disk /
   backward-drift) and the Story is **not** silently overwritten. Document both
   dispositions:

   - **Default** (drift surfaced, then proceeds): the warning names the drifted
     issue, the run continues and restores the disk-derived state, exit `1`.
   - **`--on-drift=abort`** (skip the drifted spec): re-run with
     `src/reconcile.sh --all --on-drift=abort` — that spec is **skipped**, the
     drifted Story is left exactly as the human set it in Jira (unchanged), and
     the run exits `≥1`.

4. **Fail-closed (bad credentials → no writes).** Temporarily break auth, then
   run — restore the real value immediately after:

   ```bash
   cp .env .env.bak
   # set a deliberately bad JIRA_API_TOKEN in .env
   src/reconcile.sh --all
   mv .env.bak .env               # restore the real token
   ```

   Assert: **no** write lands for the affected spec (refresh the board — nothing
   created or changed), the summary carries an **error row** for that spec, and
   the process exits `3`. The bridge fails closed: an unreadable / unwritable
   Jira never produces a partial mutation.

5. **Exit-code assertions.** Each scenario maps to a single process exit code,
   consistent with the README "Exit codes" section (monotonic escalation — the
   highest code that fires wins):

   | Scenario | Expected exit |
   |---|---|
   | Dry-run parity (check 1) | `0` |
   | Idempotent re-run, zero churn (check 2) | `0` |
   | Drift surfaced, default proceeds (check 3, default) | `1` |
   | Drift surfaced, `--on-drift=abort` skips (check 3, abort) | `≥1` |
   | Fail-closed on bad token (check 4) | `3` |

   Read the code off `echo $?` immediately after each run. A clean converged
   mirror is always `0`; a surfaced warning is `1`; an unreadable / failed spec
   is `3`.
