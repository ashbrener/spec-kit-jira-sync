# Tasks: Consumer-Side Privacy Guard

**Feature**: 006-consumer-privacy-guard | **Branch**: `006-consumer-privacy-guard`

**Input**: plan.md, research.md (R1–R10), data-model.md (VR-1..VR-8),
contracts/privacy-guard.md (C-1..C-9), spec.md (FR-001..FR-014, SC-001..SC-006)

**Strategy**: Strict TDD (tests before impl). The neutral scan **mechanism** lives
in `src/privacy_guard.sh` + `reconcile::privacy_gate`; the Atlassian
**shapes/known-values/ignore-targets** live only in `src/jira_sink.sh`. The
`tests/helpers/jira-shim.bash` curl-shim proves **zero Jira writes** on a tripped
gate. Privacy IX (no self-matching fixtures) is a hard gate throughout.

**Conventions**: `[P]` = parallelizable (disjoint files, no incomplete dep).
Tests for a unit precede its implementation. Tick each `[ ]`→`[X]` as completed.

---

## Phase 1: Setup

- [X] T001 Add exit code **4** ("consumer-tree privacy leak — fail-closed, zero Jira writes") to the exit-code table in the `src/reconcile.sh` header comment (after the `3 — transport failure` line) and to the `usage()`/`--help` text block in `src/reconcile.sh`.
- [X] T002 [P] Document exit code 4 in the exit-code table of `specs/001-core-bridge/contracts/cli.md` (the canonical CLI contract), matching the wording in T001.
- [X] T003 [P] Create `src/privacy_guard.sh` skeleton: a **vendor-neutral** header (state explicitly: no Jira/Atlassian vocabulary — extractable alongside the engine; mechanism only), `set`-safe sourcing comment, and empty stubs for `privacy_guard::assert_git` and `privacy_guard::scan` (bodies filled under Phase 2). Add the `# shellcheck source=` wiring in `src/reconcile.sh`'s module-sourcing block so the new module is sourced (order: after `config.sh`, before/with the other helpers).

**Checkpoint**: `bash -n src/privacy_guard.sh src/reconcile.sh` parses; the help
text and both contracts list exit 4.

---

## Phase 2: Foundational (neutral mechanism — blocks all user stories)

**TDD — write each test first, watch it fail, then implement.**

### `reconcile::promote_exit 4` terminal

- [X] T004 Test in `tests/unit/reconcile_exit_codes.bats` (create if absent, else extend): `reconcile::promote_exit 4` sets the exit to 4; a subsequent `promote_exit 1`/`3`/`0` does NOT demote it (4 is terminal, like 2); and `promote_exit 2` after a 4 is the only thing that may co-exist per the existing 2-is-terminal rule — assert 4 stays ≥ 3/1 and is not overwritten by them.
- [X] T005 Implement: extend the `case` in `reconcile::promote_exit` (`src/reconcile.sh`) so `4) RECONCILE_EXIT_CODE=4 ;;` is terminal (guard the top-of-function early-return so a set `4` is never demoted by `1`/`3`, mirroring the `== 2` guard). Keep `2` terminal precedence intact.

### `privacy_guard::assert_git` (FR-010)

- [X] T006 [P] Test in `tests/unit/privacy_guard.bats` (new): in a non-git temp dir, `privacy_guard::assert_git` returns non-zero (C-6 unit half); in a git work-tree it returns 0.
- [X] T007 Implement `privacy_guard::assert_git` in `src/privacy_guard.sh`: `git rev-parse --is-inside-work-tree >/dev/null 2>&1` — rc passthrough. No vendor vocabulary.

### `privacy_guard::scan` (the core mechanism — VR-1, VR-3, VR-5)

- [X] T008 Test in `tests/unit/privacy_guard.bats`: drive `privacy_guard::scan` with **stub** callbacks emitting `severity<TAB>class<TAB>pattern` lines (a fake shapes fn with one `block` regex + one `warn` regex, a fake known-values fn with one `block` literal, a fake ignore fn). In a throwaway git repo: (a) a tracked file matching the `block` regex ⇒ a `block<TAB>class<TAB>file` finding + **rc 1**; (b) a tracked file matching ONLY the `warn` regex ⇒ a `warn<TAB>class<TAB>file` finding + **rc 0** (warn never fails); (c) a tracked file containing the `block` literal ⇒ finding + rc 1; (d) a placeholder-clean repo ⇒ no output + rc 0.
- [X] T009 Test (same file) for the **ignore-target assertion**: a path passed by the ignore fn that is **tracked** (`git add`ed) ⇒ violation + rc 1; a path that **exists but is not gitignored** ⇒ violation + rc 1; a path that is gitignored-and-untracked ⇒ no violation; a path that does not exist ⇒ no violation (vacuously safe).
- [X] T010 Test (same file) **no-re-leak (VR-3/C-5)**: when a known-value literal matches, the scan's output contains the **class label and the file path** but does NOT contain the literal's bytes (assert the matched secret string is absent from `$output`).
- [X] T011 Test (same file) **read-only (VR-5/C-9)**: snapshot the repo (e.g. `git status --porcelain` + a checksum of the tree) before and after a `privacy_guard::scan` that finds violations; assert byte-identical (no edit/stage/commit).
- [X] T012 Implement `privacy_guard::scan SHAPES_FN KNOWN_FN IGNORE_FN` in `src/privacy_guard.sh` (callbacks emit `severity<TAB>class<TAB>pattern`):
  - enumerate `git ls-files -z`;
  - **shape pass**: for each `severity<TAB>class<TAB>regex` from `SHAPES_FN`, `git ls-files -z | xargs -0 grep -lIiE -- "$regex"` → each path emits `severity<TAB>class<TAB>path`;
  - **known-value pass**: for each `severity<TAB>class<TAB>literal` from `KNOWN_FN` (always `block`), `… | xargs -0 grep -lIFe -- "$literal"` → `block<TAB>class<TAB>path`;
  - **ignore assertion**: for each path from `IGNORE_FN`, `block<TAB>tracked-config<TAB>path` if `git ls-files --error-unmatch -- "$path"` rc 0, OR if `[ -e "$path" ] && ! git check-ignore -q -- "$path"`;
  - print all finding lines to stdout; **rc 1 iff ≥1 `block` finding, else rc 0** (a warn-only run returns 0). Use only `grep -l` (never `-n`), `-I` (skip binaries, FR-008), `--` termination. Read-only only. **No Jira vocabulary.**

### Neutrality-audit registration (C-7)

- [X] T013 Add `reconcile::privacy_gate` to the `_audited_functions()` list in `tests/unit/engine_vendor_neutral.bats` (so the gate is statically proven free of Atlassian vocabulary once implemented in Phase 3). The audit must stay green after Phase 3.

**Checkpoint**: `bats tests/unit/privacy_guard.bats tests/unit/reconcile_exit_codes.bats`
green; mechanism is vendor-neutral and read-only.

---

## Phase 3: User Story 1 — a real identifier stops the bridge (P1) 🎯 MVP

**Goal**: shape + known-value leak in the consumer tree ⇒ fail closed (exit 4),
zero Jira writes, file+class named. **Independent test**: commit a forbidden-shape
fixture in a throwaway consumer repo, run reconcile over the shim, assert exit 4 +
no mutating curl call + the clean-tree case proceeds.

### Tests first

- [X] T014 [P] [US1] Test `jira_sink::privacy_shapes` in `tests/unit/jira_sink_privacy.bats` (new): it prints five `severity<TAB>class<TAB>regex` lines — `block` for `api-token` + `site`, `warn` for `email` + `cloudId-uuid` + `accountId`; each regex matches a synthetic placeholder of that shape (`<name>.atlassian.net`, a fabricated UUID) while NOT matching a neutral control string.
- [X] T015 [P] [US1] Test `jira_sink::privacy_known_values` in `tests/unit/jira_sink_privacy.bats`: with `JIRA_EMAIL`/`JIRA_BASE_URL`/`JIRA_API_TOKEN` exported, it emits `block<TAB>email<TAB>…`, `block<TAB>site<TAB><host>` (scheme stripped), `block<TAB>api-token<TAB>…`; with an authors map containing an accountId, `block<TAB>accountId<TAB><id>`; with NONE present it emits zero lines (degrades to no-op). All known values are `block` tier.
- [X] T016 [US1] Integration test `tests/unit/privacy_gate_us1.bats` (new, curl-shim): in a throwaway git repo with a minimal valid `jira-config.yml` + a tracked file containing an `<x>.atlassian.net` host (BLOCK), run `reconcile.sh --all` over the shim and assert: exit **4**; the summary names the file + the `site` class; the shim recorded **zero mutating** requests (no POST/PUT). (C-1)
- [X] T017 [US1] Test (same file) **known-value (C-2)**: export a fabricated `JIRA_EMAIL`, put that exact string in a tracked file, run reconcile, assert exit 4 + the `email` class named + zero writes.
- [X] T018 [US1] Test (same file) **dry-run (C-8)**: with a leaking BLOCK tree and `--dry-run`, assert the gate still fires (exit 4) and nothing is written — the status preview fails closed.
- [X] T018b [US1] Test (same file) **WARN tier (C-10/SC-007)**: a tracked file containing ONLY a broad shape (a fabricated UUID and a generic `someone@example.com`, no known-value, no high-signal shape) ⇒ reconcile does **not** exit 4 (proceeds), and the summary carries a `warn` row naming the file + class. Proves the broad shapes never fail closed.

### Implementation

- [X] T019 [US1] Implement `jira_sink::privacy_shapes` in `src/jira_sink.sh`: print the five `severity<TAB>class<TAB>regex` lines — `block` for `api-token` (`ATA"+"TT…`) + `site` (fragment the `atlas"+"sian` literal so the source never self-matches), `warn` for `email` + `cloudId-uuid` + `accountId`. Regexes per research R4. Fragment every literal that could self-match (Privacy IX / FR-009).
- [X] T020 [US1] Implement `jira_sink::privacy_known_values` in `src/jira_sink.sh`: emit `block<TAB>email<TAB>$JIRA_EMAIL`, `block<TAB>site<TAB>${JIRA_BASE_URL#*://}` (trailing `/` stripped), `block<TAB>api-token<TAB>$JIRA_API_TOKEN` only when each var is non-empty; parse accountIds from the gitignored `jira-authors.local.yml` (via 007's `jira_sink::_load_authors`, or a minimal `grep`/`jq` if absent) and emit `block<TAB>accountId<TAB><id>` per non-null id. Absent ⇒ no line. Never echo these anywhere else.
- [X] T021 [US1] Implement `reconcile::privacy_gate` in `src/reconcile.sh` (**vendor-neutral** — references only the sink callback NAMES): call `privacy_guard::assert_git` (rc≠0 ⇒ `summary::add error "not a git repo — cannot verify the tracked tree; refusing to write"` + `promote_exit 4` + return 1); else capture findings from `privacy_guard::scan jira_sink::privacy_shapes jira_sink::privacy_known_values jira_sink::privacy_ignore_targets` (rc 1 iff a `block` finding); emit a `summary::add warn` per `warn` finding (always); on rc≠0 emit a `summary::add error` per `block` finding (file + class + remediation — see T026) + `promote_exit 4` + return 1; on rc 0 return 0 (the run proceeds — WARN rows may have been added, SC-007).
- [X] T022 [US1] Wire the call into `reconcile::main` (`src/reconcile.sh`) **immediately after `reconcile::load_config`** (so the resolved config path is known) and **before** the `remode`/`run_workstate`/per-spec write fork: `if ! reconcile::privacy_gate; then` … finalize the summary and `exit "$RECONCILE_EXIT_CODE"` (4) without entering any write path. Runs in both dry-run and real mode (the load happened before the fork).

**Checkpoint**: `bats tests/unit/privacy_gate_us1.bats tests/unit/jira_sink_privacy.bats`
green; a leaking tree ⇒ exit 4 + zero writes in both modes; a clean tree proceeds.

---

## Phase 4: User Story 2 — config & credentials are gitignored (P1)

**Goal**: the resolved `jira-config.yml`, `.env`, and `jira-authors.local.yml` must
be gitignored-and-untracked; tracked/unignored ⇒ fail closed, path named.

- [X] T023 [P] [US2] Test `jira_sink::privacy_ignore_targets` in `tests/unit/jira_sink_privacy.bats`: it prints the active resolved-config path (the `--config` value / `RECONCILE_CONFIG_PATH` default `.specify/extensions/jira/jira-config.yml`), `.env`, and `.specify/extensions/jira/jira-authors.local.yml`.
- [X] T024 [US2] Integration test `tests/unit/privacy_gate_us2.bats` (new, curl-shim): (a) clean repo with config + `.env` gitignored ⇒ gate passes; (b) `git add` the resolved `jira-config.yml` ⇒ exit 4, the config path named; (c) make `.env` tracked (or remove its ignore rule) ⇒ exit 4, `.env` named. Zero writes in the failing cases. (C-3)
- [X] T025 [US2] Implement `jira_sink::privacy_ignore_targets` in `src/jira_sink.sh`: emit the three paths (resolve the config path from the same module global the engine uses, `RECONCILE_CONFIG_PATH`, falling back to the default). Vendor-aware (the Jira paths) — correct location per the seam.

**Checkpoint**: `bats tests/unit/privacy_gate_us2.bats` green.

---

## Phase 5: User Story 3 — actionable message, no re-leak (P2)

**Goal**: the failure names file + shape class + copy-paste remediation, and never
echoes the matched secret.

- [X] T026 [US3] Implement the remediation wording in `reconcile::privacy_gate` (`src/reconcile.sh`, refining T021's `summary::add error`): `"<file>: forbidden <class> in a tracked file — move real values to the gitignored .env / jira-config.yml, replace the tracked occurrence with a neutral placeholder, and scrub history if already committed (rotate the token if it was a credential)."` Use the violation's `class`+`file` only.
- [X] T027 [US3] Test in `tests/unit/privacy_gate_us3.bats` (new): trigger each of the five shape classes + a tracked-config case; assert every failure message contains the file path, the shape-class label, and the word "placeholder"/"scrub" (remediation), and assert the **matched secret bytes are absent** from the combined summary output (C-5 / SC-004). Reuse a fabricated literal so the assertion is exact.

**Checkpoint**: `bats tests/unit/privacy_gate_us3.bats` green.

---

## Phase 6: Polish & Cross-Cutting

- [X] T028 [P] Integration test `tests/unit/privacy_gate_us1.bats` (extend) **C-6 end-to-end**: run `reconcile.sh --all` with cwd a non-git temp dir (valid config copied in) ⇒ exit 4, "not a git repo" message, zero writes.
- [X] T029 [P] Test **US4 byte-identical clean pass (SC-002)** in `tests/unit/privacy_gate_us4.bats` (new): a placeholder-clean repo with gitignored config/.env produces the SAME summary rows as a run with the gate disabled/absent would — assert no privacy-related summary row is added on the clean path (the gate is a silent pass), and the reconcile proceeds to its normal create/update/skip outcome over the shim.
- [X] T030 [P] Confirm **C-7 neutrality**: run `bats tests/unit/engine_vendor_neutral.bats` with `reconcile::privacy_gate` in the audited list — green (the gate body has no `atlassian`/`assignee`/`issuetype`/etc. token; all shapes are in `jira_sink::privacy_*`). Fix any leakage by moving vocabulary to the sink.
- [X] T031 [P] **Dogfood self-scan (C-11/FR-009/SC-005)** in `tests/unit/privacy_dogfood.bats` (new): source the real `src/privacy_guard.sh` + `src/jira_sink.sh`, run `privacy_guard::scan jira_sink::privacy_shapes <empty-known> jira_sink::privacy_ignore_targets` over **this** repo's own tracked tree, and assert **zero `block` findings** (the `ATATT`/`atlassian.net` shapes do not self-match the fragmented source; the resolved config/.env are gitignored). WARN findings (the reserved `example.com` emails, fixture UUIDs) are allowed — assert the run is NOT blocked. This is the bridge-is-its-own-consumer edge case + the FR-009 self-match proof. Also extend `tests/unit/no-real-identifiers.bats` to cover any new tracked fixture (placeholder-only).
- [X] T032 [P] Docs: add a "Consumer-side privacy guard" section to `README.md` (auto pre-write gate; the five shapes + known-value pass; exit 4; remediation) and to `CONTRIBUTING.md` (the guard's design + that gitleaks/trufflehog are **recommended, not bundled**, best-effort if on `PATH`, never a dependency; trufflehog live-verify off). Mirror `quickstart.md`.
- [X] T033 [P] Add a `CHANGELOG.md` `[Unreleased]` entry: "Consumer-side privacy guard — fail-closed pre-write gate scanning the consumer's tracked tree for the operator's own coordinates + Atlassian shapes; exit 4; asserts config/.env gitignored. Enforces Principle IX."
- [X] T034 Run the **full CI gate locally** (CI parity): `shellcheck --shell=bash --severity=style src/*.sh`, `yamllint -d relaxed .github/workflows/ci.yml`, `npx --yes markdownlint-cli2 "specs/**/*.md" "*.md"`, `bats --recursive tests/unit`. All green.
- [ ] T035 Open the PR into `main` (branch `006-consumer-privacy-guard`): title `feat(privacy): consumer-side privacy guard — fail-closed pre-write gate (exit 4)`; body cites FR-001..FR-014, the neutral/sink seam, Privacy IX enforcement, and "no constitutional amendment (enforces IX)". Confirm the privacy guard + neutrality gate + full bats matrix are green in CI.

---

## Dependencies & ordering

- **Phase 1 (T001–T003)** → **Phase 2 (T004–T013)** → **Phase 3 (US1, T014–T022)**.
- **US2 (T023–T025)** and **US3 (T026–T027)** depend on US1's gate (T021/T022)
  being wired; they extend its providers/wording. US2 ∥ US3 are independent of
  each other (disjoint test files + disjoint sink fn / reconcile wording).
- **Phase 6** after US1–US3. T034 (full gate) is the last verification before
  T035 (PR).
- The 003 neutrality registration (T013) is written in Phase 2 but only goes
  green once T021 implements a clean `reconcile::privacy_gate`; T030 re-confirms.

## Parallel execution examples

- **Phase 1**: T002 ∥ T003 (cli.md vs new src file). T001 touches `reconcile.sh`
  (sequential vs T003's sourcing edit — do T003's sourcing line after T001 or
  coordinate; both edit `reconcile.sh`, so treat T001→T003 sequential for that file).
- **Phase 2 tests**: T006 ∥ T008–T011 author different test files? They share
  `privacy_guard.bats` — keep sequential within that file; T004 (separate
  exit-codes bats) is ∥.
- **Phase 3 tests**: T014 ∥ T015 (same new file `jira_sink_privacy.bats` — keep
  sequential); T016–T018 share `privacy_gate_us1.bats` (sequential).
- **Phase 6**: T028 ∥ T029 ∥ T030 ∥ T031 ∥ T032 ∥ T033 (distinct files), then
  T034 → T035.

## MVP scope

**US1 (Phase 1 + 2 + 3)** is the shippable MVP: a leaking consumer tree fails
closed with zero Jira writes. US2 (gitignore assertion) and US3 (message polish)
are belt-and-suspenders + UX, landing in the same PR.

## Implementation strategy

Strict TDD: every `privacy_guard::*` and `jira_sink::privacy_*` unit has its test
first (Phase 2/3). The curl-shim integration tests (T016–T018, T024, T028–T029)
are the SC-001 zero-write proof. Keep the mechanism vendor-neutral (T013/T030 are
the mechanical enforcement). Privacy IX (T031) gates the fixtures. No constitution
amendment — the feature is the enforcement arm of Principle IX.
