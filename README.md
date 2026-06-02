# spec-kit-jira

**A real sync engine for mirroring spec-kit specs into Jira — idempotent,
drift-aware, and fail-closed.** Not a prompt that asks an agent to POST to your
board: it computes exactly what should change, refuses to write when it cannot
read Jira reliably, and never corrupts your board on a re-run.

## What it does

`spec-kit-jira` mirrors a spec-kit project's specs into Jira with a single
reconcile command:

- **repo → Epic** — one per-repository Epic groups all of that repo's specs.
- **spec → Story** — each `specs/NNN-feature/` becomes one Story under the Epic.
- **task phase → Subtask** — each `## Phase N` in `tasks.md` becomes a Subtask.
- **tasks → ADF checklist** — the phase's individual tasks render as a
  done/not-done checklist in the Subtask body, matching `tasks.md`.

Internally it never models Jira directly. The pipeline is
**parser → `workstate` → Jira sink**: the parser reads the on-disk spec corpus
and emits the neutral, schema-valid `workstate` format; the Jira sink consumes
only `workstate` and talks Jira REST. That seam is also why this repo matters
beyond Jira — it is the **independent second consumer** that proves `workstate`
is genuinely vendor-neutral and not secretly shaped to one tracker.

The filesystem is the single source of truth; Jira is a unidirectional,
read-only mirror. Operator edits made in Jira are not a control surface — the
next reconcile restores the disk-derived state (after surfacing any drift).

## Status

**In active development.** This section is honest about what is built versus
planned.

### Done

- **Parser → schema-valid `workstate`** — reads `spec.md` / `plan.md` /
  `tasks.md`, infers the lifecycle phase, and emits `workstate` JSON that
  validates against the published schema.
- **Vendor-neutral reconcile engine** — drift detection, commit-recency gating,
  and layered idempotency, extracted from the shipped `spec-kit-linear` and kept
  free of any Jira specifics.
- **Jira sink create path (US1)** — a fresh mirror creates the repo Epic, each
  spec Story, and per-phase Subtasks with their task checklists.
- **Idempotent zero-churn re-run (US2)** — a second run against an unchanged
  corpus performs zero writes and reuses the existing Epic.
- **Drift read (US3)** — a Story that is ahead of disk (by lifecycle order or
  commit recency) surfaces a named backward-drift warning rather than silently
  overwriting.

### Roadmap

- Lifecycle/content propagation: comments for clarification sessions and issue
  links for cross-spec dependencies (US4).
- Fail-closed integration coverage across auth / network / 429 failure modes
  (US5).
- A live-instance run beyond the mocked Jira REST harness.
- Configurable artifact/relationship mapping and a 2-level mode (collapse tasks
  into a Story checklist instead of separate Subtask issues).
- Carving the parser out into a standalone `workstate` producer so the sink
  becomes a pure `workstate → Jira` consumer.

The suite is **100+ bats tests, cross-model reviewed** at phase boundaries.

## Quick start

Reconcile is the only command. Preview every intended write without touching
Jira:

```bash
src/reconcile.sh --all --dry-run
```

Drop `--dry-run` to perform the writes. Credentials and the per-project binding
live only in gitignored files — never in the tracked tree:

- `.env` — `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`
  (e.g. `JIRA_BASE_URL=https://<your-site>.atlassian.net`).
- `jira-config.yml` — the resolved per-project binding (project key, issue-type
  / status / transition ids).

### Usage

```text
reconcile.sh [--spec NNN | --all] [--dry-run] [--on-drift=proceed|abort]
             [--quiet] [--config PATH]
```

| Flag | Meaning |
|------|---------|
| `--all` | Reconcile every spec under `specs/` (default if no `--spec`). |
| `--spec NNN` | Reconcile only feature NNN. |
| `--dry-run` | Compute and report every intended write; perform none. |
| `--on-drift=proceed\|abort` | Disposition on backward-drift; default proceed-and-warn. |
| `--quiet` | Suppress per-mutation logging; the summary still prints. |
| `--config PATH` | Override the gitignored `jira-config.yml` location. |

### Exit codes

Monotonic escalation — the highest code that fires wins:

| Code | Meaning |
|------|---------|
| 0 | Success; all processable specs reconciled (or nothing to do). |
| 1 | Completed with per-spec warnings (drift surfaced, missing `tasks.md`). |
| 2 | Project-level configuration error (no/invalid binding) — run halted. |
| 3 | One or more specs failed closed (unreadable Jira, exhausted 429 retries). |

See [`specs/001-core-bridge/quickstart.md`](specs/001-core-bridge/quickstart.md)
for setup and running the tests, and
[`specs/001-core-bridge/dogfood.md`](specs/001-core-bridge/dogfood.md) for
self-dogfood provisioning against a real instance.

## Privacy

This is a public repository. **No real Jira coordinates ever enter a tracked
file** — no workspace, site, project key, account id, cloudId/UUID, email, or
API token. Documentation and fixtures use placeholders only (e.g.
`https://<your-site>.atlassian.net`).

Real values live exclusively in gitignored files — `.env`, `jira-config.yml`,
and `tests/.private-deny` — and the privacy guard
(`tests/unit/no-real-identifiers.bats`) scans the tracked tree and gates CI on
any shape-based or operator-literal leak (Principle IX).

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for the local CI parity commands and the
contribution workflow. Project governance — the non-negotiable principles every
spec and PR is checked against — lives in
[`.specify/memory/constitution.md`](.specify/memory/constitution.md).
