# Implementation Plan: Engine Orchestration Unification

**Branch**: `003-engine-orchestration-unification` | **Date**: 2026-06-08 |
**Spec**: [spec.md](./spec.md)

**Input**: Feature specification from
`/specs/003-engine-orchestration-unification/spec.md`

## Summary

Replace the engine's 001-era per-level orchestrators
(`ensure_repo_epic` / `sync_spec_issue` / `sync_task_phase_subissues`) with a
single **neutral level loop** that drives the 002 mapping-driven projection
(`sync_level_artifact` + `link_to_parent`) for every configured level, then
**delete** the now-unused 001 orchestrators. The change is a pure internal
re-platforming with **zero observable-behavior change**: the existing 347-test
suite and the live dogfood are the equivalence oracle (same creates / updates /
links / transitions / payloads — not necessarily the same internal call order).
The win is lift-readiness: the engine's orchestration path ends up carrying **no**
Jira issue-type / artifact-name / relationship knowledge, enforced by a committed
neutrality gate (FR-012), so the post-Jira extraction becomes a mechanical move.

## Technical Context

**Language/Version**: Bash (POSIX-ish, bash 4.4+ — CI runs bash 4.4 + 5.2)

**Primary Dependencies**: `jq` (all JSON), `curl` (REST, shimmed in tests),
existing `src/{reconcile,jira_sink,config,adf,workstate,git_helpers,summary}.sh`

**Storage**: none (filesystem specs in → Jira out; no engine-side state cache —
Principle II)

**Testing**: `bats` (unit + integration over the curl-shim), `shellcheck
--severity=style`, `yamllint`, `markdownlint`, the privacy guard; the **existing
347-test suite is the equivalence oracle** and MUST pass unchanged (SC-001)

**Target Platform**: developer/CI shell + the live Jira REST v3 (dogfood board)

**Project Type**: single-project CLI / reconcile engine

**Performance Goals**: unchanged — per-spec reconcile latency dominated by Jira
REST round-trips; the refactor adds no round-trips (same observable writes)

**Constraints**: byte-for-byte behavioral equivalence across all six mapping
modes; idempotent / drift-aware / fail-closed in every mode; vendor-neutral
engine path (FR-006); Privacy IX

**Scale/Scope**: ~one engine file (`reconcile.sh`) re-platformed + the 001
orchestrators removed from `jira_sink.sh`; no new operator surface

## Constitution Check

This feature is a **behavior-preserving refactor**, so every principle is
satisfied by construction (the equivalence oracle is the proof):

| Principle | Status | How |
|---|---|---|
| I. Filesystem source of truth / read-only mirror | ✅ unchanged | reconcile stays the only write path; no write-back |
| II. Reconcile, never event-push; zero-churn | ✅ preserved | same stable identity labels; zero-churn re-run is SC-002 + the existing idempotency suite |
| III. Layered idempotency (D+E) | ✅ unchanged | Layer D only; no Layer-E touch |
| IV. Drift-aware (spec→Story anchor) | ✅ preserved | FR-004 keeps the spec→Story backward-drift anchor exactly |
| V. ID-based binding, per-repo config | ✅ unchanged | the sink still resolves ids from config |
| VI. Credentials at the edges | ✅ unchanged | no credential surface touched |
| VIII. Tests are the gate | ✅ strengthened | the equivalence is anchored to the full suite passing UNCHANGED; a new neutrality gate (FR-012) is added |
| IX. Privacy | ✅ preserved | no real coordinates; privacy guard stays green |
| X. workstate as the contract | ✅ strengthened | the engine loop consumes only neutral workstate + config labels; Jira lives behind the sink |

**Gate result**: PASS. No violations, no Complexity-Tracking entries needed. The
one *new* constitutional surface is positive — FR-006/FR-012 strengthen the
vendor-neutral engine boundary (Principle X) with an enforced audit.

## Project Structure

### Documentation (this feature)

```text
specs/003-engine-orchestration-unification/
├── spec.md
├── plan.md              # this file
├── research.md          # the 3 design decisions (absorption, neutral surface, equivalence method)
├── data-model.md        # the neutral Level / Payload / Disposition model
├── contracts/
│   └── engine-sink-interface-003.md   # the unified level-loop contract + neutrality gate + T056
├── quickstart.md
└── checklists/requirements.md
```

### Source Code (repository root)

```text
src/
├── reconcile.sh    # CHANGED: process_spec / process_workstate_item become a neutral level loop
│                   #          + a neutral per-level payload composer; rollup_* / sync_initiative kept
├── jira_sink.sh    # CHANGED: 001 orchestrators DELETED; sync_level_artifact extended to absorb
│                   #          status-transition + 2-level-checklist + repo/spec/phase payload specifics
├── config.sh       # unchanged (mapping resolution already here)
├── adf.sh          # unchanged
└── workstate.sh    # unchanged

tests/
├── unit/           # ADDITIVE ONLY: neutrality-gate audit test; payload-composer units
├── integration/    # ADDITIVE ONLY: us-full-stack-nondefault (T056); existing us1..us6 UNCHANGED
└── ...             # the existing 347 tests MUST pass with zero edits (SC-001)
```

## The unification design (the core of this plan)

### Today (the two paths to merge)

- **Engine** (`reconcile::process_spec`) hardcodes the 001 call shape:
  `ensure_repo_epic` → `sync_spec_issue` → (`_phase_is_checklist` ? skip :
  `sync_task_phase_subissues`) → links/comments → rollup; `sync_initiative`
  post-loop. `process_workstate_item` mirrors this for `--workstate`.
- **Sink** has both the 001 orchestrators (bespoke per level) AND the 002 generic
  projection (`sync_level_artifact` + `link_to_parent`), proven but unwired.

The 001 orchestrators carry behavior the generic projection does not yet fully
own: status transitions (spec), the lifecycle-phase label, per-phase disposition
maps, the in-body checklist composition, and each level's specific summary/labels.

### Target (one neutral loop + one projection)

The engine becomes a **neutral level driver**:

```text
for level in ordered_levels(mapping):            # initiative?, repo, spec, phase[*], task[*]
    identity = compose_identity(level, item)     # NEUTRAL: config label prefixes (speckit-spec:NNN …)
    parent   = projected_id(parent_of(level))    # the parent level's projected id (or "")
    payload  = compose_payload(level, item)       # NEUTRAL: {summary, body, labels, state}
    result   = sync_level_artifact(level, identity, parent, payload)   # SINK owns artifact/type/relationship
    record_disposition(level, result.disposition)                      # created/updated/skipped/failed
# checklist-sentinel levels, status transitions, rollup, initiative: SINK hooks keyed by neutral inputs
```

Everything Jira-specific — issue-type ids, the `Epic`/`Story`/`Subtask` names,
relationship resolution, ADF rendering, status-id lookup, the checklist sentinel,
the `null`-description churn fix — stays in (or moves into) the **sink**, reached
only through `sync_level_artifact` by neutral **level name** + neutral **payload**.

### How each 001 orchestrator is absorbed (behavior-preserving)

| 001 orchestrator | Absorbed as | Behavior that must be preserved (the equivalence risks) |
|---|---|---|
| `ensure_repo_epic(slug)` | `sync_level_artifact("repo", repo_label, "", payload)` where `payload.summary` reproduces the repo Epic summary | find-or-create by repo label; fail-closed on unreadable; the exact summary string |
| `sync_spec_issue(item, epic)` | `sync_level_artifact("spec", spec_label, epic_id, payload)` + the sink's status hook + (2-level) checklist hook | summary `NNN — title`; labels `[spec_label, phase:<state>, item labels]` deduped; status transition from the merge-aware state; the merged-not-Done state hint; spec→Story drift anchor; 2-level body composition |
| `sync_task_phase_subissues(story, item)` | a loop of `sync_level_artifact("phase", phase_label, story_id, payload)` | per-phase Subtask create/update; the per-phase disposition map; each phase body = its tasks' ADF taskList |

The **payload composer** (`compose_payload`) is the new neutral seam: it extracts
summary/body/labels/state from the workstate item per level, replicating the
strings the 001 orchestrators produced (so request bodies are byte-identical).
It references workstate fields + config label prefixes only — never Jira.

`sync_level_artifact` is **extended** (in the sink) to own what the orchestrators
did beyond bare create/update: applying the status transition when a level's
payload carries a `state` that maps to a status, and composing the in-body
checklist when the level (or its child) resolves to the `checklist` sentinel —
reusing the already-shipped `sync_body_checklist` / transition levers so the
emitted requests are unchanged.

### The enforced vendor-neutrality gate (FR-012 / SC-003)

- **Audited surface (enumerated)**: the engine-orchestration functions —
  `reconcile::process_spec`, `reconcile::process_workstate_item`, the new level
  loop + `compose_identity` / `compose_payload` / `ordered_levels` helpers,
  `reconcile::rollup_phases` / `rollup_repo_epic` / `sync_initiative`. The list is
  recorded in the contract and referenced by the gate so it can't silently drift.
- **The gate** (a new `tests/unit/engine_vendor_neutral.bats`): extracts the
  bodies of the enumerated functions and FAILS if any contains a Jira issue-type
  id (the configured numeric ids), a Jira artifact-name literal
  (`Epic`/`Story`/`Subtask`/`Task` as a value, not a neutral level name), or a
  relationship-vocabulary term (`Epic-link`, `parent` as a Jira relationship,
  `Initiative` as a type). Level names (`repo`/`spec`/`phase`/`task`) and config
  label prefixes are explicitly allowed (neutral).

### Equivalence method (how we prove zero behavior change)

1. Refactor incrementally; after each step run the **full existing suite** — it
   must pass with **zero test edits** (SC-001). The tests assert observable
   request shapes/counts, so green = same observable writes.
2. Add the new **T056** full-stack non-default-shape idempotency integration test
   (configured labels + parent relationship through the wired engine → re-run is
   0 created / 0 updated / 0 PUT across every parent-bearing level, SC-004).
3. Re-run the **live dogfood** zero-churn checks in each mode (SC-002) as the
   final real-world equivalence proof.

## Complexity Tracking

No constitutional violations and no added projects/patterns — the change *removes*
code paths (the 001 orchestrators) and consolidates onto one. No entries.

## Phase notes

- **Phase 0 (research.md)**: three decisions — (a) absorb-then-delete vs
  adapter (resolved: delete, per clarify); (b) neutral-surface enforcement
  (enumerated function list in the gate vs comment markers); (c) the equivalence
  method (full-suite-unchanged + T056 + live dogfood).
- **Phase 1 (data-model.md, contracts/, quickstart.md)**: the neutral Level /
  Payload / Disposition model; the `engine-sink-interface-003.md` contract (the
  unified loop, the extended `sync_level_artifact` responsibilities, the
  enumerated neutral surface + gate, the T056 contract); a quickstart confirming
  operator-observable behavior is unchanged.
