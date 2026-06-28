# Tasks: Auto-Register `after_*` Hooks — the Automatic Mirror

**Feature**: 011-hook-auto-registration | **Branch**: `011-hook-auto-registration`

**Input**: plan.md, research.md (R1–R9), data-model.md (VR-1..VR-10),
contracts/hook-registration.md (C-1..C-10), spec.md (FR-001..FR-009, SC-001..SC-006)

**Strategy**: Strict TDD. Install/config-side — the reconcile **engine is
untouched** (003 neutral). Mirror the Linear sibling's `install::register_after_hooks`
block grammar **exactly** (read `/Users/ashbrener/Code/AI/speckit-linear/src/install.sh`
~1746–1965) so feature 012's hook-health detector reuses it. **Pure-filesystem tests
— no curl-shim** (no Jira). The append helpers MUST be **pure-bash** (BSD-awk on
macOS rejects multi-line `awk -v`). No schema/exit-code change, no constitution
amendment (implements Principle VII; fix the stale "no hooks" wording).

**Conventions**: `[P]` = parallelizable (disjoint files). Tests precede impl.
Tick `[ ]`→`[X]` as completed.

---

## Phase 1: Manifest (US1 — the CLI-registered source of truth)

- [X] T001 [US1] Test (C-1) in `tests/unit/manifest_hooks.bats` (new): parse `extension.yml` and assert `provides.hooks` declares all six `after_*` hooks (`after_specify`, `after_clarify`, `after_plan`, `after_tasks`, `after_implement`, `after_analyze`), each with `command: speckit.jira.push` and `optional: false`. (Fails until T002.)
- [X] T002 [US1] Add the `provides.hooks:` block to `extension.yml`: the six `after_*` hooks, each `- command: "speckit.jira.push"`, `optional: false`, `enabled: true`, with a jira-flavoured per-phase `description` + `prompt` (e.g. after_specify → "Reconcile after /speckit-specify so the spec Story exists in Jira with the right initial status."). No `before_*`. `extension.id` stays `jira`. Correct the stale "registers NO hooks — reconcile is operator-driven" header/`provides` comments to describe the auto-mirror.

**Checkpoint**: `bats tests/unit/manifest_hooks.bats` green; `yamllint -d relaxed extension.yml` clean.

---

## Phase 2: Install registrar (US1 + US3 — idempotent, enabled:false-safe, BSD-awk-safe)

**TDD — write each test first, watch it fail, then implement. Mirror Linear's grammar.**

### Tests first — `tests/unit/hook_registration.bats` (pure-fs)

- [X] T003 [US1] Test (C-2): `install::register_after_hooks` on an ABSENT `.specify/extensions.yml` (in a `mktemp -d`) ⇒ the file is created with `settings: { auto_execute_hooks: true }`, `installed:` includes `jira`, and all six `after_*` blocks each carry an `extension: jira` entry (`command: speckit.jira.push`, `optional: false`).
- [X] T004 [US3] Test (C-3, idempotent): run the registrar twice ⇒ the second `.specify/extensions.yml` is **byte-identical** to the first (`cmp` clean — no duplicate entries, no reordering, no churn).
- [X] T005 [US3] Test (C-4, enabled:false): pre-seed one hook's `jira` entry with `enabled: false`, run the registrar ⇒ that entry stays `enabled: false` (never re-enabled), the others are registered.
- [X] T006 [US3] Test (C-5, coexistence): pre-seed `after_specify:` with an `- extension: speckit-git` entry, run the registrar ⇒ the `speckit-git` entry is untouched and a `- extension: jira` entry is added alongside under the same hook.
- [X] T007 [US3] Test (C-6, malformed): a malformed/unreadable `.specify/extensions.yml` ⇒ the registrar surfaces an informational message and returns WITHOUT corrupting the file (assert the file bytes are unchanged; no partial write; no non-zero halt of the host).
- [X] T008 [US1] Test (C-7, dogfood): with the install target = the bridge's own checkout (source==target), the rendered hook block has `condition: "${SPECKIT_JIRA_DOGFOOD_SAFE:-false}"`; with a normal target, `condition: null`.

### Implementation — `src/install.sh`

- [X] T009 [US1] Add module constants: `INSTALL_EXTENSIONS_YML=".specify/extensions.yml"` and `INSTALL_AFTER_HOOK_NAMES=(after_specify after_clarify after_plan after_tasks after_implement after_analyze)`.
- [X] T010 [US1] Implement `install::_create_minimal_extensions_yml` — write `installed:`/`settings: { auto_execute_hooks: true }`/`hooks:` when the file is absent (mirror Linear's, swap `linear`→`jira`).
- [X] T011 [US1] Implement `install::_render_hook_block <hook>` — emit `- extension: jira`, `command: speckit.jira.push`, `enabled: true`, `optional: false`, the per-phase `prompt`/`description`, and `condition`: `null` normally, or the LITERAL `${SPECKIT_JIRA_DOGFOOD_SAFE:-false}` on a dogfood target (reuse 008's source==target detection; `# shellcheck disable=SC2016` on that `printf`).
- [X] T012 [US3] Implement `install::_hook_already_registered <hook>` — awk over the `^  <hook>:` block, match `extension:[[:space:]]*jira` inside it (rc 0 = present).
- [X] T013 [US3] Implement `install::_append_under_hook` / `install::_create_hook_section` — **pure-bash line-by-line state machines** that splice the multi-line rendered block (NOT `awk -v block=<multiline>` — BSD awk macOS rejects it). Never duplicate, never reorder, never disturb other extensions' entries, never write a partial file.
- [X] T014 [US3] Implement `install::_register_one_hook <hook>` — present ⇒ preserve (honour `enabled:false`) + log + return 0; else render + append via the two paths (`_append_under_hook` if `^  <hook>:` exists, else `_create_hook_section`).
- [X] T015 [US1] Implement `install::register_after_hooks` — ensure the file (`_create_minimal_extensions_yml` if absent), then loop `INSTALL_AFTER_HOOK_NAMES` → `_register_one_hook`. Wire the call into `install::main` AFTER the binding write (`config::write_binding`).

**Checkpoint**: `bats tests/unit/hook_registration.bats` green; `shellcheck --severity=style src/*.sh` clean.

---

## Phase 3: Non-blocking push (US2 — a fired hook never breaks the host command)

- [X] T016 [US2] Test (C-8) in `tests/unit/hook_registration.bats` (or `tests/unit/push_safety.bats`): extract the one-liner from `commands/jira-push.md` and run it with `.env` PRESENT and ABSENT (stub `src/reconcile.sh` to a no-op that records it ran) ⇒ reconcile is reached in BOTH cases (no `&&`-chain break on a missing `.env`).
- [X] T017 [US2] Harden the run-line in `commands/jira-push.md` AND `.claude/commands/speckit-jira-push.md`: replace `… && set -a && source .env && set +a && bash src/reconcile.sh …` with `cd "$(git rev-parse --show-toplevel)" && { [ -f .env ] && { set -a; source .env; set +a; }; } ; bash src/reconcile.sh <FLAGS>`. Update the "report back" guidance so a hook-fired failure reads as a gentle WARNING (no creds → run `/speckit-jira-install`; exit 3 → check the token), never alarming (FR-004).

**Checkpoint**: a missing `.env` no longer hard-fails the push; reconcile's clean exit-2/3 message is reached.

---

## Phase 4: Polish & Cross-Cutting

- [ ] T018 [P] Docs flip (FR-006): update `README.md` so the **auto-sync flow is presented FIRST** (run a spec-kit command → Jira updates), and `push`/`status`/`install`/`seed` move to a **recovery / escape-hatch** section. Correct the "operator-driven / no hooks" wording in `README.md` + `extension.yml` to describe the auto-mirror.
- [ ] T019 [P] Privacy (C-9): extend `tests/unit/no-real-identifiers.bats` to cover the new fixtures (any `tests/fixtures/**/extensions.yml` + the `extension.yml` hooks block) — placeholder-only, no real Jira coordinate; the dogfood `${SPECKIT_JIRA_DOGFOOD_SAFE}` literal is not a coordinate.
- [ ] T020 [P] Neutrality (C-10): run `bats tests/unit/engine_vendor_neutral.bats` — green. The registrar lives in `install.sh` (config-side); no `reconcile::*` change. Guard-confirmation (no change expected).
- [ ] T021 [P] Add a `CHANGELOG.md` `[Unreleased]` entry (Added: **automatic mirror** — `after_*` hooks auto-register so every spec-kit command syncs to Jira; non-blocking; honours `enabled:false`; implements Principle VII).
- [ ] T022 Run the **full CI gate** locally: `shellcheck --shell=bash --severity=style src/*.sh`, `yamllint -d relaxed extension.yml .github/workflows/ci.yml`, `npx --yes markdownlint-cli2 "specs/**/*.md" "*.md"`, `bats --recursive tests/unit`. All green.
- [ ] T023 Open the PR into `main` (branch `011-hook-auto-registration`): title `feat(hooks): auto-register after_* hooks — the automatic mirror (implements Principle VII)`; body cites the gap (zero hooks vs VII's mandate), the manifest + install-registrar seam (mirroring Linear), non-blocking-structural, FR-001..FR-009, "no amendment (implements VII; fixes the stale wording)", Privacy IX + 003 neutrality, and that it is the foundation for feature 012 (the Linear spec-014 self-heal port). Confirm the full bats matrix + neutrality + privacy gates green in CI.

---

## Dependencies & ordering

- **Phase 1 (T001–T002)** → **Phase 2 (T003–T015)** → **Phase 3 (T016–T017)** →
  **Phase 4 (T018–T023)**.
- Within Phase 2: tests T003–T008 first (sequential within `hook_registration.bats`),
  then impl T009–T015 (T015 wires after T010–T014 exist; T013 pure-bash splice before
  T014/T015).
- T022 (full gate) precedes T023 (PR).

## Parallel execution examples

- **Phase 1**: T001 then T002 (same manifest file — sequential).
- **Phase 2**: the impl helpers (T010–T014) all edit `src/install.sh` — sequential;
  the tests are in one bats file — sequential.
- **Phase 4**: T018 ∥ T019 ∥ T020 ∥ T021 (distinct files), then T022 → T023.

## MVP scope

**US1 (manifest + registrar create) + US2 (non-blocking push)** is the shippable
mirror: install registers the hooks, every spec-kit command auto-syncs, and a
missing credential never breaks the workflow. US3 (idempotency + enabled:false +
coexistence + malformed-resilience) hardens it; all land in one PR.

## Implementation strategy

Strict TDD; mirror Linear's `register_after_hooks` block grammar exactly (so 012
reuses it). Append helpers are **pure-bash** (BSD-awk macOS lesson). The dogfood
`condition` gate protects the bridge's own dev. Non-blocking is structural (the
skill fires the hook post-work) + the hardened push degrades to a clean warning.
Engine untouched (T020), Privacy IX gates the fixtures (T019). No schema/exit-code
change, no amendment.
