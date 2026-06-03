# Implementation Plan: Core Bridge — Mirror spec-kit Specs into Jira

**Branch**: `001-core-bridge` | **Date**: 2026-05-31 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-core-bridge/spec.md`

## Summary

Mirror a spec-kit repository's specs into Jira via a single idempotent,
drift-aware, fail-closed reconcile (Layer D). The **parser** reads
`specs/NNN-*/` and emits schema-valid `workstate` JSON; the vendor-neutral
**engine** (copied from the sibling spec-kit-linear) computes drift/recency and
orchestrates writes through a fixed interface; a from-scratch **jira-sink**
implements that interface against the Jira Cloud REST API. The repo's specs are
grouped under a single per-repository **Epic**; each spec is a **Story**; each
task phase is a **Subtask**. This feature is also the independent second
consumer that proves the `workstate` contract.

## Technical Context

**Language/Version**: Bash 4.4+ (engine + sink + parser are pure bash, mirroring
the sibling tool).

**Primary Dependencies**: `curl`, `jq`, `git`, `gh` (runtime tools, as the
sibling). Dev/CI only: `python3` + `jsonschema` (authoritative `workstate`
Draft-2020-12 validation), `bats-core` (tests), `shellcheck`, `yamllint`,
`markdownlint-cli2`.

**Storage**: Files only. On-disk specs are the source of truth; the resolved
per-repo binding (`.specify/extensions/jira/jira-config.yml`) and the credential
(`.env`) are **gitignored**. No database, no daemon.

**Testing**: `bats` unit + integration. Jira REST is mocked via a **curl-shim**
(shadow `curl` with a stub returning fixture JSON keyed by method+URL) — no live
instance in unit/CI. `workstate` output is validated against the published
schema as a test gate. Integration tests gated on `RUN_INTEGRATION_TESTS=1`.

**Target Platform**: macOS + Linux; CI matrix bash 4.4 / 5.2 × ubuntu / macos
(inherited CI).

**Project Type**: CLI / spec-kit extension (bridge tool).

**Performance Goals**: Reconcile a repo of dozens of specs in seconds plus
network time; bounded, polite API usage (respect rate limits).

**Constraints**: Engine stays vendor-neutral (Jira specifics only in sink +
config); idempotent (zero churn on unchanged input); fail-closed on unreadable
Jira; offline-mockable tests; **no real Jira coordinates/PII in any tracked
file** (privacy guard gates CI).

**Scale/Scope**: Dozens of specs per repo → one Epic + N Stories + per-phase
Subtasks; hundreds of issues per project at most.

## Constitution Check

*GATE: must pass before Phase 0 and re-checked after Phase 1.*

| # | Principle | Compliance in this plan | Gate |
|---|-----------|-------------------------|------|
| I | Filesystem is source of truth | Reconcile writes ONLY to Jira; never to the filesystem (FR-019). | ✅ |
| II | Reconcile, never event-push | One reconcile path; identity from filesystem-evident keys (labels), no sidecar cache (FR-004, FR-008). | ✅ |
| III | Layered idempotency (D+E) | This feature is **Layer D only**; Layer E (Action) is explicitly out of scope. Layer boundaries preserved. | ✅ |
| IV | Drift-aware write-authority | Engine's drift/recency/disposition copied unchanged; surfaced not enforced (FR-009..011). | ✅ |
| V | ID-based binding, per-repo config | Sink consumes a resolved gitignored `jira-config.yml` (ids, status/transition map). Producing it (seed/install) is a later feature — this one only consumes. | ✅ (consume-only) |
| VI | Credentials at the edges | Basic auth from gitignored `.env` (FR-017); never tracked. | ✅ |
| VII | Memory-just-works | The reconcile command is the path hooks will call; hook auto-registration is install (later feature). No conflict. | ✅ (deferred) |
| VIII | Surface, don't enforce | Structured summary + named warnings + fail-closed (FR-013..015). | ✅ |
| IX | No real identifiers in tree | All fixtures/docs use placeholders; privacy guard gates CI (FR-018, SC-006). | ✅ |
| X | workstate is the contract | Parser produces schema-valid `workstate`; sink consumes only it; unknown `extensions` ignored (FR-003, FR-020). | ✅ |

**Result**: PASS, no violations. Complexity Tracking is empty.

Two boundary notes (not violations): (a) Principle V's binding is *consumed*,
not produced, here — the seed/install feature produces it; this plan assumes a
valid binding exists. (b) The per-repo Epic (clarified hierarchy) is a
**sink-side projection** of `workstate.source.repo`, not a new `workstate`
item — the floor schema sufficed unchanged (a positive Principle X signal).

## Project Structure

### Documentation (this feature)

```text
specs/001-core-bridge/
├── plan.md              # This file
├── research.md          # Phase 0 — decisions (engine seam, ADF, idempotency keys, 429, mock)
├── data-model.md        # Phase 1 — workstate↔Jira mapping, config shape, entities
├── quickstart.md        # Phase 1 — run reconcile (dry-run first), run tests
├── contracts/
│   ├── cli.md           # reconcile CLI surface (flags, exit codes)
│   ├── engine-sink-interface.md  # the functions the sink MUST expose to the engine
│   ├── jira-rest.md     # Jira REST endpoints touched + auth + 429 policy
│   └── workstate.md     # the consumed workstate fields (floor subset)
└── tasks.md             # Phase 2 (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
src/
├── parser.sh            # REUSE from sibling, adapted to EMIT workstate JSON
├── workstate.sh         # FRESH — build/validate workstate items from parsed specs
├── git_helpers.sh       # COPY unchanged (origin header) — recency/drift git infra
├── summary.sh           # COPY unchanged (origin header) — structured run summary
├── config.sh            # ADAPT — load/validate gitignored jira-config.yml (Jira fields)
├── reconcile.sh         # COPY the ENGINE half — drift/recency/disposition/lifecycle
│                        #   + orchestration; writer calls go through the interface
├── jira_sink.sh         # FRESH — implements the engine↔writer interface vs REST
│                        #   (mutate_issue_create/update, query_*, sync_*, label/epic)
├── jira_rest.sh         # FRESH — thin curl+jq REST client: Basic auth, 429 backoff,
│                        #   fail-closed read; ADF body rendering helpers
└── adf.sh               # FRESH — minimal Markdown→ADF (paragraphs, lists, taskList,
                         #   code, links, truncation)

tests/
├── unit/                # bats: parser, workstate, config, summary, drift engine,
│                        #   jira_sink (against curl-shim), adf, no-real-identifiers
├── integration/         # bats: end-to-end reconcile over the curl-shim mock
│                        #   (fresh / idempotent re-run / drift / fail-closed)
└── fixtures/
    ├── specs/           # sample spec dirs (placeholder content)
    ├── workstate/       # expected workstate JSON per fixture spec
    └── jira_responses/  # mocked REST responses keyed by method+URL
```

**Structure Decision**: Single-project CLI layout mirroring the sibling's
`src/` + `tests/{unit,integration,fixtures}`. The decisive boundary is
**engine vs sink**: `reconcile.sh` (copied engine) calls a fixed set of
`mutate_*` / `query_*` / `sync_*` functions that `jira_sink.sh` (fresh)
provides — the same seam proven in the sibling, re-implemented against REST.
`config::get_status_transition` is the single vendor lever (phase → Jira status
+ transition id). This separation is what lets the engine be extracted into a
shared package later (PLAN.md §11 debt).

## Complexity Tracking

> No Constitution Check violations — this section is intentionally empty.
