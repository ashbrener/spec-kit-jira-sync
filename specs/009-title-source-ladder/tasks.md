# Tasks: Human-Readable Issue-Title Source Ladder

**Feature**: 009-title-source-ladder | **Branch**: `009-title-source-ladder`

**Input**: plan.md, research.md (R1–R8), data-model.md (VR-1..VR-8),
contracts/title-ladder.md (C-1..C-12), spec.md (FR-001..FR-009, SC-001..SC-006)

**Strategy**: Strict TDD (tests before impl). A small, deterministic change to the
**neutral** title-derivation layer (`workstate.sh` + `parser.sh`) — 3 new pure
functions + 1 rewrite. **Pure filesystem parsing — NO curl-shim** (no Jira). The
**clean-H1 byte-identical** result is the zero-churn regression anchor; lock it
first. Privacy IX is a hard gate (placeholder-only fixtures). No schema change, no
sink change, no new exit code, no amendment.

**Conventions**: `[P]` = parallelizable (disjoint files). Tests precede impl.
Tick `[ ]`→`[X]` as completed.

---

## Phase 1: Setup

- [ ] T001 [P] Create `tests/unit/title_ladder.bats` (new) sourcing `src/parser.sh` + `src/workstate.sh`, with a helper that writes a small placeholder `spec.md` into a `mktemp -d` dir named like `009-<slug>` so `parser::short_name` resolves. (Bodies of the cases land in the phases below.)
- [ ] T002 [P] Confirm `## Summary` is the canonical section (it is — `workstate::_spec_body` reads `^## Summary$`); no template change needed. (Verification task — no file change.)

---

## Phase 2: Foundational (the 3 pure functions — blocks the ladder)

**TDD — write each test first, watch it fail, then implement.**

### `parser::spec_title_line` (the `Title:` rung)

- [ ] T003 Test in `tests/unit/title_ladder.bats`: `parser::spec_title_line <spec.md>` returns the value of a `Title:` line (plain `Title: Foo Bar` AND bold `**Title:**  Foo Bar`), trimmed; a spec with no `Title:` line ⇒ empty output; a `Title:` with an empty value ⇒ empty.
- [ ] T004 Implement `parser::spec_title_line <spec_md_path>` in `src/parser.sh`: clone `parser::spec_author`'s awk exactly, changing the key match to `title` (case-insensitive), strip leading/trailing bold markers, split on the first colon, trim the value, print + exit on first non-empty match; no match ⇒ rc 0 no output. No Jira vocabulary.

### `workstate::_cap_title` (the 120 cap)

- [ ] T005 [P] Test in `tests/unit/title_ladder.bats`: `workstate::_cap_title` — a ≤120-char string is echoed verbatim; a >120 multi-word string is cut to the longest prefix ≤120 ending on a **word boundary** (assert `${#out} ≤ 120`, the output is a prefix of the input, the char after the cut in the input is a space, and NO trailing ellipsis); a >120 single-token string is hard-cut to exactly 120.
- [ ] T006 Implement `workstate::_cap_title <string>` in `src/workstate.sh`: `(( ${#s} <= 120 ))` ⇒ `printf '%s' "$s"`; else take `pre=${s:0:120}`, if `pre` contains a space cut at the last space (`pre=${pre% *}` loop or `${pre%[![:space:]]*}` trim style) else keep `${s:0:120}`; print, no ellipsis. Pure parameter ops — no locale/time/random.

### `workstate::_summary_first_sentence` (the Summary rung)

- [ ] T007 Test in `tests/unit/title_ladder.bats`: a spec whose `## Summary` first prose line is `"Does X. More text."` ⇒ `"Does X."`; a `## Summary` opening with a blockquote/list/image/code-fence then prose ⇒ the first **prose** sentence (C-10); a `## Summary` with only markup / no prose ⇒ empty; a single prose line with no terminal punctuation ⇒ the whole line (trimmed).
- [ ] T008 Implement `workstate::_summary_first_sentence <spec_dir>` in `src/workstate.sh`: pipe `workstate::_spec_body "$spec_dir"`; skip leading lines matching blank / blockquote `^>` / list `^[-*+]` / image `^!` / code-fence / heading `^#` / table `^|`; on the first remaining (prose) line, extract the first sentence — up to the first `.`-followed-by-space, `.`-at-EOL, `?`, or `!` (include the terminator, then trim) — or the whole line if no terminator; trim; empty if no prose line. Deterministic, read-only.

**Checkpoint**: `bats tests/unit/title_ladder.bats` — the 3 foundational units green.

---

## Phase 3: User Story 2 — a clean H1 is preserved exactly (P1, regression anchor) 🎯

**Goal**: lock zero-churn BEFORE wiring fallbacks. **Independent test**: a clean-H1
fixture resolves byte-identically to today; same fixture twice is identical.

- [ ] T009 [US2] Test in `tests/unit/title_ladder.bats` (C-1): a fixture with `# Feature Specification: Clean Name` (and any body) ⇒ `workstate::_spec_title` returns exactly `Clean Name` — and assert it equals the value the **pre-feature** rule produced (capture the old awk's output inline in the test as the oracle). (C-9) Deriving the same fixture twice ⇒ identical output.
- [ ] T010 [US2] Rewrite `workstate::_spec_title <spec_dir>` in `src/workstate.sh` as the 4-rung ladder: (1) `t=$(parser::spec_title_line "$spec_md")`; `[[ -n $t ]]` ⇒ `_cap_title "$t"`, return. (2) compute `h1` (first `#` heading, strip `Feature Specification:` label — keep today's awk); `short=$(parser::short_name "$spec_dir" || true)`; use h1 ⇔ `[[ -n $h1 && $h1 != '[FEATURE NAME]' && $h1 != "$short" && ${#h1} -le 120 ]]` ⇒ `_cap_title "$h1"`, return. (3) `s=$(workstate::_summary_first_sentence "$spec_dir")`; `[[ -n $s ]]` ⇒ `_cap_title "$s"`, return. (4) `printf '%s\n' "$short"`. Preserve the signature + the empty-spec early-return; clean within-cap H1 stays byte-identical (T009 green).

**Checkpoint**: T009 green — the regression anchor holds; clean specs do not churn.

---

## Phase 4: User Story 1 — a weak H1 yields a readable title (P1)

- [ ] T011 [US1] Test (C-2): placeholder H1 `# Feature Specification: [FEATURE NAME]` + `## Summary` with prose ⇒ title = first Summary sentence (capped), NOT the kebab slug.
- [ ] T012 [US1] Test (C-5): no usable `#` heading + a `## Summary` ⇒ title = first Summary sentence.
- [ ] T013 [US1] Test (C-6): no `#` heading, no `## Summary`, dir `009-foo-bar` ⇒ title = `foo-bar` (kebab last resort).
- [ ] T014 [US1] Test (C-7): H1 byte-equal to the kebab short-name + a `## Summary` ⇒ H1 treated as weak ⇒ title = first Summary sentence.
- [ ] T015 [US1] Test (C-10): `## Summary` opening with a list/blockquote/image then prose ⇒ first prose sentence (markup skipped). (Implementation already covered by T008/T010 — these are assertion tasks; fix any gap they reveal.)

**Checkpoint**: `bats tests/unit/title_ladder.bats` — US1 cases green.

---

## Phase 5: User Story 3 — override + verbose-H1 demotion (P2)

- [ ] T016 [US3] Test (C-3): a >120-char verbose H1 + a `## Summary` ⇒ title = first Summary sentence (capped ≤120 on a word boundary), NOT the H1 wall.
- [ ] T017 [US3] Test (C-4): a `Title: Crisp Override` line + a verbose H1 ⇒ title = `Crisp Override` (rung 1 wins).
- [ ] T018 [US3] Test (C-8): a `## Summary` whose first sentence is >120 chars ⇒ title capped ≤120, ends on a word boundary, no mid-word cut, no inserted ellipsis. (Covered by T006/T008/T010 — assertion task; close any gap.)

**Checkpoint**: `bats tests/unit/title_ladder.bats` — all C-1..C-10 green.

---

## Phase 6: Polish & Cross-Cutting

- [ ] T019 [P] Privacy (C-11): extend `tests/unit/no-real-identifiers.bats` to assert the new title fixtures (whether heredoc-inline or under `tests/fixtures/titles/`) are placeholder-only — neutral text only (`Clean Name`, `Does X. More.`, example dirs); no real name/email/coordinate. If fixtures are inline-heredoc (not tracked files), assert the `title_ladder.bats` source itself carries no real identifier.
- [ ] T020 [P] Neutrality (C-12): run `bats tests/unit/engine_vendor_neutral.bats` — green. The new `parser::spec_title_line` / `workstate::_*` functions are in the neutral producer layer, NOT in the audited `reconcile::*` list, and carry no Jira vocabulary. Guard-confirmation task (no change expected).
- [ ] T021 [P] Docs: add a brief note to `README.md` (the section describing what lands in Jira / the spec title) that the spec issue title is derived via a deterministic ladder (explicit `Title:` → concise `# Feature Specification:` H1 → first `## Summary` sentence → dir slug; 120-char cap; no AI). Add a `CHANGELOG.md` `[Unreleased]` entry.
- [ ] T022 Run the **full CI gate** locally (CI parity): `shellcheck --shell=bash --severity=style src/*.sh`, `yamllint -d relaxed .github/workflows/ci.yml`, `npx --yes markdownlint-cli2 "specs/**/*.md" "*.md"`, `bats --recursive tests/unit`. All green.
- [ ] T023 Open the PR into `main` (branch `009-title-source-ladder`): title `feat(title): human-readable issue-title source ladder`; body cites FR-001..FR-009, the deterministic neutral derivation, backward-compat (clean-H1 byte-identical), Privacy IX + 003 neutrality, "no schema change, no amendment; sk-linear port is a follow-up". Confirm the full bats matrix + neutrality + privacy gates green in CI.

---

## Dependencies & ordering

- **Phase 1 → Phase 2 (T003–T008)** → **US2 (T009–T010, the regression anchor — do FIRST among the stories)** → **US1 (T011–T015)** → **US3 (T016–T018)** → **Phase 6**.
- US1 + US3 are assertion-heavy over the ladder built in T010; they reveal and close
  edge gaps in T008/T006 rather than add new code.
- T022 (full gate) precedes T023 (PR).

## Parallel execution examples

- **Phase 1**: T001 ∥ T002. **Phase 2**: T005 (`_cap_title`, pure) is ∥ to the
  `parser`/`_summary` work; tests within `title_ladder.bats` are sequential (same
  file).
- **Phase 6**: T019 ∥ T020 ∥ T021 (distinct files), then T022 → T023.

## MVP scope

**US2 + US1 (Phases 1–4)** is the shippable MVP: clean H1s don't churn, and weak/
missing H1s get a readable Summary-derived title instead of a slug. US3 (override +
verbose-H1 demotion + cap) completes the ceremony in the same PR.

## Implementation strategy

Strict TDD; the **clean-H1 byte-identical** test (T009) is written and locked
**first** so the ladder rewrite (T010) can't regress good titles. The 3 pure
functions are unit-tested in isolation (T003–T008) before composition. Everything is
deterministic filesystem parsing — no Jira, no shim. Neutral layer only (T020);
Privacy IX gates the fixtures (T019). No schema/sink/exit-code change, no amendment.
