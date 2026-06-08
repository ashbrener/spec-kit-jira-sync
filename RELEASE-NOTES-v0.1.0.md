# spec-kit-jira-sync v0.1.0

**A real reconcile engine — idempotent, drift-aware, fail-closed — that mirrors
your spec-kit specs into Jira and never corrupts your board.**

This is not a prompt that asks an LLM to "make some Jira tickets." It is a
deterministic reconcile engine (the same hardened core the shipped
`spec-kit-linear-sync` runs) wired to Jira's REST API. The filesystem is the
single source of truth; Jira is a one-way, read-only mirror. Every run converges
the board to disk:

- **Idempotent** — a re-run over an unchanged spec corpus performs **zero**
  writes. It reuses the existing issues instead of duplicating them. Run it as
  often as you like.
- **Drift-aware** — before each write the engine computes a backward-drift
  signal (lifecycle ordering + commit recency). If Jira is ahead of disk it
  surfaces a named WARNING rather than silently clobbering, and you choose the
  disposition (`--on-drift=proceed` warns and writes; `--on-drift=abort` skips
  the drifted spec).
- **Fail-closed** — invalid config exits `2`; an unreadable Jira exits `3`.
  When the engine cannot read the board reliably it refuses to write rather than
  risk a duplicate. No partial corruption.
- **Schema-gated** — every record is validated against the neutral `workstate`
  schema (under `uv`, PEP 668-safe) before any write touches Jira.

## What it mirrors

By default, the zero-config projection is:

- **Epic per repo** — one per-repository Epic.
- **Story per spec** — one Story per `specs/NNN-feature/` directory, linked under
  the repo Epic, transitioned through your workflow as the spec's lifecycle phase
  advances.
- **Subtask per phase** — one Subtask per task phase, with that phase's tasks
  rendered as a done/not-done ADF checklist in the Subtask body.

## Feature 001 — the core bridge (Layer D reconcile)

A single `src/reconcile.sh` command mirrors a spec-kit project's specs into Jira
through **parser → schema-valid `workstate` → Jira sink**. The parser reads the
on-disk spec corpus (`spec.md` / `plan.md` / `tasks.md`), infers the lifecycle
phase, and emits neutral `workstate` JSON; the Jira sink consumes only
`workstate`. The reconcile engine (drift detection, commit-recency gating,
layered idempotency) is vendor-neutral — Jira lives only in the sink and config.

## Feature 002 — configurable artifact mapping

An optional `mapping:` block in `jira-config.yml` makes the spec-kit→Jira
projection operator-configurable, while keeping today's behavior as the frozen,
zero-config default (a no-config upgrade is **byte-for-byte identical** — the
regression anchor):

- **Per-level mapping + available-type detection** — each `workstate` level
  (repo/spec/phase/task) maps to a configurable Jira issue type and a
  parent-link relationship, validated at config-load against the project's
  **live available issue types**, with a per-level `on_absent` fallback. All
  fail-closed before any write.
- **2-level checklist mode** — phases/tasks collapse into a keyed in-body
  checklist on the spec issue (no Subtask children), diffed as an isolated
  byte-stable sub-tree so re-runs stay zero-churn and human prose edits survive.
- **Status rollup (off by default)** — rolls phase/spec completion up to issue
  status (phase done when all tasks checked, repo Epic done when all specs
  merged), transitioning only on a real completion change.
- **Initiative super-level (off by default)** — a narrative level above the Epic,
  mapping to a Jira Initiative where available and degrading gracefully onto the
  Epic (behind a stable marker + repo label) where it is not — never
  hard-failing. Narrative is sourced only from the explicit `spec.md` `Input:`
  line.
- **`--workstate <file|->` direct input** — feeds a schema-validated `workstate`
  document straight to the sink, skipping the parser, so any producer can drive
  the mirror.

## Install

```
specify extension add jira
```

Then copy `config-template.yml` to `.specify/extensions/jira/jira-config.yml`,
fill in your project key, issue-type ids, and phase→status ids, and set
`JIRA_BASE_URL` / `JIRA_EMAIL` / `JIRA_API_TOKEN` in a gitignored `.env`.

Two commands ship: `/speckit.jira.push` (reconcile/write) and
`/speckit.jira.status` (read-only dry-run drift preview).

## Privacy

No real Jira coordinates or PII ship in this release. The Basic-auth token and
all site/project binding values live only in your gitignored `.env` and
`jira-config.yml`. A privacy guard gates CI.

**License:** MIT
