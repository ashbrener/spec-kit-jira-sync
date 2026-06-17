# Implementation Plan: Jira Install + Seed Ceremony

**Branch**: `008-install-seed-ceremony` | **Date**: 2026-06-17 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/008-install-seed-ceremony/spec.md`

## Summary

Close the biggest adoption gap versus the Linear sibling: implement the
constitution's **Install** and **Seed** steps so `specify extension add jira-sync`
is followed by `/speckit-jira-install` (resolve the binding) instead of
hand-editing `jira-config.yml`. Install verifies the `.env` credential, resolves —
via the Jira REST API (the sink's transport) — the project key, issue-type ids, the
6 lifecycle phase→status mappings, and (best-effort) the story-points field id, and
writes the gitignored binding; it offers to chain into seed. Seed validates the
`phase:*`/`task-phase:N` labels and confirms the lifecycle status/transition mapping
is reachable, never mutating the admin-scoped workflow. Both are **sink-side**
config-resolution commands — the vendor-neutral engine is untouched (003 stays
green). Fail-closed (exit 2/3) with exact remediation; the binding is written ONLY
to the gitignored config (Privacy IX); re-runs are byte-identical (idempotent).

## Technical Context

**Language/Version**: Bash 4.4+/5.2 (matches the engine + sink).

**Primary Dependencies**: `jira_rest.sh` (existing Basic-auth transport — reused
for `myself`/project/statuses/field GETs), `config.sh` (existing reader +
`mapping::detect_available_types` probe — reused; gains a new **writer**),
`jq`/`curl`/`git`. **No new dependency** (no `yq`). The Atlassian MCP is an
optional interactive aid only, never the source of written ids.

**Storage**: None beyond the one gitignored file the writer produces
(`.specify/extensions/jira/jira-config.yml`). No backend/daemon/sidecar.

**Testing**: `bats` + the `tests/helpers/jira-shim.bash` curl-shim (offline) —
shimmed REST responses prove the resolve→write, idempotent byte-stability, and
fail-closed-no-write paths. `no-real-identifiers.bats` + the 006 guard stay green.

**Target Platform**: macOS/Linux operator workstations + CI (the consumer repo).

**Project Type**: Single-project CLI bridge (existing `src/` + `commands/` +
`tests/` layout).

**Performance Goals**: A handful of REST GETs + one atomic file write — negligible.

**Constraints**: REST-authoritative ids (Principle V, no name-fallback);
credentials only from `.env` (Principle VI); verify-deps-and-remediate, fail-closed
(Principle VIII); resolved binding only in the gitignored config (Principle IX);
byte-identical idempotent writes; operator `mapping:`/`attribution:`/`remode:`
blocks preserved; engine path untouched (003 neutrality).

**Scale/Scope**: New `src/install.sh` + `src/seed.sh`, one new `config::write_binding`
writer in `config.sh`, two command bodies (+ dev twins) registered in
`extension.yml`, README/template doc updates. No new exit code (reuses 2/3).

## Constitution Check

*GATE: re-checked after Phase 1 design — PASS.*

| Principle | Assessment |
|---|---|
| **Operational Workflow (Install + Seed)** | The constitution **already defines** Install ("resolve the project key, issue-type ids, status + transition ids, story-points field id → write the gitignored `jira-config.yml` → verify deps → report") and Seed ("ensure labels, confirm the status/transition mapping, capture ids, safe to re-run"). This feature **implements** them verbatim. ✅ **No amendment.** |
| **V. ID-based binding, per-repo config** | Install captures every status/transition/type **id** at resolution and writes them to the gitignored config; no name-fallback. Re-running install = rebind (V's stated model). ✅ Core driver. |
| **VI. Credentials at the edges** | Reads `JIRA_*` only from the gitignored `.env`; never writes the token anywhere; the binding holds ids, not secrets. ✅ |
| **VIII. Surface, don't enforce** | Dependency report with `✓`/`⚠`/`✗` + exact copy-paste remediation; fail-closed (exit 2/3) on any missing piece; never silent best-effort; never edits the operator's workflow. ✅ |
| **IX. Privacy** | Resolved coordinates written ONLY to the gitignored `jira-config.yml`; committed surface stays placeholder-only (`config-template.yml`); fixtures placeholder-only; after install the 006 guard + `no-real-identifiers.bats` stay green. ✅ |
| **II. Reconcile, never event-push** | Install/seed keep no sidecar; the binding is the only state; re-runs are byte-identical no-ops. ✅ |
| **Engine/sink seam (003)** | Install/seed are sink/config-side; they add no vendor vocabulary to any audited engine function — the neutrality gate stays green. ✅ |
| Data-model mapping | Unchanged (install/seed produce the binding the existing mapping consumes). ✅ **No MAJOR.** |

**Verdict**: No amendment. The feature implements an already-constitutional
workflow; every principle it touches it reinforces.

### Initial Constitution Check (pre-Phase-0): PASS

All three forks pinned in Clarifications (REST-authoritative, seed-validates,
install→seed chain); no NEEDS CLARIFICATION; no principle conflict.

## Project Structure

### Documentation (this feature)

```text
specs/008-install-seed-ceremony/
├── plan.md              # This file
├── research.md          # Phase 0 — R1..R11 (resolver shape, REST probes, phase→status nuance, writer, seed-validates)
├── data-model.md        # Phase 1 — resolution inputs/outputs + VR-1..VR-9
├── quickstart.md        # Phase 1 — the operator on-ramp (.env → install → seed → go)
├── contracts/
│   └── install-seed.md  # Phase 1 — command bodies, install.sh/seed.sh/config::write_binding seam + C-1..C-12
└── tasks.md             # Phase 2 — /speckit-tasks (not yet)
```

### Source Code (repository root)

```text
src/
├── install.sh   # NEW — install::{main,parse_args,guard_source_target,dependency_report,resolve,promote_exit}
├── seed.sh      # NEW — seed::{main,validate_labels,confirm_reachability}
├── config.sh    # +config::write_binding (template-fill + per-line substitution; preserve operator blocks; byte-stable)
├── jira_rest.sh # reused (myself / project / statuses / field GETs) — likely +a thin jira_rest::get if not already exposing all verbs
└── (mapping::detect_available_types reused as the issue-type probe)

commands/
├── jira-install.md  # NEW — speckit.jira.install (mirror jira-push.md frontmatter); offers to chain seed
└── jira-seed.md     # NEW — speckit.jira.seed

.claude/commands/
├── speckit-jira-install.md  # NEW — dev-layout twin
└── speckit-jira-seed.md     # NEW — dev-layout twin

extension.yml         # +provides.commands: speckit.jira.install, speckit.jira.seed
config-template.yml   # update the "fill by hand" note → "run /speckit-jira-install"
README.md             # Install section: replace "fill the ids by hand" → /speckit-jira-install; mark roadmap item done
CHANGELOG.md          # [Unreleased]

tests/unit/
├── install.bats        # NEW — C-1..C-7, C-10..C-12 over the shim (resolve/write/idempotency/fail-closed/source-target)
├── seed.bats           # NEW — C-8, C-9 (validate + reachability + fail-closed)
├── config_write.bats   # NEW — config::write_binding byte-stability + operator-block preservation
└── no-real-identifiers.bats  # +assert new fixtures placeholder-only
```

**Structure Decision**: Reuse the single-project layout. Install/seed are new
sink-side scripts that lean on the existing transport (`jira_rest`) and probe
(`detect_available_types`); the only shared-module change is an additive
`config::write_binding` (the reader gains a writer). The command bodies follow the
established `jira-push.md` pattern. Nothing in the engine path changes — the
neutral/Jira split is preserved by construction.

## Phase 2 (tasks) preview — strict TDD, by user story

- **Setup**: `src/install.sh` + `src/seed.sh` skeletons; register the two commands
  in `extension.yml`; command-body stubs.
- **Foundational (TDD)**: `config::write_binding` (template-fill + per-line
  substitution + operator-block preservation + byte-stable atomic write) with
  `config_write.bats` first; `install::guard_source_target`;
  `install::dependency_report` (myself probe + tool checks + remediation).
- **US1 (P1 — install resolves the binding)**: `install::resolve` (reuse
  `detect_available_types`; `GET project/<key>/statuses`; the interactive/`--phase-status`
  phase→status map; best-effort `GET field`) + `install::main` wiring + the
  command body; C-1..C-4, C-11 over the shim; reconcile-dry-run-clean proof.
- **US2 (P1 — seed validates)**: `seed::main` (label-prefix validation +
  reachability confirm + capture) + the command body; C-8, C-9.
- **US3 (P2 — dep verification/remediation)**: the fail-closed paths C-5, C-6, C-7
  (exit 2/3, zero-byte writes, exact remediation).
- **Polish/cross-cutting**: install offers to chain seed (FR-013); C-10 privacy
  (006 + no-real-identifiers green post-install), C-12 neutrality; README/template/
  CHANGELOG; full CI gate; PR.

## Complexity Tracking

*No constitution violations — table intentionally empty.* The feature adds two
sink-side scripts + one additive config writer + two command bodies; no new
dependency, no new exit code, no engine change, no amendment.
