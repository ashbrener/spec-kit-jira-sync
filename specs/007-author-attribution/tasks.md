---
description: "Task list for feature 007 — author-based attribution"
---

# Tasks: Author-Based Attribution

**Input**: Design documents from `/specs/007-author-attribution/`

**Prerequisites**: plan.md, spec.md, research.md (R1–R7), data-model.md,
contracts/{authors-map,attribution-seam}.md

**Tests**: TDD — test tasks precede their implementation.

**Seam (003)**: author **resolution** is vendor-neutral (parser/git_helpers →
neutral `item.author` floor); the **assignee/accountId/handle** mechanics are
sink-only. `engine_vendor_neutral.bats` MUST stay green. Opt-in, default OFF =
byte-identical (US4 anchor). Privacy IX is a hard gate.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (disjoint files, no dependency on an incomplete task)
- **[Story]**: US1–US4 (user-story phases only)

---

## Phase 1: Setup

- [ ] T001 Add `.specify/extensions/jira/jira-authors.local.yml` to `.gitignore` (the operator map holds real emails/accountIds = PII; mirror the existing `.env`/`jira-config.yml` ignores). Confirm `git check-ignore` matches.
- [ ] T002 [P] Commit `.specify/extensions/jira/jira-authors.local.yml.sample` — the map shape with **placeholder** ids only (per `contracts/authors-map.md`), shaped not to self-match the privacy guard (Principle IX).
- [ ] T003 [P] Add the opt-in `attribution:` block to `config-template.yml` (`enabled`/`assignee`/`label`/`author_source`/`authors_file`), documented as default-OFF = today's behavior.
- [ ] T004 Add a neutral, additive `author` floor field (`{value, source}`) to the workstate schema (`~/Code/AI/workstate-schema/schema/workstate.schema.json`). **(cross-repo, like 005's `decisions[]`)** Additive-safe (items without it still validate); CANNOT ride the 007 PR; the bridge CI gate doesn't require it (validation conditional). Merge to the schema repo's local main.

**Checkpoint**: gitignore + sample + config block + schema field in place.

---

## Phase 2: Foundational — neutral resolution + sink map load (blocks all stories)

> TDD: tests (T005–T007) first.

- [ ] T005 [P] Unit `tests/unit/author_resolution.bats`: `parser::spec_author` returns an `Owner:`/`Author:` line value (case-insensitive) else empty; `git_helpers::spec_first_author` returns the first-add email (fixture git repo) else empty; `workstate::_author_json` resolves Owner-first-else-git-else-empty, emitting `{value,source}` (research R1/R2).
- [ ] T006 [P] Unit `tests/unit/authors_map.bats`: `jira_sink::_load_authors` parses the gitignored map → `email→{accountId,handle}` + `default_assignee`; a `null` accountId is label-only; an absent file → empty map; a known author missing `handle` is flagged.
- [ ] T007 [P] Unit `tests/unit/attribution_config.bats`: `config` accessors for `attribution.{enabled,assignee,label,author_source,authors_file}`; absent block ⇒ disabled (default OFF).
- [ ] T008 Implement `parser::spec_author <spec_md>` in `src/parser.sh` (neutral) — makes T005(a) green.
- [ ] T009 Implement `git_helpers::spec_first_author <spec_dir>` in `src/git_helpers.sh` (`git log --diff-filter=A --reverse --format='%ae' -- <dir>/ | head -1`; empty on no-git) — makes T005(b) green.
- [ ] T010 Implement `workstate::_author_json <spec_dir>` in `src/workstate.sh` and wire `item.author` into `item_for_spec` (neutral floor; Owner-first-else-git). Depends on T008, T009. **(analyze M1 — the flow to the sink)** Because `sync_level_artifact` consumes the *neutral* `compose_payload` output (not the raw item), `reconcile::compose_payload spec` MUST also pass `author {value,source}` through (a neutral string + source enum — audited-gate-safe, no Jira vocab) so the sink's create branch can read `input.author`. Thread it there, not via a side-channel.
- [ ] T011 Implement the `attribution.*` config accessors in `src/config.sh` — makes T007 green.
- [ ] T012 Implement `jira_sink::_load_authors <path>` in `src/jira_sink.sh` (parse the gitignored map; absent → empty) — makes T006 green.
- [ ] T013 Confirm the engine/parser path is vendor-neutral: author resolution + the `author` floor carry no Jira account/issue-type vocabulary; the gate (`engine_vendor_neutral.bats`) stays green (parser/git_helpers/workstate aren't audited engine fns; the reconcile threading is neutral).

**Checkpoint**: author resolves neutrally onto the item; the sink can load the map; config gates exist.

---

## Phase 3: User Story 1 — The board shows who authored each spec (P1) 🎯 MVP

**Goal**: enabled + a mapped author → the spec issue is created assigned to that
account AND labelled `author:<handle>`.

**Independent test**: reconcile a spec whose author maps to an accountId → the
create payload carries `fields.assignee.accountId` and the labels include
`author:<handle>`.

- [ ] T014 [P] [US1] Integration `tests/integration/attr_us1_assignee_label.bats`: attribution enabled, author mapped to an accountId+handle → on CREATE the spec issue's payload has `fields.assignee.accountId` AND `author:<handle>` in labels (AS-1, SC-001); an `Owner:` line overrides the git author (AS-2).
- [ ] T015 [US1] Implement attribution in the spec-level sync (`src/jira_sink.sh`): read `input.author` (from `compose_payload`, per T010); load the authors map; on the ABSENT→**CREATE** branch inject `fields.assignee.accountId` when the author maps to a non-null accountId (the create-only gate — `JIRA_SINK_LEVEL_DISPOSITION` is the create signal); extend the composed `labels_json` with `author:<handle>` (the sink resolves value→handle from the map — the neutral payload never holds the handle); emit the author+source summary row (FR-001/FR-002/FR-004). Depends on T010–T012. **(analyze M2)** Attribution applies at the spec→Task level only; the optional epic/phase **label-inheritance toggle** (FR-005 second half) is OUT of MVP scope (default spec-level only) — note it as a future stretch, do not implement now.

**Checkpoint**: US1 MVP — mapped authors are assigned + labelled on create.

---

## Phase 4: User Story 2 — Non-Jira-users are still attributed (P1)

**Goal**: a known author with no accountId → unassigned but labelled; an
unresolvable author → graceful no-op.

**Independent test**: a `null`-accountId author → the issue is unassigned but
carries `author:<handle>`; an unknown author → no label, no assignee, no error.

- [ ] T016 [P] [US2] Integration `tests/integration/attr_us2_nonuser_label.bats`: a known author whose map entry has `accountId: null` → CREATE omits assignee but labels `author:<handle>` (AS-1, SC-002); a spec with no `Owner:` line and no git history → no author label, no assignee, run completes (AS-2, FR-007 graceful).
- [ ] T017 [US2] Harden the sink path for `null` accountId (label-only) and unknown author (skip both) in `src/jira_sink.sh`. Depends on T015.

**Checkpoint**: the universal label track works for everyone, including non-members.

---

## Phase 5: User Story 3 — Idempotent, never clobbers a manual reassignment (P1)

**Goal**: assignee set on create only; update sends none; the `author:*` label is
stable (stripped-then-set).

**Independent test**: create (assignee set) → manually reassign → reconcile again
→ no assignee field in the update payload, the manual assignee survives; one
stable `author:*` label.

- [ ] T018 [P] [US3] Integration `tests/integration/attr_us3_idempotent.bats`: an existing (already-created) spec issue → the UPDATE payload contains **no** assignee field (FR-003/SC-003, Linear FR-034); re-run leaves exactly one `author:<handle>` label (stale `author:*` stripped, not stacked) (FR-004); a changed author replaces the label.
- [ ] T019 [US3] Implement the **create-only assignee gate** (assignee only in the CREATE payload, never UPDATE) and the **strip-stale-then-set** `author:*` label hygiene in `src/jira_sink.sh`. Depends on T015.

**Checkpoint**: idempotent + manual-reassignment-safe.

---

## Phase 6: User Story 4 — Off by default, zero behavior change (P2)

**Goal**: `attribution.enabled` false/absent ⇒ byte-identical to today.

**Independent test**: with the block absent, the create/update payloads have no
assignee and no `author:*` label.

- [ ] T020 [P] [US4] Integration `tests/integration/attr_us4_off_byte_identical.bats`: `attribution.enabled` absent AND false → zero assignee fields, zero `author:*` labels in every payload; identical to pre-007 (AS-1, FR-006, SC-004).
- [ ] T021 [US4] Confirm the default-OFF short-circuit (no map load, no resolution side-effects, no payload change) in `src/reconcile.sh`/`src/jira_sink.sh`. Depends on T015.

**Checkpoint**: backward-compat regression anchor holds.

---

## Phase 7: Cross-cutting + Polish

- [ ] T022 [US1] FR-008 fail-soft: a rejected assignee write (bad/stale accountId) is **surfaced** (warned, with `_error_detail`) and the spec still completes with its `author:<handle>` label — NOT a full-run abort. Integration `tests/integration/attr_bad_assignee_failsoft.bats`. Depends on T015.
- [ ] T023 [P] Privacy guard: extend/confirm `tests/unit/no-real-identifiers.bats` covers the new `.sample` + every attribution fixture (no real email/accountId; labels carry a non-PII handle, never an email) — Privacy IX / FR-010.
- [ ] T024 [P] Docs: `README.md` (attribution section — enable + the two tracks + the project-default-assignee `PROJECT_LEAD` caveat, FR-007) and `config-template.yml` cross-ref; markdownlint clean.
- [ ] T025 [P] `CHANGELOG.md` `[Unreleased] → ### Added`: author-based attribution (two-track: author label always + assignee on create; opt-in; gitignored map).
- [ ] T026 Confirm the **003 neutrality gate** + the existing suite are unchanged (no regression in the spec sync's non-attribution path; off-by-default byte-identical).
- [ ] T027 Run `scripts/check.sh` to green at CI parity (move `.specify/extensions/jira/jira-config.yml` + `tests/.private-deny` aside): shellcheck, yamllint relaxed, markdownlint, full bats. Fix any lint.
- [ ] T028 **Rebase 007 onto post-005 `main`** (once #12 merges) to absorb 005's `jira_sink.sh`/`reconcile.sh` changes, re-run the gate, then open the `007 → main` PR (body notes Linear FR-034 parity + the gitignored authors map + no-amendment Constitution result + the separate workstate-schema author-field change).

---

## Dependencies & execution order

- **Phase 1 setup** (T001–T004) then **Phase 2 foundational** (T005–T013) block all stories. Within Phase 2: tests T005–T007 [P]; then T008/T009 (parser/git) → T010 (workstate, needs both), T011 (config), T012 (map load) → T013 (neutrality).
- **User stories after foundational**: US1 (T014–T015) is the MVP; US2 (T016–T017), US3 (T018–T019), US4 (T020–T021) each independently testable. US2/US3 harden the same sink attribution path T015 adds, so they are sequential on `jira_sink.sh` (not [P] with each other for the impl tasks; their tests ARE [P]).
- **Polish** (T022–T028) last; T026/T027 gate the T028 PR.

## Parallel execution examples

- **Phase 1**: T002, T003 in parallel (sample + config — disjoint).
- **Phase 2 tests**: T005, T006, T007 in parallel (three disjoint test files).
- **US test files**: T014, T016, T018, T020 in parallel (disjoint integration files) before their impl tasks.
- **Polish**: T023, T024, T025 in parallel (privacy / docs / changelog — disjoint).

## Implementation strategy

**MVP = Phase 1 + Phase 2 + US1 (T001–T015)**: enabled + a mapped author → the
spec issue is assigned + labelled on create. US2 then covers the universal label
(non-members), US3 locks idempotency + manual-reassignment safety (inseparable
from the assignee track), US4 is the backward-compat anchor. Keep the full gate
green at every checkpoint; the default-OFF path must stay byte-identical.
