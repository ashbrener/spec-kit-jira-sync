# Contract: `src/hookcheck.sh` surface + `reconcile::main` wiring

The public surface of the new module and the exact integration seam into the
reconcile engine. Mirrors the Linear sibling's `src/hookcheck.sh`; only vendor
tokens differ (`jira` / `speckit.jira.push` / `/speckit-jira-install`). Test IDs
`C-1..C-12` map to the bats assertions the tasks phase will generate.

## Module surface (`hookcheck::*`)

| Function | Signature | Contract |
|----------|-----------|----------|
| `hookcheck::classify` | `<hook> [<yml>]` → stdout `present\|disabled\|absent`; rc 2 on unreadable | C-2. Same block grammar as `install::_hook_already_registered`; reads `enabled:`. |
| `hookcheck::assess_into` | `[<yml>]` → sets `HOOKCHECK_OVERALL/_MISSING[]/_DISABLED[]`; always rc 0 | C-3. Ladder: absent→`not_installed`; unreadable / no `hooks:` key / classify rc≠0 → `unverifiable`. |
| `hookcheck::assess` | `[<yml>]` → 3 stdout lines `overall=/missing=/disabled=` | C-3b. stdout form of the above. |
| `hookcheck::warn_once` | `<overall> <missing...>` | C-4. ONE `summary::add warned` for partial/none; ONE `summary::add info` for unverifiable; latched by `_RECONCILE_HOOKS_WARNED`; present/not_installed → silent. |
| `hookcheck::status_line` | `<overall> <missing...> -- <disabled...>` → stdout line | C-5. Human health line for every state; NEVER touches the exit code. |
| `hookcheck::_is_interactive` | — → rc 0/1 | C-6. `HOOKCHECK_FORCE_INTERACTIVE=1`→0; `HOOKCHECK_FORCE_NONINTERACTIVE=1`→1; else `[[ -t 0 ]]`. |
| `hookcheck::_read_consent` | `<n>` → stdout reply | C-6. Prompt to `HOOKCHECK_TTY` (default `/dev/tty`); read from `HOOKCHECK_TTY_IN` (default `HOOKCHECK_TTY`/`dev/tty`). |
| `hookcheck::_ensure_install_sourced` | — | C-7. No-op if `install::register_after_hooks` already defined; else guarded `source install.sh`; latched. |
| `hookcheck::offer_selfheal` | `<overall> <missing...>` | C-8. Only mutating fn. partial/none AND interactive AND consent `y*` → `install::register_after_hooks` + `summary::add updated` + re-`assess_into`; else no-op. |
| `hookcheck::reconcile_check` | — | C-9. Once-per-run entry: `assess_into` → (DRY_RUN? status-line-info : warn_once) → `offer_selfheal`. |

Globals: `HOOKCHECK_OVERALL` (string), `HOOKCHECK_MISSING[]`, `HOOKCHECK_DISABLED[]`,
`HOOKCHECK_AFTER_HOOK_NAMES[]` (readonly; == `INSTALL_AFTER_HOOK_NAMES`),
`HOOKCHECK_EXTENSIONS_YML` (default `.specify/extensions.yml`, overridable).
Include-guard: `_HOOKCHECK_SH_LOADED`.

## Reconcile wiring (`reconcile::main`)

```bash
# top of reconcile.sh, beside the other source lines:
source "${SCRIPT_DIR}/hookcheck.sh"

# in reconcile::main, immediately BEFORE the final summary::emit:
hookcheck::reconcile_check || true      # non-blocking; never alters RECONCILE_EXIT_CODE
```

`hookcheck::reconcile_check` branches internally (C-10):

```bash
hookcheck::reconcile_check() {
    hookcheck::assess_into
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        summary::add info "$(hookcheck::status_line "$HOOKCHECK_OVERALL" \
            "${HOOKCHECK_MISSING[@]}" -- "${HOOKCHECK_DISABLED[@]}")"   # FR-006 status line
    else
        hookcheck::warn_once "$HOOKCHECK_OVERALL" "${HOOKCHECK_MISSING[@]}"  # FR-002 warn
    fi
    hookcheck::offer_selfheal "$HOOKCHECK_OVERALL" "${HOOKCHECK_MISSING[@]}"   # FR-009
}
```

**Invariants**:

- **C-11 (non-blocking / exit)**: neither branch calls `summary::add error` nor
  touches `RECONCILE_EXIT_CODE`; the `|| true` absorbs any internal failure. Status
  (`--dry-run`) therefore always exits 0; push keeps its own disposition (FR-003/006).
- **C-12 (neutrality)**: `hookcheck::reconcile_check` is called from `reconcile::main`
  (un-audited) and lives in `hookcheck.sh`; no vendor token enters any audited
  `reconcile::*` function → `engine_vendor_neutral.bats` stays green.

## Include-guard contract (enabling the consented heal)

Each shared lib gains, right after `set -euo pipefail`:

```bash
[[ -n "${_CONFIG_SH_LOADED:-}" ]] && return 0
readonly _CONFIG_SH_LOADED=1
```

(analogously `_JIRA_REST_SH_LOADED`, `_INSTALL_SH_LOADED`, `_SUMMARY_SH_LOADED`,
`_GIT_HELPERS_SH_LOADED`, `_PARSER_SH_LOADED`, `_WORKSTATE_SH_LOADED`,
`_JIRA_SINK_SH_LOADED`, `_PRIVACY_GUARD_SH_LOADED`, `_ADF_SH_LOADED`). This makes
`source install.sh` (which re-sources `config.sh`+`jira_rest.sh`+`summary.sh`) safe
after `reconcile.sh` already loaded them — no `readonly` double-declaration. Verified
by C-8 (a consented heal completes without a "readonly: already declared" error).
`reconcile.sh` is an entrypoint (nothing sources it) → no guard.
