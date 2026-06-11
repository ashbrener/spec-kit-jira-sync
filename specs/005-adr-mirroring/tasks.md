---
description: "Task list for feature 005 — ADR / decision-record mirroring"
---

# Tasks: ADR / Decision-Record Mirroring

**Input**: Design documents from `/specs/005-adr-mirroring/`

**Prerequisites**: plan.md, spec.md, research.md (R1–R8), data-model.md,
contracts/{adr-comment-layout,parser-sink-adr}.md

**Tests**: TDD — test tasks precede their implementation.

**Foundation**: a **parallel clone** of the clarify-session comment path
(`parser::clarify_sessions` → workstate `notes[]` → `sync_clarify_comments` + its
hidden-marker idempotency + `DRY-0` guard + fail-closed read), kept isolated so
clarify behavior + tests are untouched. Engine stays vendor-neutral (003 gate);
ADRs ride a neutral `workstate.decisions[]` floor (Principle X). 005 is rebased
onto `main` (#9/#10 merged) — the `DRY-0` guard + parent-scoped find exist.

**Parity oracle**: `contracts/adr-comment-layout.md` (matches linear 008, SC-005).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (disjoint files, no dependency on an incomplete task)
- **[Story]**: US1–US3 (user-story phases only)

---

## Phase 1: Setup

- [x] T001 Add an optional, vendor-neutral `decisions[]` floor field to the workstate schema (`~/Code/AI/workstate-schema/schema/workstate.schema.json`): an array of `{id,title,status,decision,rationale,alternatives,source}` (all strings; `rationale`/`alternatives` optional). **(analyze M1 — cross-repo)** This is a SEPARATE-repo change (this repo validates against `$WORKSTATE_SCHEMA` → the external schema, conditionally — see `workstate.sh:567`); it CANNOT ride the 005 PR. Make the field **additive-safe** (so an item with `decisions[]` still validates against the un-updated schema — confirm the schema is not `additionalProperties:false` at the item level, or land the schema change as its own `workstate-schema` PR first). T004 runs with `WORKSTATE_SCHEMA` pointed at the updated copy.
- [x] T002 [P] Add `research.md` test fixtures under `tests/fixtures/specs/`: one spec dir whose `research.md` uses the **bold-lead** grammar (`**Decision.**`/`**Rationale.**`/`**Alternatives…**`, the form this repo uses) and one using the **stock bullet** grammar (`- Decision:`/`- Rationale:`/`- Alternatives considered:`), each with ≥2 decision blocks incl. one **un-headed** (title-slug) and one with an explicit `R<N>`/`D<N>` heading id; plus a `research.md` with zero decision blocks and a spec with no `research.md`. Placeholders only (Principle IX).

**Checkpoint**: schema field + fixtures available.

---

## Phase 2: Foundational — the ADR pipeline (blocks all user stories)

> TDD: tests (T003–T005) first.

- [x] T003 [P] Unit test `tests/unit/parser_decision_records.bats`: `parser::decision_records` extracts records from BOTH grammars (case-insensitive labels, multi-line values); derives a stable id (heading `R<N>`/`D<N>` else title slug, positional `-2` disambiguation on duplicate slug); returns `[]` for no-file and no-blocks (never errors); omits absent sub-parts (research R1/R2).
- [x] T004 [P] Unit test `tests/unit/workstate_decisions.bats`: the workstate item carries `decisions[]` built from `research.md`; empty `[]` when absent; the array validates against the schema's new floor field.
- [x] T005 [P] Unit test `tests/unit/adr_comment_render.bats`: the ADR body renderer emits the parity layout (title `ADR <id> — <title>`, Status, Decision, Rationale, Alternatives — omitting absent ones — Source `research.md#<id>`, marker last); the normalized-body digest is stable across cosmetic whitespace and changes when content changes (research R5/R6).
- [ ] T006 Implement `parser::decision_records <research_md>` in `src/parser.sh` (tolerant, neutral, never-fails) — makes T003 green.
- [ ] T007 Implement `workstate::_decisions_json <spec_dir>` in `src/workstate.sh` and wire `decisions[]` into item assembly next to `_notes_json` — makes T004 green. Depends on T006.
- [ ] T008 Implement the ADR body renderer (ADF, reusing `adf::from_markdown`/comment builders, per `contracts/adr-comment-layout.md`) + a normalized-body comparison helper in `src/jira_sink.sh` — makes T005 green. **(analyze M2)** The "is it changed?" check normalizes the *fetched existing comment body* and compares it to the desired rendered body (the identity marker is stable in both, so it doesn't affect the compare) — no separately-stored digest token needed.
- [ ] T008b Implement `jira_sink::mutate_comment_update <issue_key> <comment_id> <body_adf>` in `src/jira_sink.sh` — PUT `/issue/{key}/comment/{id}`, mirroring `mutate_comment_create` (DRY_RUN no-op, malformed-ADF guard, fail logging with `_error_detail`). **(analyze H1 — NET-NEW: the clarify path is create-or-skip only; there is no comment-update primitive today.)** Unit-test it alongside T006–T009.
- [ ] T009 Implement `jira_sink::sync_decision_records <issue_key> <item_json>` in `src/jira_sink.sh`: per `item.decisions[]`, compute marker `[speckit-adr:<spec>-<id>]` (spec num from `item.id`); `query_existing_comment_body` (paginated, returns `{id,body}`) → rc 3 fail-closed; ABSENT → `mutate_comment_create`; PRESENT → if the normalized bodies differ, `mutate_comment_update` using the returned `id` (FR-005, in place — no duplicate), else skip; honor `DRY_RUN` + the `DRY-0` placeholder; tally create/update/skip (FR-002/004/005/010). Depends on T008, T008b.
- [ ] T010 Implement engine wrapper `reconcile::sync_decision_records` in `src/reconcile.sh` and wire a call right AFTER `reconcile::sync_clarify_comments` at BOTH call sites (`process_spec` + `process_workstate_item`), same rc-3-fail-closed / rc≠0-exit-1 handling + `DRY-0` guard. Depends on T009.
- [ ] T011 Confirm the engine path stays vendor-neutral: the `decisions[]` extraction/projection carry no Jira issue-type/artifact/relationship tokens. If `reconcile::sync_decision_records` is a thin sink-delegating wrapper (like the clarify wrapper, not audited), no gate change is needed; otherwise add it to `tests/unit/engine_vendor_neutral.bats` `_audited_functions`. Gate stays green.

**Checkpoint**: the ADR pipeline (parse → decisions[] → render+digest → sink → wired) is unit-green; neutrality gate green.

---

## Phase 3: User Story 1 — Decisions show up on the spec issue (P1) 🎯 MVP

**Goal**: a spec's `research.md` ADRs appear as one comment each on its Jira issue.

**Independent test**: reconcile a 2-ADR spec → the issue gains exactly two ADR
comments with the decision/rationale/alternatives/source; coexist with clarify.

- [ ] T012 [P] [US1] Integration `tests/integration/adr_us1_mirror.bats`: a spec whose `research.md` has 2 decisions → exactly 2 ADR comments created (absent → create), each carrying id/title/status/decision/rationale/alternatives + `research.md#<id>` source + the `[speckit-adr:…]` marker (AS-1, SC-001).
- [ ] T013 [P] [US1] Integration: a spec already mirrored with clarify-session comments → ADR comments are ADDED without touching the clarify (`speckit-note:`) comments — disjoint marker streams coexist (AS-3, FR-008).
- [ ] T014 [P] [US1] Integration: a spec with no `research.md` (and one with a `research.md` that has no decision blocks) → ZERO ADR comments, ZERO errors, run completes (AS-2, FR-007, SC-004).
- [ ] T015 [US1] Wire US1 green + FR-008 observability: the run summary tallies ADR comments created (no silent posting). Depends on T010.

**Checkpoint**: US1 is the MVP — ADRs mirror to the issue, coexisting with clarify, graceful when absent.

---

## Phase 4: User Story 2 — Re-running never duplicates or churns (P1)

**Goal**: each ADR appears once; unchanged → zero churn; edited → one in-place update.

**Independent test**: reconcile twice unchanged → 0 writes; edit one ADR → 1
update, 0 creates; add one → 1 create.

- [ ] T016 [P] [US2] Integration `tests/integration/adr_us2_idempotent.bats`: re-run against an already-mirrored, unchanged corpus → 0 ADR creates, 0 edits (digest match → skip) (AS-1, FR-004, SC-002).
- [ ] T017 [P] [US2] Integration: change one ADR's decision/rationale text on disk → exactly 1 comment UPDATED in place, 0 new comments (find-by-marker + digest mismatch) (AS-2, FR-005, SC-003).
- [ ] T018 [P] [US2] Integration: add a new ADR to `research.md` → exactly 1 new comment, existing ADR comments untouched (AS-3, FR-006).
- [ ] T019 [P] [US2] Integration: an unreadable comment probe → rc 3 fail-closed (no blind duplicate); a `DRY-0` placeholder issue (dry-run of an unmirrored spec) → the probe is skipped, no 404 (FR-010, edge case).
- [ ] T020 [US2] Harden `sync_decision_records` digest/update path if any of T016–T019 fail. Depends on T016–T019.

**Checkpoint**: idempotent + update-in-place + fail-closed proven.

---

## Phase 5: User Story 3 — Consistent with the Linear sibling (P2)

**Goal**: the ADR comment's user-visible shape matches linear 008.

**Independent test**: the rendered ADR body matches the golden contract layout.

- [ ] T021 [P] [US3] Integration `tests/integration/adr_parity.bats`: render an ADR from a fixed `research.md` fixture and assert the body matches `contracts/adr-comment-layout.md` exactly — title line, Status, Decision/Rationale/Alternatives (absent omitted), Source `research.md#<id>`, marker last (FR-009, SC-005). This is the same golden shape the Linear sibling asserts.
- [ ] T022 [US3] Reconcile any layout drift to the golden contract (and update the contract + the Linear sibling's expectation if a deliberate shape change is agreed). Depends on T021.

**Checkpoint**: cross-sink parity locked by a golden test.

---

## Phase 6: Polish & cross-cutting

- [ ] T023 [P] Document the ADR mirror in `README.md` ("What lands in Jira" — add the ADR-comment row) and note in `config-template.yml` that it needs no config (additive, on by default). markdownlint clean.
- [ ] T024 [P] `CHANGELOG.md` `[Unreleased] → ### Added`: ADR / decision-record mirroring (research.md decisions → idempotent spec-issue comments; linear-parity; neutral `decisions[]` floor).
- [ ] T025 [P] Privacy guard: confirm every new fixture/test uses placeholder coordinates; `tests/unit/no-real-identifiers.bats` green (Privacy IX / FR-013).
- [ ] T026 Run `scripts/check.sh` to green at CI parity (move `.specify/extensions/jira/jira-config.yml` + `tests/.private-deny` aside): shellcheck, yamllint relaxed, markdownlint, full bats. Fix any lint.
- [ ] T027 Confirm the **003 neutrality gate** + the existing suite are unchanged — NO regression in the clarify-comment path (the ADR stream is isolated; clarify-comment counts must be identical to pre-005). **(analyze L1)** Also assert FR-012: no new command / no `extension.id` change / no new CLI surface was added (ADR mirroring is additive on the existing reconcile path).
- [ ] T028 Open the `005 → main` PR after green; PR body notes the linear-008 parity + the neutral `decisions[]` floor + no-amendment Constitution result.

---

## Dependencies & execution order

- **Phase 2 foundational** (T003–T011) blocks all user stories. Within it: tests T003–T005 [P]; then T006 → T007 (workstate, needs parser), T008 (renderer+digest), T009 (sink, needs T008) → T010 (engine wiring, needs T009) → T011 (neutrality confirm).
- **User stories after foundational**: US1 (T012–T015) is the MVP; US2 (T016–T020) and US3 (T021–T022) are independently testable and can be tackled in priority order — they share the foundational pipeline but add no new production dependency on each other (US2 may harden T009, US3 may touch the renderer T008).
- **Polish** (T023–T028) last; T026/T027 gate the T028 PR.

## Parallel execution examples

- **Phase 2 tests**: T003, T004, T005 in parallel (three disjoint new test files).
- **US1**: T012, T013, T014 in parallel (disjoint integration files) before T015.
- **US2**: T016–T019 in parallel before T020.
- **Polish**: T023, T024, T025 in parallel (docs / changelog / privacy — disjoint).

## Implementation strategy

**MVP = Phase 1 + Phase 2 + US1 (T001–T015)**: ADRs from `research.md` rendered as
comments on the spec issue, coexisting with clarify, graceful when absent. US2 then
locks idempotency + update-in-place (inseparable from MVP value), US3 locks the
Linear parity. Keep the full gate green at every checkpoint; the clarify-comment
path must stay byte-identical.
