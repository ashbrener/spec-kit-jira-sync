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

INSTALL_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=src/jira_rest.sh
source "${INSTALL_SH_DIR}/jira_rest.sh"
# shellcheck source=src/config.sh
source "${INSTALL_SH_DIR}/config.sh"
# shellcheck source=src/summary.sh
source "${INSTALL_SH_DIR}/summary.sh"

# ---------------------------------------------------------------------------
# Module state. The monotonic exit code (mirrors reconcile::promote_exit) and
# the in-memory resolution state install fills before the single write.
# ---------------------------------------------------------------------------
declare -g INSTALL_EXIT_CODE=0

# Resolved values, keyed by the dotted config key (project_key,
# issue_types.epic, phase_status.specifying, …). Populated by install::resolve;
# consumed by the single config::write_binding at the end of install::main.
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

# install::parse_args <args…>
install::parse_args() { : ; }

# install::guard_source_target — FR-007 source==target halt (exit 2)
install::guard_source_target() { : ; }

# install::dependency_report — FR-004 verify deps + auth, remediation, exit 2/3
install::dependency_report() { : ; }

# install::resolve — REST-resolve project/issue-types/phase_status/field
install::resolve() { : ; }

# install::main <args…>
install::main() { : ; }

# Entry point: only when executed directly (not sourced by a test).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    install::main "$@"
fi
