# Phase 0 Research: Jira Install + Seed Ceremony

Grounds the install/seed design in the existing modules (`jira_rest.sh`,
`config.sh`, `config-template.yml`, the `commands/*.md` pattern) and the
spec-kit-linear sibling's install/seed structure, adapted to Jira REST. All three
spec forks are already pinned (REST-authoritative, seed-validates, install→seed
chain). This file records the implementation decisions.

## R1 — Install resolver module + entry shape (sk-linear parity, narrower)

- **Decision**: New `src/install.sh` with `install::main` → `install::parse_args`
  → `install::guard_source_target` → `install::dependency_report` →
  `install::resolve` → `install::write_config` → (offer) seed. Mirror sk-linear's
  `install.sh` structure (parse → self-install guard → dep report → resolve →
  write), but **much narrower**: this bridge registers **no hooks**, installs **no
  git hooks**, and ships **no GitHub Action** (per `extension.yml`), so install is
  purely *credential-verify → resolve ids → write the gitignored binding*.
- **Rationale**: Structural parity makes the two bridges legible together; the
  narrower surface reflects this bridge's operator-driven design (Principle VII is
  satisfied by the on-demand commands, not auto-hooks).
- **Alternatives**: extend `reconcile.sh` with an `--install` mode (rejected —
  reconcile is the write path; install is a separate ceremony with its own command
  body and exit semantics).

## R2 — Resolution transport: REST via `jira_rest::get` (clarify a)

- **Decision**: All durable ids are resolved via the existing
  `jira_rest::get <path>` (Basic-auth from `.env`), the same transport the sink
  uses — never the MCP for written values. Probes:
  - **project key + issue-type ids**: reuse `mapping::detect_available_types`
    (already `GET project/<key>` → `.issueTypes[] = <name>\t<id>` rows). This both
    validates the key is readable and yields the epic/story/subtask ids.
  - **statuses**: `GET project/<key>/statuses` → the statuses available on the
    project (per issue type), each `{name, id, statusCategory}`.
  - **story-points field**: `GET field` → find the story-points custom field id
    (best-effort, see R5).
- **Rationale**: FR-002 + Principle V (capture ids at resolution, no name-fallback)
  + Principle VI (`.env` only). `jira_rest::get` already handles auth, 429 backoff,
  and fail-closed rc (3 = unreadable), so install inherits the sink's transport
  contract for free.
- **MCP**: an optional interactive convenience the *command body* (agent) MAY use
  to help the operator browse projects, but the script writes only REST-derived
  ids.

## R3 — The core Jira nuance: phase→status is an operator-SEMANTIC mapping

- **Decision**: Unlike Linear (which **creates** its 9 named lifecycle states and
  owns them), Jira statuses are **operator-owned and admin-scoped** — install
  cannot create them. So install resolves `phase_status` by **mapping each of the
  6 spec-kit lifecycle phases** (`specifying`, `planning`, `tasking`,
  `implementing`, `ready_to_merge`, `merged`) **onto a status that already exists
  on the project's workflow**. Install fetches the project's statuses, proposes a
  **default mapping by `statusCategory`** (`To Do`→early phases, `In Progress`→
  `tasking`/`implementing`, `Done`→`ready_to_merge`/`merged`), and lets the
  operator confirm/adjust interactively; it then captures the **chosen status id**
  per phase.
- **Rationale**: This is the heart of why a Jira install is genuinely
  interactive — the lifecycle→status correspondence is a human decision the bridge
  cannot infer. Defaulting by `statusCategory` makes the common case one-keypress
  while keeping the operator in control (Principle VIII).
- **Non-interactive**: a `--phase-status <phase>=<statusName|id>` flag set (or a
  pre-existing config) lets CI/non-interactive runs supply the mapping; absent a
  resolvable mapping in non-interactive mode, install fails closed (exit 2) naming
  the unmapped phases.

## R4 — Transitions: leave `transitions: {}` by default (resolve at write time)

- **Decision**: Install writes `transitions: {}` (the template default). The sink
  already resolves the matching transition **by target status at write time**; an
  explicit transition id is only needed when a workflow has >1 transition reaching
  the same status. Install therefore does **not** pin transition ids in the common
  case; pinning is an advanced/optional path (a future flag), surfaced as a note
  if the workflow is detected to have ambiguous transitions.
- **Rationale**: Matches `config-template.yml`'s documented contract and keeps
  install from over-resolving. Pinning every transition would require an existing
  issue to `GET …/transitions` against, which a fresh project may not have.

## R5 — Story-points field id: optional / best-effort

- **Decision**: Resolve the story-points custom-field id via `GET field`
  (matching the standard `jsw-story-points` / "Story Points" field) **best-effort**:
  if found, record it; if absent, record it as absent with a surfaced note —
  **never fatal**. The bridge does not consume story points today (per the
  `config-template.yml` note), so a missing field must not block install.
- **Rationale**: FR partial-resolution edge case ("except where a field is
  legitimately optional"). Resolving it now means the binding is ready when a later
  feature needs it (Principle V — captured at resolution), without making it a
  hard dependency.

## R6 — Config writer: template-fill + per-line substitution, operator-block-preserving

- **Decision**: Add a deterministic config writer (new — `config.sh` has only
  readers). Approach mirrors sk-linear's `install::write_config`:
  - **Fresh**: copy `config-template.yml` → the gitignored path, then substitute
    the resolved values into the placeholder positions (`project_key: "PROJ"` →
    real, `issue_types.epic: "10001"` → real, each `phase_status.<phase>` → the
    chosen id) via **per-line awk/sed within block scope**, temp file + `mv`
    (atomic).
  - **Existing**: substitute only the resolved id fields; **preserve
    operator-authored blocks install does not own** — `mapping:`, `attribution:`,
    `remode:` (FR-012). Never reformat or reorder untouched lines.
  - **Byte-stable** (FR-008/SC-005): no timestamp/nonce; the same resolved ids
    produce an identical file, so a re-run is a visible no-op.
- **Rationale**: Per-line substitution (vs a full structured re-emit) is what
  makes operator-block preservation + byte-stability simple and is the proven
  sk-linear approach. Keeps the dep surface bash + `jq` (no `yq`).
- **Alternatives**: full structured emit from a model (rejected — would reformat
  operator blocks and risk byte-drift); `yq` round-trip (rejected — new dependency,
  and it reflows formatting).

## R7 — Seed: validate + capture, never create (clarify b)

- **Decision**: `src/seed.sh` (shares the config writer with install). Seed:
  - **validates/normalizes** the `phase:*` / `task-phase:N` label prefixes from
    `labels.*` (Jira labels auto-create on first reconcile use — seed confirms the
    prefixes are well-formed, does **not** pre-create labels);
  - **confirms reachability**: for each of the 6 `phase_status` ids in the binding,
    confirm the status exists on the project (`GET project/<key>/statuses`) and a
    representative transition reaches it; capture/confirm the ids;
  - **never** creates labels and **never** mutates the project's (admin-scoped)
    workflow statuses/transitions.
  - **Fail closed (exit 2)** naming exactly which lifecycle step's status/transition
    is unreachable, writing no partial binding.
- **Rationale**: clarify b + the Jira reality that statuses/transitions are
  admin-owned. Seed is the *trust gate* that proves the lifecycle the bridge will
  drive actually exists before the first real reconcile — a much lighter,
  validation-only counterpart to Linear's create-heavy seed.

## R8 — Exit codes + no-partial-write

- **Decision**: Reuse the reconcile contract — **exit 2** = project-level config
  error / missing inputs (no `.env` vars, unmappable phases, source==target);
  **exit 3** = Jira unreadable (auth failure, transport). Resolve everything **in
  memory first**, then write the binding **once, atomically** at the very end — so
  any failure writes **zero bytes** (FR-005/SC-003).
- **Rationale**: One operator mental model across install/seed/reconcile; the
  resolve-then-write-once shape makes "no partial binding" structural, not a
  cleanup afterthought.

## R9 — Source≠target guard (FR-007)

- **Decision**: Detect running from the bridge's own checkout (mirror sk-linear's
  `detect_self_install`: canonicalize the extension source root and the target
  repo root with `cd … && pwd -P` and compare; additionally flag when the target's
  `specs/` are the bridge's own feature specs). Halt with a clear message (exit 2)
  rather than bind the bridge to a project.
- **Rationale**: FR-007; prevents an operator running install inside the bridge
  checkout from scribbling a binding over the dev repo.

## R10 — Command bodies + manifest (clarify c)

- **Decision**: `commands/jira-install.md` + `commands/jira-seed.md` (agent-executed,
  mirror `jira-push.md` frontmatter: `name: speckit.jira.install` etc. + an
  `arguments:` block), plus the dev-layout
  `.claude/commands/speckit-jira-{install,seed}.md` twins. Register both in
  `extension.yml` `provides.commands`. The install body **offers to run seed** on
  success with a confirm (FR-013); declining leaves seed explicit.
- **Rationale**: FR-009/FR-013; the command bodies are the operator's entry point,
  consistent with how push/status ship.

## R11 — Testing (offline curl-shim) + privacy

- **Decision**: Unit/integration via `tests/helpers/jira-shim.bash` — shim the
  REST responses (`project/<key>`, `project/<key>/statuses`, `field`,
  `…/transitions`) and assert: (1) a full resolve writes a complete binding;
  (2) re-running yields a **byte-identical** file (idempotency); (3) a missing/bad
  `.env` fails closed (exit 2/3) and writes **zero bytes**; (4) seed fail-closes on
  an unreachable status naming the phase; (5) operator `mapping:`/`attribution:`
  blocks survive a re-run (FR-012). All fixtures placeholder-only; after a
  (shimmed) install writes the gitignored config, **006's consumer-side guard +
  `no-real-identifiers.bats` stay green** (the written path is gitignored).
- **Rationale**: Offline, deterministic, and proves the privacy + idempotency +
  fail-closed contracts without a live Jira.

## Resolved decisions summary

| # | Decision |
|---|---|
| R1 | `src/install.sh` mirrors sk-linear (narrower — no hooks/git-hooks/action) |
| R2 | REST via `jira_rest::get`; reuse `detect_available_types`; MCP optional only |
| R3 | phase→status is an operator-semantic interactive map (default by statusCategory) |
| R4 | `transitions: {}` default — sink resolves at write time; pinning is optional |
| R5 | story-points field id best-effort/optional, never fatal |
| R6 | template-fill + per-line substitution writer; preserve operator blocks; byte-stable |
| R7 | seed validates/captures, never creates labels or mutates the workflow |
| R8 | exit 2 (config) / 3 (Jira unreadable); resolve-in-memory then write-once atomically |
| R9 | source==target guard (canonicalized path compare) |
| R10 | command bodies + manifest registration; install offers to chain seed |
| R11 | offline curl-shim tests; idempotency + fail-closed + privacy proofs |
