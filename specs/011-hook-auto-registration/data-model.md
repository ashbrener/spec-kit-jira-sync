# Phase 1 Data Model: Auto-Register `after_*` Hooks

No engine state, no schema change. The "model" is two YAML artifacts — the
committed `extension.yml` manifest declaration and the per-consumer
`.specify/extensions.yml` the registrar writes — plus the registrar functions.

## Entities

### Manifest hook declaration (`extension.yml` → `provides.hooks`)

The committed source of truth the spec-kit CLI registers at `add`. Six entries,
one per `after_*` phase:

```yaml
provides:
  hooks:
    after_specify:
      - command: "speckit.jira.push"
        description: "<jira-flavoured>"
        prompt: "<jira-flavoured>"
        optional: false
        enabled: true
    after_clarify: …   # …plan, …tasks, …implement, …analyze
```

No `before_*` hooks. `extension.id` stays `jira`.

### Consumer hook entry (`.specify/extensions.yml` → `hooks.<phase>[]`)

What the registrar writes/repairs in the operator's project (mirrors Linear's
shape so the 012 detector agrees):

```yaml
installed:
- jira
settings:
  auto_execute_hooks: true        # required for the skills to auto-EXECUTE
hooks:
  after_specify:
  - extension: jira
    command: speckit.jira.push
    enabled: true                 # operator may set false → honoured, never re-enabled
    optional: false               # Principle VII (non-skippable registration)
    prompt: "<jira prompt>"
    description: "<jira description>"
    condition: null               # or "${SPECKIT_JIRA_DOGFOOD_SAFE:-false}" on a dogfood target
  # …the other five after_* phases
```

A hook is **present** iff its `<phase>:` block contains `extension: jira`
(`enabled` may be true/false). The operator owns `enabled`.

### Hook registrar (install-side)

| Function | Responsibility |
|---|---|
| `install::register_after_hooks` | ensure file (minimal, `auto_execute_hooks:true`); loop the 6 names |
| `install::_register_one_hook <h>` | idempotent: present ⇒ preserve (honour `enabled:false`) + return; else render+append |
| `install::_hook_already_registered <h>` | awk: `extension: jira` inside the `^  <h>:` block |
| `install::_render_hook_block <h>` | the consumer entry (jira command + dogfood-gated `condition`) |
| `install::_append_under_hook` / `_create_hook_section` / `_create_minimal_extensions_yml` | pure-bash splice (no multi-line `awk -v`) |

### Hardened push entry-point (`commands/jira-push.md` + `.claude` twin)

The one-liner sources `.env` **only when present**, then runs reconcile regardless,
so an auto-fired hook with no creds degrades to reconcile's clean exit-2/3 warning
rather than a broken `&&` chain.

## Validation rules

- **VR-1 (FR-001/SC-001)**: `extension.yml provides.hooks` declares all six
  `after_*` hooks → `speckit.jira.push`, `optional:false`, `enabled:true`.
- **VR-2 (FR-002/SC-001)**: a fresh `.specify/extensions.yml` is created with
  `settings.auto_execute_hooks: true` + the six hooks (each `extension: jira`,
  `command: speckit.jira.push`, `optional:false`).
- **VR-3 (FR-002/SC-004)**: re-running the registrar is **byte-identical** (no
  duplicate entries, no reordering, no churn).
- **VR-4 (FR-003/SC-004)**: a hook the operator set `enabled: false` is **preserved**
  (never re-enabled) across re-run.
- **VR-5 (FR-009)**: another extension's hook entry (e.g. `extension: speckit-git`)
  under the same `<phase>:` is untouched; a malformed/unreadable file yields an
  informational message and **no corruption / no partial write / no halt**.
- **VR-6 (FR-004/SC-003)**: the push one-liner runs reconcile **with and without**
  `.env` (no hard-fail on a missing `.env`); a hook-fired sync failure surfaces a
  clean warning, the host command still succeeds.
- **VR-7 (dogfood)**: on a source==target (bridge's own repo) install, the rendered
  `condition` is the `${SPECKIT_JIRA_DOGFOOD_SAFE:-false}` gate; otherwise `null`.
- **VR-8 (FR-007/SC-005)**: no real Jira coordinate in `extension.yml`,
  `.specify/extensions.yml`, or any fixture; `no-real-identifiers.bats` green.
- **VR-9 (FR-008/SC-005)**: registration is install/config-side; the
  `engine_vendor_neutral.bats` audit stays green (no `reconcile::*` change).
- **VR-10 (FR-006/SC-006)**: docs present auto-sync first; on-demand commands in a
  recovery section; the stale "operator-driven, no hooks" wording corrected.
