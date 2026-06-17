# Phase 1 Data Model: Jira Install + Seed Ceremony

No persisted engine state (Principle II). The "model" is the transient resolution
state install/seed hold in memory and the one durable artifact they produce — the
gitignored `jira-config.yml`. No backend, no sidecar (Architectural Constraints).

## Entities

### Resolution inputs (read-only)

| Input | Source | Used for |
|---|---|---|
| `JIRA_BASE_URL` / `JIRA_EMAIL` / `JIRA_API_TOKEN` | gitignored `.env` (exported by the command body) | Basic-auth transport (`jira_rest`) |
| project key | operator arg / interactive pick | the binding's `project_key`; the `GET project/<key>` probe |
| target repo root | cwd (`git rev-parse --show-toplevel`) | source≠target guard; the install target |

### Resolved binding fields (the output — written to `jira-config.yml`)

| Field | Resolved from | Required? |
|---|---|---|
| `project_key` | operator pick / arg, validated by `GET project/<key>` | yes |
| `issue_types.{epic,story,subtask}` | `GET project/<key>` `.issueTypes[]` (via `detect_available_types`) | yes (per mapped level) |
| `issue_types.{task,initiative}` | same | only if a `mapping:` level projects them |
| `phase_status.<phase>` (×6) | operator maps each lifecycle phase → a project status id (`GET project/<key>/statuses`, default by `statusCategory`) | yes |
| `transitions` | `{}` (sink resolves by target status at write time) | no (advanced pinning optional) |
| `story_points_field_id` | `GET field` (best-effort) | no (recorded absent with a note) |
| `labels.*` | template defaults (operator-chosen prefixes) | yes (carried from template) |
| `mapping:` / `attribution:` / `remode:` | operator-authored — **preserved, never owned by install** | n/a |

The 6 lifecycle phases are exactly: `specifying`, `planning`, `tasking`,
`implementing`, `ready_to_merge`, `merged` (matching `config-template.yml`'s
`phase_status`).

### Project status (probe result, transient)

`GET project/<key>/statuses` → per issue type, a list of
`{ name, id, statusCategory.key ∈ {new, indeterminate, done} }`. Install groups
by `statusCategory` to propose the default phase→status mapping; seed uses it to
confirm each configured `phase_status` id still exists.

### Lifecycle mapping (the seed trust gate)

The set of `(lifecycle phase → status id → reachable transition)` triples. Seed
confirms every triple is reachable on the project's workflow; an unreachable
triple is a fail-closed (exit 2) naming that phase.

### Dependency report (transient, surfaced)

Per-check rows (`.env` present + authenticates via a `myself` probe;
`jq`/`curl`/`git` present + min version; project key readable; MCP reachable if
used) → `✓`/`⚠`/`✗`. Any `✗` ⇒ fail closed before any resolution, with exact
remediation (Principle VIII).

## Interfaces (the seam — see contracts/install-seed.md)

| Function | Module | Responsibility |
|---|---|---|
| `install::main` | `src/install.sh` | orchestrate: guard → dep-report → resolve → write → offer-seed |
| `install::guard_source_target` | `src/install.sh` | FR-007 source==target halt (exit 2) |
| `install::dependency_report` | `src/install.sh` | FR-004 verify deps + auth (`myself`), exact remediation, exit 2/3 |
| `install::resolve` | `src/install.sh` | REST-resolve project/issue-types/phase_status/field into memory |
| `config::write_binding` | `src/config.sh` (new writer) | template-fill + per-line substitution; preserve operator blocks; byte-stable atomic write |
| `seed::main` | `src/seed.sh` | validate labels + confirm lifecycle reachability + capture; fail closed (exit 2) |
| `jira_rest::get` | `src/jira_rest.sh` (existing) | the GET transport (reused) |
| `mapping::detect_available_types` | `src/config.sh` (existing) | issue-type id probe (reused) |

## Validation rules

- **VR-1 (FR-001/SC-001)**: a successful install writes a complete binding
  (`project_key` + issue-type ids for every mapped level + 6 `phase_status` ids);
  `reconcile.sh --dry-run` then runs without an exit-2 config halt.
- **VR-2 (FR-002/Principle V)**: every written status/transition/type value is an
  **id** captured at resolution — never a display name to be re-looked-up.
- **VR-3 (FR-005/SC-003)**: any failure (missing `.env`, unmappable phase,
  unreadable Jira) writes **zero bytes** — resolve-in-memory then write-once.
  Missing inputs ⇒ exit 2; unreadable Jira ⇒ exit 3.
- **VR-4 (FR-006/SC-004)**: the binding is written ONLY to the gitignored
  `jira-config.yml`; no real coordinate enters a tracked file/commit/captured log;
  after install, 006's guard + `no-real-identifiers.bats` stay green.
- **VR-5 (FR-008/SC-005)**: re-resolving the same project yields a byte-identical
  binding (stable key order, no nonce) — a visible no-op.
- **VR-6 (FR-012)**: a re-run preserves operator-authored `mapping:` /
  `attribution:` / `remode:` blocks byte-for-byte; only the resolved id fields are
  rewritten.
- **VR-7 (FR-003/SC-002)**: seed validates the `phase:*`/`task-phase:N` prefixes
  and confirms every lifecycle status+transition is reachable; idempotent on
  re-run; never creates labels or mutates the workflow.
- **VR-8 (FR-007)**: running from the bridge's own checkout halts (exit 2) before
  writing anything.
- **VR-9 (FR-011/SC-007)**: install/seed touch only the sink/config surface; the
  engine path is unchanged — the 003 neutrality gate stays green.
