# Phase 1 Data Model: Extension Identity Realignment

No persistent schema change and no `workstate` change. The "entities" here are
the identity-bearing values the bridge publishes and the rules that keep them in
agreement.

## Entities

### E1 — Extension identity (the single value)

| Field | Old | New |
|-------|-----|-----|
| catalog key / catalog `id` | `jira-sync` | `jira-sync` (unchanged) |
| manifest `extension.id` | `jira` | **`jira-sync`** |
| command namespace | `speckit.jira.*` | **`speckit.jira-sync.*`** |
| install directory | `.specify/extensions/jira/` | **`.specify/extensions/jira-sync/`** |
| hook-registration token | `extension: jira` | **`extension: jira-sync`** |

Source of truth after this feature: `src/identity.sh` — one constant consumed by
the registrar, the detector, and the config path.

### E2 — Command surface (4 commands, renamed)

| Old command | New command | Old slash | New slash |
|-------------|-------------|-----------|-----------|
| `speckit.jira.push` | `speckit.jira-sync.push` | `/speckit-jira-push` | `/speckit-jira-sync-push` |
| `speckit.jira.status` | `speckit.jira-sync.status` | `/speckit-jira-status` | `/speckit-jira-sync-status` |
| `speckit.jira.install` | `speckit.jira-sync.install` | `/speckit-jira-install` | `/speckit-jira-sync-install` |
| `speckit.jira.seed` | `speckit.jira-sync.seed` | `/speckit-jira-seed` | `/speckit-jira-sync-seed` |

Each has a manifest entry (`commands/…`) and a dev-layout twin
(`.claude/commands/…`); both files are renamed and kept in step.

### E3 — Hook registration record (per consumer project)

The six `after_*` entries in the consumer's `.specify/extensions.yml`. Each names
the owning extension and the command it fires:

| Field | Old | New |
|-------|-----|-----|
| `extension:` | `jira` | `jira-sync` |
| `command:` | `speckit.jira.push` | `speckit.jira-sync.push` |

This is the token the registrar **writes** and the health check **reads** — they
must derive it from the same constant (VR-3).

### E4 — Resolved binding (gitignored)

| | Path |
|---|---|
| preferred (new) | `.specify/extensions/jira-sync/jira-config.yml` |
| legacy (still read) | `.specify/extensions/jira/jira-config.yml` |

Contents unchanged. Never auto-moved or deleted.

### E5 — Published catalog listing

| Field | Old | New |
|-------|-----|-----|
| `version` | 0.5.0 (pending) | **0.6.0** |
| `provides.commands` | 4 | 4 |
| `provides.hooks` | **0** (stale) | **6** |

## Validation Rules

- **VR-1**: manifest `extension.id` MUST equal the published catalog `id`.
- **VR-2**: every declared command name MUST be `speckit.<extension.id>.<leaf>`.
- **VR-3**: the token the registrar writes and the token the detector matches MUST
  come from the same constant — divergence is a build failure, not a runtime bug.
- **VR-4**: the install directory name MUST equal the extension id.
- **VR-5**: an old-identity hook entry MUST classify as `absent` (so the shipped
  self-heal surfaces and offers it) — never as `present`, never as an error.
- **VR-6**: a hook the operator disabled MUST remain disabled through migration.
- **VR-7**: a resolved binding at the legacy path MUST still load, with exactly one
  informational line naming the new location; it MUST NOT be moved or deleted.
- **VR-8**: stale old-identity artifacts MUST be surfaced, never removed.
- **VR-9**: published capability counts MUST match the shipped manifest.
- **VR-10**: nothing the bridge projects to the tracker changes — no schema, no
  mapping, no exit code (identity change only).
- **VR-11**: no real coordinate enters a tracked file.

## State Transitions

```text
old-identity install  --(upgrade to v0.6.0)-->  hooks classify ABSENT
                      --(operator consents to the shipped self-heal)-->
                      hooks registered as `extension: jira-sync`  → auto-sync resumes

legacy binding path   --(read in place, location surfaced)-->  operator moves it when ready
```

The bridge only ever performs the consented left→right hook transition; the
binding move is the operator's, on their schedule.
