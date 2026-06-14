# Quickstart: Consumer-Side Privacy Guard

The bridge now refuses to write to Jira from a consumer repo whose **tracked**
tree contains a real Jira identifier. It is automatic — a pre-write gate on every
reconcile (and at install). You do nothing to enable it.

## What it checks

Before any Jira write, the bridge scans the consumer repo's whole tracked tree
(`git ls-files`) for:

Findings come in **two tiers** (precision-blocks, recall-warns):

- **BLOCK** (fail closed, **exit 4**, zero writes):
  - **your own resolved coordinates** (exact, zero false positives): your Jira
    email, `*.atlassian.net` site host, and API token (from the `JIRA_*` env the
    push command exports), plus the accountIds in `jira-authors.local.yml`;
  - the Atlassian **API-token prefix** (`ATATT…`) and a **site host**
    `<name>.atlassian.net` (the reserved `example.atlassian.net` documentation
    host is exempt).
- **WARN** (surfaced, the run **proceeds**): a generic **email**, a
  **cloudId/UUID**, or a 24-hex / `NNNNNN:UUID` **accountId** — broad shapes that
  also match ordinary content, so they advise but never halt you.

It also asserts your resolved `jira-config.yml`, `.env`, and
`jira-authors.local.yml` are **gitignored and untracked** (tracked or unignored
⇒ BLOCK). A non-git target also fails closed.

## When it trips

```text
$ /speckit-jira-push
ERROR  README.md: forbidden site in a tracked file — move real values to the
       gitignored .env / jira-config.yml, replace the tracked occurrence with a
       placeholder, and scrub history if already committed.
# exit 4 — nothing was written to Jira
```

The report names the **file** and the **shape class**; it never prints the
matched secret back (so your terminal/CI log doesn't re-leak it).

## Fixing a finding

1. Move the real value into the gitignored `.env` (credentials) or
   `.specify/extensions/jira/jira-config.yml` (resolved binding).
2. Replace the tracked occurrence with a neutral placeholder
   (`<your-site>.atlassian.net`, `you@example.com`).
3. If it was already committed, scrub it from history (`git filter-repo` or BFG)
   and rotate the token — committed secrets are compromised.
4. Re-run — a clean tree passes silently and the bridge proceeds.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | every spec processed |
| 1 | partial failure |
| 2 | project-level config error |
| 3 | Jira unreachable |
| **4** | **privacy leak in the tracked tree — fail-closed, zero writes** |

## Recommended (not required): broader secret scanning

The core guard is dependency-free. For *generic* secrets it doesn't know about,
add [gitleaks](https://github.com/gitleaks/gitleaks) or
[trufflehog](https://github.com/trufflesecurity/trufflehog) to your repo's CI.
If one is already on your `PATH`, the bridge surfaces its findings best-effort —
but it is never required and never replaces the built-in known-value + shape
guarantee. (trufflehog's live-verification is intentionally not used — it would
call Jira's API.)

## Edge cases

- **Not a git repo** ⇒ the guard fails closed (it can't enumerate a tracked tree,
  so it can't prove it's safe).
- **Dogfooding (the bridge repo is its own consumer)** ⇒ this guard and the
  CI guard (`no-real-identifiers.bats`) cover the same tree and agree.
- **A value split across lines** ⇒ a known limitation of a line-based shape scan;
  your own exact literals are still caught, and gitleaks/trufflehog cover more.
