#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/reconcile_hookcheck.bats — 012 reconcile-side wiring (C-10/C-11).
#
# Drives hookcheck::reconcile_check over temp extensions.yml fixtures with
# summary::add + install::register_after_hooks stubbed, so no Jira/install
# machinery runs. Covers the push branch (US1: warn_once), the dry-run branch
# (US2: first-class status line), and the consented self-heal offer on BOTH
# branches (US3). The hook path is non-blocking: it never calls
# `summary::add error` and never mutates RECONCILE_EXIT_CODE.
# =============================================================================

SRC_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
HOOKCHECK_SH="${SRC_ROOT}/src/hookcheck.sh"

setup() {
    load '../helpers/hookcheck_fixtures'
    TEST_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/speckit-recon-hc-XXXXXX")"
    OUT="${TEST_TMP}/calls.log"
    ANS="${TEST_TMP}/answer"
    YML="${TEST_TMP}/extensions.yml"
    : >"$OUT"
}

teardown() {
    [[ -n "${TEST_TMP:-}" && -d "${TEST_TMP}" ]] && rm -rf "${TEST_TMP}"
}

# Source the module + install recording stubs. RECONCILE_EXIT_CODE mirrors the
# reconcile global so a test can assert the hook path never touches it.
_preamble() {
    cat <<EOF
source '${HOOKCHECK_SH}'
summary::add() { printf 'SUMMARY:%s:%s\n' "\$1" "\$2" >>'${OUT}'; }
install::register_after_hooks() { printf 'REGISTERED\n' >>'${OUT}'; }
declare -g RECONCILE_EXIT_CODE=0
declare -g _RECONCILE_HOOKS_WARNED=0
export HOOKCHECK_EXTENSIONS_YML='${YML}'
export _HOOKCHECK_INSTALL_SOURCED=1
EOF
}

# ---- US1: push branch (DRY_RUN=0) -> warn_once ------------------------------

@test "push branch: partial fixture emits ONE named warned row (not error)" {
    hookcheck_fixtures::partial "$YML"
    run bash -c "$(_preamble)
        export DRY_RUN=0 HOOKCHECK_FORCE_NONINTERACTIVE=1
        hookcheck::reconcile_check
        echo \"EXIT=\$RECONCILE_EXIT_CODE\"
        cat '${OUT}'"
    [[ "$output" == *"SUMMARY:warned:"* ]]
    [[ "$output" == *"after_tasks"* ]]
    [[ "$output" == *"/speckit-jira-install"* ]]
    [[ "$output" != *"SUMMARY:error"* ]]
    [[ "$output" == *"EXIT=0"* ]]
}

@test "push branch: warn is latched to once across two checks in a run" {
    hookcheck_fixtures::none "$YML"
    run bash -c "$(_preamble)
        export DRY_RUN=0 HOOKCHECK_FORCE_NONINTERACTIVE=1
        hookcheck::reconcile_check
        hookcheck::reconcile_check
        grep -c 'SUMMARY:warned' '${OUT}' || true"
    [ "$output" = "1" ]
}

@test "push branch: all-present fixture warns nothing, exit unchanged" {
    hookcheck_fixtures::all_present "$YML"
    run bash -c "$(_preamble)
        export DRY_RUN=0 HOOKCHECK_FORCE_NONINTERACTIVE=1
        hookcheck::reconcile_check
        echo \"EXIT=\$RECONCILE_EXIT_CODE\"
        grep -c SUMMARY '${OUT}' || true"
    [[ "$output" == *"EXIT=0"* ]]
    # only the trailing grep line prints; no SUMMARY rows
    [[ "$output" == *$'\n0' || "$output" == "EXIT=0"$'\n'"0" ]]
}

# ---- US2: dry-run branch (DRY_RUN=1) -> first-class status line -------------

@test "dry-run branch: present -> info status line 'all present', exit 0" {
    hookcheck_fixtures::all_present "$YML"
    run bash -c "$(_preamble)
        export DRY_RUN=1 HOOKCHECK_FORCE_NONINTERACTIVE=1
        hookcheck::reconcile_check
        echo \"EXIT=\$RECONCILE_EXIT_CODE\"
        cat '${OUT}'"
    [[ "$output" == *"SUMMARY:info:"* ]]
    [[ "$output" == *"all present"* ]]
    [[ "$output" != *"SUMMARY:warned"* ]]
    [[ "$output" == *"EXIT=0"* ]]
}

@test "dry-run branch: partial -> info status line naming the missing, exit 0" {
    hookcheck_fixtures::partial "$YML"
    run bash -c "$(_preamble)
        export DRY_RUN=1 HOOKCHECK_FORCE_NONINTERACTIVE=1
        hookcheck::reconcile_check
        echo \"EXIT=\$RECONCILE_EXIT_CODE\"
        cat '${OUT}'"
    [[ "$output" == *"SUMMARY:info:"* ]]
    [[ "$output" == *"partial"* ]]
    [[ "$output" == *"after_tasks"* ]]
    [[ "$output" == *"EXIT=0"* ]]
}

@test "dry-run branch: none -> info 'none registered' status line, exit 0" {
    hookcheck_fixtures::none "$YML"
    run bash -c "$(_preamble)
        export DRY_RUN=1 HOOKCHECK_FORCE_NONINTERACTIVE=1
        hookcheck::reconcile_check
        echo \"EXIT=\$RECONCILE_EXIT_CODE\"
        cat '${OUT}'"
    [[ "$output" == *"SUMMARY:info:"* ]]
    [[ "$output" == *"none registered"* ]]
    [[ "$output" == *"EXIT=0"* ]]
}

@test "dry-run branch: unverifiable -> info 'could not verify', exit 0" {
    hookcheck_fixtures::malformed "$YML"
    run bash -c "$(_preamble)
        export DRY_RUN=1 HOOKCHECK_FORCE_NONINTERACTIVE=1
        hookcheck::reconcile_check
        echo \"EXIT=\$RECONCILE_EXIT_CODE\"
        cat '${OUT}'"
    [[ "$output" == *"SUMMARY:info:"* ]]
    [[ "$output" == *"could not verify"* ]]
    [[ "$output" == *"EXIT=0"* ]]
}

@test "dry-run branch: not_installed (no file) -> info line, exit 0" {
    run bash -c "$(_preamble)
        export DRY_RUN=1 HOOKCHECK_FORCE_NONINTERACTIVE=1
        export HOOKCHECK_EXTENSIONS_YML='${TEST_TMP}/nope.yml'
        hookcheck::reconcile_check
        echo \"EXIT=\$RECONCILE_EXIT_CODE\"
        cat '${OUT}'"
    [[ "$output" == *"SUMMARY:info:"* ]]
    [[ "$output" == *"not installed"* ]]
    [[ "$output" == *"EXIT=0"* ]]
}

# ---- US3: consented self-heal offered on BOTH branches ---------------------

@test "self-heal: push branch + interactive 'y' re-registers all missing" {
    printf 'y\n' >"$ANS"
    hookcheck_fixtures::partial "$YML"
    run bash -c "$(_preamble)
        export DRY_RUN=0 HOOKCHECK_FORCE_INTERACTIVE=1 HOOKCHECK_TTY=/dev/null HOOKCHECK_TTY_IN='${ANS}'
        hookcheck::reconcile_check
        echo \"EXIT=\$RECONCILE_EXIT_CODE\"
        cat '${OUT}'"
    [[ "$output" == *"REGISTERED"* ]]
    [[ "$output" == *"SUMMARY:updated:"* ]]
    [[ "$output" == *"EXIT=0"* ]]
}

@test "self-heal: dry-run branch + interactive 'y' re-registers all missing" {
    printf 'y\n' >"$ANS"
    hookcheck_fixtures::partial "$YML"
    run bash -c "$(_preamble)
        export DRY_RUN=1 HOOKCHECK_FORCE_INTERACTIVE=1 HOOKCHECK_TTY=/dev/null HOOKCHECK_TTY_IN='${ANS}'
        hookcheck::reconcile_check
        echo \"EXIT=\$RECONCILE_EXIT_CODE\"
        cat '${OUT}'"
    [[ "$output" == *"REGISTERED"* ]]
    [[ "$output" == *"EXIT=0"* ]]
}

@test "self-heal: non-interactive leaves the fixture untouched (no registration)" {
    printf 'y\n' >"$ANS"
    hookcheck_fixtures::partial "$YML"
    run bash -c "$(_preamble)
        export DRY_RUN=0 HOOKCHECK_FORCE_NONINTERACTIVE=1 HOOKCHECK_TTY=/dev/null HOOKCHECK_TTY_IN='${ANS}'
        hookcheck::reconcile_check
        cat '${OUT}'"
    [[ "$output" != *"REGISTERED"* ]]
}
