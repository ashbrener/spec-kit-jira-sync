#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/include_guards.bats — 012 include-guard safety (Phase 1).
#
# The consented self-heal (hookcheck::offer_selfheal) sources install.sh, which
# re-sources config.sh + jira_rest.sh + summary.sh AFTER reconcile.sh already
# loaded config.sh/summary.sh. Those libs carry `readonly` declarations, so
# without idempotent include-guards a second source is a "readonly: already
# declared" crash. These tests pin that every shared lib is safe to source
# twice, and that the exact heal-time source order succeeds.
# =============================================================================

SRC_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SRC_DIR="${SRC_ROOT}/src"

# Every shared lib that carries the include-guard idiom (NOT reconcile.sh — the
# entrypoint; nothing sources it).
GUARDED_LIBS=(
    config.sh
    jira_rest.sh
    install.sh
    summary.sh
    git_helpers.sh
    parser.sh
    workstate.sh
    jira_sink.sh
    privacy_guard.sh
    adf.sh
)

@test "each shared lib is safe to source twice (no readonly double-declare)" {
    for lib in "${GUARDED_LIBS[@]}"; do
        run bash -c "set -euo pipefail; source '${SRC_DIR}/${lib}'; source '${SRC_DIR}/${lib}'; echo OK"
        [ "$status" -eq 0 ] || {
            echo "double-source of ${lib} failed (rc=$status): $output" >&2
            return 1
        }
        [ "$output" = "OK" ]
    done
}

@test "each shared lib carries a matching include-guard var" {
    declare -A guard_var=(
        [config.sh]=_CONFIG_SH_LOADED
        [jira_rest.sh]=_JIRA_REST_SH_LOADED
        [install.sh]=_INSTALL_SH_LOADED
        [summary.sh]=_SUMMARY_SH_LOADED
        [git_helpers.sh]=_GIT_HELPERS_SH_LOADED
        [parser.sh]=_PARSER_SH_LOADED
        [workstate.sh]=_WORKSTATE_SH_LOADED
        [jira_sink.sh]=_JIRA_SINK_SH_LOADED
        [privacy_guard.sh]=_PRIVACY_GUARD_SH_LOADED
        [adf.sh]=_ADF_SH_LOADED
    )
    for lib in "${GUARDED_LIBS[@]}"; do
        run grep -q "readonly ${guard_var[$lib]}=1" "${SRC_DIR}/${lib}"
        [ "$status" -eq 0 ] || {
            echo "${lib} missing guard var ${guard_var[$lib]}" >&2
            return 1
        }
    done
}

@test "heal-time source order (reconcile libs then install.sh) succeeds" {
    # This is the exact order a consented self-heal hits: reconcile.sh has
    # already sourced config.sh + summary.sh; offer_selfheal then sources
    # install.sh, which re-sources config.sh/summary.sh/jira_rest.sh.
    run bash -c "set -euo pipefail
        source '${SRC_DIR}/config.sh'
        source '${SRC_DIR}/summary.sh'
        source '${SRC_DIR}/install.sh'
        echo OK"
    [ "$status" -eq 0 ]
    [ "$output" = "OK" ]
}
