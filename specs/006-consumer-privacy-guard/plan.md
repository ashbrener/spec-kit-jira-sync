# Implementation Plan: Consumer-Side Privacy Guard

**Branch**: `006-consumer-privacy-guard` | **Date**: 2026-06-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/006-consumer-privacy-guard/spec.md`

## Summary

Extend the bridge's privacy guarantee from *this* repo to the **consumer repos**
it is installed into. Today `tests/unit/no-real-identifiers.bats` only scans this
bridge-development repo in CI. This feature adds a **consumer-side, fail-closed
pre-write gate**: before any Jira write on every reconcile (and at install), scan
the consumer repo's whole tracked tree for the operator's own resolved Jira
coordinates (exact, zero-false-positive) and for generic Atlassian shapes, assert
the resolved `jira-config.yml`/`.env` are gitignored, and **hard-abort (exit 4,
zero writes)** on any hit — naming the file and shape class without re-leaking the
secret. The scan **mechanism** is vendor-neutral (`src/privacy_guard.sh` +
`reconcile::privacy_gate`); only the Atlassian **shape/known-value definitions**
live in the sink (`jira_sink::privacy_*`), preserving the 003 engine/sink seam.

## Technical Context

**Language/Version**: Bash 4.4+/5.2 (matches the existing engine).

**Primary Dependencies**: `git` (`ls-files`, `check-ignore`, `rev-parse`) + `grep`
+ `jq` — all already required. **No new dependency** (FR-014). gitleaks/trufflehog
are recommended-in-docs + best-effort-if-on-PATH only, never required.

**Storage**: None — read-only, in-memory scan (no backend/daemon/sidecar, per
Architectural Constraints).

**Testing**: `bats` unit + the `tests/helpers/jira-shim.bash` curl-shim (to prove
zero Jira writes on a tripped gate). The existing `no-real-identifiers.bats` and
the new fixtures both stay green.

**Target Platform**: macOS/Linux operator workstations + CI (the consumer repo's
git working tree).

**Project Type**: Single-project CLI bridge (existing `src/` + `tests/` layout).

**Performance Goals**: One `git ls-files` pass + a handful of `grep` sweeps per
reconcile — negligible vs the network round-trips that follow. No measurable
regression on a clean tree (SC-002).

**Constraints**: Vendor-neutral mechanism (FR-012, 003 neutrality gate);
read-only/side-effect-free on the consumer tree (FR-011); fixtures must not
self-match (FR-009, Principle IX); byte-identical behavior on a clean tree (US4).

**Scale/Scope**: Consumer repos up to typical source-tree size; binary blobs
skipped. One new neutral module, three sink provider functions, one orchestrator,
one new exit code.

## Constitution Check

*GATE: re-checked after Phase 1 design — still PASS.*

| Principle | Assessment |
|---|---|
| **IX. No Real Identifiers (Privacy)** | This feature **enforces** IX, extending it from this repo's CI to the consumer tree. The guard's own shapes/fixtures are fragmented + placeholder-only (FR-009); real coordinates stay only in gitignored `.env`/`jira-config.yml`/`tests/.private-deny`. ✅ **Core driver — no amendment.** |
| **I. Filesystem source of truth / fail-closed** | The gate is **read-only** on the consumer tree (FR-011 — never writes back) and **fails closed** before any Jira write — directly in-grain with the existing fail-closed reads (I carve-out / IV precedent). A leak aborts like an unreadable read does. ✅ Additive safety gate, **no amendment**. |
| **II. Reconcile, never event-push** | One gate in the single reconcile write path; no cache, no per-event state; re-runnable with identical outcome. ✅ |
| **VI. Credentials at the edges** | The known-value pass reads `JIRA_*` from the exported env + the gitignored map in memory only; never writes them anywhere. ✅ Reinforces VI. |
| **VIII. Surface, don't enforce** | The guard **surfaces** the exact file + shape class + copy-paste remediation and stops; it never edits the operator's files (FR-006/FR-011). The fail-closed *abort* is a security stop (like a config error), not a workflow mutation. ✅ |
| **Engine/sink seam** (Architectural Constraints) | Mechanism is vendor-neutral (`privacy_guard.sh` + `reconcile::privacy_gate`, added to the 003 audited list); only `jira_sink::privacy_*` is Atlassian-aware (FR-012). ✅ Gate stays green. |
| **X. workstate is the internal contract** | Untouched — the guard scans files, not workstate; no parser/schema change. ✅ |
| Data-model mapping | Untouched (no new artifact/level/relationship). ✅ **No MAJOR.** |

**Verdict**: No constitutional amendment required. The feature is the enforcement
arm of an existing non-negotiable principle (IX), implemented as a fail-closed
read consistent with Principle I/IV. The one externally-visible addition — exit
code **4** — is an additive entry to the exit-code contract (Principle VIII:
name the failure class), not a change to any existing behavior.

### Initial Constitution Check (pre-Phase-0): PASS

Same as above — no NEEDS CLARIFICATION (all four forks pinned in the spec's
Clarifications), no principle conflict, no amendment. Cleared to research.

## Project Structure

### Documentation (this feature)

```text
specs/006-consumer-privacy-guard/
├── plan.md              # This file
├── research.md          # Phase 0 — R1..R10 (gate placement, seam, shapes, exit 4, …)
├── data-model.md        # Phase 1 — entities + the interface table + VR-1..VR-8
├── quickstart.md        # Phase 1 — operator-facing behavior + remediation
├── contracts/
│   └── privacy-guard.md # Phase 1 — the scanner/provider/orchestrator seam + C-1..C-9
└── tasks.md             # Phase 2 — /speckit-tasks (not yet)
```

### Source Code (repository root)

```text
src/
├── privacy_guard.sh   # NEW — vendor-neutral: assert_git, scan (enumerate/match/assert-ignored/verdict)
├── jira_sink.sh       # +privacy_shapes, +privacy_known_values, +privacy_ignore_targets (Jira-aware)
└── reconcile.sh       # +reconcile::privacy_gate (neutral orchestrator); call site in main() after
                       #   load_config, before the write fork; +exit-code 4 in promote_exit + header + usage()

tests/unit/
├── privacy_guard.bats         # NEW — C-1..C-9 over the curl-shim + throwaway git repos
├── engine_vendor_neutral.bats # +reconcile::privacy_gate to the audited-function list (stays green)
└── no-real-identifiers.bats   # +assert the new fixtures are tracked + placeholder-only (Privacy IX)

specs/001-core-bridge/contracts/cli.md  # +exit 4 to the documented exit-code table
README.md / CONTRIBUTING.md             # +the consumer-side guard + gitleaks/trufflehog recommendation
CHANGELOG.md                            # [Unreleased] entry
```

**Structure Decision**: Reuse the existing single-project `src/` + `tests/unit/`
layout. The only new file is the neutral `src/privacy_guard.sh`; everything else
is additive functions on existing modules. The neutral/Jira split is physical
(mechanism in `privacy_guard.sh`/`reconcile.sh`, shapes in `jira_sink.sh`) so the
003 neutrality gate mechanically enforces FR-012.

## Phase 2 (tasks) preview — strict TDD, by user story

- **Setup**: new exit-code 4 wiring (header table, `usage()`, cli contract);
  `src/privacy_guard.sh` skeleton.
- **Foundational (neutral mechanism, TDD)**: `privacy_guard::assert_git`;
  `privacy_guard::scan` (enumerate → shape pass → known-value pass → ignore
  assertion → verdict, all `grep -l`, read-only); `reconcile::promote_exit 4`
  terminal; add `reconcile::privacy_gate` to the neutrality audit list.
- **US1 (P1 — BLOCK-tier leak ⇒ fail closed; WARN-tier ⇒ surface + proceed)**:
  `jira_sink::privacy_shapes` (tiered — `block`: ATATT token + `.atlassian.net`
  site; `warn`: generic email/UUID/accountId) + `jira_sink::privacy_known_values`
  (always block); `reconcile::privacy_gate` wired into `main()` after
  `load_config`; C-1, C-2, C-8 (dry-run), C-10 (warn proceeds), zero-write proof
  via shim. *(Tiering added per analyze finding C1 — broad shapes false-positive
  on this repo's own example.com/UUID fixtures; precision-blocks/recall-warns is
  best-practice + faithful to Principle VIII.)*
- **US2 (P1 — gitignore assertion)**: `jira_sink::privacy_ignore_targets`; C-3.
- **US3 (P2 — actionable, no re-leak)**: the `summary::add error` remediation
  text; C-5 (class+file, never bytes).
- **Cross-cutting**: C-6 (non-git ⇒ fail closed), C-7 (neutrality), C-9
  (read-only), US4 byte-identical clean pass; `no-real-identifiers.bats` covers
  the new fixtures; README/CONTRIBUTING/CHANGELOG; full CI gate; PR.

## Complexity Tracking

*No constitution violations — table intentionally empty.* The feature adds one
neutral module + three small sink providers + one orchestrator + one exit code;
no new dependency, no backend, no mapping change, no amendment.
