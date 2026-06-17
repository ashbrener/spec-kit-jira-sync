# Implementation Plan: Human-Readable Issue-Title Source Ladder

**Branch**: `009-title-source-ladder` | **Date**: 2026-06-17 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/009-title-source-ladder/spec.md`

## Summary

Replace the single H1-or-kebab title rule in `workstate::_spec_title` with a
deterministic, first-match-wins **ladder**: explicit `Title:` line → a concise
within-cap `# Feature Specification:` H1 → first sentence of `## Summary` → kebab
short-name. A 120-char word-boundary cap (no ellipsis) demotes a verbose
pasted-input heading below the Summary so a wall can never become the title. The
change is confined to the **neutral title-derivation layer** (`workstate.sh` +
`parser.sh`); the Jira sink keeps mapping `item.title` → the issue `summary`
unchanged. Deterministic (no LLM at reconcile — Principle II), backward-compatible
(a clean within-cap H1 returns byte-identically → zero churn), vendor-neutral (003
gate green), Privacy-IX-clean (placeholder-only fixtures). No schema change, no
constitutional amendment.

## Technical Context

**Language/Version**: Bash 4.4+/5.2.

**Primary Dependencies**: only existing ones — reuses `workstate::_spec_body`
(the `## Summary` extractor) and mirrors `parser::spec_author` (the `Owner:`/`Author:`
front-matter reader). `awk`/pure-shell string ops. **No new dependency**, **no
network**, **no LLM**.

**Storage**: None — pure filesystem parsing of `spec.md`; no `workstate` schema
change (the field `item.title` already exists).

**Testing**: `bats` unit tests over small placeholder `spec.md` fixtures
(no curl-shim — this is pure parsing). `no-real-identifiers.bats` covers the new
fixtures.

**Target Platform**: macOS/Linux (the operator's reconcile run).

**Project Type**: Single-project CLI bridge.

**Performance Goals**: A few `awk` passes per spec — negligible.

**Constraints**: deterministic/idempotent (Principle II); backward-compatible
(clean-H1 byte-identical); vendor-neutral (stays in `workstate`/`parser`, 003
gate); Privacy IX (placeholder fixtures); spec-level title only.

**Scale/Scope**: 3 new small functions + 1 rewritten function in 2 files; one new
bats file; doc touch-ups. ~1 day.

## Constitution Check

*GATE: re-checked after Phase 1 — PASS.*

| Principle | Assessment |
|---|---|
| **II. Reconcile, never event-push** | Title derivation is **deterministic** — no LLM, no network, no locale/time/random; same `spec.md` ⇒ same title ⇒ zero-churn re-run. **Reinforces II.** ✅ |
| **VIII. Surface, don't enforce** | The resolved title is visible in the run summary; an optional one-line "derived via <rung>" note may be added (kept minimal). No file is mutated by the bridge. ✅ |
| **IX. Privacy** | Reads only operator-written `spec.md` prose; adds no tracked storage; fixtures placeholder-only; `no-real-identifiers.bats` + 006 guard stay green. ✅ |
| **X. workstate is the contract** | Uses the existing `item.title` field — **no schema change**, no parallel model. ✅ |
| **Engine/sink seam (003)** | Derivation stays in the neutral `workstate`/`parser` producers; the 003 audit targets `reconcile::*`, not these; the new functions carry no Jira vocabulary. Sink mapping unchanged. **Neutrality gate green.** ✅ |
| **I. Filesystem source of truth** | The better title is derived from disk; a one-time summary UPDATE on weak-H1 specs is the filesystem correctly overwriting the board (I). ✅ |
| Data-model mapping | Unchanged. ✅ **No amendment.** |

**Verdict**: No amendment. A deterministic, vendor-neutral readability improvement
to an existing field; reinforces Principles II/X.

### Initial Constitution Check (pre-Phase-0): PASS

Three forks pinned (ladder order; 120-char word-boundary cap; no number prefix);
no NEEDS CLARIFICATION; no principle conflict.

## Project Structure

### Documentation (this feature)

```text
specs/009-title-source-ladder/
├── plan.md              # This file
├── research.md          # Phase 0 — R1..R8 (reuse map, ladder, cap, neutrality)
├── data-model.md        # Phase 1 — the ladder + VR-1..VR-8
├── quickstart.md        # Phase 1 — how the title is chosen + fixes
├── contracts/
│   └── title-ladder.md  # Phase 1 — the function seam + C-1..C-12
└── tasks.md             # Phase 2 — /speckit-tasks (not yet)
```

### Source Code (repository root)

```text
src/
├── parser.sh     # +parser::spec_title_line (mirror parser::spec_author, key `title`)
└── workstate.sh  # +_summary_first_sentence (reuse _spec_body) +_cap_title (pure);
                  #   REWRITE _spec_title as the 4-rung ladder; item_for_spec unchanged

tests/unit/
├── title_ladder.bats          # NEW — C-1..C-10 over placeholder spec.md fixtures + idempotency
└── no-real-identifiers.bats   # +assert the new fixtures are placeholder-only (C-11)

README.md / CHANGELOG.md        # brief note: titles now derived via the ladder
```

**Structure Decision**: Confined to the two neutral producer modules. No sink
change, no manifest change, no new exit code, no schema change. The new functions
are small and pure; `_spec_title`'s rewrite preserves its signature and its
clean-H1 output exactly (the regression anchor). `parser.sh`/`workstate.sh` carry
the `# ORIGIN: copied from spec-kit-linear` shared header — adding the ladder here
is fine; **porting it into spec-kit-linear is a cross-repo follow-up** (a design
goal, not a dependency of this PR).

## Phase 2 (tasks) preview — strict TDD

- **Foundational (TDD)**: `parser::spec_title_line` (mirror author reader);
  `workstate::_cap_title` (120 / word-boundary / no-ellipsis, pure);
  `workstate::_summary_first_sentence` (reuse `_spec_body`, skip non-prose, first
  sentence) — each test-first.
- **US2 (P1 — regression anchor first)**: rewrite `_spec_title` as the ladder;
  assert C-1 (clean H1 byte-identical) + C-9 (idempotent) **before** touching the
  fallbacks, to lock zero-churn.
- **US1 (P1)**: C-2/C-5/C-6/C-7/C-10 (placeholder/Summary/kebab/markup-skip).
- **US3 (P2)**: C-3/C-4 (verbose-H1 demotion + `Title:` override) + C-8 (cap).
- **Polish**: C-11 privacy fixtures, C-12 neutrality; README/CHANGELOG; full CI
  gate; PR.

## Complexity Tracking

*No violations — table intentionally empty.* Three small pure functions + one
rewrite in the neutral layer; no dependency, no schema change, no sink change, no
amendment.
