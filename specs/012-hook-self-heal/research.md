# Phase 0 Research: Hook Self-Healing (port of Linear spec-014)

Detect + repair the stripped `after_*` auto-sync hooks. Sink/config-side; the
vendor-neutral reconcile engine is untouched (003 gate green). Grounded in the
Linear sibling's shipped `src/hookcheck.sh` — this repo mirrors its mechanism so
the two sinks stay at parity and 011's registrar (already mirrored from Linear) is
the shared notion of "registered".

## R1 — Module shape: a new `src/hookcheck.sh` (mirror Linear exactly)

- **Decision**: create `src/hookcheck.sh` exposing the Linear namespace verbatim:
  `hookcheck::classify`, `assess_into`, `assess`, `warn_once`, `status_line`,
  `_is_interactive`, `_read_consent`, `_ensure_install_sourced`, `offer_selfheal`,
  `reconcile_check`. Only the vendor tokens change: extension id `linear`→`jira`,
  command `speckit.linear.push`→`speckit.jira.push`, `speckit.linear.install`→
  `/speckit-jira-install`, and the `_RECONCILE_HOOKS_WARNED` latch name is reused
  as-is (jira's reconcile already uses `_RECONCILE_*_WARNED` latches).
- **Rationale**: FR-001/002/006/007/009/010/011. A faithful port minimises risk and
  guarantees cross-sink parity. `classify`'s awk walk mirrors 011's
  `install::_hook_already_registered` block grammar (enter on `^  <hook>:`, leave
  on the next 2-space key, track each `- extension:` entry's name + `enabled:`) so
  detection and repair agree on "present" (FR-007).

## R2 — The six hook names must not drift from 011

- **Decision**: `readonly -a HOOKCHECK_AFTER_HOOK_NAMES=(after_specify after_clarify
  after_plan after_tasks after_implement after_analyze)` — identical to
  `install.sh`'s `INSTALL_AFTER_HOOK_NAMES`. A pin test asserts the two arrays are
  equal so a future divergence fails CI (mirrors Linear's pin test).
- **Rationale**: FR-007 — detection and the registrar must enumerate the same set.

## R3 — jira-specific wiring: ONE check in `reconcile::main`, branch on `--dry-run`

- **Finding**: Linear has two entrypoints — `src/status.sh` calls `assess_into` +
  `status_line` + `offer_selfheal`; `src/reconcile.sh` calls `reconcile_check`
  (assess → warn_once → offer_selfheal). jira has **no `src/status.sh`**;
  `speckit.jira.status` is `reconcile.sh --dry-run` (`ARG_DRY_RUN=1` / `DRY_RUN=1`).
- **Decision**: `hookcheck::reconcile_check` branches on the dry-run flag:
  - `assess_into`
  - if `${DRY_RUN:-0}` == 1 (status): emit the first-class health line via
    `summary::add info "$(hookcheck::status_line …)"` (FR-006);
  - else (real push): `hookcheck::warn_once` (FR-002, latched);
  - both paths then `hookcheck::offer_selfheal` (FR-009).
  Wire a single `hookcheck::reconcile_check || true` into `reconcile::main` just
  **before** `summary::emit` (reconcile.sh ~line 3066), so the health surfaces in
  the same structured summary and can never alter the run's exit disposition.
- **Rationale**: FR-003/006 + the spec's clarified jira resolution. One wiring,
  both surfaces; the `|| true` guarantees non-blocking even if the check itself
  errored. Status keeps exit 0 because `status_line`/`info` never call
  `summary::add error` and never touch `RECONCILE_EXIT_CODE`.

## R4 — Interactivity = REAL controlling TTY only (the clarified decision)

- **Finding**: jira's slash commands (`/speckit-jira-push`, `/speckit-jira-status`)
  run `reconcile.sh` via the **agent's Bash tool, which has no controlling TTY**.
  So the y/N self-heal reaches an operator ONLY when they run `reconcile.sh`
  directly in a terminal.
- **Decision**: `_is_interactive` gates on `[[ -t 0 ]]` with the
  `HOOKCHECK_FORCE_INTERACTIVE` / `HOOKCHECK_FORCE_NONINTERACTIVE` overrides;
  `_read_consent` reads the answer from the controlling terminal (`/dev/tty`),
  with `HOOKCHECK_TTY` (prompt sink) + `HOOKCHECK_TTY_IN` (answer source) test
  seams so the prompt write cannot truncate a file-backed test answer. The
  slash-command / hook-fired / CI paths are therefore **warn-only**, remediation
  `/speckit-jira-install`.
- **Rationale**: FR-009 + the clarified spec decision (2026-06-29). Keeps the
  consent path honestly testable offline and never surprises automation.

## R5 — Self-heal reuses 011's registrar; the include-guard hazard is REAL

- **Finding**: `reconcile.sh` sources `config.sh` + `summary.sh` (+ others) at
  startup. `install.sh` **re-sources** `config.sh` (8 `readonly` lines) +
  `jira_rest.sh` (5 `readonly` lines) + `summary.sh`. None of the shared libs
  currently carry an include-guard. So `offer_selfheal` → `_ensure_install_sourced`
  → `source install.sh` would **re-run those `readonly` declarations → "readonly
  variable: already declared" → the self-heal crashes**.
- **Decision**: add the idempotent include-guard idiom to the shared libs BEFORE
  wiring the heal:
  `[[ -n "${_<NAME>_SH_LOADED:-}" ]] && return 0; readonly _<NAME>_SH_LOADED=1`
  (placed after the shebang/`set -euo pipefail`, before the first `readonly`).
  Minimum-necessary set (double-sourced + carry `readonly`): `config.sh`,
  `jira_rest.sh`, `install.sh`. Apply uniformly to all shared libs (`summary.sh`,
  `git_helpers.sh`, `parser.sh`, `workstate.sh`, `jira_sink.sh`, `privacy_guard.sh`,
  `adf.sh`) for robustness — mirrors Linear's "safe to source twice" guard.
  `hookcheck.sh` itself carries `_HOOKCHECK_SH_LOADED`. `_ensure_install_sourced`
  additionally skips the source if `install::register_after_hooks` is already
  defined (so a test stub avoids the heavy source entirely).
- **Rationale**: FR-009/010 — the consented heal must actually run. This is the
  concrete "include-guard" task the 011 checklist flagged. `reconcile.sh` is an
  entrypoint (has `main`), so it does NOT get a guard (nothing sources it); only
  the sourced libs do.

## R6 — Malformed / absent file semantics (fail-soft, never a false "missing")

- **Decision**: mirror Linear's `assess_into` ladder:
  - file absent → `not_installed` (silent; the install ceremony is the path — no nag);
  - present but unreadable → `unverifiable`;
  - readable but no top-level `hooks:` key → `unverifiable` (a stripped file still
    carries `hooks:`; its absence means "not a parseable hook registry", so degrade
    rather than misreport "none");
  - `classify` returning non-zero (rc 2) on any hook → `unverifiable`.
  `warn_once` emits ONE `summary::add info` row for `unverifiable`; `status_line`
  prints "could not verify". Never a halt, never a false missing.
- **Rationale**: FR-008 + SC-005. Fail-soft; informational only.

## R7 — Neutrality boundary (003 gate) — VERIFIED green-safe

- **Finding**: `engine_vendor_neutral.bats` audits an **enumerated list** of
  `reconcile::*` functions (process_spec, sync_*, compose_*, rollup_*, cascade_*,
  compute_orphans, remode, privacy_gate, …). It strips comments +
  `summary::add`/`*::_log`/`reconcile::log` lines. `reconcile::main` is NOT in the
  list; `hookcheck::*` is a different namespace in a different file.
- **Decision**: keep ALL jira-specific vocabulary inside `src/hookcheck.sh`; the
  only engine touch is `source hookcheck.sh` + a single `hookcheck::reconcile_check`
  call in `reconcile::main`. Do NOT add `hookcheck::*` to the audited list, and do
  NOT introduce vendor tokens into any audited `reconcile::*` function.
- **Rationale**: FR-013 / Principle X. The gate stays green with no waiver.

## R8 — Testing (pure-filesystem; no curl-shim; no Jira)

- **Decision**: `tests/unit/hookcheck.bats` drives the module directly over
  temp `.specify/extensions.yml` fixtures (via `HOOKCHECK_EXTENSIONS_YML`):
  classify present/disabled/absent; assess overall present/partial/none/
  unverifiable/not_installed; `warn_once` fires exactly once across a simulated
  multi-spec loop (latch); `status_line` text in every state + never mutates exit;
  interactive (`HOOKCHECK_FORCE_INTERACTIVE=1` + `HOOKCHECK_TTY_IN=<file>`) `y` →
  all missing re-registered (assert `.specify/extensions.yml`), `n`/empty → no
  mutation; non-interactive → no prompt/no mutation; `enabled:false` preserved
  through a heal; a stubbed `install::register_after_hooks` avoids the heavy source.
  `tests/unit/reconcile_hookcheck.bats` asserts the `reconcile::main` branch:
  dry-run emits the status line, real push emits the warn — both non-blocking.
  Extend `no-real-identifiers.bats` to the new fixtures. `engine_vendor_neutral.bats`
  stays green.
- **Rationale**: SC-001..007. No Jira dependency on any tested path.

## R9 — Docs (FR-012)

- **Decision**: a crisp note (README recovery section + the push command doc) that
  `specify extension add jira --from <zip> --force` strips the hooks, and the
  restore path is `/speckit-jira-install` (or the interactive self-heal offer).
  CHANGELOG `[Unreleased]` Added line. No docs "flip" (011 already did that).
- **Rationale**: FR-012 — make the one known strip-path and its fix discoverable.

## Resolved decisions summary

| # | Decision |
|---|----------|
| R1 | New `src/hookcheck.sh`, Linear namespace verbatim; only vendor tokens change |
| R2 | `HOOKCHECK_AFTER_HOOK_NAMES` == 011's `INSTALL_AFTER_HOOK_NAMES` (pin test) |
| R3 | One `hookcheck::reconcile_check` in `reconcile::main`, branch on `DRY_RUN` (status line vs warn); both offer heal; guarded by a trailing or-true so it can never block |
| R4 | Interactivity = real controlling TTY only; slash/hook/CI = warn-only (test seams) |
| R5 | Add idempotent include-guards to shared libs so the consented heal can source install.sh without readonly-redeclare |
| R6 | Fail-soft ladder: absent→not_installed(silent), unreadable/no-`hooks:`→unverifiable; never false-missing |
| R7 | Neutrality: all vendor vocab stays in hookcheck.sh; main + hookcheck:: are un-audited → 003 green |
| R8 | Pure-fs bats (no curl-shim): classify/assess/warn-once/status/consent/heal + reconcile wiring + privacy |
| R9 | Doc note: `--force` strips hooks → `/speckit-jira-install`/self-heal restore; CHANGELOG |
