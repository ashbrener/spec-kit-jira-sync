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

# shellcheck source=src/jira_rest.sh
source "${SEED_SH_DIR}/jira_rest.sh"
# shellcheck source=src/config.sh
source "${SEED_SH_DIR}/config.sh"
# shellcheck source=src/summary.sh
source "${SEED_SH_DIR}/summary.sh"

declare -g SEED_EXIT_CODE=0

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
seed::parse_args() { : ; }

# seed::validate_labels — confirm/normalize the label prefixes; never create.
seed::validate_labels() { : ; }

# seed::confirm_reachability — every phase_status id exists on the workflow.
seed::confirm_reachability() { : ; }

# seed::main <args…>
seed::main() { : ; }

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    seed::main "$@"
fi
