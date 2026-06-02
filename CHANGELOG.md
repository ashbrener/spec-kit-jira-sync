# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

> **In active development — not yet released.** This is a pre-release project; no
> versions are tagged yet and the API may change. See the
> [README](README.md) for current status and the
> [contribution guide](CONTRIBUTING.md) for local CI parity.

## [Unreleased]

### Added

- **Core bridge (Layer D reconcile)** — a single `src/reconcile.sh` command that
  mirrors a spec-kit project's specs into Jira through the pipeline
  **parser → schema-valid `workstate` → Jira sink**. The parser reads the
  on-disk spec corpus (`spec.md` / `plan.md` / `tasks.md`), infers the lifecycle
  phase, and emits neutral `workstate` JSON; the Jira sink consumes only
  `workstate`.
- **Vendor-neutral reconcile engine** — drift detection, commit-recency gating,
  and layered idempotency, adapted from the shipped `spec-kit-linear` and kept
  free of any Jira specifics (Jira lives only in the sink and config). The engine
  is idempotent, drift-aware, and fail-closed.
- **US1 — fresh-mirror create path** — a first run over an empty board creates
  the per-repository Epic, one Story per spec under that Epic, and a Subtask per
  task phase, with each phase's tasks rendered as a done/not-done ADF checklist
  in the Subtask body.
- **US2 — idempotent zero-churn re-run** — a second run against an unchanged
  corpus performs zero writes, reuses the existing Epic rather than duplicating
  it, and reconciles a disk-authoritative Story status back to the derived value.
- **US3 — drift read** — a Story that is ahead of disk by lifecycle order or by
  commit recency surfaces a named backward-drift warning; drift is reported and
  never blocks the write by default.
- **Config template + dogfood guide** — `config-template.yml` for the per-project
  binding and `specs/001-core-bridge/dogfood.md` for self-provisioning against a
  real instance.
- **uv-based schema validation** — the `workstate` schema gate runs under `uv`
  (PEP 668-safe), validating every emitted record against the published schema
  before any write.
- **Test suite** — bats unit coverage for the parser, engine, sink, ADF
  rendering, and the privacy guard, driven against a mocked Jira REST harness.

### Changed

- Schema-validation gate repointed from a pip/venv install to `uv`, removing the
  PEP 668 externally-managed-environment dependence.
- `reconcile.sh` usage/help aligned with the documented exit codes and the
  `--all` default.

### Fixed

- Sink now translates the configured lifecycle prefix to the neutral `phase:`
  form during the drift reshape, so the drift-read path matches the engine
  contract.
- `ensure_repo_epic` fails closed when the Epic cannot be read reliably, rather
  than risking a duplicate.
- Parser phase normalization corrected in the producer half.
- POST idempotency and feature-pin handling hardened in the foundational sink.

[Unreleased]: https://keepachangelog.com/en/1.1.0/
