# Feature Specification: Human-Readable Issue-Title Source Ladder

**Feature Branch**: `009-title-source-ladder`

**Created**: 2026-06-17

**Status**: Draft

**Input**: User description: "The spec issue's title/summary is often not
human-readable. Today the bridge takes the first `#` heading in spec.md and falls
back to the kebab directory name. Two failure modes: a placeholder/missing H1 →
the title is the kebab slug; a verbose pasted-Input H1 → the title is an
unreadable wall. The bridge can't summarize (deterministic, no LLM at reconcile),
so derive a crisp human title deterministically from spec.md via a source ladder."

## Why this matters

Every spec the bridge mirrors becomes an issue on the operator's board, and the
**title is the first thing a human reads**. Today that title is derived by a
single rule — the first `#` heading in `spec.md`, with the `Feature
Specification:` label stripped, falling back to the kebab directory short-name
when there is no usable heading. That rule breaks in two common, operator-reported
ways:

- **(a) Weak/missing H1 → kebab slug.** A spec whose H1 is the unfilled
  `[FEATURE NAME]` placeholder, is empty, or is absent produces a title that is the
  directory slug (e.g. `seed-data-contract`) — not a sentence a human reads.
- **(b) Verbose H1 → a wall.** A spec whose author pasted a multi-sentence
  description as the `#` heading produces a title that is an unreadable paragraph.

In both cases the board shows the operator's raw input shape instead of a crisp
title. The bridge is a **deterministic reconcile engine with no LLM at reconcile
time** (reproducible, offline, no API cost — Principle II), so it **cannot
summarize** the input at sync time. The fix is therefore not summarization but a
deterministic **source ladder**: derive the title from the best available
human-written content in `spec.md`, with an explicit operator escape hatch, and a
length cap so a pasted wall can never become the title. Summarization stays where
it belongs — authoring time (`/speckit-specify` writing the H1) — but the bridge
becomes robust when that H1 is weak or verbose.

This is **vendor-neutral**: the title is derived from `spec.md` content, not from
Jira, so the logic lives in the neutral title-derivation layer (it reads the spec,
the sink merely maps the resolved title to the issue `summary`). The 003 neutrality
gate is unaffected. The same title logic exists in the Linear sibling; porting the
ladder there is a follow-up, not a dependency of this work.

## Clarifications

### Session 2026-06-17

All three design forks resolved by their leans (strong, non-contentious):

- Q: (a) Ladder priority when both a concise H1 and a `## Summary` exist? → A:
  **explicit `Title:` line > a concise, within-cap H1 > first sentence of `##
  Summary` > kebab short-name.** A *verbose* H1 (over the cap) is demoted **below**
  the Summary sentence, so a pasted-Input heading never wins.
- Q: (b) Length cap value + truncation style? → A: **120 characters, truncated on
  a word boundary** (never mid-word), with **no inserted ellipsis** — the full text
  already lives in the description body, so the title need not signal truncation.
- Q: (c) Prepend the feature number to the title (e.g. `001: <title>`)? → A:
  **No** — keep titles clean; the `speckit-spec:NNN` label already carries the
  number for traceability.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A weak H1 yields a readable title, not a slug (Priority: P1) 🎯 MVP

A spec was created but its `#` heading is still the `[FEATURE NAME]` placeholder
(or empty, or missing). It does have a `## Summary` describing the feature. When
the bridge reconciles it, the issue title is the **first sentence of the Summary**
(capped on a word boundary) — a readable phrase — instead of the kebab directory
slug.

**Why this priority**: This is the most common failure (a spec that skipped
filling the H1) and the one that produces the least-readable boards. Fixing it is
the core value.

**Independent Test**: Create a spec whose H1 is the placeholder/empty and which has
a `## Summary`; reconcile; confirm the title is the first Summary sentence (capped),
not the directory slug. Remove the Summary too; confirm it falls back to the kebab
slug (graceful last resort).

**Acceptance Scenarios**:

1. **Given** a spec with a placeholder/empty/missing H1 and a non-empty `##
   Summary`, **When** the bridge derives the title, **Then** the title is the first
   sentence of the Summary, trimmed and capped on a word boundary.
2. **Given** a spec with neither a usable H1 nor a `## Summary`, **When** the
   bridge derives the title, **Then** it falls back to the kebab short-name (today's
   behavior — graceful last resort).

---

### User Story 2 - A clean H1 is preserved exactly (Priority: P1)

A spec has a proper `# Feature Specification: <Name>` heading with a concise human
name. When the bridge reconciles it, the title is **exactly that name** — byte-
identical to what the bridge produces today — so no existing issue's title churns.

**Why this priority**: Backward compatibility is non-negotiable. The majority of
well-formed specs must see **zero change** (no spurious title UPDATE on the next
reconcile). The ladder must improve weak cases without disturbing good ones.

**Independent Test**: Take a spec with a clean concise H1; reconcile under the new
ladder; confirm the title equals the H1 name and equals what the pre-feature logic
produced (no diff, no churn).

**Acceptance Scenarios**:

1. **Given** a spec with a clean, within-cap `# Feature Specification: <Name>` H1,
   **When** the bridge derives the title, **Then** the title is exactly `<Name>`,
   byte-identical to the pre-feature result.
2. **Given** an unchanged spec reconciled twice, **When** the title is derived each
   time, **Then** both titles are identical (deterministic, zero-churn).

---

### User Story 3 - The operator can override, and a verbose H1 can't win (Priority: P2)

An operator whose spec has a long, verbose H1 (a pasted multi-sentence input) adds
an explicit `Title:` line to the spec. The bridge uses that line as the title,
above everything else. Even without the override, a verbose H1 that exceeds the cap
is **demoted** so the title comes from the Summary sentence instead — the wall
never becomes the title.

**Why this priority**: Gives operators a deterministic escape hatch (the override)
and guarantees the verbose-H1 case (b) is handled even when they do nothing.

**Independent Test**: (i) a spec with both a verbose H1 and a `Title:` line →
title is the `Title:` value; (ii) a spec with a >cap verbose H1 and a `## Summary`
but no `Title:` → title is the Summary sentence (capped), not the H1 wall.

**Acceptance Scenarios**:

1. **Given** a spec with an explicit `Title:` line, **When** the bridge derives the
   title, **Then** that line's value wins over the H1, the Summary, and the kebab.
2. **Given** a spec whose H1 exceeds the length cap and which has a `## Summary`
   (and no `Title:`), **When** the bridge derives the title, **Then** the verbose
   H1 is demoted and the title is the first Summary sentence, capped.

---

### Edge Cases

- **`Title:` line is itself verbose**: the explicit override is still capped on a
  word boundary (the operator's intent is honored, but the title stays bounded).
- **Summary first "sentence" has no terminal punctuation** (a single long line):
  treat the whole line as the sentence, then cap it.
- **Summary starts with a non-prose element** (a blockquote, a list, an image, a
  code fence): skip to the first prose sentence; if none, fall through to the kebab
  short-name rather than emit markup as a title.
- **H1 exactly equals the kebab short-name** (e.g. the tool wrote the slug as the
  heading): treat as a weak H1 (no human value over the slug) and fall through to
  Summary.
- **Title would be empty after trimming/markup-stripping**: fall through to the
  next rung; never emit an empty title.
- **Determinism**: identical `spec.md` bytes ⇒ identical title on every run; no
  locale/time/random influence (Principle II). A re-run is a visible no-op.
- **Privacy**: the ladder reads only operator-written `spec.md` prose; it stores
  nothing new and emits no real coordinate. Committed fixtures are placeholder-only.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001 (Source ladder)**: The bridge MUST derive the spec issue's title via a
  deterministic, first-match-wins ladder, replacing today's single H1-or-kebab
  rule: (1) an explicit `Title:` line in `spec.md`; (2) the `# Feature
  Specification: <Name>` H1 (label stripped) **only when** it is a real, concise
  name — not the `[FEATURE NAME]` placeholder, not empty, not byte-equal to the
  kebab short-name, and within the length cap; (3) the first sentence of the `##
  Summary` section (trimmed); (4) the kebab directory short-name (unchanged last
  resort).
- **FR-002 (Length cap)**: The resolved title MUST be capped at **120 characters**
  (resolved 2026-06-17) on a **word boundary** (never mid-word), with no inserted
  ellipsis. The cap MUST demote an over-cap H1 (so a verbose H1
  cannot become the title) and MUST bound the Summary sentence and the `Title:`
  override. No spec content is lost — the full text remains in the description body.
- **FR-003 (Determinism + idempotency)**: The same `spec.md` MUST yield the same
  title on every run — same rung selected, same cap applied, byte-stable — so a
  re-run on an unchanged spec is zero-churn (Principle II). No LLM, no
  locale/time/random input.
- **FR-004 (Backward compatibility)**: A spec that today resolves to a clean,
  within-cap H1 MUST keep that exact title (byte-identical, no spurious summary
  UPDATE). Only specs that today fall back to kebab, or whose H1 is the
  placeholder/verbose, change — a one-time, desirable title improvement.
- **FR-005 (No reconcile-time summarization)**: The bridge MUST NOT call any LLM /
  AI / network summarizer to derive the title; derivation is purely deterministic
  parsing of `spec.md` (Principle II — reproducible, offline).
- **FR-006 (Privacy IX)**: The ladder MUST introduce no new tracked storage and
  emit no real identifier. Every committed fixture/example MUST be placeholder-only;
  `no-real-identifiers.bats` and the 006 consumer-side guard MUST stay green.
- **FR-007 (Vendor-neutral)**: Title derivation MUST stay in the neutral
  title-derivation layer (it reads `spec.md`, not Jira); the sink MUST keep mapping
  the resolved title to the issue `summary` unchanged. The 003 engine-neutrality
  gate MUST stay green.
- **FR-008 (Surface)**: The run summary SHOULD make the chosen title observable
  (and, where useful, which ladder rung produced it), so an operator can see why a
  title resolved as it did (Principle VIII).
- **FR-009 (Spec-level only)**: The ladder applies to the **spec-level** issue
  title only. The repo Epic title and the phase Subtask titles are unchanged
  (out of scope).

### Key Entities *(include if feature involves data)*

- **Title source ladder**: the ordered set of candidate sources (`Title:` line →
  concise H1 → first Summary sentence → kebab short-name) and the first-match-wins
  selection over them.
- **`Title:` override line**: an optional operator-written line in `spec.md` (same
  front-matter shape as the `Owner:`/`Author:` line feature 007 reads) carrying the
  crisp title verbatim.
- **Resolved title**: the deterministic, capped string the neutral layer puts on
  `item.title`, which the sink maps to the issue `summary`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A spec with a placeholder/empty/missing H1 and a `## Summary`
  produces a title equal to the first Summary sentence (capped on a word boundary),
  never the kebab slug — 100% of the time.
- **SC-002**: A spec with a clean, within-cap H1 produces a title byte-identical to
  the pre-feature result (zero churn) — 100% of the time.
- **SC-003**: An explicit `Title:` line wins over the H1, Summary, and kebab — 100%
  of the time; a verbose (>cap) H1 with a Summary present never produces the H1 as
  the title.
- **SC-004**: The same spec reconciled twice yields a byte-identical title (zero
  observable churn).
- **SC-005**: No resolved title exceeds the cap, and no title is truncated
  mid-word.
- **SC-006**: No real identifier appears in any tracked file the feature adds —
  `no-real-identifiers.bats` + the 006 guard stay green; the 003 neutrality gate
  stays green.

## Assumptions

- **The spec content is the only title source.** The bridge derives, never
  summarizes; a crisp title ultimately depends on the operator's `spec.md` having
  *some* readable content (H1, `Title:`, or Summary) — the kebab slug remains the
  honest last resort when none exists.
- **`## Summary` is the canonical concise section.** spec-kit's template places a
  short Summary near the top; its first sentence is a reasonable deterministic
  title source. (Confirm the section name in plan: `## Summary` vs `## Overview`.)
- **The `Title:` line shape mirrors `Owner:`/`Author:`** (feature 007) for operator
  familiarity and parser reuse.
- **Changing the derivation produces a one-time title UPDATE** on weak-H1 specs at
  the next reconcile — acceptable and desirable (Principle I: filesystem wins; a
  manually-edited Jira title is overwritten by the better derived one).
- **~120 chars is the working cap** pending clarify; Jira/Linear both accept longer
  titles, so the cap is a readability choice, not a platform limit.

## Out of Scope

- Any **LLM/AI/network summarization** at reconcile time (breaks determinism +
  offline — explicitly rejected).
- Changing the issue **description body** (only the title/summary derivation
  changes).
- The **cross-repo port** of the ladder into spec-kit-linear (a follow-up; this PR
  is the Jira-side implementation of the neutral logic).
- Titles of **non-spec levels** — the repo Epic and phase Subtasks keep their
  current titles.

## Open Questions — RESOLVED (Clarifications, Session 2026-06-17)

All three forks are pinned in the Clarifications section above: (a) ladder priority
= explicit `Title:` > concise-within-cap H1 > first Summary sentence > kebab (a
verbose H1 demoted below Summary); (b) cap = **120 chars**, word-boundary, no
ellipsis; (c) do **not** prepend the feature number. No `[NEEDS CLARIFICATION]`
markers remain. No constitutional amendment — deterministic title derivation
reinforces Principle II (no LLM at reconcile) and stays vendor-neutral (003).
