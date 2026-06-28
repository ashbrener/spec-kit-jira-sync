# Contract: Auto-Register `after_*` Hooks

The manifest declaration, the install-side registrar (mirroring Linear's block
grammar), and the hardened push entry-point. Install/config-side; the reconcile
engine is untouched (003 neutral).

## 1. `extension.yml` — `provides.hooks`

Declare the six `after_*` hooks; the spec-kit CLI registers them on
`specify extension add jira`:

```yaml
provides:
  hooks:
    after_specify:
      - command: "speckit.jira.push"
        optional: false
        enabled: true
        description: "<jira-flavoured>"
        prompt: "<jira-flavoured>"
    # after_clarify, after_plan, after_tasks, after_implement, after_analyze — same shape
```

- MUST: all six phases; `command: speckit.jira.push`; `optional: false`. No
  `before_*`. `extension.id` stays `jira`.
- The stale "registers NO hooks — operator-driven" header comment is corrected.

## 2. Install registrar — `src/install.sh`

### `install::register_after_hooks` (wired into `install::main` after the binding write)

- File absent ⇒ `install::_create_minimal_extensions_yml` (`installed:`, `settings:
  { auto_execute_hooks: true }`, `hooks:`). Then loop `INSTALL_AFTER_HOOK_NAMES`
  (the six) → `_register_one_hook`.

### `install::_register_one_hook <hook>`

- `_hook_already_registered <hook>` (a `extension: jira` entry exists in the
  `^  <hook>:` block) ⇒ **preserve** (honour any `enabled: false`), log, return 0.
- Else render `_render_hook_block <hook>` and append: if the `<hook>:` key exists ⇒
  `_append_under_hook`; else ⇒ `_create_hook_section`.

### `install::_render_hook_block <hook>` → the consumer entry

```yaml
  - extension: jira
    command: speckit.jira.push
    enabled: true
    optional: false
    prompt: <jira prompt per phase>
    description: <jira description per phase>
    condition: null              # or "${SPECKIT_JIRA_DOGFOOD_SAFE:-false}" on a dogfood target
```

- **Dogfood**: when the install target is the bridge's own checkout (reuse 008's
  source==target detection), `condition` is the literal `${SPECKIT_JIRA_DOGFOOD_SAFE:-false}`
  (host-evaluated; SC2016 disabled at that line); else `null`.

### Append helpers — pure-bash (no multi-line `awk -v`)

`_append_under_hook` / `_create_hook_section` / `_create_minimal_extensions_yml`
splice the multi-line block via a line-by-line bash state machine (BSD-awk macOS
safe). MUST: never duplicate an entry, never reorder, never disturb other
extensions' entries, never write a partial/corrupt file; malformed input ⇒
informational message + return without mutating.

## 3. Hardened push — `commands/jira-push.md` (+ `.claude/commands/speckit-jira-push.md`)

Replace the `&& source .env &&` chain with a `.env`-optional form:

```bash
cd "$(git rev-parse --show-toplevel)" && { [ -f .env ] && { set -a; source .env; set +a; }; } ; bash src/reconcile.sh <FLAGS>
```

- A missing `.env` no longer breaks the chain — reconcile runs and exits 2/3 with
  its clean message. The "report back" frames a hook-fired failure as a gentle
  WARNING (no creds → `/speckit-jira-install`; unreadable → check token).

## 4. Docs flip — README + `extension.yml`

Auto-sync flow presented FIRST; `push`/`status`/`install`/`seed` in a recovery
section. The "operator-driven / no hooks" rationale corrected to the auto-mirror.

## 5. Behavioral assertions (testable; pure-filesystem)

| ID | Assertion |
|---|---|
| C-1 | `extension.yml provides.hooks` declares all six `after_*` → `speckit.jira.push`, `optional:false`, `enabled:true` |
| C-2 | registrar on an absent file ⇒ creates it with `settings.auto_execute_hooks: true` + the six `extension: jira` hooks |
| C-3 | re-running the registrar ⇒ **byte-identical** `.specify/extensions.yml` (no dup, no churn) |
| C-4 | a hook pre-set `enabled: false` ⇒ preserved (never re-enabled) across re-run |
| C-5 | a pre-existing `extension: speckit-git` entry under `after_specify:` ⇒ untouched; the `jira` entry is added alongside |
| C-6 | a malformed `.specify/extensions.yml` ⇒ informational message, no corruption, no halt, no partial write |
| C-7 | dogfood target (source==target) ⇒ `condition: "${SPECKIT_JIRA_DOGFOOD_SAFE:-false}"`; else `condition: null` |
| C-8 | the push one-liner runs `src/reconcile.sh` both **with** `.env` and **without** it (no hard-fail on missing `.env`) |
| C-9 | `no-real-identifiers.bats` green — `extension.yml`, fixtures, and any `.specify/extensions.yml` fixture are placeholder-only |
| C-10 | `engine_vendor_neutral.bats` green — no `reconcile::*` change; registration is install/config-side |
