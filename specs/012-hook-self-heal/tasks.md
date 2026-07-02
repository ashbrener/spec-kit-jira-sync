---

description: "TDD task list — feature 012 hook self-healing"
---

# Tasks: Hook Self-Healing — Detect + Repair Stripped Auto-Sync Hooks

**Input**: Design documents from `/specs/012-hook-self-heal/`

**Prerequisites**: plan.md, spec.md, research.md (R1-R9), data-model.md
(E1-E3 / VR-1..VR-11), contracts/hookcheck-integration.md (C-1..C-12)

**Tests**: TDD — every test task precedes its implementation task and MUST fail
first (red → green). All tests are **pure-filesystem bats** (NO curl-shim; no
Jira). Reference implementation: the Linear sibling's `src/hookcheck.sh` +
`tests/unit/hookcheck.bats` + `tests/unit/hookcheck_selfheal.bats` +
`tests/helpers/hookcheck_fixtures.bash` (mirror verbatim; only vendor tokens
change — extension id `jira`, command `speckit.jira.push`, remediation
`/speckit-jira-install`).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on incomplete work)
- **[Story]**: US1 (warn) / US2 (status line) / US3 (consented heal)

## Path Conventions

Single project — `src/`, `tests/` at repository root (per plan.md Structure Decision).

---

## Phase 1: Setup — GATING include-guards (blocks the self-heal)

**Purpose**: The consented self-heal (`offer_selfheal`) sources `install.sh`,
which re-sources `config.sh` + `jira_rest.sh` (both carry `readonly`) after
`reconcile.sh` already loaded `config.sh`/`summary.sh` → a `readonly` double-declare
crash without include-guards. This phase MUST complete before Phase 5 (US3).

- [X] T001 [P] Write `tests/unit/include_guards.bats` (RED): sourcing each shared
  lib twice in one shell is a clean no-op (no "readonly: already declared" / no
  non-zero rc); plus an assertion that `source src/config.sh; source
  src/summary.sh; source src/install.sh` (install.sh AFTER reconcile's libs)
  succeeds — the exact heal-time source order.
- [X] T002 [P] Add the include-guard idiom
  (`[[ -n "${_CONFIG_SH_LOADED:-}" ]] && return 0; readonly _CONFIG_SH_LOADED=1`,
  right after the shebang/`set` line, before the first `readonly`) to `src/config.sh`.
- [X] T003 [P] Add the include-guard (`_JIRA_REST_SH_LOADED`) to `src/jira_rest.sh`.
- [X] T004 [P] Add the include-guard (`_INSTALL_SH_LOADED`) to `src/install.sh`
  (after its `set` line, before its `source` block + first `readonly`).
- [X] T005 [P] Add the include-guard uniformly to the remaining shared libs:
  `_SUMMARY_SH_LOADED` (`src/summary.sh`), `_GIT_HELPERS_SH_LOADED`
  (`src/git_helpers.sh`), `_PARSER_SH_LOADED` (`src/parser.sh`),
  `_WORKSTATE_SH_LOADED` (`src/workstate.sh`), `_JIRA_SINK_SH_LOADED`
  (`src/jira_sink.sh`), `_PRIVACY_GUARD_SH_LOADED` (`src/privacy_guard.sh`),
  `_ADF_SH_LOADED` (`src/adf.sh`). Do NOT touch `src/reconcile.sh` (entrypoint —
  nothing sources it).
- [X] T006 Run `tests/unit/include_guards.bats` (GREEN) + `shellcheck
  --severity=style src/*.sh` clean; confirm the full existing bats suite still
  passes (guards are transparent to single-source callers).

**Checkpoint**: every shared lib is safe to source twice → the heal can source
`install.sh` without crashing.

---

## Phase 2: Foundational — `src/hookcheck.sh` module (blocks US1/US2/US3)

**Purpose**: the shared detect/classify/warn/status/heal module. One file serves
all three stories. TDD — write the fixtures helper + failing tests, then the module.

- [ ] T007 [P] Write `tests/helpers/hookcheck_fixtures.bash` — placeholder-only
  `.specify/extensions.yml` fixture builders (all-present / partial / none /
  disabled / git-sibling / no-`hooks:`-key / malformed), mirroring Linear's helper.
  NO real Jira coordinate (extension id `jira`, command `speckit.jira.push`,
  placeholder prompts only).
- [ ] T008 [P] Write `tests/unit/hookcheck.bats` (RED) — the detect/report surface,
  mirroring Linear's 16 cases adapted to `jira`:
  - **C-2 classify**: registered-enabled → `present`; `enabled:false` → `disabled`;
    no `jira` entry → `absent`; a git sibling's `enabled:false` does NOT make jira
    disabled; a git-only block → jira `absent`; unreadable file → rc 2.
  - **C-3 assess_into**: all six → `present`/no missing; 3+3 → `partial` naming the
    absent; none → `none`; a disabled hook → `present` + listed disabled; readable
    but no `hooks:` key → `unverifiable` (not `none`); absent file → `not_installed`;
    always exits 0 even when unverifiable.
  - **C-5 status_line**: partial names missing + `/speckit-jira-install`; none →
    "none registered" + remediation; present → "all present"; unverifiable →
    "could not verify".
  - **VR-10 pin**: `HOOKCHECK_AFTER_HOOK_NAMES` is identical to install's
    `INSTALL_AFTER_HOOK_NAMES`.
- [ ] T009 [P] Write `tests/unit/hookcheck_selfheal.bats` (RED) — warn + consent,
  mirroring Linear's 9 cases adapted to `jira`:
  - **C-4 warn_once**: emits ONE `summary::add warned` (named) for partial; latched
    — a second call in the same run is silent; `present`/`not_installed` emit
    nothing; `unverifiable` emits one `info` row (not a warning).
  - **C-6/C-8 offer_selfheal**: forced-interactive + `y` (via `HOOKCHECK_TTY_IN`
    file) re-registers ALL missing hooks at once (assert `.specify/extensions.yml`);
    `n` and empty (default No) decline — no mutation; non-interactive never prompts
    and never mutates; nothing-missing (`present`) → no offer regardless of tty;
    `enabled:false` preserved through a heal.
  - **C-7 `_ensure_install_sourced`**: no-ops when a stub
    `install::register_after_hooks` is predefined (avoids the heavy source).
- [ ] T010 Create `src/hookcheck.sh` (GREEN) — port Linear's module verbatim, only
  vendor tokens changed. Include-guard `_HOOKCHECK_SH_LOADED`; `readonly -a
  HOOKCHECK_AFTER_HOOK_NAMES` (the six, == install's); `HOOKCHECK_EXTENSIONS_YML`
  default `.specify/extensions.yml`; globals `HOOKCHECK_OVERALL/_MISSING[]/_DISABLED[]`.
  Implement per contract C-1..C-9: `classify`, `assess_into`, `assess`, `warn_once`
  (reuse the `_RECONCILE_HOOKS_WARNED` latch), `status_line`, `_is_interactive`
  (`HOOKCHECK_FORCE_INTERACTIVE`/`_NONINTERACTIVE` seams + `[[ -t 0 ]]`),
  `_read_consent` (`HOOKCHECK_TTY` sink / `HOOKCHECK_TTY_IN` source, default
  `/dev/tty`), `_ensure_install_sourced` (guarded lazy source; skip if the writer
  is already defined), `offer_selfheal`, `reconcile_check`. The `classify` awk walk
  mirrors 011's `install::_hook_already_registered` grammar (FR-007). Make T008 +
  T009 pass.
- [ ] T011 `shellcheck --severity=style src/hookcheck.sh` clean; run T008 + T009
  GREEN. (BSD-awk-safe — no multi-line `awk -v`.)

**Checkpoint**: the module detects, reports, warns, and (interactively) heals in
isolation — fully unit-tested with no Jira.

---

## Phase 3: US1 — A stripped hook set is loud, not silent (Priority: P1) 🎯 MVP

**Goal**: on a real push, missing hooks produce ONE named warning; the reconcile
still completes and keeps its exit disposition.

**Independent test**: hooks absent → run a (non-dry-run) reconcile that reaches
`main` → exactly one warning names the absent hooks + `/speckit-jira-install`, and
the reconcile's own exit is unchanged.

- [ ] T012 [US1] Write `tests/unit/reconcile_hookcheck.bats` (RED) — the push
  branch (C-10/C-11): with `HOOKCHECK_EXTENSIONS_YML` pointed at a partial fixture
  and `DRY_RUN=0`, `hookcheck::reconcile_check` emits the `warned` row (named);
  latched to once; non-blocking — it neither calls `summary::add error` nor changes
  `RECONCILE_EXIT_CODE`.
- [ ] T013 [US1] Wire the module into `src/reconcile.sh`: add `source
  "${SCRIPT_DIR}/hookcheck.sh"` beside the other source lines; add
  `hookcheck::reconcile_check || true` in `reconcile::main` immediately BEFORE the
  final `summary::emit` (~line 3066). Implement `hookcheck::reconcile_check` to
  branch on `${DRY_RUN:-0}`: non-dry-run → `warn_once` (this story). Make T012
  (push branch) pass.

**Checkpoint**: US1 delivers — a stripped set warns loudly on push, non-blocking.

---

## Phase 4: US2 — Status reports hook health as a first-class line (Priority: P1)

**Goal**: `speckit.jira.status` (`reconcile --dry-run`) reports hook health as a
first-class line in every state and ALWAYS exits 0.

**Independent test**: all present → "all present"; some absent → names the missing;
every case exits 0.

- [ ] T014 [US2] Extend `tests/unit/reconcile_hookcheck.bats` (RED) — the dry-run
  branch (C-10/C-11): with `DRY_RUN=1`, `hookcheck::reconcile_check` emits the
  first-class status line via `summary::add info "$(hookcheck::status_line …)"` in
  all states (present/partial/none/unverifiable/not_installed), and the run stays
  exit 0 (status health never changes the exit code).
- [ ] T015 [US2] Complete the `${DRY_RUN:-0}` branch in
  `hookcheck::reconcile_check` (in `src/hookcheck.sh`): dry-run → `summary::add
  info "$(hookcheck::status_line "$HOOKCHECK_OVERALL" "${HOOKCHECK_MISSING[@]}" --
  "${HOOKCHECK_DISABLED[@]}")"`. Make T014 pass. Confirm status exit-0 invariant.

**Checkpoint**: US2 delivers — status shows a first-class hook-health line, exit 0.

---

## Phase 5: US3 — Consented one-step repair (Priority: P2)

**Goal**: when hooks are missing and the session has a REAL controlling TTY, push
and status offer a single y/N (default No) to re-register ALL missing hooks at once,
reusing 011's idempotent registrar; non-interactive never prompts or mutates.

**Independent test**: forced-interactive + `y` → all missing re-registered (verify
the file); `n`/empty → untouched; non-interactive → warn-only, no mutation.
(Depends on Phase 1 include-guards.)

- [ ] T016 [US3] Extend `tests/unit/reconcile_hookcheck.bats` (RED): both branches
  call `hookcheck::offer_selfheal` after the warn/status-line; forced-interactive +
  `y` (real registrar, guarded source) mutates the fixture to re-register all
  missing; non-interactive leaves it untouched; the offer never changes
  `RECONCILE_EXIT_CODE`.
- [ ] T017 [US3] Confirm `hookcheck::reconcile_check` calls `hookcheck::offer_selfheal
  "$HOOKCHECK_OVERALL" "${HOOKCHECK_MISSING[@]}"` on BOTH branches (already sketched
  in T010); verify the guarded `_ensure_install_sourced` → `install::register_after_hooks`
  path works end-to-end against the Phase-1 guards (no readonly crash). Make T016 pass.

**Checkpoint**: US3 delivers — one-keystroke repair at a real terminal; safe in CI.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T018 [P] Verify `tests/unit/engine_vendor_neutral.bats` stays GREEN (C-12):
  `hookcheck::*` + `reconcile::main` are outside the audited `reconcile::*` list;
  confirm NO vendor token was added to any enumerated engine function.
- [ ] T019 [P] Extend `tests/unit/no-real-identifiers.bats` (C-9) to scan the new
  `tests/fixtures/extensions/*` fixtures (if any materialised) +
  `tests/helpers/hookcheck_fixtures.bash` + `src/hookcheck.sh` — placeholder-only,
  no real coordinate. Run it GREEN.
- [ ] T020 [P] Docs (FR-012): add a crisp note to the README recovery section +
  `commands/jira-push.md` (and the `.claude/commands/` twin) that `specify
  extension add jira --from <zip> --force` strips the `after_*` hooks, and the
  restore path is `/speckit-jira-install` (or the interactive self-heal offer).
- [ ] T021 [P] Add a `CHANGELOG.md` `[Unreleased]` → Added line: "hook
  self-healing — the bridge self-reports stripped auto-sync hooks and offers a
  consented one-step re-register (spec 012)".
- [ ] T022 Full CI gate locally: `shellcheck --severity=style src/*.sh` (incl.
  `hookcheck.sh`), `yamllint -d relaxed` (extension.yml + ci.yml), `npx
  markdownlint-cli2 "specs/**/*.md" "*.md"`, and the FULL `bats --recursive
  tests/unit` (BSD-awk-safe; macOS + Linux parity). All green.
- [ ] T023 Open a PR into `main` from `012-hook-self-heal` (do NOT merge — the
  operator merges). Body: the strip→detect→heal story, cross-sink parity with
  Linear spec-014, the guarantees (non-blocking, consent-only mutation, no Jira
  write, status exit-0), and the neutrality/privacy gates green.

---

## Dependencies & Execution Order

- **Phase 1 (include-guards)** — GATING for Phase 5 (the heal sources install.sh).
  T001 [P] first (RED), then T002-T005 [P] (disjoint files), then T006 (verify).
- **Phase 2 (module)** — blocks US1/US2/US3. T007-T009 [P] (RED, disjoint test
  files), then T010 (module), T011 (verify).
- **US1 (Phase 3)** → **US2 (Phase 4)** share `reconcile.sh` + `reconcile_check`
  (same files) → sequential. US1 is the MVP.
- **US3 (Phase 5)** needs Phase 1 + Phase 2 + the wiring from US1/US2.
- **Phase 6** after the stories; T018-T021 [P] (disjoint), T022 (gate), T023 (PR).

## Parallel Opportunities

- Phase 1: T001, T002, T003, T004, T005 all [P] (disjoint files).
- Phase 2: T007, T008, T009 all [P] (three disjoint test/helper files) before T010.
- Phase 6: T018, T019, T020, T021 all [P].

## Implementation Strategy

**MVP = Phase 1 + Phase 2 + US1** (loud warning on a stripped set). US2 (status
line) and US3 (consented heal) layer on incrementally; each is independently
testable. Ship order: guards → module → warn (US1) → status line (US2) → heal (US3)
→ polish/PR.
