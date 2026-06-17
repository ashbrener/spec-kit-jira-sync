# Phase 1 Data Model: Issue-Title Source Ladder

No persisted state, no schema change (Principle II / Principle X — `workstate`
floor unchanged). The "model" is the deterministic selection over candidate title
sources within the neutral producer, resolving to the existing `item.title` field.

## Entities

### Title candidate sources (the ladder, priority order)

| Rung | Source | Read from | Used when |
|---|---|---|---|
| 1 | `Title:` line | a front-matter `Title:` line in `spec.md` | present + non-empty |
| 2 | H1 feature name | first `#` heading, `Feature Specification:` label stripped | real + concise: not `[FEATURE NAME]`, not empty, not byte-equal to the kebab short-name, `≤120` chars |
| 3 | Summary sentence | first prose sentence of `## Summary` | rungs 1–2 missed + a prose sentence exists |
| 4 | kebab short-name | the `NNN-<slug>` dir suffix | last resort |

First match wins. Rungs 1–3 pass through the 120-char word-boundary cap; rung 4
does not (slugs are short).

### Resolved title

The deterministic, capped string placed on `item.title` (unchanged field). The
Jira sink maps it to the issue `summary` (unchanged mapping).

## Functions (the seam — see contracts/title-ladder.md)

| Function | Module | Neutral? | Responsibility |
|---|---|---|---|
| `parser::spec_title_line` | `src/parser.sh` | yes | read the `Title:` front-matter line (mirror `parser::spec_author`) |
| `workstate::_summary_first_sentence` | `src/workstate.sh` | yes | first prose sentence of `## Summary` (reuse `_spec_body`) |
| `workstate::_cap_title` | `src/workstate.sh` | yes | cap at 120, word boundary, no ellipsis (pure) |
| `workstate::_spec_title` | `src/workstate.sh` | yes | the 4-rung ladder (rewritten) |
| `workstate::item_for_spec` | `src/workstate.sh` | yes | unchanged — sets `item.title` |

All four are vendor-neutral (read `spec.md`, no Jira vocabulary); the 003 audit
targets `reconcile::*`, not these, so the neutrality gate is unaffected.

## Validation rules

- **VR-1 (FR-001/SC-001)**: placeholder/empty/missing H1 + a `## Summary` ⇒ title =
  first Summary sentence (capped), never the kebab slug.
- **VR-2 (FR-004/SC-002)**: a clean, within-cap H1 ⇒ title byte-identical to the
  pre-feature result (zero churn).
- **VR-3 (FR-001/SC-003)**: an explicit `Title:` line wins over H1/Summary/kebab; a
  >120 verbose H1 with a Summary present never yields the H1.
- **VR-4 (FR-002/SC-005)**: no resolved title exceeds 120 chars; no title is cut
  mid-word; no ellipsis is inserted.
- **VR-5 (FR-003/SC-004)**: identical `spec.md` ⇒ identical title every run
  (deterministic, zero-churn); no LLM/locale/time/random input.
- **VR-6 (FR-006/SC-006)**: new fixtures are placeholder-only; `no-real-identifiers.bats`
  + the 006 guard stay green.
- **VR-7 (FR-007/SC-006)**: derivation stays in `workstate`/`parser` (neutral); the
  sink mapping is unchanged; the 003 gate stays green.
- **VR-8 (FR-009)**: only the **spec-level** title changes; repo Epic + phase
  Subtask titles are untouched.
