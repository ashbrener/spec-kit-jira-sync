# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

> **In active development — not yet released.** This is a pre-release project; no
> versions are tagged yet and the API may change. See the
> [README](README.md) for current status and the
> [contribution guide](CONTRIBUTING.md) for local CI parity.

## [Unreleased]

### Added

- **Mapping re-mode / orphan pruning (feature 004)** — a guarded, opt-in
  `reconcile.sh --remode` that converges a board to the shape the *current*
  mapping projects: it prunes the bridge-owned artifacts a prior mapping shape
  left as orphans, then regenerates the new shape in one pass. Orphans are
  identified by a vendor-neutral diff `O = E \ D` over the `speckit-*` identity
  labels (the engine owns the diff; the sink owns the prune mechanic), so an
  operator-created issue — carrying no identity label — is *structurally*
  excluded and never touched (FR-002). The destructive path is reachable **only**
  via `--remode`; `--remode --dry-run` previews the exact prune + regenerate set
  with zero writes (byte-faithful to the real run); reads are fail-closed (an
  unreadable read aborts before any delete); a partial prune failure is surfaced
  and completable by a re-run; backward-drift on a to-be-pruned issue is warned
  first. The destruction model is operator-selectable (`remode.destruction:
  hard-delete` default | `archive`). The ordinary reconcile stays strictly
  non-destructive and only **warns** when it detects prior-shape orphans
  (FR-014). Built on the feature-003 neutral level loop.
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
- **In-session slash commands** — `/speckit-jira-push` (reconcile/write) and
  `/speckit-jira-status` (read-only dry-run preview) run the engine from inside
  the agent harness; `pull` is deferred (unidirectional, read-only mirror).
- **Configurable artifact mapping (feature 002)** — an optional `mapping:` block
  in `jira-config.yml` makes the spec-kit→Jira projection operator-configurable
  while keeping today's behavior as the frozen, zero-config default (a no-config
  upgrade is byte-for-byte identical — the regression anchor):
  - **Alias-layer default + per-level mapping** — each `workstate` level
    (repo/spec/phase/task) maps to a configurable Jira issue type and a
    parent-link relationship, validated at config-load (the relationship matrix,
    required ids, and live **available-issue-type detection** with a per-level
    `on_absent` fallback) — all fail-closed before any write.
  - **2-level checklist mode** — phases/tasks collapse into a keyed in-body
    checklist on the spec issue (no Subtask children), diffed as an isolated
    byte-stable sub-tree so re-runs stay zero-churn and human prose edits are
    preserved.
  - **Status rollup (off by default)** — rolls phase/spec completion up to issue
    status (phase done when all tasks checked, repo Epic done when all specs
    merged), transitioning only on a real completion change.
  - **Initiative super-level (off by default)** — a narrative level above the
    Epic mapping to a Jira Initiative where available, degrading gracefully onto
    the Epic (behind a stable marker + repo label) where it is not — never
    hard-failing; narrative sourced only from the explicit `spec.md` `Input:`
    line.
  - **`--workstate <file|->` direct input** — feeds a schema-validated
    `workstate` document straight to the sink, skipping the parser, so any
    producer can drive the mirror (the seam toward a standalone parser).

### Changed

- **Constitution v1.0.0 → v1.1.0** (MINOR) — a scoped controlled-destruction
  carve-out added to Principle I for feature 004: the ordinary mirror stays
  strictly non-destructive, but the explicit, opt-in re-mode MAY remove
  bridge-owned artifacts (flag-only, bridge-owned-only, dry-run-previewable,
  fail-closed). No principle removed, data-model mapping unchanged.
- Schema-validation gate repointed from a pip/venv install to `uv`, removing the
  PEP 668 externally-managed-environment dependence.
- `reconcile.sh` usage/help aligned with the documented exit codes and the
  `--all` default.
- **Engine orchestration unification (feature 003)** — internal re-platforming
  with **no operator-observable change**: the engine now drives one neutral,
  mapping-driven projection (`sync_level_artifact` + `link_to_parent`) for every
  level via a vendor-neutral level loop, and the 001-era orchestrators
  (`ensure_repo_epic` / `sync_spec_issue` / `sync_task_phase_subissues`, ~450
  lines) are removed. An enforced committed gate
  (`tests/unit/engine_vendor_neutral.bats`) keeps the engine path free of Jira
  issue-type / artifact-name / relationship knowledge, so the eventual engine
  extraction is a near-mechanical lift. Behavior is byte-for-byte identical (the
  full existing suite passes unchanged; a new full-stack non-default-shape
  zero-churn test guards the configured path).

### Fixed

- Sink now translates the configured lifecycle prefix to the neutral `phase:`
  form during the drift reshape, so the drift-read path matches the engine
  contract.
- `ensure_repo_epic` fails closed when the Epic cannot be read reliably, rather
  than risking a duplicate.
- Parser phase normalization corrected in the producer half.
- POST idempotency and feature-pin handling hardened in the foundational sink.

[Unreleased]: https://keepachangelog.com/en/1.1.0/
