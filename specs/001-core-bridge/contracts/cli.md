# Contract — reconcile CLI surface

The operator-facing command for Layer-D reconcile. (Install/hook registration is
a later feature; this is the underlying command hooks will call.)

## Invocation

```text
reconcile.sh [--spec NNN | --all] [--dry-run] [--on-drift=proceed|abort]
             [--quiet] [--config PATH]
```

| Flag | Meaning |
|------|---------|
| `--all` | Reconcile every spec under `specs/` (default if no `--spec`). |
| `--spec NNN` | Reconcile only feature NNN. |
| `--dry-run` | Compute and report every intended write; perform none (FR-016). |
| `--on-drift=proceed\|abort` | Non-interactive disposition on backward-drift; default proceed-and-warn (FR-011). |
| `--quiet` | Suppress per-mutation logging; the summary still prints. |
| `--config PATH` | Override the gitignored `jira-config.yml` location. |

## Inputs (environment)

- `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN` from the gitignored `.env`
  (FR-017). Missing/invalid → project-level configuration error (halt).

## Outputs

- A structured run summary to stdout: counts `created/updated/skipped` plus
  named `warning`/`error` rows (FR-015).
- Per-mutation log lines to stderr (unless `--quiet`).

## Exit codes (monotonic escalation)

| Code | Meaning |
|------|---------|
| 0 | Success; all processable specs reconciled (or nothing to do). |
| 1 | Completed with per-spec warnings (e.g., drift surfaced, missing `tasks.md`). |
| 3 | One or more specs failed closed (unreadable Jira, exhausted 429 retries). |
| 2 | Project-level configuration error (no/invalid binding) — run halted. |
| 4 | Consumer-tree privacy leak — fail-closed, zero Jira writes (a real identifier shape / known coordinate in a tracked file, or the target is not a git work-tree). Terminal: never demoted by 1/3. |

Higher code wins when multiple occur. Non-zero on any fail-closed (SC-005).
Exit 4 is terminal (like 2): once a privacy leak is detected the run halts
before any write and the code is never demoted.

## Guarantees

- Idempotent: re-run on unchanged input performs zero writes (FR-008).
- Never writes to the filesystem or git/GitHub state (FR-019).
- Fail-closed per spec; continues other specs; halts only on config errors
  (FR-013, FR-014).
