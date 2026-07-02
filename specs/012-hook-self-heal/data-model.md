# Phase 1 Data Model: Hook Self-Healing

No persistent schema and no `workstate` change. The "entities" are the in-memory
assessment values the module computes from the consumer's `.specify/extensions.yml`
and the validation rules governing them. Everything is config-side; no Jira object.

## Entities

### E1 — Hook classification (per `after_*` hook)

One of exactly three states for each of the six hooks, for the `jira` extension:

| State | Meaning | Rule |
|-------|---------|------|
| `present` | a `- extension: jira` entry exists under `^  <hook>:` and is not disabled | counts as wired |
| `disabled` | that entry carries `enabled: false` | intentional; NEVER "missing", NEVER re-enabled (VR-3) |
| `absent` | no `- extension: jira` entry under that hook | the ONLY state that counts as "missing" (VR-1) |

Produced by `hookcheck::classify <hook> [<yml>]`. Returns rc 2 (not a state) when
the file exists but is unreadable — the caller maps that to `unverifiable` (VR-5).

### E2 — Hook-health assessment (per reconcile run)

The whole-file rollup, set into globals by `hookcheck::assess_into`:

| Field | Type | Notes |
|-------|------|-------|
| `HOOKCHECK_OVERALL` | enum | `present` \| `partial` \| `none` \| `unverifiable` \| `not_installed` |
| `HOOKCHECK_MISSING[]` | array | the `absent` hook names (drives the warning + status line) |
| `HOOKCHECK_DISABLED[]` | array | the `disabled` hook names (reported as intentional, never warned) |

`overall` derivation (VR-2):

- 0 missing → `present`
- all six missing → `none`
- some missing (1–5) → `partial`
- file absent → `not_installed`; unreadable / no `hooks:` key / any classify rc≠0 →
  `unverifiable`

### E3 — Self-heal offer (interactive, consent-gated, all-at-once)

The single mutating action. Reuses 011's `install::register_after_hooks`.

| Field | Type | Notes |
|-------|------|-------|
| trigger | `overall ∈ {partial, none}` AND real controlling TTY | else no-op (VR-6/VR-7) |
| consent | single y/N, default No | one prompt re-registers ALL missing hooks (VR-8) |
| effect | idempotent re-registration in place | preserves `enabled: false`; no Jira write (VR-9) |
| post | re-`assess_into` | so a follow-up reconcile reports clean (SC-004) |

## Validation Rules

- **VR-1**: only `absent` counts as missing; `present` and `disabled` do not.
- **VR-2**: `overall` follows the derivation table above deterministically.
- **VR-3**: a `disabled` hook is never reported missing, never warned, never
  re-enabled by the heal (honours operator intent — Principle VII).
- **VR-4**: the warning fires **at most once per reconcile run** (latched via
  `_RECONCILE_HOOKS_WARNED`), even across the multi-spec `--all` loop.
- **VR-5**: a file that is absent → `not_installed` (silent); unreadable, or
  readable-without-a-`hooks:`-key, or any `classify` rc≠0 → `unverifiable`
  (one informational row); NEVER a halt, NEVER a false `absent`.
- **VR-6**: interactivity = a **real controlling TTY** (`[[ -t 0 ]]`, overridable
  by the `HOOKCHECK_FORCE_*` seams). The slash-command/hook-fired/CI paths are
  non-interactive → warn-only.
- **VR-7**: a non-interactive run NEVER prompts and NEVER mutates the file.
- **VR-8**: on consent, ALL missing hooks are re-registered in a single step (not
  one prompt per hook); default (Enter) = No.
- **VR-9**: the heal makes NO Jira write and NEVER alters the reconcile's own exit
  disposition.
- **VR-10**: `HOOKCHECK_AFTER_HOOK_NAMES` equals `install.sh`'s
  `INSTALL_AFTER_HOOK_NAMES` (pin test) so detection and repair enumerate the same
  six hooks (FR-007).
- **VR-11**: detection uses the SAME `.specify/extensions.yml` block grammar as
  011's `install::_hook_already_registered` (enter `^  <hook>:`, per-`- extension:`
  entry, `enabled:` tracked) so "registered" means the same thing to both.

## State Transitions

The file's hook-health moves only under explicit action:

```text
absent/partial  --(operator runs /speckit-jira-install OR consents to self-heal)-->  present
present         --(specify extension add jira --from <zip> --force)-->               none (stripped)
present         --(operator edits enabled: false)-->                                  present (that hook = disabled/intentional)
```

The module observes these; it only ever performs the left→right repair transition,
and only with consent at a real TTY.
