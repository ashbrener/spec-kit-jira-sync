#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# src/install.sh — the Jira install ceremony (feature 008).
#
# SINK-SIDE config resolution, NOT engine. Install resolves the per-repo Jira
# binding (project key, issue-type ids, the 6 lifecycle phase→status ids, and
# the best-effort story-points field id) by reading the project over the Jira
# REST API — the SAME transport the sink uses (`jira_rest::get`) — and writes
# the gitignored `.specify/extensions/jira/jira-config.yml` via the new
# `config::write_binding` writer. It reuses `mapping::detect_available_types`
# as the issue-type probe. It NEVER touches the vendor-neutral engine path, so
# the 003 neutrality gate is unaffected (install:: is not an audited engine
# function).
#
# Design (specs/008-install-seed-ceremony):
#   - REST-authoritative (Principle V): every written status/type value is an
#     id captured at resolution, never a name to be re-looked-up.
#   - Resolve-in-memory THEN write-once (the single config::write_binding is the
#     LAST step): any earlier failure (guard / dependency report / resolve)
#     returns non-zero BEFORE the write, so a failed run writes ZERO bytes.
#   - Fail-closed exit codes mirror reconcile: 2 = config error / missing inputs
#     / source==target / unmappable phase; 3 = Jira unreadable. No new code.
#   - Privacy (Principle IX): the resolved binding is written ONLY to the
#     gitignored config path; nothing real is echoed into a tracked file.
#
# Safe under `set -euo pipefail` at the entry point; sourced libraries do not
# mutate the caller's shell options. shellcheck-clean (--severity=style).
# =============================================================================

# Idempotent include-guard (012) — safe to source twice. The consented
# self-heal (hookcheck::offer_selfheal) sources this file after reconcile.sh
# already loaded config.sh/summary.sh; the guard here (before the source block
# below) makes that re-entry a clean no-op.
[[ -n "${_INSTALL_SH_LOADED:-}" ]] && return 0
readonly _INSTALL_SH_LOADED=1

INSTALL_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./jira_rest.sh disable=SC1091
source "${INSTALL_SH_DIR}/jira_rest.sh"
# shellcheck source=./config.sh disable=SC1091
source "${INSTALL_SH_DIR}/config.sh"
# shellcheck source=./summary.sh disable=SC1091
source "${INSTALL_SH_DIR}/summary.sh"

# ---------------------------------------------------------------------------
# Module state. The monotonic exit code (mirrors reconcile::promote_exit) and
# the in-memory resolution state install fills before the single write.
# ---------------------------------------------------------------------------
declare -g INSTALL_EXIT_CODE=0

# Parsed-argument state (populated by install::parse_args, consumed by main).
declare -g INSTALL_PROJECT=""
declare -g INSTALL_NON_INTERACTIVE=0
declare -g INSTALL_OFFER_SEED=1          # FR-013: offer seed on success by default
declare -g INSTALL_RUN_SEED=0            # --with-seed: run seed immediately
declare -g INSTALL_CONFIG_PATH="${CONFIG_DEFAULT_PATH}"
# Repeated --phase-status <phase>=<status> overrides, as plain words.
declare -ga INSTALL_PHASE_OVERRIDES=()

# ---------------------------------------------------------------------------
# Feature 011 — the automatic mirror (Principle VII). The install ceremony
# registers the six `after_*` lifecycle hooks into the consumer's
# `.specify/extensions.yml` so every `/speckit-*` command auto-mirrors the spec
# state to Jira. INSTALL_AFTER_HOOK_NAMES all fire the same command
# (`speckit.jira.push`) because reconcile is the single convergent operation.
# Mirrors the Linear sibling's block grammar exactly so a future hook-health
# detector (feature 012) and this registrar agree on what "present" means.
# ---------------------------------------------------------------------------
readonly INSTALL_EXTENSIONS_YML=".specify/extensions.yml"
readonly -a INSTALL_AFTER_HOOK_NAMES=(
    "after_specify"
    "after_clarify"
    "after_plan"
    "after_tasks"
    "after_implement"
    "after_analyze"
)

# Resolved values, keyed by the dotted config key (project_key,
# issue_types.epic, phase_status.specifying, …). Populated by install::resolve;
# consumed by the single config::write_binding at the end of install::main (and
# inspected by the unit tests). Global by design — read across functions/tests.
# shellcheck disable=SC2034
declare -gA INSTALL_RESOLVED=()

# install::promote_exit <code>
#   Monotonic escalation mirroring reconcile::promote_exit: 2 is terminal
#   (config error — the operator MUST act), then 3 over 1 over 0.
install::promote_exit() {
    local incoming="$1"
    if (( INSTALL_EXIT_CODE == 2 )); then
        return 0
    fi
    case "$incoming" in
        2) INSTALL_EXIT_CODE=2 ;;
        3) (( INSTALL_EXIT_CODE < 3 )) && INSTALL_EXIT_CODE=3 ;;
        1) (( INSTALL_EXIT_CODE < 1 )) && INSTALL_EXIT_CODE=1 ;;
        0) : ;;
        *) : ;;
    esac
    return 0
}

# install::_log <message…> — stderr only, never a credential.
install::_log() {
    printf 'spec-kit-jira install: %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# install::guard_source_target [target_root]  (FR-007 / C-7)
#   Halt when install is run from the bridge's OWN checkout rather than a
#   consumer repo — so an operator never scribbles a real binding over the dev
#   tree. Canonicalize the extension source root (where this script lives) and
#   the target repo root and compare; additionally flag when the target's
#   `specs/` are the bridge's own feature specs. Returns 2 (config-error intent)
#   on a match, 0 otherwise. Performs no probe and no write.
# ---------------------------------------------------------------------------
install::guard_source_target() {
    local target="${1:-$(pwd)}"

    # The extension source root is the parent of src/ (this script's dir).
    local source_root
    source_root="$(cd "${INSTALL_SH_DIR}/.." 2>/dev/null && pwd -P)" || return 2

    local target_root
    target_root="$(cd "${target}" 2>/dev/null && pwd -P)" || {
        install::_log "target repo root not found: ${target}"
        return 2
    }

    if [[ "${source_root}" == "${target_root}" ]]; then
        install::_log "refusing to install: the target is the bridge's own checkout (${target_root})."
        install::_log "remediation: run /speckit-jira-install from your CONSUMER repo, not the bridge's source tree."
        return 2
    fi

    # Defensive: the bridge ships its own specs/008-install-seed-ceremony etc.;
    # if the target tree carries the bridge's manifest it is the bridge itself.
    if [[ -f "${target_root}/extension.yml" ]] \
        && grep -q 'id: "jira"' "${target_root}/extension.yml" 2>/dev/null \
        && [[ -f "${target_root}/src/install.sh" ]]; then
        install::_log "refusing to install: the target tree looks like the bridge's own source (carries extension.yml + src/install.sh)."
        install::_log "remediation: run /speckit-jira-install from your CONSUMER repo."
        return 2
    fi

    return 0
}

# =============================================================================
# Feature 011 — auto-register the six `after_*` hooks (Principle VII).
#
# Install/config-side ONLY: this reads the manifest's command name + writes the
# consumer's `.specify/extensions.yml`. It NEVER touches the vendor-neutral
# reconcile engine (the 003 neutrality gate is unaffected — install:: is not an
# audited engine function).
#
# YAML manipulation uses grep + a PURE-BASH line-by-line splice (NOT multi-line
# `awk -v` — BSD awk on macOS rejects a newline-bearing `-v` value with
# `awk: newline in string`). yq is NOT a required dependency.
# =============================================================================

# install::_is_dogfood_target  (M1 — the NON-HALTING dogfood detector)
#
# Returns 0 (dogfood) iff the install target is the bridge's OWN checkout, ELSE
# 1. This is a SEPARATE, return-only twin of install::guard_source_target — the
# guard HALTS (exit 2) on source==target and is wired into install::main BEFORE
# register_after_hooks, so it would never let the registrar run in the bridge's
# own tree. The registrar needs to KNOW it is dogfooding (to gate the hook
# `condition`) without aborting, hence this non-halting detector. The same
# `INSTALL_SH_DIR/.. vs $(pwd)` `pwd -P` compare, no exit. Tests override the
# verdict via INSTALL_DOGFOOD_OVERRIDE (mirrors Linear's testable
# INSTALL_DOGFOOD_DETECTED).
install::_is_dogfood_target() {
    # Test/override hook: an explicit 0/1 forces the verdict.
    if [[ -n "${INSTALL_DOGFOOD_OVERRIDE:-}" ]]; then
        (( INSTALL_DOGFOOD_OVERRIDE == 1 )) && return 0
        return 1
    fi
    local source_root target_root
    source_root="$(cd "${INSTALL_SH_DIR}/.." 2>/dev/null && pwd -P)" || return 1
    target_root="$(pwd -P 2>/dev/null)" || return 1
    [[ "${source_root}" == "${target_root}" ]] && return 0
    # Defensive: the target tree carrying the bridge's own manifest is the bridge.
    if [[ -f "${target_root}/extension.yml" ]] \
        && grep -q 'id: "jira"' "${target_root}/extension.yml" 2>/dev/null \
        && [[ -f "${target_root}/src/install.sh" ]]; then
        return 0
    fi
    return 1
}

# install::register_after_hooks  (FR-002, wired into install::main after the
# binding write). Ensure the consumer file exists (minimal scaffold if absent),
# then idempotently register each of the six `after_*` hooks.
install::register_after_hooks() {
    if [[ ! -f "$INSTALL_EXTENSIONS_YML" ]]; then
        install::_create_minimal_extensions_yml
    fi

    # Resilience (FR-009): an unreadable/malformed file must not be corrupted or
    # halt the host — surface an informational message and return cleanly.
    if [[ ! -r "$INSTALL_EXTENSIONS_YML" ]]; then
        install::_log "could not register hooks — verify ${INSTALL_EXTENSIONS_YML} (unreadable). No changes made."
        return 0
    fi

    local hook
    for hook in "${INSTALL_AFTER_HOOK_NAMES[@]}"; do
        install::_register_one_hook "$hook"
    done
}

# install::_create_minimal_extensions_yml — write the minimal consumer file when
# absent: `installed:` (with jira), `settings: { auto_execute_hooks: true }`
# (required for the skills to auto-EXECUTE the hook), and an empty `hooks:`.
install::_create_minimal_extensions_yml() {
    mkdir -p "$(dirname "$INSTALL_EXTENSIONS_YML")"
    cat >"$INSTALL_EXTENSIONS_YML" <<'YAML'
installed:
- jira
settings:
  auto_execute_hooks: true
hooks:
YAML
    install::_log "created ${INSTALL_EXTENSIONS_YML}"
}

# install::_register_one_hook <hook_name>
#
# Idempotently insert the `jira` entry under <hook_name>. Re-registration
# honours any existing `enabled: false` the operator chose (Principle VII / VIII)
# — a present entry is PRESERVED untouched.
install::_register_one_hook() {
    local hook="$1"

    if install::_hook_already_registered "$hook"; then
        install::_log "hook ${hook} already registered; preserving existing entry"
        return 0
    fi

    local block
    block="$(install::_render_hook_block "$hook")"

    # Two append paths:
    #   (a) the `<hook>:` key already exists — append the jira block under it
    #       (alongside any other extension's entries, untouched).
    #   (b) the `<hook>:` key is missing — create the section with the block.
    if grep -qE "^[[:space:]]{2}${hook}:[[:space:]]*$" "$INSTALL_EXTENSIONS_YML"; then
        install::_append_under_hook "$hook" "$block"
    else
        install::_create_hook_section "$hook" "$block"
    fi
}

# install::_hook_already_registered <hook_name>
#
# Returns 0 iff the named after_* hook already has a `jira` extension entry. The
# match is anchored on `extension: jira` appearing inside the `^  <hook>:` block
# (single-line awk vars only — BSD-awk safe).
install::_hook_already_registered() {
    local hook="$1"
    [[ -f "$INSTALL_EXTENSIONS_YML" ]] || return 1
    awk -v want="$hook" '
        BEGIN { in_block = 0; found = 0 }
        $0 ~ "^  " want ":" {
            in_block = 1
            next
        }
        in_block && /^  [a-zA-Z_]+:[[:space:]]*$/ {
            in_block = 0
        }
        in_block && /extension:[[:space:]]*jira/ {
            found = 1
            exit
        }
        END { exit (found ? 0 : 1) }
    ' "$INSTALL_EXTENSIONS_YML"
}

# install::_render_hook_block <hook_name>
#
# Emit the YAML for a single `jira` entry under a hook block. On a DOGFOOD target
# (install::_is_dogfood_target ⇒ 0), the `condition` is the LITERAL
# `${SPECKIT_JIRA_DOGFOOD_SAFE:-false}` (host-evaluated at fire time — the
# bridge's own dev does not auto-push unless the operator opts in); else `null`.
install::_render_hook_block() {
    local hook="$1"
    local description prompt
    case "$hook" in
        after_specify)
            description="Reconcile after /speckit-specify so the new spec Story exists in Jira with the correct initial status."
            prompt="Reconciling spec.md to Jira..."
            ;;
        after_clarify)
            description="Reconcile after /speckit-clarify so ratified clarifications appear as comments on the spec Story."
            prompt="Reconciling clarification rounds to Jira comments..."
            ;;
        after_plan)
            description="Reconcile after /speckit-plan so the spec Story advances to the planning status and plan/ADR summaries appear as comments."
            prompt="Reconciling plan.md to Jira..."
            ;;
        after_tasks)
            description="Reconcile after /speckit-tasks so each lifecycle phase becomes a Jira Subtask of the spec Story with the right checklist."
            prompt="Reconciling tasks.md to Jira subtasks..."
            ;;
        after_implement)
            description="Reconcile after /speckit-implement so checklist completion and the lifecycle status roll up in Jira."
            prompt="Reconciling implementation progress to Jira..."
            ;;
        after_analyze)
            description="Reconcile after /speckit-analyze so analyze findings appear as comments on the spec Story."
            prompt="Reconciling analyze findings to Jira comments..."
            ;;
        *)
            description="Reconcile after /${hook#after_} so Jira stays in sync."
            prompt="Reconciling to Jira..."
            ;;
    esac

    {
        printf '  - extension: jira\n'
        printf '    command: speckit.jira.push\n'
        printf '    enabled: true\n'
        printf '    optional: false\n'
        printf '    prompt: %s\n' "$prompt"
        printf '    description: %s\n' "$description"
        if install::_is_dogfood_target; then
            # SC2016 suppressed: the `${SPECKIT_JIRA_DOGFOOD_SAFE:-false}` text is
            # written VERBATIM into the YAML; the host agent (not us) evaluates it
            # at hook-fire time. We want literal text, not bash expansion here.
            # shellcheck disable=SC2016
            printf '    condition: "${SPECKIT_JIRA_DOGFOOD_SAFE:-false}"\n'
        else
            printf '    condition: null\n'
        fi
    }
}

# install::_append_under_hook <hook_name> <block_text>
#
# Insert the rendered block immediately after the named hook header, before the
# next sibling hook or EOF. Preserves any existing entries under the hook (e.g.
# a speckit-git entry). PURE-BASH line-by-line state machine (BSD awk on macOS
# rejects multi-line `-v` — the Linear dogfood run surfaced `awk: newline in
# string`); the awk dependency stays limited to single-line vars elsewhere.
install::_append_under_hook() {
    local hook="$1"
    local block="$2"
    local tmp
    tmp="$(mktemp -t spec-kit-jira-ext-yml.XXXXXX)"

    # state="before"  — copy verbatim until the hook header.
    # state="in_hook" — buffer the hook's child lines until the next sibling
    #                   header (two-space indent + key + colon) or EOF, then
    #                   flush the buffer + the new block.
    # state="after"   — copy the rest verbatim.
    local state="before"
    local -a block_buf=()
    local emitted=0
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$state" == "before" ]]; then
            if [[ "$line" =~ ^[[:space:]]{2}${hook}:[[:space:]]*$ ]]; then
                printf '%s\n' "$line" >>"$tmp"
                state="in_hook"
                block_buf=()
                continue
            fi
            printf '%s\n' "$line" >>"$tmp"
            continue
        fi
        if [[ "$state" == "in_hook" ]]; then
            if [[ "$line" =~ ^\ {2}[a-zA-Z_]+:[[:space:]]*$ ]]; then
                local buf_line
                for buf_line in "${block_buf[@]+"${block_buf[@]}"}"; do
                    printf '%s\n' "$buf_line" >>"$tmp"
                done
                printf '%s\n' "$block" >>"$tmp"
                emitted=1
                printf '%s\n' "$line" >>"$tmp"
                state="after"
                continue
            fi
            block_buf+=("$line")
            continue
        fi
        printf '%s\n' "$line" >>"$tmp"
    done < "$INSTALL_EXTENSIONS_YML"

    # Drained the whole file still inside the hook block — flush + emit at EOF.
    if [[ "$state" == "in_hook" ]] && (( emitted == 0 )); then
        local buf_line
        for buf_line in "${block_buf[@]+"${block_buf[@]}"}"; do
            printf '%s\n' "$buf_line" >>"$tmp"
        done
        printf '%s\n' "$block" >>"$tmp"
    fi

    mv "$tmp" "$INSTALL_EXTENSIONS_YML"
}

# install::_create_hook_section <hook_name> <block_text>
#
# Append a brand-new `  <hook>:` section (+ the block) to the tail of the file.
# Used when the host file has no entry for the hook at all. Adds the `hooks:`
# key first when missing.
install::_create_hook_section() {
    local hook="$1"
    local block="$2"
    # Read the hooks-key presence BEFORE opening the append redirect so the
    # read+write of one file in a single pipeline (SC2094) stays clean.
    local needs_hooks_header=0
    if ! grep -qE '^hooks:[[:space:]]*$' "$INSTALL_EXTENSIONS_YML"; then
        needs_hooks_header=1
    fi
    {
        if (( needs_hooks_header == 1 )); then
            printf 'hooks:\n'
        fi
        printf '  %s:\n' "$hook"
        printf '%s\n' "$block"
    } >>"$INSTALL_EXTENSIONS_YML"
}

# ---------------------------------------------------------------------------
# install::dependency_report <project_key>  (FR-004 / FR-005, Principle VIII)
#   Verify every dependency BEFORE any resolution or write: the .env Basic-auth
#   vars present, jq/curl/git present, the credential authenticates (a GET
#   myself probe), and the target project key is readable. Each check emits a
#   ✓/✗ row to stderr with exact copy-paste remediation on failure. Returns:
#     0  all green
#     2  missing local input / tool (JIRA_* var, jq/curl/git)
#     3  Jira unreadable (myself / project GET fails — auth/transport)
#   Writes nothing.
# ---------------------------------------------------------------------------
install::dependency_report() {
    local project="${1:-}"
    local rc=0

    # 1. Local tools.
    local tool
    for tool in jq curl git; do
        if command -v "${tool}" >/dev/null 2>&1; then
            install::_log "✓ ${tool} present"
        else
            install::_log "✗ ${tool} missing"
            install::_log "  remediation: install ${tool} (macOS: brew install ${tool}; Debian/Ubuntu: sudo apt-get install ${tool})"
            install::promote_exit 2; rc=2
        fi
    done

    # 2. .env Basic-auth vars.
    local var missing=()
    for var in JIRA_BASE_URL JIRA_EMAIL JIRA_API_TOKEN; do
        if [[ -n "${!var:-}" ]]; then
            install::_log "✓ ${var} set"
        else
            install::_log "✗ ${var} missing"
            missing+=("${var}")
            install::promote_exit 2; rc=2
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        install::_log "  remediation: add to the gitignored .env, then re-run:"
        for var in "${missing[@]}"; do
            case "${var}" in
                JIRA_BASE_URL)  install::_log "    JIRA_BASE_URL=https://<your-site>.atlassian.net" ;;
                JIRA_EMAIL)     install::_log "    JIRA_EMAIL=you@example.com" ;;
                JIRA_API_TOKEN) install::_log "    JIRA_API_TOKEN=<your Atlassian API token>" ;;
            esac
        done
        # Missing creds: cannot probe Jira — return the config-error code now.
        return "${INSTALL_EXIT_CODE}"
    fi

    # 3. Authenticate via a GET myself probe (the sink's transport).
    if jira_rest::get "myself" >/dev/null 2>&1; then
        install::_log "✓ credential authenticates (GET myself)"
    else
        install::_log "✗ credential does not authenticate (GET myself failed)"
        install::_log "  remediation: check JIRA_EMAIL + JIRA_API_TOKEN in .env (regenerate the token at id.atlassian.com if needed)."
        install::promote_exit 3; rc=3
        return "${INSTALL_EXIT_CODE}"
    fi

    # 4. Target project readable.
    if [[ -n "${project}" ]]; then
        if jira_rest::get "project/${project}" >/dev/null 2>&1; then
            install::_log "✓ project ${project} readable"
        else
            install::_log "✗ project ${project} not readable (GET project/${project} failed)"
            install::_log "  remediation: confirm the project key and that ${JIRA_EMAIL:-the credential} can see it."
            install::promote_exit 3; rc=3
            return "${INSTALL_EXIT_CODE}"
        fi
    fi

    return "${rc}"
}

# ---------------------------------------------------------------------------
# install::resolve <project_key> [--non-interactive] [phase=status…]
#   (FR-001/FR-002, Principle V) REST-only resolution into INSTALL_RESOLVED:
#     - project + issue types via mapping::detect_available_types (the reused
#       probe) → issue_types.{epic,story,subtask};
#     - phase→status: GET project/<key>/statuses, group by statusCategory.key,
#       propose a default for the 6 lifecycle phases (new→specifying/planning,
#       indeterminate→tasking/implementing, done→ready_to_merge/merged), allow a
#       per-phase override; capture the chosen STATUS ID per phase;
#     - story-points field id: GET field, best-effort (absent ⇒ skipped, note).
#   Every value is an id (never a name). An unmappable phase ⇒ promote_exit 2
#   naming it. Returns the promoted exit code; populates state only (no write).
# ---------------------------------------------------------------------------
install::resolve() {
    local project="${1:-}"
    shift || true
    # Optional per-phase overrides as `phase=statusNameOrId` extra args.
    local -A phase_override=()
    local a
    for a in "$@"; do
        [[ "${a}" == *=* ]] || continue
        phase_override["${a%%=*}"]="${a#*=}"
    done

    if [[ -z "${project}" ]]; then
        install::_log "✗ no project key supplied to resolve"
        install::promote_exit 2
        return "${INSTALL_EXIT_CODE}"
    fi
    INSTALL_RESOLVED[project_key]="${project}"

    # --- issue-type ids via the reused probe -------------------------------
    # mapping::detect_available_types reads CONFIG_VALUES[project_key]; set it so
    # the probe targets the project we are resolving (it does not require a full
    # loaded config beyond that key).
    CONFIG_LOADED_PATH="${CONFIG_LOADED_PATH:-install::resolve}"
    # CONFIG_VALUES is the global associative array config.sh declares (sourced);
    # the probe reads project_key from it.
    # shellcheck disable=SC2034,SC2154
    CONFIG_VALUES[project_key]="${project}"
    local rows rc=0
    if ! rows="$(mapping::detect_available_types 2>/dev/null)"; then
        install::_log "✗ could not read the project's issue types (GET project/${project})"
        install::promote_exit 3
        return "${INSTALL_EXIT_CODE}"
    fi
    local name id
    local -A type_by_name=()
    while IFS=$'\t' read -r name id; do
        [[ -n "${name}" ]] || continue
        type_by_name["${name}"]="${id}"
    done <<< "${rows}"
    # Map the three default projections by their canonical Jira type name.
    local want
    for want in "epic:Epic" "story:Story" "subtask:Subtask"; do
        local slot="${want%%:*}" tname="${want#*:}"
        if [[ -n "${type_by_name[${tname}]:-}" ]]; then
            INSTALL_RESOLVED["issue_types.${slot}"]="${type_by_name[${tname}]}"
        else
            install::_log "✗ the project has no '${tname}' issue type (needed for issue_types.${slot})"
            install::promote_exit 2; rc=2
        fi
    done
    (( rc == 0 )) || return "${INSTALL_EXIT_CODE}"

    # --- phase→status map via GET project/<key>/statuses -------------------
    local sraw
    if ! sraw="$(jira_rest::get "project/${project}/statuses" 2>/dev/null)"; then
        install::_log "✗ could not read the project's statuses (GET project/${project}/statuses)"
        install::promote_exit 3
        return "${INSTALL_EXIT_CODE}"
    fi
    # Flatten to `<statusCategoryKey>\t<id>\t<name>` rows, de-duplicated by id.
    local catrows
    catrows="$(printf '%s' "${sraw}" | jq -r '
        [.[].statuses[]?] | unique_by(.id) | .[]
        | "\(.statusCategory.key // "")\t\(.id)\t\(.name)"
    ' 2>/dev/null)" || catrows=""
    # Pick a default id per statusCategory (the first seen of each category).
    local cat_new="" cat_ind="" cat_done=""
    local ckey cid cname
    declare -A id_by_name=() id_set=()
    while IFS=$'\t' read -r ckey cid cname; do
        [[ -n "${cid}" ]] || continue
        id_set["${cid}"]=1
        [[ -n "${cname}" ]] && id_by_name["${cname}"]="${cid}"
        case "${ckey}" in
            new)           [[ -z "${cat_new}" ]]  && cat_new="${cid}" ;;
            indeterminate) [[ -z "${cat_ind}" ]]  && cat_ind="${cid}" ;;
            done)          [[ -z "${cat_done}" ]] && cat_done="${cid}" ;;
        esac
    done <<< "${catrows}"

    # The default phase→category-id assignment (R3).
    local -A phase_default=(
        [specifying]="${cat_new}"
        [planning]="${cat_new}"
        [tasking]="${cat_ind}"
        [implementing]="${cat_ind}"
        [ready_to_merge]="${cat_done}"
        [merged]="${cat_done}"
    )

    # R2 (robust SC-005): on a RE-RUN where a binding already exists, default
    # each phase from the EXISTING binding's phase_status id — but ONLY when that
    # id still exists on the project's workflow (else it is stale; fall back to
    # the statusCategory default). This makes an interactive accept-defaults
    # re-run byte-identical instead of silently re-categorizing.
    local -A phase_existing=()
    if [[ -n "${INSTALL_CONFIG_PATH:-}" && -r "${INSTALL_CONFIG_PATH}" ]]; then
        local eph eid
        for eph in specifying planning tasking implementing ready_to_merge merged; do
            # A shallow grep over the existing binding's phase_status block —
            # avoids re-loading config (which would clobber CONFIG_VALUES we set).
            eid="$(awk -v key="${eph}" '
                /^[[:space:]]*phase_status:[[:space:]]*$/ { inblk=1; next }
                inblk && /^[[:space:]]{0,2}[A-Za-z]/ && $0 !~ /^[[:space:]]{4}/ { inblk=0 }
                inblk && $0 ~ ("^[[:space:]]+" key "[[:space:]]*:") {
                    v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); gsub(/["\x27[:space:]]/,"",v); print v; exit
                }
            ' "${INSTALL_CONFIG_PATH}" 2>/dev/null)" || eid=""
            [[ -n "${eid}" ]] && phase_existing["${eph}"]="${eid}"
        done
    fi

    local phase chosen
    for phase in specifying planning tasking implementing ready_to_merge merged; do
        if [[ -n "${phase_override[${phase}]:-}" ]]; then
            # An override is a status NAME or an id; resolve a name to its id.
            local ov="${phase_override[${phase}]}"
            if [[ -n "${id_set[${ov}]:-}" ]]; then
                chosen="${ov}"
            elif [[ -n "${id_by_name[${ov}]:-}" ]]; then
                chosen="${id_by_name[${ov}]}"
            else
                install::_log "✗ --phase-status ${phase}=${ov}: no project status matches that name or id"
                install::promote_exit 2; rc=2
                continue
            fi
        elif [[ -n "${phase_existing[${phase}]:-}" \
                && -n "${id_set[${phase_existing[${phase}]}]:-}" ]]; then
            # R2: keep the operator's existing (still-valid) mapping on a re-run.
            chosen="${phase_existing[${phase}]}"
        else
            chosen="${phase_default[${phase}]}"
        fi
        if [[ -z "${chosen}" ]]; then
            install::_log "✗ cannot map lifecycle phase '${phase}': the project has no status in the expected category."
            install::_log "  remediation: supply --phase-status ${phase}=<statusName|id> (a status that exists on this project's workflow)."
            install::promote_exit 2; rc=2
            continue
        fi
        INSTALL_RESOLVED["phase_status.${phase}"]="${chosen}"
    done
    (( rc == 0 )) || return "${INSTALL_EXIT_CODE}"

    # --- story-points field id (best-effort, optional R5) ------------------
    local fraw fid
    if fraw="$(jira_rest::get "field" 2>/dev/null)"; then
        fid="$(printf '%s' "${fraw}" | jq -r '
            [ .[]
              | select(
                  ((.schema.custom // "") | test("story-?points"; "i"))
                  or ((.name // "") | test("^story points$"; "i"))
                ) ]
            | (.[0].id // "")
        ' 2>/dev/null)" || fid=""
        if [[ -n "${fid}" ]]; then
            INSTALL_RESOLVED[story_points_field_id]="${fid}"
            install::_log "✓ story-points field resolved (${fid})"
        else
            install::_log "⚠ no story-points field found — recording it as absent (not fatal; the bridge does not require it today)."
        fi
    else
        install::_log "⚠ could not read the field list — story-points field left unresolved (not fatal)."
    fi

    return "${INSTALL_EXIT_CODE}"
}

# ---------------------------------------------------------------------------
# install::parse_args <args…>
#   Parse the install flags into module state:
#     --project <KEY>                bind this project (else interactive prompt)
#     --non-interactive              never prompt; require flags
#     --phase-status <phase>=<stat>  repeated per-phase override
#     --with-seed                    run seed immediately after a clean install
#     --no-seed                      do not offer seed
#     --config <path>                write to a non-default path (tests)
#   Unknown flags ⇒ promote_exit 2.
# ---------------------------------------------------------------------------
install::parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --project)
                INSTALL_PROJECT="${2:-}"; shift 2 || { install::promote_exit 2; return 2; } ;;
            --project=*)
                INSTALL_PROJECT="${1#*=}"; shift ;;
            --non-interactive)
                INSTALL_NON_INTERACTIVE=1; shift ;;
            --phase-status)
                INSTALL_PHASE_OVERRIDES+=("${2:-}"); shift 2 || { install::promote_exit 2; return 2; } ;;
            --phase-status=*)
                INSTALL_PHASE_OVERRIDES+=("${1#*=}"); shift ;;
            --with-seed)
                INSTALL_RUN_SEED=1; INSTALL_OFFER_SEED=1; shift ;;
            --no-seed)
                INSTALL_OFFER_SEED=0; INSTALL_RUN_SEED=0; shift ;;
            --config)
                INSTALL_CONFIG_PATH="${2:-}"; shift 2 || { install::promote_exit 2; return 2; } ;;
            --config=*)
                INSTALL_CONFIG_PATH="${1#*=}"; shift ;;
            *)
                install::_log "✗ unknown argument: $1"
                install::promote_exit 2; return 2 ;;
        esac
    done
    return 0
}

# ---------------------------------------------------------------------------
# install::main <args…>  (FR-001, orchestration)
#   guard_source_target → dependency_report → resolve → config::write_binding
#   (the SINGLE write, LAST). Resolve-in-memory then write-once: any earlier
#   non-zero return halts BEFORE the write, so a failed run writes ZERO bytes
#   (FR-005/SC-003). Exits via the monotonic install::promote_exit.
# ---------------------------------------------------------------------------
install::main() {
    INSTALL_EXIT_CODE=0
    INSTALL_RESOLVED=()

    install::parse_args "$@" || return "${INSTALL_EXIT_CODE}"

    # 1. Source≠target guard (before any probe or write).
    if ! install::guard_source_target "$(pwd)"; then
        install::promote_exit 2
        return "${INSTALL_EXIT_CODE}"
    fi

    # 2. A project key is required to probe; in non-interactive mode it MUST be
    #    a flag. (Interactive prompting is the command body's job; the script
    #    requires the resolved key.)
    if [[ -z "${INSTALL_PROJECT}" ]]; then
        install::_log "✗ no project key supplied (--project <KEY>)."
        if (( INSTALL_NON_INTERACTIVE == 1 )); then
            install::_log "  remediation: --non-interactive requires --project <KEY> (no prompt is possible)."
        else
            install::_log "  remediation: pass --project <KEY> (find it in any issue key, e.g. PROJ-123)."
        fi
        install::promote_exit 2
        return "${INSTALL_EXIT_CODE}"
    fi

    # 3. Dependency report (verifies creds + auth + project readable). Returns a
    #    non-zero exit code on any ✗ — fail closed before resolve/write.
    if ! install::dependency_report "${INSTALL_PROJECT}"; then
        return "${INSTALL_EXIT_CODE}"
    fi

    # 4. Resolve every id into memory (no write yet).
    if ! install::resolve "${INSTALL_PROJECT}" "${INSTALL_PHASE_OVERRIDES[@]}"; then
        return "${INSTALL_EXIT_CODE}"
    fi

    # 5. The SINGLE write — last step. Flatten INSTALL_RESOLVED to key=value args.
    local -a kvs=()
    local k
    for k in "${!INSTALL_RESOLVED[@]}"; do
        kvs+=("${k}=${INSTALL_RESOLVED[$k]}")
    done
    if ! config::write_binding "${INSTALL_CONFIG_PATH}" "${kvs[@]}"; then
        install::_log "✗ failed to write the binding to ${INSTALL_CONFIG_PATH}"
        install::promote_exit 2
        return "${INSTALL_EXIT_CODE}"
    fi

    install::_log "✓ wrote ${INSTALL_CONFIG_PATH} for project ${INSTALL_PROJECT}"
    install::_log "  resolved: issue types + 6 phase→status ids${INSTALL_RESOLVED[story_points_field_id]:+ + story-points field}"

    # 6. FR-002 / Principle VII: auto-register the six after_* hooks so every
    #    /speckit-* lifecycle command auto-mirrors to Jira. Install/config-side
    #    only (writes the consumer's .specify/extensions.yml); the reconcile
    #    engine is untouched. Idempotent (byte-identical re-run); honours an
    #    operator enabled:false. This runs AFTER the binding write.
    install::register_after_hooks
    install::_log "✓ registered after_* hooks in ${INSTALL_EXTENSIONS_YML} — /speckit-* commands now auto-mirror to Jira"

    # 7. FR-013: offer / run seed. The script-side honors --with-seed (runs seed
    #    in-process); the interactive offer lives in the command body.
    if (( INSTALL_RUN_SEED == 1 )); then
        if [[ -r "${SEED_SH_PATH:-${INSTALL_SH_DIR}/seed.sh}" ]]; then
            # shellcheck source=./seed.sh disable=SC1091
            source "${INSTALL_SH_DIR}/seed.sh"
            seed::main --config "${INSTALL_CONFIG_PATH}" || install::promote_exit "$?"
        fi
    elif (( INSTALL_OFFER_SEED == 1 )); then
        install::_log "next: run /speckit-jira-seed to confirm the lifecycle mapping is reachable."
    fi

    return "${INSTALL_EXIT_CODE}"
}

# Entry point: only when executed directly (not sourced by a test).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    install::main "$@"
fi
