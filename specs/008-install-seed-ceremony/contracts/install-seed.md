# Contract: Jira Install + Seed Ceremony

The command surface (`/speckit-jira-install`, `/speckit-jira-seed`), the resolver
scripts (`src/install.sh`, `src/seed.sh`), the new config writer
(`config::write_binding`), and the reused transport (`jira_rest::get`,
`mapping::detect_available_types`). All resolution is REST-authoritative; the
engine path is untouched (003 neutrality stays green).

## 1. Command bodies (agent-executed, mirror `commands/jira-push.md`)

### `commands/jira-install.md` — `speckit.jira.install`

- **Frontmatter**: `name: speckit.jira.install`, a one-line description, and an
  `arguments:` block: `project` (optional key), `non-interactive` (optional),
  `phase-status` (optional repeated `<phase>=<status>` for CI), `with-seed` /
  `no-seed` (optional — control the FR-013 chain).
- **Body**: export `.env`, then run `bash src/install.sh <flags>` from the consumer
  repo root; report what was resolved (project key, issue-type ids, the 6
  phase→status mappings, the story-points field or its absence) and the exit code's
  meaning (2 = config/missing inputs, 3 = Jira unreadable). On success, **offer to
  run seed** (FR-013) unless `--no-seed`.

### `commands/jira-seed.md` — `speckit.jira.seed`

- **Frontmatter**: `name: speckit.jira.seed`, description, `arguments:`:
  `dry-run` (optional).
- **Body**: export `.env`, run `bash src/seed.sh <flags>`; report the
  label-prefix validation, the per-phase status/transition reachability, and any
  fail-closed (exit 2) naming the unreachable lifecycle step.

Dev-layout twins: `.claude/commands/speckit-jira-{install,seed}.md`. Both
registered in `extension.yml` `provides.commands` alongside push/status.

## 2. `src/install.sh`

### `install::main(args…)`

Orchestration: `parse_args` → `guard_source_target` → `dependency_report` →
`resolve` → `config::write_binding` → (offer) `seed::main`. Resolves everything
**in memory** before the single write (no partial binding). Exit code via a
monotonic `install::promote_exit` (2 terminal-ish over 3 over 1, mirroring
reconcile).

### `install::guard_source_target()` (FR-007)

Canonicalize the extension source root and the target repo root (`cd … && pwd -P`)
and compare; also flag when the target `specs/` are the bridge's own. Equal ⇒
`exit 2` with a clear message, before any probe or write.

### `install::dependency_report()` (FR-004, Principle VIII)

Per-check `✓`/`⚠`/`✗`: `.env` has `JIRA_BASE_URL`/`JIRA_EMAIL`/`JIRA_API_TOKEN`
and authenticates (a `GET myself` probe via `jira_rest::get`); `jq`/`curl`/`git`
present + min version; the project key is readable. Any `✗` ⇒ fail closed with
**exact copy-paste remediation** — `exit 2` for missing local inputs/tools,
`exit 3` for an unreadable/forbidden Jira (auth/transport). Writes nothing.

### `install::resolve()` (FR-001/FR-002, Principle V)

REST-only, capture ids:
- **project + issue types**: `mapping::detect_available_types` (`GET project/<key>`
  → `.issueTypes[] = <name>\t<id>`) → `issue_types.{epic,story,subtask}` (+ task/
  initiative only if a `mapping:` level needs them).
- **phase→status** (the interactive core, R3): `GET project/<key>/statuses` →
  group by `statusCategory`; propose a default map for the 6 lifecycle phases
  (`new`→`specifying`/`planning`, `indeterminate`→`tasking`/`implementing`,
  `done`→`ready_to_merge`/`merged`); operator confirms/adjusts (or supplies
  `--phase-status` in non-interactive); capture the chosen **status id** per phase.
  An unmappable phase in non-interactive mode ⇒ `exit 2` naming it.
- **transitions**: `{}` (sink resolves at write time; R4).
- **story-points field**: `GET field` best-effort (R5); record id or absent-note,
  never fatal.

## 3. `config::write_binding(path, resolved…)` (new — `src/config.sh`)

- **Fresh path absent**: copy `config-template.yml` → the gitignored path; then
  substitute each resolved value into its placeholder position by **per-line
  awk/sed within block scope** (`project_key`, each `issue_types.*`, each
  `phase_status.*`, the story-points field), temp file + `mv` (atomic).
- **Existing**: substitute only the resolved id fields; **preserve operator blocks**
  `mapping:` / `attribution:` / `remode:` byte-for-byte (FR-012); never reorder
  untouched lines.
- **Byte-stable** (FR-008): no timestamp/nonce; identical resolved ids ⇒ identical
  file. Written ONLY to the gitignored path (FR-006); never echoes a real value
  elsewhere.

## 4. `src/seed.sh`

### `seed::main(args…)` (FR-003, clarify b)

- **Validate labels**: read `labels.{spec_prefix,repo_prefix,phase_prefix,
  lifecycle_prefix,task_prefix}`; confirm the `phase:*` / `task-phase:N` prefixes
  are well-formed/normalized. Does **not** pre-create labels (they auto-create on
  first reconcile use).
- **Confirm reachability**: for each of the 6 `phase_status` ids,
  `GET project/<key>/statuses` confirms the status exists; confirm a representative
  transition reaches it. Capture/confirm ids into the binding via
  `config::write_binding`.
- **Never** mutates the project's workflow statuses/transitions.
- **Fail closed** (`exit 2`) naming exactly which lifecycle step is unreachable;
  writes no partial binding. Idempotent: a re-run on a healthy project is a
  byte-identical no-op.

## 5. Exit-code contract (reused from reconcile)

| Code | Meaning |
|---|---|
| 0 | install/seed completed; binding written/confirmed |
| 1 | recoverable transient (429/5xx after retry) — re-run |
| 2 | project-level config error / missing inputs / source==target — halt, no partial write |
| 3 | Jira unreadable (auth/transport) — halt, no write |

(No new exit code; this reuses 2/3 exactly as reconcile defines them.)

## 6. Behavioral assertions (testable, offline curl-shim)

| ID | Assertion |
|---|---|
| C-1 | fresh repo + valid (shimmed) `.env` + project ⇒ install writes a complete binding (project_key + issue-type ids + 6 phase_status ids); `reconcile.sh --dry-run` then runs with no exit-2 config halt |
| C-2 | every written status/type/transition value is an **id**, not a name (Principle V) |
| C-3 | re-running install against the same shimmed project ⇒ **byte-identical** `jira-config.yml` |
| C-4 | a pre-existing `mapping:`/`attribution:`/`remode:` block survives a re-run byte-for-byte (FR-012) |
| C-5 | missing/blank `.env` ⇒ exit 2, names the missing vars + remediation, **zero bytes written** |
| C-6 | present but non-authenticating credential (shim 401/403) ⇒ exit 3, **zero bytes written** |
| C-7 | source==target (run from the bridge checkout) ⇒ exit 2, nothing written |
| C-8 | seed validates `phase:*`/`task-phase:N` + confirms each phase_status reachable; idempotent re-run is a byte-identical no-op |
| C-9 | seed against a project missing a required status (shim) ⇒ exit 2 naming the lifecycle step, no partial write |
| C-10 | after a (shimmed) install writes the gitignored config, the 006 guard + `no-real-identifiers.bats` stay green; the written path is gitignored |
| C-11 | story-points field absent in the shim ⇒ install still succeeds (records absent-note), exit 0 |
| C-12 | the engine neutrality gate (`engine_vendor_neutral.bats`) stays green — install/seed add no vendor vocabulary to any audited engine function |
