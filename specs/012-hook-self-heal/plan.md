# Implementation Plan: Hook Self-Healing — Detect + Repair Stripped Auto-Sync Hooks

**Branch**: `012-hook-self-heal` | **Date**: 2026-07-02 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/012-hook-self-heal/spec.md`

## Summary

Feature 011 made spec-kit-jira an automatic mirror by registering six `after_*`
hooks into the consumer's `.specify/extensions.yml`. The sanctioned update path
(`specify extension add jira --from <zip> --force`) **silently strips** those
hooks, so auto-sync stops and the board drifts with no signal. This feature adds
a new sink/config-side module `src/hookcheck.sh` that **self-reports hook health**
on every reconcile and, on an operator's explicit consent at a real terminal,
**re-registers the missing hooks in place** by reusing feature 011's idempotent
`install::register_after_hooks`.

Technical approach: a direct port of the Linear sibling's shipped `src/hookcheck.sh`
(spec-014), adapted to jira's single-entrypoint reconcile. Because jira has no
`src/status.sh` (`speckit.jira.status` **is** `reconcile.sh --dry-run`), one
per-run check wires once into `reconcile::main` and **branches on `--dry-run`**:
the dry-run/status path emits a first-class hook-health line; the real-push path
emits a warn-once-if-missing. Both paths offer the consented self-heal, which
only ever fires at a real controlling TTY. The vendor-neutral reconcile engine is
untouched (the check is a `hookcheck::` call from the un-audited `main`), and no
Jira write, schema change, or new exit code is introduced.

## Technical Context

**Language/Version**: Bash 4.4+ / 5.x (portable; BSD/macOS + GNU/Linux — the CI matrix)

**Primary Dependencies**: `awk`, `grep` on the detect/warn path (dependency-light,
mirrors Linear); lazily `source`s `src/install.sh` ONLY when a consented self-heal
needs the writer. No new external dependency.

**Storage**: Reads/writes only the consumer's local `.specify/extensions.yml`
(config-side). No Jira I/O. Filesystem is the source of truth (Principle I).

**Testing**: `bats` — pure-filesystem unit tests (NO curl-shim; no Jira). Test
seams `HOOKCHECK_TTY` / `HOOKCHECK_TTY_IN` / `HOOKCHECK_FORCE_INTERACTIVE` /
`HOOKCHECK_FORCE_NONINTERACTIVE` / `HOOKCHECK_EXTENSIONS_YML` make the consent
path deterministic offline.

**Target Platform**: developer/CI shells (Linux + macOS), invoked by the spec-kit
CLI / the agent's Bash tool / direct operator terminal.

**Project Type**: single-project CLI bridge (the existing `src/` + `tests/` tree).

**Performance Goals**: negligible — one `awk`/`grep` pass over a small YAML file,
once per reconcile run.

**Constraints**: non-blocking (never alters reconcile's exit disposition); status
stays exit 0; idempotent; honour `enabled: false`; BSD-awk-safe; Privacy IX
(placeholder-only fixtures); 003 engine-neutrality gate stays green.

**Scale/Scope**: one new module (~200 lines mirrored from Linear), a one-call
wiring into `reconcile::main`, include-guards added to the shared libs, one new
bats file, doc note. No schema/mapping change.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **VII — Memory-Just-Works, Escape Hatches Beside It**: ENFORCES it. 011 registers
  the auto-sync hooks; 012 keeps them registered by surfacing a stripped set and
  offering the one-step restore. The `/speckit-jira-install` escape hatch is the
  non-interactive remediation. ✅ (no amendment — this implements existing intent.)
- **VIII — Surface, Don't Enforce**: the defining principle here. The warning never
  blocks; the status line never changes the exit code; mutation happens ONLY on
  explicit operator consent at a real TTY; non-interactive runs mutate nothing. ✅
- **IX — No Real Identifiers (Privacy)**: the module + fixtures reference only
  command names + the local extensions file; no real Jira coordinate is read or
  written. `no-real-identifiers.bats` extended to the new fixtures. ✅
- **I / II — Filesystem source of truth, reconcile/idempotent**: reads local truth,
  reuses 011's idempotent registrar for repair; a re-heal writes nothing new. ✅
- **X / 003 neutrality**: the engine stays vendor-neutral. `hookcheck::*` lives in
  its own file and is called from `reconcile::main` (NOT an audited function). No
  vendor vocabulary enters any enumerated `reconcile::*` function. The neutrality
  gate audits that enumerated list only; `main` and `hookcheck::` are out of scope
  → gate stays green. ✅
- **No schema change, no new exit code, no constitution amendment.** ✅

**Result: PASS.** No violations; Complexity Tracking not required.

## Project Structure

### Documentation (this feature)

```text
specs/012-hook-self-heal/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── hookcheck-integration.md   # the module surface + reconcile wiring contract
└── tasks.md             # Phase 2 (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
src/
├── hookcheck.sh         # NEW — hookcheck::* detect/classify/warn/status/self-heal
├── reconcile.sh         # MODIFIED — source hookcheck.sh; one hookcheck::reconcile_check
│                        #   call in reconcile::main, branching on DRY_RUN
├── install.sh           # MODIFIED — add an idempotent include-guard (reused by heal)
├── config.sh            # MODIFIED — add include-guard (carries `readonly`; re-sourced)
├── jira_rest.sh         # MODIFIED — add include-guard (carries `readonly`; re-sourced)
├── summary.sh           # MODIFIED — add include-guard (uniformity/safety)
├── git_helpers.sh       # MODIFIED — add include-guard (uniformity/safety)
├── parser.sh            # MODIFIED — add include-guard (uniformity/safety)
├── workstate.sh         # MODIFIED — add include-guard (uniformity/safety)
├── jira_sink.sh         # MODIFIED — add include-guard (uniformity/safety)
├── privacy_guard.sh     # MODIFIED — add include-guard (uniformity/safety)
└── adf.sh               # MODIFIED — add include-guard (uniformity/safety)

tests/
├── unit/
│   ├── hookcheck.bats           # NEW — classify/assess/warn-once/status-line/consent/heal
│   ├── reconcile_hookcheck.bats # NEW — reconcile::main dry-run-vs-push wiring
│   ├── engine_vendor_neutral.bats   # unchanged; must stay green
│   └── no-real-identifiers.bats     # extended to cover new fixtures
├── fixtures/
│   └── extensions/              # NEW — placeholder .specify/extensions.yml fixtures
└── helpers/                     # existing bats helpers (no curl-shim needed here)

commands/jira-push.md, .claude/commands/*, README.md, CHANGELOG.md  # doc note (FR-012)
```

**Structure Decision**: single-project layout — a new peer module `src/hookcheck.sh`
alongside the existing bridge libs, mirroring how the Linear sibling scoped its
`hookcheck.sh` outside the audited engine. Include-guards are added to the shared
libs so `hookcheck.sh` can lazy-source the 011 registrar on consent without a
`readonly` double-declaration crash.

## Complexity Tracking

> No Constitution Check violations — section intentionally empty.
