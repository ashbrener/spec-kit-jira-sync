#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# src/seed.sh — the Jira seed ceremony (feature 008).
#
# SINK-SIDE config validation, NOT engine. Seed is the lifecycle trust gate: it
# validates/normalizes the `phase:*` / `task-phase:N` label prefixes and
# confirms every configured lifecycle `phase_status` id is reachable on the
# project's workflow (`GET project/<key>/statuses` over `jira_rest::get`),
# capturing/confirming the ids via `config::write_binding`. It NEVER pre-creates
# labels (Jira auto-creates them on first reconcile use) and NEVER mutates the
# project's admin-scoped workflow statuses/transitions (clarify b).
#
# It is NOT an audited engine function — the 003 neutrality gate is unaffected.
#
# Design (specs/008-install-seed-ceremony):
#   - Resolve-in-memory THEN write-once: an unreachable status fails closed
#     (exit 2) naming the lifecycle step BEFORE any write — no partial binding.
#   - Fail-closed exit codes mirror reconcile: 2 = config error / unreachable
#     lifecycle step; 3 = Jira unreadable. Idempotent byte-identical no-op on a
#     healthy project.
#   - Privacy (Principle IX): writes only the gitignored config path.
#
# Safe under `set -euo pipefail` at the entry point; sourced libraries do not
# mutate the caller's shell options. shellcheck-clean (--severity=style).
# =============================================================================

SEED_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./jira_rest.sh disable=SC1091
source "${SEED_SH_DIR}/jira_rest.sh"
# shellcheck source=./config.sh disable=SC1091
source "${SEED_SH_DIR}/config.sh"
# shellcheck source=./summary.sh disable=SC1091
source "${SEED_SH_DIR}/summary.sh"

declare -g SEED_EXIT_CODE=0
declare -g SEED_CONFIG_PATH="${CONFIG_DEFAULT_PATH}"

# seed::_log <message…> — stderr only, never a credential.
seed::_log() {
    printf 'spec-kit-jira seed: %s\n' "$*" >&2
}

# seed::promote_exit <code> — monotonic escalation (mirrors reconcile).
seed::promote_exit() {
    local incoming="$1"
    if (( SEED_EXIT_CODE == 2 )); then
        return 0
    fi
    case "$incoming" in
        2) SEED_EXIT_CODE=2 ;;
        3) (( SEED_EXIT_CODE < 3 )) && SEED_EXIT_CODE=3 ;;
        1) (( SEED_EXIT_CODE < 1 )) && SEED_EXIT_CODE=1 ;;
        0) : ;;
        *) : ;;
    esac
    return 0
}

# seed::parse_args <args…>
#   --config <path>   the bound jira-config.yml (default the gitignored path)
#   --dry-run         validate + confirm reachability + report, write nothing
seed::parse_args() {
    SEED_DRY_RUN=0
    while (( $# > 0 )); do
        case "$1" in
            --config)
                SEED_CONFIG_PATH="${2:-}"; shift 2 || { seed::promote_exit 2; return 2; } ;;
            --config=*)
                SEED_CONFIG_PATH="${1#*=}"; shift ;;
            --dry-run)
                SEED_DRY_RUN=1; shift ;;
            *)
                seed::_log "✗ unknown argument: $1"
                seed::promote_exit 2; return 2 ;;
        esac
    done
    return 0
}
declare -g SEED_DRY_RUN=0

# ---------------------------------------------------------------------------
# seed::validate_labels  (FR-003 / VR-7)
#   Confirm the `phase:*` / `task-phase:N` (and the spec/repo/task) label
#   prefixes from the loaded config are present + well-formed. Jira labels
#   auto-create on first reconcile use, so seed NEVER pre-creates a label — it
#   only validates the prefixes are non-empty and contain no whitespace (a label
#   prefix with a space would split into two labels). Returns non-zero (exit-2
#   intent) on a malformed prefix.
# ---------------------------------------------------------------------------
seed::validate_labels() {
    local rc=0 key prefix
    for key in spec_prefix repo_prefix phase_prefix lifecycle_prefix task_prefix; do
        prefix="${CONFIG_VALUES[labels.${key}]:-}"
        if [[ "${key}" == "task_prefix" && -z "${prefix}" ]]; then
            # task_prefix is only required for a Task-projected level; absence is
            # fine for the zero-config default. Skip the empty check.
            continue
        fi
        if [[ -z "${prefix}" ]]; then
            seed::_log "✗ labels.${key} is missing"
            seed::promote_exit 2; rc=2; continue
        fi
        if [[ "${prefix}" =~ [[:space:]] ]]; then
            seed::_log "✗ labels.${key} ('${prefix}') contains whitespace — a label prefix must be a single token."
            seed::promote_exit 2; rc=2; continue
        fi
        seed::_log "✓ label prefix ${key}=${prefix}"
    done
    return "${rc}"
}

# ---------------------------------------------------------------------------
# seed::confirm_reachability  (FR-003 / VR-7, the trust gate)
#   For each of the 6 configured `phase_status` ids, confirm the status exists
#   on the project (GET project/<key>/statuses). NEVER mutates the workflow.
#   Fail closed (exit 2) naming exactly which lifecycle step is unreachable.
#   An unreadable statuses probe is exit 3 (Jira unreadable).
# ---------------------------------------------------------------------------
seed::confirm_reachability() {
    local project="${CONFIG_VALUES[project_key]:-}"
    if [[ -z "${project}" ]]; then
        seed::_log "✗ project_key missing from the binding"
        seed::promote_exit 2
        return "${SEED_EXIT_CODE}"
    fi

    local sraw
    if ! sraw="$(jira_rest::get "project/${project}/statuses" 2>/dev/null)"; then
        seed::_log "✗ could not read the project's statuses (GET project/${project}/statuses)"
        seed::_log "  remediation: confirm the project key + that the credential can read the project's workflow."
        seed::promote_exit 3
        return "${SEED_EXIT_CODE}"
    fi

    # The set of status ids that exist on the project's workflow.
    local -A present=()
    local id
    while IFS= read -r id; do
        [[ -n "${id}" ]] && present["${id}"]=1
    done < <(printf '%s' "${sraw}" | jq -r '[.[].statuses[]?.id] | unique | .[]' 2>/dev/null)

    local rc=0 phase want
    for phase in specifying planning tasking implementing ready_to_merge merged; do
        want="${CONFIG_VALUES[phase_status.${phase}]:-}"
        if [[ -z "${want}" ]]; then
            seed::_log "✗ phase_status.${phase} is missing from the binding (run /speckit-jira-install)."
            seed::promote_exit 2; rc=2; continue
        fi
        if [[ -n "${present[${want}]:-}" ]]; then
            seed::_log "✓ ${phase} → status ${want} reachable"
        else
            seed::_log "✗ ${phase}: status id ${want} is NOT on project ${project}'s workflow (unreachable)."
            seed::_log "  remediation: re-run /speckit-jira-install (or --phase-status ${phase}=<statusName|id>) to map ${phase} onto an existing status."
            seed::promote_exit 2; rc=2
        fi
    done
    return "${rc}"
}

# ---------------------------------------------------------------------------
# seed::main <args…>  (FR-003, orchestration — clarify b)
#   load binding → validate labels → confirm reachability → (re)write the
#   binding once via config::write_binding (byte-identical no-op on a healthy
#   project). Any failure returns non-zero BEFORE the write — no partial binding.
# ---------------------------------------------------------------------------
seed::main() {
    SEED_EXIT_CODE=0
    seed::parse_args "$@" || return "${SEED_EXIT_CODE}"

    # Load the bound config (config::load halts via _die/exit 2 if absent —
    # guard the path first so we can return our own exit code cleanly).
    if [[ ! -r "${SEED_CONFIG_PATH}" ]]; then
        seed::_log "✗ no binding at ${SEED_CONFIG_PATH} — run /speckit-jira-install first."
        seed::promote_exit 2
        return "${SEED_EXIT_CODE}"
    fi
    config::load "${SEED_CONFIG_PATH}"

    seed::validate_labels || return "${SEED_EXIT_CODE}"
    seed::confirm_reachability || return "${SEED_EXIT_CODE}"

    if (( SEED_DRY_RUN == 1 )); then
        seed::_log "✓ dry-run: labels + lifecycle mapping validated; no binding written."
        return "${SEED_EXIT_CODE}"
    fi

    # Capture/confirm the validated ids back into the binding (byte-identical
    # no-op when nothing changed). Pass the SAME resolved ids we just confirmed.
    local -a kvs=("project_key=${CONFIG_VALUES[project_key]}")
    local itype
    for itype in epic story subtask; do
        [[ -n "${CONFIG_VALUES[issue_types.${itype}]:-}" ]] \
            && kvs+=("issue_types.${itype}=${CONFIG_VALUES[issue_types.${itype}]}")
    done
    local phase
    for phase in specifying planning tasking implementing ready_to_merge merged; do
        kvs+=("phase_status.${phase}=${CONFIG_VALUES[phase_status.${phase}]}")
    done
    if ! config::write_binding "${SEED_CONFIG_PATH}" "${kvs[@]}"; then
        seed::_log "✗ failed to write the binding to ${SEED_CONFIG_PATH}"
        seed::promote_exit 2
        return "${SEED_EXIT_CODE}"
    fi

    seed::_log "✓ seed complete: labels validated, every lifecycle status reachable, binding confirmed."
    return "${SEED_EXIT_CODE}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    seed::main "$@"
fi
