# Implementation Plan: Configurable Artifact Mapping

**Branch**: `002-configurable-mapping` | **Date**: 2026-06-03 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-configurable-mapping/spec.md`

## Summary

Extend the shipped 001 core bridge with an operator-configurable artifact-mapping
layer that lives entirely in the Jira sink + config — the vendor-neutral reconcile
engine is untouched. A back-compat **alias layer** keeps today's
repo→Epic / spec→Story / phase→Subtask / task→checklist behavior as the **frozen
zero-config default**; new opt-in levers add per-level issue-type + relationship
mapping (validated against the project's **detected available issue types**), a
**2-level checklist mode**, an off-by-default **status rollup**, an off-by-default
**Initiative super-level** that degrades gracefully, and a **workstate-direct input
seam** (`--workstate`). Idempotent / drift-aware / fail-closed hold in every mode.

## Technical Context

**Language/Version**: Bash (CI matrix: bash 4.4 + 5.2)

**Primary Dependencies**: `jq` (JSON), `curl` (Jira Cloud REST v3), the published
`workstate` schema (Draft 2020-12) — **no new runtime dependencies**

**Storage**: gitignored `.specify/extensions/jira/jira-config.yml` (binding + the
new `mapping:` block) and `.env` (credentials); no database

**Testing**: `bats` (unit + integration) over the curl-shim mock; `shellcheck
--severity=style`; `yamllint -d relaxed`; `markdownlint-cli2`; `workstate` schema
validation

**Target Platform**: macOS + Linux (CI: ubuntu + macos)

**Project Type**: single-project CLI / reconcile sync engine

**Performance Goals**: not latency-bound — correctness-bound; zero-churn idempotent
re-runs in every mode; all config validation completes before any write

**Constraints**: idempotent + drift-aware + fail-closed in ALL modes
(constitutional); engine stays vendor-neutral (mapping/detection/validation in
sink + config only); Privacy IX (no real coordinates in tracked files);
back-compat (pre-feature configs unchanged, byte-for-byte)

**Scale/Scope**: per-repo, a single Jira project per run; tens of specs/phases; up
to 5 mapping levels (initiative / repo / spec / phase / task)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

All ten principles hold; feature-002 is **additive** and preserves the
differentiator. No violations.

| Principle | Verdict | Why |
|---|---|---|
| I Filesystem source of truth · II Reconcile · IV Drift-aware | PASS | Directionality unchanged (Jira stays a read-only mirror); `spec→Story` remains the backward-drift anchor even with the Initiative super-level on. |
| III Layered idempotency | PASS | FR-008/FR-012 require zero-churn re-runs in EVERY mode (2-level checklist byte-identical via keyed sub-tree diff; rollup transitions only on changed completion). The headline gate. |
| V Per-repo config · VI Creds at edges | PASS | The `mapping:` block is additive in the gitignored config; no credentials in config. |
| VII Memory-just-works | PASS | Identity stays filesystem-derived via labels (adds a task-identity prefix for Task-projected levels). |
| VIII Surface, don't enforce | PASS | Config validation (available-type, relationship matrix) fails closed and surfaces a workspace-level error before any write. |
| IX Privacy | PASS | Placeholders only (FR-019). |
| X workstate is the internal contract | **STRENGTHENED** | The `--workstate` direct-input seam exposes workstate as a first-class input (FR-015/016). |
| Architectural constraint: engine vendor-neutral | PASS | FR-018 keeps all mapping/Jira logic in the sink + config; the engine half of `reconcile.sh` is untouched except the input-seam arg. |

**Post-design re-check (after Phase 1)**: the data model + contracts keep mapping
logic in `config.sh`/`jira_sink.sh` and the input seam in the entrypoint —
re-evaluated PASS, no new violations introduced.

## Project Structure

### Documentation (this feature)

```text
specs/002-configurable-mapping/
├── plan.md          # this file
├── research.md      # Phase 0 — resolved clarify questions (Q2–Q11) + tech decisions
├── data-model.md    # Phase 1 — mapping config schema, entities, validation matrix
├── quickstart.md    # Phase 1 — operator guide (modes, validation, workstate-direct)
├── contracts/       # Phase 1 — mapping-config, --workstate CLI, engine↔sink additions
├── DESIGN-DRAFT.md  # pre-spec design note (source)
├── checklists/requirements.md
└── tasks.md         # Phase 2 (/speckit-tasks — NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
src/
├── config.sh        # + parse the `mapping:` block; alias-layer default synthesis;
│                    #   relationship-validation matrix; available-issue-type
│                    #   detection + validation (fail-closed at config-load)
├── jira_sink.sh     # + mapping-driven artifact projection; 2-level checklist
│                    #   render (keyed sub-tree diff); status-rollup transitions;
│                    #   Initiative super-level + graceful degradation
├── adf.sh           # + 2-level checklist body render with an isolated, byte-stable
│                    #   sub-tree for zero-churn re-render
├── reconcile.sh     # + `--workstate <file|->` input seam, schema-validated on
│                    #   entry (vendor-neutral entrypoint concern only)
├── workstate.sh     # + workstate-direct ingestion/validation; task-identity label
└── git_helpers.sh, summary.sh   # unchanged

tests/
├── unit/            # mapping parse + alias equivalence; available-type detection;
│                    #   relationship matrix; 2-level keying; rollup idempotency;
│                    #   workstate-direct entry validation
└── integration/     # default-equivalence (US1); 3-level; 2-level zero-churn;
                     #   absent-type fail-closed; rollup; initiative degrade;
                     #   workstate-direct == specs-tree projection
```

**Structure Decision**: A single-project **extension** of 001 — no new modules. The
mapping layer threads through the existing `config.sh` (parse + alias + validation)
and `jira_sink.sh` (projection + render + rollup + initiative), with the
`--workstate` seam in the `reconcile.sh` entrypoint and `workstate.sh`. The
vendor-neutral engine half of `reconcile.sh` is untouched except for accepting the
new input source.

## Complexity Tracking

> No constitution violations — this section is intentionally empty.
