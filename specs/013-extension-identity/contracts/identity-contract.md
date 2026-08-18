# Contract: the single identity + the rename map

Defines the one identity constant, who consumes it, and the exact rename map.
Test ids `C-1..C-10` map to the bats assertions the tasks phase will generate.

## The constant (`src/identity.sh`)

A tiny, dependency-free, include-guarded lib. No side effects, no I/O.

| Name | Value | Consumers |
|------|-------|-----------|
| `SPECKIT_EXT_ID` | `jira-sync` | `install.sh` (writes `extension:`), `hookcheck.sh` (awk match), `config.sh` (path) |
| `SPECKIT_EXT_PUSH_COMMAND` | `speckit.jira-sync.push` | `install.sh` (hook `command:`) |
| `SPECKIT_EXT_INSTALL_DIR` | `.specify/extensions/jira-sync` | `config.sh`, `install.sh` |

**C-1**: `hookcheck.sh` sources `identity.sh` **directly** — never via
`install.sh`, which it sources only lazily on consent. Sourcing `identity.sh`
twice is a clean no-op (include-guard).

## Consumer contract

| # | Requirement |
|---|-------------|
| **C-2** | `install::_render_hook_block` emits `- extension: ${SPECKIT_EXT_ID}` and `command: ${SPECKIT_EXT_PUSH_COMMAND}` — no literal. |
| **C-3** | `install::_hook_already_registered` matches on `${SPECKIT_EXT_ID}` — no literal. |
| **C-4** | `hookcheck::classify` passes the id into awk with a **single-line** `awk -v` (BSD-safe) — no literal, no multi-line `-v`. |
| **C-5** | `config.sh` `CONFIG_DEFAULT_PATH` derives from `${SPECKIT_EXT_INSTALL_DIR}`; when it is absent and the legacy `.specify/extensions/jira/jira-config.yml` exists, that file is loaded and ONE informational line names the new location. Never moved, never deleted. |

## Rename map (exhaustive, live surfaces only)

| Surface | From | To |
|---------|------|-----|
| `extension.yml` | `id: "jira"` | `id: "jira-sync"` |
| `extension.yml` commands | `speckit.jira.{push,status,install,seed}` | `speckit.jira-sync.{…}` |
| `extension.yml` hooks | `command: "speckit.jira.push"` ×6 | `speckit.jira-sync.push` ×6 |
| `commands/` | `jira-{push,status,install,seed}.md` | `jira-sync-{…}.md` (`git mv`) |
| `.claude/commands/` | `speckit-jira-{…}.md` | `speckit-jira-sync-{…}.md` (`git mv`) |
| config path | `.specify/extensions/jira/jira-config.yml` | `.specify/extensions/jira-sync/jira-config.yml` (legacy still read) |
| dogfood env | `SPECKIT_JIRA_DOGFOOD_SAFE` | `SPECKIT_JIRA_SYNC_DOGFOOD_SAFE` |
| remediation strings | `/speckit-jira-install` | `/speckit-jira-sync-install` |

**NOT renamed**: historical `specs/001`–`012` documents (they record what was true
when written); anything the bridge has already written into Jira.

## Test contract

| # | Assertion |
|---|-----------|
| **C-6** (pin, FR-012) | manifest `extension.id` == `SPECKIT_EXT_ID`; every declared command name starts `speckit.${SPECKIT_EXT_ID}.`; the manifest declares 4 commands + 6 `after_*` hooks. Fails if any diverge. |
| **C-7** (lockstep, FR-005) | the token the registrar writes is byte-identical to the token the detector matches — asserted by registering into a temp file and classifying it back as `present`. |
| **C-8** (migration, FR-006/007) | from an old-identity `extensions.yml`: classify → `absent`; the warn/status line fires; consent re-registers as `extension: jira-sync`; a pre-existing `enabled: false` survives. |
| **C-9** (config fallback, FR-008) | new path preferred; legacy path loads with exactly one informational line; the legacy file is neither moved nor deleted. |
| **C-10** (gates) | `engine_vendor_neutral.bats` green untouched; `no-real-identifiers.bats` green; no `speckit\.jira\.` or `extension: jira` literal remains in any **live** file. |
