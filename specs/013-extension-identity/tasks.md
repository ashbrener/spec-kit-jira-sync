---

description: "TDD task list — feature 013 extension identity realignment"
---

# Tasks: Extension Identity Realignment — One Name, Everywhere

**Input**: Design documents from `/specs/013-extension-identity/`

**Prerequisites**: plan.md, spec.md, research.md (R1-R9), data-model.md
(E1-E5 / VR-1..VR-11), contracts/identity-contract.md (C-1..C-10)

**Tests**: TDD — every test task precedes its implementation and MUST fail first
(red → green). Ships **v0.6.0 (BREAKING)**.

**Run tests with bash 5**: `export PATH="/opt/homebrew/bin:$PATH"`. Two known
local-only failures (`config.bats` "default path", `no-real-identifiers`) are
caused by the operator's gitignored files and are green in CI — do not chase them.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on incomplete work)
- **[Story]**: US1 (correct update) / US2 (survivable upgrade) / US3 (accurate listing)

---

## Phase 1: Setup — the single identity constant (blocks everything)

**Purpose**: the extension id is hardcoded three times today (`install.sh:324`,
`hookcheck.sh:102`, `config.sh:70`). Extract it once so writer and reader cannot
diverge — this is the change that makes 012's FR-007 structural instead of lucky.

- [X] T001 Write `tests/unit/extension_identity.bats` (RED) — the C-6 pin +
  C-1 guard: `extension.yml`'s `extension.id` equals `SPECKIT_EXT_ID`; EVERY
  declared command name starts `speckit.${SPECKIT_EXT_ID}.`; the manifest declares
  exactly 4 commands and 6 `after_*` hooks; sourcing `src/identity.sh` twice in one
  shell is a clean no-op. Parse the manifest with PyYAML (as `manifest_hooks.bats`
  does — PyYAML is installed in CI).
- [X] T002 Create `src/identity.sh` (GREEN) — dependency-free, no I/O, no side
  effects, include-guarded `_IDENTITY_SH_LOADED`. Export
  `SPECKIT_EXT_ID="jira-sync"`, `SPECKIT_EXT_PUSH_COMMAND="speckit.jira-sync.push"`,
  `SPECKIT_EXT_INSTALL_DIR=".specify/extensions/jira-sync"`.
- [X] T003 `shellcheck --severity=style src/identity.sh` clean; T001 GREEN except
  the manifest assertions (they go green in Phase 2 — note this expected interim).

**Checkpoint**: one constant exists; every later phase consumes it.

---

## Phase 2: US1 — a user is never offered someone else's extension (P1) 🎯 MVP

**Goal**: the published identity, the manifest identity, and the command namespace
are one value, so the updater resolves to this bridge.

**Independent test**: manifest `extension.id` == the catalog id we publish
(`jira-sync`), and every command sits under `speckit.jira-sync.`.

- [X] T004 [US1] Update `extension.yml`: `id: "jira"` → `"jira-sync"`; the four
  command names → `speckit.jira-sync.{push,status,install,seed}`; all six
  `provides.hooks` `command:` refs → `speckit.jira-sync.push`; the four `file:`
  paths → the renamed files (T005); and rewrite the header comment that documents
  the id/catalog mismatch — it describes the bug this feature removes.
- [X] T005 [US1] `git mv` the manifest command files (preserve history):
  `commands/jira-{push,status,install,seed}.md` →
  `commands/jira-sync-{push,status,install,seed}.md`; update each file's
  frontmatter `name:` and every internal command reference.
- [X] T006 [P] [US1] `git mv` the dev-layout twins:
  `.claude/commands/speckit-jira-{push,status,install,seed}.md` →
  `.claude/commands/speckit-jira-sync-{push,status,install,seed}.md`; update
  frontmatter, internal references, and the reconcile run-line in each.
- [X] T007 [US1] Update `tests/unit/manifest_hooks.bats` for the new command names
  (keep the PyYAML parse — a manifest-contract test must not reuse the bridge's own
  reader). T001's manifest assertions now go GREEN.

**Checkpoint**: US1 delivers — one published identity; no namespace collision.

---

## Phase 3: US1+US2 — registrar/detector lockstep (the real architecture)

**Goal**: the token the registrar writes and the token the health check reads come
from the same constant, so they can never drift.

**Independent test**: register into a temp file, classify it back as `present`.

- [X] T008 Write the C-7 lockstep test in `tests/unit/extension_identity.bats`
  (RED): call `install::register_after_hooks` against a temp
  `.specify/extensions.yml`, then `hookcheck::classify` each hook and assert
  `present` — proving writer and reader agree without comparing literals.
- [X] T009 Update `src/install.sh` (GREEN): source `identity.sh`;
  `_render_hook_block` emits `- extension: ${SPECKIT_EXT_ID}` and
  `command: ${SPECKIT_EXT_PUSH_COMMAND}` (C-2 — no literal);
  `_hook_already_registered` matches on `${SPECKIT_EXT_ID}` (C-3 — no literal);
  `.specify/extensions/jira` paths → `${SPECKIT_EXT_INSTALL_DIR}`; rename the
  dogfood env var `SPECKIT_JIRA_DOGFOOD_SAFE` → `SPECKIT_JIRA_SYNC_DOGFOOD_SAFE`
  (keep the SC2016 disable on that printf).
- [X] T010 Update `src/hookcheck.sh` (GREEN): source `identity.sh` **directly**
  (C-1 — never via `install.sh`, which it sources only lazily on consent);
  `classify` passes the id into awk with a **single-line**
  `awk -v want_ext="$SPECKIT_EXT_ID"` (C-4 — BSD-safe, no literal, no multi-line
  `-v`); remediation strings → `/speckit-jira-sync-install`; header comments updated.
- [X] T011 [P] Update `tests/helpers/hookcheck_fixtures.bash` for the new token
  (`extension: jira-sync`) and command (`speckit.jira-sync.push`).
- [X] T012 Update `tests/unit/{hook_registration,hookcheck,hookcheck_selfheal,reconcile_hookcheck}.bats`
  for the new token/commands; all GREEN.

**Checkpoint**: identity divergence is now a build failure, not a latent bug.

---

## Phase 4: US2 — a survivable upgrade (P1)

**Goal**: an operator upgrading from the old identity is told what happened and
fixes it in one consented step; their resolved binding still works.

**Independent test**: from an old-identity project, hooks read `absent`, the
warning fires, consent re-registers under the new token; legacy config still loads.

- [ ] T013 [US2] Write `tests/unit/identity_migration.bats` (RED) — the C-8
  end-to-end migration, the load-bearing claim: seed a `.specify/extensions.yml`
  with old entries (`extension: jira` / `command: speckit.jira.push`); assert
  `hookcheck::classify` → `absent`; the warn/status line fires; a consented heal
  re-registers as `extension: jira-sync` + `speckit.jira-sync.push`; and a
  pre-existing `enabled: false` entry survives untouched (VR-5/VR-6).
- [ ] T014 [US2] Write the C-9 config-fallback test in `tests/unit/config.bats`
  (RED): the new path is preferred; when only the legacy
  `.specify/extensions/jira/jira-config.yml` exists it loads and emits EXACTLY ONE
  informational line naming the new location; the legacy file is neither moved
  nor deleted.
- [ ] T015 [US2] Update `src/config.sh` (GREEN): source `identity.sh`;
  `CONFIG_DEFAULT_PATH` derives from `${SPECKIT_EXT_INSTALL_DIR}`; add the legacy
  read-fallback per C-5 (read in place, one info line, never move, never delete).
- [ ] T016 [P] [US2] Update `.gitignore` to ignore the new binding path while
  KEEPING the old path ignored; update `config-template.yml`'s documented path.
- [ ] T017 [US2] Verify T013 GREEN with no new migration machinery — the shipped
  012 self-heal carries it. If it does not, STOP and report rather than bolting on
  a bespoke migration path.

**Checkpoint**: US2 delivers — the rename is survivable in one consented step.

---

## Phase 5: US3 — an accurate published listing (P2)

**Goal**: the catalog listing's stated capabilities match what ships.

- [ ] T018 [US3] Verify `scripts/publish-catalog.sh` submits
  `provides {commands: 4, hooks: 6}` (the listing currently says `hooks: 0`,
  stale from v0.4.0 which genuinely had none) and the aligned id; adjust the
  script if it carries stale values forward.

---

## Phase 6: Polish, gates & release

- [ ] T019 [P] Update `README.md`: all command names, the new install directory,
  and a **v0.6.0 BREAKING / migration** section (mirror
  `specs/013-extension-identity/quickstart.md`).
- [ ] T020 [P] Correct `.specify/memory/constitution.md` references (~lines 202,
  238, 242, 251, 375, 379) naming `speckit.jira.push` / the old config path, AND
  remove the bogus `.pull` command references (~242, 379) — this bridge has never
  shipped `.pull`. **DOC FIX ONLY — do NOT bump the constitution version.**
- [ ] T021 [P] Update `CLAUDE.md` (Commands section + non-negotiables) to the new
  command names and install path.
- [ ] T022 [P] Add a `CHANGELOG.md` `[Unreleased]` → **Changed / BREAKING** entry:
  the rename, the renamed commands, the migration, the dogfood env-var rename.
- [ ] T023 Add the C-10 sweep test (in `tests/unit/extension_identity.bats`): NO
  `speckit\.jira\.` or `extension: jira` literal remains in any LIVE file
  (`src/`, `commands/`, `.claude/commands/`, `extension.yml`, `README.md`,
  `CLAUDE.md`, `config-template.yml`, `tests/`). **Exclude `specs/001`–`012`** —
  they record what was true when written and are not rewritten.
- [ ] T024 Verify `tests/unit/engine_vendor_neutral.bats` GREEN **untouched** and
  `tests/unit/no-real-identifiers.bats` GREEN (Privacy IX).
- [ ] T025 Bump `extension.yml` → `version: "0.6.0"` and roll `CHANGELOG.md`
  `[Unreleased]` into `[0.6.0]` with the link refs.
- [ ] T026 Full CI gate locally: `shellcheck --severity=style src/*.sh` (incl.
  `identity.sh`), `yamllint -d relaxed extension.yml .github/workflows/ci.yml`,
  `npx markdownlint-cli2 "specs/**/*.md" "*.md"`, and the full
  `bats --recursive tests/unit` under bash 5. All green (bar the two known
  local-only failures).
- [ ] T027 Open a PR into `main` from `013-extension-identity` (do **NOT** merge —
  the operator merges). Body: the collision, the one-name fix, the migration, and
  the two upstream review findings this addresses.

---

## Phase 7: Post-merge follow-ups (do NOT do before the PR is merged)

- [ ] T028 **[post-merge]** Tag v0.6.0, publish the GitHub release, and run
  `scripts/publish-catalog.sh v0.6.0` to file the catalog submission.
- [ ] T029 **[post-merge]** Reply on github/spec-kit PR #4168 / issue #4099
  stating both review findings are addressed — identity aligned
  (`extension.id` == catalog id == command namespace) and
  `provides {commands: 4, hooks: 6}` — and ask the maintainer to retrigger on the
  new tag.

---

## Dependencies & Execution Order

- **Phase 1 (constant)** blocks everything. T001 (RED) → T002 → T003.
- **Phase 2 (US1)** — T004 and T005 touch `extension.yml`/`commands/` in step
  (sequential); T006 is [P] (different directory); T007 after T004/T005.
- **Phase 3** needs Phase 1 + 2. T008 (RED) → T009, T010 (different files but both
  must land before T008 goes green) → T011 [P] → T012.
- **Phase 4 (US2)** needs Phase 3 (the detector must already use the constant).
  T013, T014 (RED, different files → [P]-able) → T015 → T016 [P] → T017.
- **Phase 5 (US3)** independent of 3/4; can run any time after Phase 2.
- **Phase 6** last; T019-T022 [P], then T023-T026, then T027.
- **Phase 7** only after the operator merges.

## Parallel Opportunities

- Phase 2: T006 alongside T004/T005.
- Phase 3: T011 alongside T012's non-overlapping files.
- Phase 4: T013 and T014 (disjoint test files); T016 alongside T015.
- Phase 6: T019, T020, T021, T022 all [P].

## Implementation Strategy

**MVP = Phase 1 + Phase 2** — one published identity, which is what unblocks the
catalog submission. Phase 3 makes the invariant structural, Phase 4 makes the
upgrade survivable, Phase 5 fixes the listing metadata. Ship order: constant →
manifest/commands → lockstep → migration → listing → docs/gates/PR.
