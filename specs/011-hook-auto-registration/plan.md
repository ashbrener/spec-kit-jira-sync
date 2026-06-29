# Implementation Plan: Auto-Register `after_*` Hooks — the Automatic Mirror

**Branch**: `011-hook-auto-registration` | **Date**: 2026-06-28 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/011-hook-auto-registration/spec.md`

## Summary

Make spec-kit-jira the automatic mirror its constitution always specified
(Principle VII) — close the gap where the bridge registers **zero** hooks and only
syncs when the operator manually runs `/speckit-jira-push`. Declare the six
`after_*` hooks in `extension.yml provides.hooks` (the spec-kit CLI registers them
at `add`), add an idempotent install-side registrar (`install::register_after_hooks`,
mirroring the Linear sibling's block grammar) that writes/repairs them in the
consumer's `.specify/extensions.yml` (honouring `enabled: false`, dogfood-gated),
and harden the push entry-point so an auto-fired hook with no creds degrades to a
clean warning instead of a hard error. Non-blocking is **structural** (the skill
fires the hook *after* the command's work). Install/config-side only — the
vendor-neutral reconcile engine is untouched (003 gate green). Foundation for
feature 012 (the Linear spec-014 hook self-heal port). **No constitution
amendment** — it implements VII; the only doc fix is the contradicting
"operator-driven, no hooks" wording.

## Technical Context

**Language/Version**: Bash 4.4+/5.2.

**Primary Dependencies**: existing — `src/install.sh` (the 008 ceremony, gains the
registrar + `INSTALL_AFTER_HOOK_NAMES`/`INSTALL_EXTENSIONS_YML`), the spec-kit
framework's hook-firing (verified: skills `EXECUTE_COMMAND` an `optional:false`
hook as their last step). `awk`/`grep`/pure-bash. No new dependency, no network.

**Storage**: none beyond the consumer's `.specify/extensions.yml` the registrar
writes; no schema change.

**Testing**: `bats` — pure-filesystem registrar tests (no curl-shim; no Jira) +
a manifest assertion + a push-one-liner safety check + `no-real-identifiers`.

**Target Platform**: macOS/Linux (registrar must be BSD-awk safe — pure-bash splice).

**Project Type**: single-project CLI bridge.

**Performance**: a few file reads/writes at install; negligible.

**Constraints**: implements Principle VII (no amendment); non-blocking auto-sync
(VIII — structural via `after_*` timing + warn-not-error); honour `enabled:false`
(never re-enable); idempotent byte-identical re-run (II); vendor-neutral engine
untouched (003); Privacy IX; dogfood-gated so the bridge's own dev doesn't auto-push.

**Scale/Scope**: a manifest `provides.hooks` block, ~6 registrar functions in
`install.sh`, a two-line hardening of the push command body (+ twin), a docs flip,
one new bats file. No engine change.

## Constitution Check

*GATE — PASS, no amendment.*

| Principle | Assessment |
|---|---|
| **VII. Memory-Just-Works** | This feature **implements** VII's explicit mandate ("MUST auto-register every `after_*` hook with `optional:false`; auto-sync is the primary path"). The current "no hooks / operator-driven" state *violated* VII; this closes the gap. The only constitutional touch is **correcting the contradicting documentation wording** — a doc fix, not a principle change. ✅ **Core driver — no amendment.** |
| **VIII. Surface, don't enforce** | A fired hook **never** fails the host `/speckit-*` command — it warns (no creds → install; unreadable → token). Non-blocking is structural (`after_*` fires post-work) + the hardened push degrades to a clean warning. ✅ |
| **II. Reconcile, never event-push / idempotent** | The hook fires the **same** reconcile (one code path); auto-sync on unchanged state is zero-churn; the registrar is idempotent (byte-identical re-run). ✅ |
| **V. ID-based binding / per-repo config** | Registration writes the consumer's `.specify/extensions.yml`; the resolved binding (008) is unchanged. ✅ |
| **IX. Privacy** | Hooks reference command names + the gitignored config; no real coordinate in the manifest, the consumer file, or fixtures. ✅ |
| **Engine/sink seam (003)** | Registration is install/config-side; no `reconcile::*` change → the neutrality gate stays green. ✅ |
| Data-model mapping | Unchanged. ✅ **No MAJOR.** |

**Verdict**: PASS, **no amendment**. Implements an existing non-negotiable principle.

### Initial Constitution Check (pre-Phase-0): PASS

Four forks pinned (all-6→push, non-blocking, both-mechanisms, optional:false-coexists);
no NEEDS CLARIFICATION; mapping unchanged.

## Project Structure

### Documentation (this feature)

```text
specs/011-hook-auto-registration/
├── plan.md, research.md (R1..R9), data-model.md (VR-1..VR-10),
├── quickstart.md, contracts/hook-registration.md (C-1..C-10)
└── tasks.md            # Phase 2 — /speckit-tasks (not yet)
```

### Source Code (repository root)

```text
extension.yml          # +provides.hooks (6 after_* → speckit.jira.push, optional:false); fix the "no hooks" header
src/install.sh         # +INSTALL_EXTENSIONS_YML / INSTALL_AFTER_HOOK_NAMES
                       #  +install::register_after_hooks / _register_one_hook / _hook_already_registered
                       #  +_render_hook_block (dogfood-gated condition) / _append_under_hook / _create_hook_section
                       #  +_create_minimal_extensions_yml (settings.auto_execute_hooks:true); wire into install::main
commands/jira-push.md  # harden the .env source (optional) so an auto-fired hook never hard-fails; gentle warning
.claude/commands/speckit-jira-push.md  # same hardening (the dev twin)
README.md              # docs flip: auto-sync first; push/status/install/seed → recovery section

tests/unit/
├── hook_registration.bats     # NEW — C-2..C-8 (pure-fs: create/idempotent/enabled-false/other-ext/malformed/dogfood/push-safety)
├── manifest_hooks.bats        # NEW — C-1 (extension.yml declares the 6 after_* → push, optional:false)
└── no-real-identifiers.bats   # +new fixtures placeholder-only (C-9)
```

**Structure Decision**: Extend the 008 install ceremony with the registrar (the
natural home — install is where hooks get wired); the manifest gains the
`provides.hooks` block; the push command body gets a two-line hardening. Mirror the
Linear sibling's `register_after_hooks` grammar **exactly** so feature 012's
hook-health detector reuses it. Nothing in the reconcile engine changes — the 003
neutral/Jira seam is preserved by construction. `install.sh`/`parser.sh` etc. carry
the shared `# ORIGIN` header; the registrar is the same diff Linear already shipped.

## Phase 2 (tasks) preview — strict TDD

- **Manifest (US1)**: add `provides.hooks` (6 after_* → push, optional:false);
  `manifest_hooks.bats` (C-1) first.
- **Registrar (US1/US3, TDD)**: `_create_minimal_extensions_yml` (auto_execute_hooks),
  `_render_hook_block` (dogfood `condition`), `_hook_already_registered`,
  `_append_under_hook`/`_create_hook_section` (pure-bash), `register_after_hooks`,
  wire into `install::main`; tests C-2 (create), C-3 (idempotent byte-identical),
  C-4 (enabled:false preserved), C-5 (other-extension untouched), C-6 (malformed →
  informational), C-7 (dogfood condition).
- **Non-blocking push (US2)**: harden `jira-push.md` + twin; C-8 (runs with/without
  `.env`).
- **Polish**: docs flip + fix the "no hooks" wording (FR-006); C-9 privacy, C-10
  neutrality; full CI gate; PR.

## Complexity Tracking

*No violations — table empty.* A manifest block + ~6 install-side registrar
functions + a two-line push hardening + a docs flip; no dependency, no schema, no
engine change, **no amendment**.
