# Implementation Plan: Lifecycle→Subtask Board Cascade + Phase-Parser Broadening

**Branch**: `010-lifecycle-subtask-cascade` | **Date**: 2026-06-22 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/010-lifecycle-subtask-cascade/spec.md`

## Summary

Fix two board-correctness bugs (dogfound; same as the Linear sibling). **(1)** A
terminal spec strands its phase Subtasks: lifecycle drives only the spec Story, and
subtask status is touched only by the opt-in checkbox-ratio rollup (off by default).
Fix: a **terminal lifecycle cascade** — when a spec is `ready_to_merge`/`merged`,
force every phase Subtask to the merged/done status, always (ungated), idempotent,
fail-closed. **(2)** `parser::task_phases` requires `## Phase <digits>:` so letter/
dash headers (`## Phase A — …`) produce zero subtasks. Fix: **broaden the phase
header** to a numeric-or-letter index with any separator, string-keying the index
pipeline. The cascade *decision* is vendor-neutral (in `reconcile.sh`); the
*transition* reuses the sink's existing `rollup::transition_if_changed` (003 seam
preserved). No new sink function, no schema change, no mapping change. Rides v0.4.0.

## Technical Context

**Language/Version**: Bash 4.4+/5.2.

**Primary Dependencies**: existing only — reuses `rollup::transition_if_changed` +
`rollup::done_status_id` (sink), `query_issue_full`, `parser::lifecycle_phase`.
`awk`/`jq`. No new dependency.

**Storage**: none (no schema change; `item.title`/child shape unchanged — the phase
index is just treated as a string token).

**Testing**: `bats` — curl-shim integration for the cascade (merged→done, idempotent,
non-terminal-unchanged, fail-closed) + pure-parser bats for the header broadening.

**Target Platform**: macOS/Linux reconcile runs.

**Project Type**: single-project CLI bridge.

**Performance**: one extra status read+maybe-transition per phase Subtask on a
terminal spec; negligible.

**Constraints**: deterministic/idempotent (II); vendor-neutral cascade decision +
sink transition (003 gate); fail-closed on unreadable reads, fail-soft on unmapped
status; backward-compatible parser (no churn for `## Phase N:` specs); Privacy IX;
artifact mapping unchanged (no MAJOR).

**Scale/Scope**: ~1 new `reconcile::cascade_phases` + a dispatch tweak at 2 call
sites + 3 awk broadenings + 4 index-extraction string-keyings; 2 new bats files.

## Constitution Check

*GATE — formal ruling on the amendment question (spec decision b).*

**Does the always-on lifecycle→subtask-status cascade need an amendment?**
The Architectural-Constraints line reads: *"…lifecycle state → spec-Issue status
(set via a transition POST) + `phase:*` label."* Ruling: **NO amendment required.**

1. **Not exclusive.** The line states what lifecycle *drives*; it is not phrased as
   "lifecycle drives *only* the spec issue." It enumerates the spec-issue projection,
   not a prohibition on subtask-status writes.
2. **Precedent (002).** `status_rollup` already transitions phase-Subtask status
   under Layer D, shipped without an amendment. Subtask-status writes are
   established in-grain Layer-D behavior; the cascade is another trigger for the
   same write.
3. **Enforces, not extends.** The constitution's whole thesis is that the board
   *mirrors* the source-of-truth lifecycle (Principles I/II). A merged spec whose
   Subtasks read "To Do" **violates** that intent; the cascade restores it.
4. **No MAJOR.** The data-model mapping (`phase → subtask`) is unchanged; only a
   status transition is added. MAJOR is reserved for mapping/layer changes.
5. **Layer boundaries (III).** The cascade is Layer D (reconcile), the same layer
   that owns subtask status today; no Layer-E touch. ✅

**Fallback (only if a reviewer reads the line as exclusive):** a one-paragraph
**MINOR v1.1.0→v1.2.0** amendment to Architectural Constraints — *"A terminal
lifecycle (`ready_to_merge`/`merged`) additionally cascades bridge-owned phase-
subtask status to the done state; bounded to bridge-owned artifacts, idempotent,
fail-closed."* Drop-in ready; **not** taken by default.

| Other principles | Assessment |
|---|---|
| **II. Reconcile/idempotent** | Transition only on a real change; deterministic parser; zero-churn re-run. ✅ |
| **IV. Drift-aware / fail-closed** | Unreadable subtask read ⇒ exit 3, no partial cascade. ✅ |
| **VIII. Surface** | Cascade actions + an unmapped-status warning emitted in the summary. ✅ |
| **Engine/sink seam (003)** | Cascade decision (terminal⇒done) is neutral in `reconcile.sh`; the transition reuses the sink. Neutrality gate stays green. ✅ |
| **IX. Privacy** | Placeholder-only fixtures. ✅ |

**Verdict**: PASS, **no amendment** (recommended), MINOR-v1.2.0 fallback documented.

### Initial Constitution Check (pre-Phase-0): PASS

Three forks pinned (trigger `{ready_to_merge,merged}`; no amendment; numeric+letter
indices); no NEEDS CLARIFICATION; mapping unchanged.

## Project Structure

### Documentation (this feature)

```text
specs/010-lifecycle-subtask-cascade/
├── plan.md, research.md (R1..R8), data-model.md (VR-1..VR-9),
├── quickstart.md, contracts/cascade-parser.md (C-1..C-12)
└── tasks.md            # Phase 2 — /speckit-tasks (not yet)
```

### Source Code (repository root)

```text
src/
├── parser.sh     # broaden the 3 phase-header awk sites (:204/:249/:365): numeric|letter
                  #   index + any separator; strip sep via sub(/^[^A-Za-z0-9]+/,"") (locale-stable)
└── reconcile.sh  # +reconcile::cascade_phases (terminal⇒force each Subtask done, reusing
                  #   rollup::transition_if_changed); phase-status DISPATCH at :2316/:2455
                  #   (terminal→cascade / else→rollup-if-enabled); string-key the numeric-only
                  #   child-id extraction at :1237/:1248/:1309/:2656

src/jira_sink.sh  # UNCHANGED — rollup::transition_if_changed / done_status_id reused

tests/unit/
├── cascade_phases.bats   # NEW — C-1..C-7 (curl-shim: merged→done, idempotent, non-terminal, fail-closed)
├── phase_parser.bats     # NEW — C-8..C-10 (letter/dash headers; numeric-colon byte-identical)
└── no-real-identifiers.bats  # +new fixtures placeholder-only (C-12)

README.md / CHANGELOG.md   # note the cascade + flexible headers
```

**Structure Decision**: Confined to `reconcile.sh` (engine decision) + `parser.sh`
(neutral); the sink is reused unchanged, so the 003 neutrality seam is preserved by
construction. `parser.sh`/`reconcile.sh` carry the shared `# ORIGIN` header — the
parser broadening is the same diff to port to spec-kit-linear (a follow-up).

## Phase 2 (tasks) preview — strict TDD

- **Parser (US2, FR-005/006/007)**: broaden the 3 awk sites + string-key the 4
  child-id extractions; tests first — `## Phase A — …`/`## Phase 1 — …` detected,
  `## Phase N: Name` byte-identical (the regression anchor).
- **Cascade (US1, FR-001..004)**: `reconcile::cascade_phases` (reuse
  `transition_if_changed` with `computed=complete`); the phase-status dispatch at
  the 2 call sites; curl-shim tests — merged+rollup-off→done, idempotent,
  fail-closed, `ready_to_merge` parity.
- **US3**: non-terminal unchanged (rollup-off→no write; rollup-on→ratio).
- **Polish**: C-11 neutrality, C-12 privacy fixtures; README/CHANGELOG; full CI gate;
  PR.

## Complexity Tracking

*No violations — table empty.* One new neutral function + a dispatch tweak + a
localized parser broadening; reuses the sink transition; no dependency, no schema,
no mapping change, **no amendment** (recommended).
