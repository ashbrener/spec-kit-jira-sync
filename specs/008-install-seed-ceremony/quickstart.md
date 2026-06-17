# Quickstart: Jira Install + Seed Ceremony

After `specify extension add jira-sync`, you used to hand-edit the gitignored
`jira-config.yml` and paste in every id. Now two commands do it for you.

## 1. Provide the credential (once)

A gitignored `.env` at the consumer repo root:

```bash
JIRA_BASE_URL=https://<your-site>.atlassian.net
JIRA_EMAIL=<you@example.com>
JIRA_API_TOKEN=<atlassian-api-token>   # never commit; .env is gitignored
```

## 2. Install — resolve the binding

```text
/speckit-jira-install            # interactive: pick the project, confirm phase→status
/speckit-jira-install --project PROJ
```

Install verifies your credential authenticates, then resolves and writes
`.specify/extensions/jira/jira-config.yml`:

- the **project key** and the **issue-type ids** (Epic / Story / Subtask);
- the **6 lifecycle phase → status** mappings. Jira statuses are yours (the bridge
  can't create them), so install proposes a default by status category
  (To Do → early phases, In Progress → tasking/implementing, Done →
  ready-to-merge/merged) and lets you confirm or adjust;
- the **story-points field** id if your project has one (optional — skipped with a
  note if absent).

It writes **only** the gitignored config; nothing real touches the tracked tree.
On success it offers to run seed.

## 3. Seed — validate the lifecycle

```text
/speckit-jira-seed
```

Seed confirms the `phase:*` / `task-phase:N` label conventions and that every
lifecycle status + transition the bridge will drive is **reachable** on your
project's workflow — surfacing a misconfigured workflow now, as a clear error,
rather than mid-reconcile. It never creates labels or edits your workflow
(admin-scoped). Safe to re-run.

## 4. Go

```bash
src/reconcile.sh --all --dry-run   # preview; no exit-2 "config missing" anymore
```

## Failure modes (fail-closed, nothing written)

| You see | Means | Fix |
|---|---|---|
| exit 2, "missing JIRA_* in .env" | no/incomplete credential | add the `.env` lines above |
| exit 3, "Jira unreadable (401/403)" | bad token / no access | rotate the token; confirm project access |
| exit 2, "running from the bridge checkout" | ran it in the wrong repo | run from your consumer repo |
| exit 2, "phase `implementing` has no reachable status" (seed) | workflow missing a status | map the phase to an existing status, or adjust the workflow |

Every failure writes **zero bytes** — a half-finished binding never happens.

## Re-running

Install and seed are idempotent: re-resolving an unchanged project rewrites a
**byte-identical** config (a visible no-op), and your hand-authored `mapping:` /
`attribution:` / `remode:` blocks are preserved untouched.
