# Phase 0 Research: Lifecycle→Subtask Cascade + Phase-Parser Broadening

Grounded in the existing rollup machinery and parser. The cascade **reuses** the
sink's transition path (no new sink function); the parser broadening is a localized
awk change plus a string-keying of the phase-index pipeline. Three forks pinned
(trigger `{ready_to_merge, merged}`; no constitution amendment; numeric+single-letter
indices).

## R1 — The cascade reuses `rollup::transition_if_changed` (no new sink fn)

- **Finding**: `rollup::transition_if_changed key computed prior`
  (`src/jira_sink.sh:1134`) already maps **`computed="complete"` → the `merged`
  status** (`config::get_status_transition "merged"`), and is a **no-op when
  `computed==prior`** (idempotent), returning rc 1 only on a transport failure.
  `rollup::done_status_id` (`:1122`) is that same merged status.
- **Decision**: the cascade does **not** need a new sink function. For a terminal
  spec, for each phase Subtask: read current status, derive `prior` (`== done_status
  ? complete : partial`), call `rollup::transition_if_changed key "complete" prior`.
  Already-done ⇒ `noop` (idempotent); else ⇒ transition to the merged status. The
  current-status read is the **fail-closed** point (unreadable ⇒ exit 3, no partial
  cascade); an unmapped merged status ⇒ `transition_if_changed` returns `noop`
  (**fail-soft**, surfaced as a warning by the caller).
- **Rationale**: the existing `reconcile::rollup_phases` (`:1298`) is *exactly* this
  loop with `computed` from the checkbox ratio instead of forced `"complete"`. So
  the cascade is `rollup_phases` with `computed:=complete` and no rollup-gate.

## R2 — Restructure the phase-status step (the two call sites)

- **Finding**: `reconcile::rollup_phases` is invoked at `src/reconcile.sh:2316`
  (the US4/3-level path) and `:2455` (the standard per-spec path), each currently
  guarded by `reconcile::status_rollup_enabled` (`:1290`, default off).
- **Decision**: replace each guarded call with a single **phase-status dispatch**:

  ```text
  if lifecycle_phase ∈ {ready_to_merge, merged}:   reconcile::cascade_phases …   # ALWAYS (ungated)
  elif status_rollup_enabled:                        reconcile::rollup_phases …    # today's ratio path
  else:                                              (nothing — today's default)
  ```

  Non-terminal behavior is **byte-identical to today** (FR-002); the cascade is the
  only new write, and only for terminal specs.
- **Implementation shape**: extract the shared per-subtask transition loop (the body
  of `rollup_phases`) into a helper taking a `computed` resolver; `cascade_phases`
  passes `"complete"`, `rollup_phases` passes `rollup::compute_completion`. Minimal
  duplication; both stay in `reconcile.sh` (engine) and call the sink transition.

## R3 — Terminal set + cascade target

- **Decision**: terminal set = `{ready_to_merge, merged}` (resolved), read from
  `parser::lifecycle_phase` (neutral) — the same `lifecycle_phase` already threaded
  through the per-spec flow (`reconcile.sh:1060-1077`). Cascade target = the
  **merged** status (`rollup::done_status_id`) for **both** terminal tokens — by
  ready-to-merge the phases are done, so children go to the done status even though
  the parent Story sits at `ready_to_merge`. (Different levels, different states —
  expected.)
- **Forward-only** (accepted limitation): if lifecycle later regresses below
  `ready_to_merge`, the cascade won't fire and won't un-set children unless the
  ratio rollup is on.

## R4 — Parser broadening (locale-robust separator strip)

- **Finding**: three awk blocks use `/^## Phase [0-9]+:/` then split index/name on
  the colon — `parser::task_phases` (`:204`), `tasks_in_phase` (`:249`), the
  unphased scan (`:365`).
- **Decision**: broaden to accept a **numeric or single-letter** index and **any
  separator** (`:`/`-`/en-dash/em-dash):
  - Match a phase header as a `## Phase` prefix + an index `[0-9A-Za-z]+` + a boundary
    (separator or whitespace), so `## Phaser` does not match.
  - Extract `idx` = the leading `[0-9A-Za-z]+`; `name` = the remainder with the
    separator stripped via **`sub(/^[^A-Za-z0-9]+/, "", name)`** — this removes a
    leading run of spaces + the separator byte(s) **without embedding a multibyte
    dash in the regex** (the 009-D1 locale lesson: `[^A-Za-z0-9]` is a negated ASCII
    class, locale-stable across `C`/UTF-8; it strips em-/en-dash bytes too).
- **Backward-compat (FR-007)**: `## Phase N: Name` → idx `N`, name `Name` —
  byte-identical to today. Verified the colon path is a strict subset of the new
  rule.
- **Known limitation**: a phase *name* legitimately starting with punctuation
  (`(beta) …`) would lose the leading punct; documented (phase names rarely do).

## R5 — String-keyed index pipeline (the ripple fix)

- **Finding**: four jq sites extract a **numeric-only** trailing token to match a
  child to its phase: `[match("[0-9]+$")?][0].string` at `reconcile.sh:1237, 1248,
  1309, 2656`. With a letter index, these match nothing → letter phases' tasks/
  subtasks don't attach.
- **Decision**: generalize the extraction to the **phase-index token** the rest of
  the pipeline uses. The workstate child id + the `task-phase:<idx>` identity label
  carry the token; change `[0-9]+$` → the index-token pattern (`[0-9A-Za-z]+$`, or
  better, parse the suffix after the known child-id/label prefix so the token is
  exact). Confirm the child-id shape during implement and key on it consistently at
  all four sites + the cascade/rollup phase_map join.
- **Rationale**: FR-006 — the index is a string token end-to-end; numeric-only
  extraction is the one place that assumed digits.

## R6 — Idempotency, fail-closed, fail-soft

- **Decision**: idempotent (transition only on a real change — inherited from
  `transition_if_changed`); **fail-closed (exit 3)** on an unreadable subtask
  status read (no partial cascade); **fail-soft (warn)** when the merged status is
  unmapped (nothing to transition to). Mirrors the existing `rollup_phases`
  error posture (`reconcile.sh:1317-1331`).

## R7 — Constitution: no amendment (formal ruling in plan)

- **Decision (lean, to be formalized in the plan's Constitution Check)**: **no
  amendment**. The Architectural-Constraints line "lifecycle state → spec-Issue
  status (set via a transition POST) + phase:* label" states what lifecycle drives;
  it is not an *exclusivity* clause. Feature **002's `status_rollup` already writes
  phase-Subtask status under Layer D without an amendment**, establishing that
  subtask-status writes are in-grain. The cascade **enforces** the constitution's
  intent that the board mirror lifecycle (stranded subtasks *violate* it). The
  **artifact mapping is unchanged** (phase still → Subtask) ⇒ not MAJOR.
- **Fallback**: if the gate reads the line as exclusive, a one-paragraph **MINOR
  v1.1.0→v1.2.0** amendment ("terminal lifecycle additionally cascades to
  bridge-owned phase-subtask status; bounded to bridge-owned artifacts; idempotent;
  fail-closed") — written to be a clean drop-in. Plan recommends no-amendment.

## R8 — Testing (curl-shim + parser bats)

- **Cascade (curl-shim integration)**: merged spec + rollup OFF → each phase Subtask
  transitioned to the merged status (SC-001); idempotent re-run → zero transitions
  (SC-004); non-terminal spec → no subtask writes (SC-003); `ready_to_merge` → same
  cascade; unreadable subtask read → exit 3, no partial (FR-004).
- **Parser (bats)**: `## Phase A — Name`, `## Phase 1 — Name`, `## Phase 10: Name`
  → correct index token + name; `## Phase N: Name` byte-identical (SC-005);
  `## Phaser:` does not match.
- **Gates**: `engine_vendor_neutral.bats` green (cascade decision in reconcile has
  no Jira vocab; transition in sink); `no-real-identifiers.bats` green (placeholder
  fixtures).

## Resolved decisions summary

| # | Decision |
|---|---|
| R1 | Cascade reuses `rollup::transition_if_changed` with `computed="complete"` — no new sink fn |
| R2 | Phase-status dispatch: terminal→cascade (ungated), else rollup-if-enabled, else nothing |
| R3 | Terminal set `{ready_to_merge, merged}`; target = merged status; forward-only |
| R4 | Broaden the 3 awk sites; strip separator via `sub(/^[^A-Za-z0-9]+/,"")` (locale-stable) |
| R5 | String-key the 4 numeric-only `[0-9]+$` child-id extractions |
| R6 | Idempotent; fail-closed on unreadable read; fail-soft on unmapped status |
| R7 | No constitution amendment (002 precedent + enforces intent); MINOR v1.2.0 fallback |
| R8 | curl-shim cascade tests + parser bats; neutrality + privacy gates |
