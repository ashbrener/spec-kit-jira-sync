# Implementation Plan: Extension Identity Realignment — One Name, Everywhere

**Branch**: `013-extension-identity` | **Date**: 2026-08-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/013-extension-identity/spec.md`

## Summary

The bridge answers to two names: its manifest declares `extension.id: "jira"`
while the community catalog lists it as `jira-sync` — and the `jira` slot is
owned by an unrelated extension. The updater therefore resolves our users to
*their* extension. This feature makes one name authoritative everywhere:
**`jira-sync`** — catalog key, manifest id, command namespace, install directory,
and the hook-registration token — mirroring the Linear sibling's proven shape.

Technical approach: a mechanical rename across ~22 live files, plus one genuine
piece of architecture — the identity is currently **hardcoded twice**
(`install.sh:324` writes `extension: jira`; `hookcheck.sh:102` reads
`cur_ext == "jira"`), so this plan extracts a single sourced constant both use,
making the FR-005 "writer and reader agree" guarantee structural rather than
coincidental. Migration rides the already-shipped 012 self-heal: old-identity
hook entries read as `absent`, so the operator gets the warn/status line and the
consented one-step re-register for free. The operator's resolved binding survives
via a read-fallback to the legacy config path (surfaced, never silently moved).
Ships as **v0.6.0** (breaking — operator-invoked command names change).

## Technical Context

**Language/Version**: Bash 4.4+ / 5.x (portable; the existing CI matrix)

**Primary Dependencies**: unchanged — `awk`, `grep`, `jq`, `curl`. No new runtime
dependency. One new tiny sourced lib (`src/identity.sh`) internal to the repo.

**Storage**: the gitignored resolved binding moves to
`.specify/extensions/jira-sync/jira-config.yml`; the legacy path is still **read**
so an upgrading operator is not forced to re-resolve.

**Testing**: `bats` — pure-filesystem for the identity/registrar/detector paths;
existing curl-shim suites unchanged. New: an identity pin test (FR-012) and an
end-to-end old→new migration test (FR-006).

**Target Platform**: developer/CI shells (Linux + macOS matrix).

**Project Type**: single-project CLI bridge.

**Performance Goals**: none affected — identity resolution is a sourced constant.

**Constraints**: no schema/mapping/exit-code change; nothing the bridge projects
changes (FR-013); Privacy IX; the 003 engine-neutrality gate stays green;
BSD-awk-safe (single-line `awk -v` only).

**Scale/Scope**: ~22 live files. Historical `specs/00*`–`012` documents are NOT
rewritten — they record what was true when written.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **VII — Memory-Just-Works**: ENFORCES it. Auto-sync is worthless if the updater
  can swap the bridge for an unrelated extension; this makes the registered hooks
  point at an identity that resolves to *us*. ✅
- **VIII — Surface, Don't Enforce**: the migration is surface-first — stale
  old-identity entries and the legacy install directory are **reported and
  offered**, never silently moved or deleted. The consented 012 repair is the
  only mutation. ✅
- **I — Filesystem is the source of truth**: the operator's files are read, not
  rewritten behind their back; the legacy binding is honoured in place. ✅
- **IX — Privacy**: placeholder-only fixtures; no real coordinate. ✅
- **X / 003 neutrality**: the change lands in the manifest, command surface,
  `install.sh`, `hookcheck.sh`, and `config.sh` — none of which are audited
  engine functions. `engine_vendor_neutral.bats` must stay green **untouched**. ✅
- **NO schema change, NO mapping change, NO new exit code.** ✅

**Amendment: NOT required.** The constitution names `speckit.jira.push` and
`.specify/extensions/jira/jira-config.yml` at lines 202, 238, 242, 251, 375, 379 —
those are **descriptive references**, not principles. Correcting them is a doc
fix (the same call made in feature 011). Note lines 242/379 also reference a
`.pull` command this bridge has never had — a pre-existing inaccuracy inherited
from the Linear sibling; correct it in the same pass.

**Result: PASS.** No violations; Complexity Tracking not required.

## Project Structure

### Documentation (this feature)

```text
specs/013-extension-identity/
├── plan.md              # This file
├── research.md          # Phase 0 output (R1-R9)
├── data-model.md        # Phase 1 output (identity entities + rules)
├── quickstart.md        # Phase 1 output (the migration, operator-facing)
├── contracts/
│   └── identity-contract.md   # the single-source identity + rename map
└── tasks.md             # Phase 2 (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
src/
├── identity.sh          # NEW — the single source of truth for the extension
│                        #   identity, command namespace + hook token
├── install.sh           # MODIFIED — registrar writes the sourced token
├── hookcheck.sh         # MODIFIED — detector reads the same sourced token
├── config.sh            # MODIFIED — new default path + legacy read-fallback
└── (reconcile.sh, jira_sink.sh, …) # user-facing strings only where they name
                                    #   a command or the install path

extension.yml            # MODIFIED — id, 4 command names, hook command refs, header
commands/                # RENAMED  — jira-*.md → jira-sync-*.md (git mv)
.claude/commands/        # RENAMED  — speckit-jira-*.md → speckit-jira-sync-*.md
config-template.yml      # MODIFIED — documented path
.gitignore               # MODIFIED — ignore the new binding path (keep the old)

tests/unit/
├── extension_identity.bats   # NEW — the FR-012 pin
├── identity_migration.bats   # NEW — old→new end-to-end (FR-006)
└── (manifest_hooks, hook_registration, hookcheck, hookcheck_selfheal,
    reconcile_hookcheck, config, no-real-identifiers)  # MODIFIED fixtures

README.md · CLAUDE.md · CHANGELOG.md · .specify/memory/constitution.md  # doc updates
scripts/publish-catalog.sh  # verify it submits provides{commands:4,hooks:6}
```

**Structure Decision**: single-project layout, unchanged. The one structural
addition is `src/identity.sh` — a tiny include-guarded constants lib sourced by
both the registrar and the detector, so the identity exists **once**.

## Key Design Decisions

1. **Command files are renamed, not just re-declared.** `git mv` both sets
   (`commands/jira-push.md` → `jira-sync-push.md`; `.claude/commands/speckit-jira-push.md`
   → `speckit-jira-sync-push.md`) and update the manifest `file:` paths. Keeping
   old filenames under new command names is the kind of drift this feature exists
   to remove. `git mv` preserves history.
2. **Config: new path preferred, legacy path still read.** `CONFIG_DEFAULT_PATH`
   becomes `.specify/extensions/jira-sync/jira-config.yml`; if absent and the
   legacy path exists, use it and emit ONE informational line telling the operator
   where to move it. Never auto-move, never delete (Principle I/VIII; the 004
   controlled-destruction carve-out is the precedent for anything destructive).
   `.gitignore` covers both.
3. **Dogfood env var renamed** `SPECKIT_JIRA_DOGFOOD_SAFE` →
   `SPECKIT_JIRA_SYNC_DOGFOOD_SAFE` for consistency; dev-only surface, listed in
   the breaking-change notes.
4. **Migration rides 012 — but is proven, not assumed.** A dedicated test drives
   a project wired to `extension: jira` through the renamed bridge and asserts:
   classify → `absent`, warn/status line fires, consented heal re-registers under
   `extension: jira-sync`, and a pre-existing `enabled: false` survives.
5. **One identity constant (the real architecture).** `src/identity.sh` exports
   the extension id, the push command, and the install-dir name. `install.sh`
   renders from it; `hookcheck.sh` passes it into awk via a single-line
   `awk -v` (BSD-safe). The pin test asserts the manifest, the constant, and every
   declared command namespace agree — so FR-005/FR-012 can't silently regress.
   `hookcheck.sh` must source `identity.sh` directly (NOT via `install.sh`, which
   it only sources lazily on consent).
6. **Catalog metadata**: `provides {commands: 4, hooks: 6}` at v0.6.0 publish;
   then reply on the upstream PR/issue that both review findings are addressed.

## Complexity Tracking

> No Constitution Check violations — section intentionally empty.
