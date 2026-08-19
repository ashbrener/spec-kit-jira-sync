#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/identity_migration.bats  (feature 013 — C-8, the load-bearing claim)
#
# An operator upgrading from a pre-0.6.0 install has six hook entries wired to
# the OLD extension id. Feature 013 adds NO migration machinery: the renamed
# detector simply no longer recognises those entries, so they classify `absent`
# — which is precisely the state the shipped 012 self-heal exists to surface and
# repair. This suite proves that end to end, because the whole upgrade story
# rests on it:
#
#   1. an old-identity extensions.yml classifies `absent` for all six hooks
#      (never `present`, never an error)                              [VR-5]
#   2. the push-path warning and the status health line both fire
#   3. a consented heal re-registers under the NEW id + push command
#   4. the operator's old entries are left untouched — including an
#      `enabled: false` they chose (surfaced, never rewritten)        [VR-6/R7]
#   5. an already-migrated `enabled: false` hook stays disabled through a heal
#
# Real writer, real detector: nothing but `summary::add` is stubbed.
# Privacy (Principle IX): placeholder-only — ids, command names, neutral prose.
# =============================================================================

SRC_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

setup() {
    TEST_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/speckit-identity-migration-XXXXXX")"
    CONSUMER="${TEST_TMP}/consumer"
    EXT_YML="${CONSUMER}/.specify/extensions.yml"
    ANS="${TEST_TMP}/answer"
    OUT="${TEST_TMP}/calls.log"
    mkdir -p "${CONSUMER}/.specify"
    : >"$OUT"
    # shellcheck source=../../src/identity.sh disable=SC1091
    source "${SRC_ROOT}/src/identity.sh"
}

teardown() {
    [[ -n "${TEST_TMP:-}" && -d "${TEST_TMP}" ]] && rm -rf "${TEST_TMP}"
}

# The pre-0.6.0 on-disk shape: the old id + the old command namespace, in the
# exact block grammar the old registrar wrote. The old id comes from
# identity.sh's read-side legacy constant, so no stale literal lives here.
# `after_analyze` is the hook this operator deliberately turned off.
_seed_old_identity_yml() {
    local disabled_hook="${1:-after_analyze}"
    local h enabled
    {
        printf 'installed:\n'
        printf -- '- %s\n' "${SPECKIT_EXT_LEGACY_ID}"
        printf 'settings:\n'
        printf '  auto_execute_hooks: true\n'
        printf 'hooks:\n'
        for h in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
            enabled=true
            [[ "$h" == "$disabled_hook" ]] && enabled=false
            printf '  %s:\n' "$h"
            printf '  - extension: %s\n' "${SPECKIT_EXT_LEGACY_ID}"
            printf '    command: speckit.%s.push\n' "${SPECKIT_EXT_LEGACY_ID}"
            printf '    enabled: %s\n' "$enabled"
            printf '    optional: false\n'
            printf '    prompt: Reconciling to Jira...\n'
            printf '    description: Reconcile after /%s so Jira stays in sync.\n' "${h#after_}"
        done
    } >"$EXT_YML"
}

# Source the real registrar + detector inside the consumer tree.
_preamble() {
    cat <<EOF
set -euo pipefail
cd '${CONSUMER}'
source '${SRC_ROOT}/src/install.sh'
source '${SRC_ROOT}/src/hookcheck.sh'
summary::add() { printf 'SUMMARY:%s:%s\n' "\$1" "\$2" >>'${OUT}'; }
install::_log() { :; }
export _HOOKCHECK_INSTALL_SOURCED=1
EOF
}

# --- 1. the old identity reads as absent -------------------------------------

@test "C-8: every old-identity hook entry classifies absent (not present, not an error)" {
    _seed_old_identity_yml
    run bash -c "$(_preamble)
        for h in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
            printf '%s=%s\n' \"\$h\" \"\$(hookcheck::classify \"\$h\")\"
        done"
    [ "$status" -eq 0 ]
    local hook
    for hook in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
        grep -qx "${hook}=absent" <<<"$output" || {
            echo "expected ${hook}=absent under the old identity:" >&2
            echo "$output" >&2
            return 1
        }
    done
}

@test "C-8: an old-identity project assesses overall=none" {
    _seed_old_identity_yml
    run bash -c "$(_preamble)
        hookcheck::assess_into
        printf 'overall=%s\n' \"\$HOOKCHECK_OVERALL\"
        printf 'missing=%s\n' \"\${HOOKCHECK_MISSING[*]}\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"overall=none"* ]]
    [[ "$output" == *"after_specify"* ]]
    [[ "$output" == *"after_analyze"* ]]
}

# --- 2. the operator is told ---------------------------------------------------

@test "C-8: the push-path warning fires with the new remediation command" {
    _seed_old_identity_yml
    run bash -c "$(_preamble)
        declare -g _RECONCILE_HOOKS_WARNED=0
        declare -g DRY_RUN=0
        export HOOKCHECK_FORCE_NONINTERACTIVE=1
        hookcheck::reconcile_check
        cat '${OUT}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUMMARY:warned:"* ]]
    [[ "$output" == *"/speckit-jira-sync-install"* ]]
}

@test "C-8: the status health line fires on the dry-run branch" {
    _seed_old_identity_yml
    run bash -c "$(_preamble)
        declare -g _RECONCILE_HOOKS_WARNED=0
        declare -g DRY_RUN=1
        export HOOKCHECK_FORCE_NONINTERACTIVE=1
        hookcheck::reconcile_check
        cat '${OUT}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUMMARY:info:"* ]]
    [[ "$output" == *"none registered"* ]]
}

@test "C-8: a non-interactive run never mutates the operator's file" {
    _seed_old_identity_yml
    local before
    before="$(cksum "$EXT_YML")"
    run bash -c "$(_preamble)
        declare -g _RECONCILE_HOOKS_WARNED=0
        declare -g DRY_RUN=0
        export HOOKCHECK_FORCE_NONINTERACTIVE=1
        hookcheck::reconcile_check"
    [ "$status" -eq 0 ]
    [ "$(cksum "$EXT_YML")" = "$before" ]
}

# --- 3. one consented step migrates -------------------------------------------

@test "C-8: a consented heal re-registers all six under the new identity" {
    _seed_old_identity_yml
    printf 'y\n' >"$ANS"
    run bash -c "$(_preamble)
        declare -g _RECONCILE_HOOKS_WARNED=0
        declare -g DRY_RUN=0
        export HOOKCHECK_FORCE_INTERACTIVE=1 HOOKCHECK_TTY=/dev/null HOOKCHECK_TTY_IN='${ANS}'
        hookcheck::reconcile_check"
    [ "$status" -eq 0 ]

    # Six entries under the NEW id, each firing the NEW push command.
    [ "$(grep -c "^  - extension: ${SPECKIT_EXT_ID}\$" "$EXT_YML")" -eq 6 ]
    [ "$(grep -c "^    command: ${SPECKIT_EXT_PUSH_COMMAND}\$" "$EXT_YML")" -eq 6 ]

    # And the detector now agrees: every hook reads present.
    run bash -c "$(_preamble)
        hookcheck::assess_into
        printf 'overall=%s\n' \"\$HOOKCHECK_OVERALL\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"overall=present"* ]]
}

@test "C-8: the heal leaves the operator's old entries in place (surfaced, never rewritten)" {
    _seed_old_identity_yml after_analyze
    printf 'y\n' >"$ANS"
    run bash -c "$(_preamble)
        declare -g _RECONCILE_HOOKS_WARNED=0
        declare -g DRY_RUN=0
        export HOOKCHECK_FORCE_INTERACTIVE=1 HOOKCHECK_TTY=/dev/null HOOKCHECK_TTY_IN='${ANS}'
        hookcheck::reconcile_check"
    [ "$status" -eq 0 ]
    # All six legacy entries survive verbatim — nothing is deleted or rewritten.
    [ "$(grep -c "^  - extension: ${SPECKIT_EXT_LEGACY_ID}\$" "$EXT_YML")" -eq 6 ]
    [ "$(grep -c "^    command: speckit[.]${SPECKIT_EXT_LEGACY_ID}[.]push\$" "$EXT_YML")" -eq 6 ]
    # Including the one the operator had turned off: still there, still false.
    [ "$(grep -c '^    enabled: false$' "$EXT_YML")" -eq 1 ]
}

# --- 4. an already-migrated disabled hook stays disabled ------------------------

@test "C-8: a new-identity enabled:false hook is disabled (not missing) and is never re-enabled" {
    # Half-migrated tree: five hooks already on the new id, after_analyze on the
    # new id but deliberately disabled by the operator.
    local h enabled
    {
        printf 'installed:\n'
        printf -- '- %s\n' "${SPECKIT_EXT_ID}"
        printf 'settings:\n'
        printf '  auto_execute_hooks: true\n'
        printf 'hooks:\n'
        for h in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
            enabled=true
            [[ "$h" == "after_analyze" ]] && enabled=false
            printf '  %s:\n' "$h"
            printf '  - extension: %s\n' "${SPECKIT_EXT_ID}"
            printf '    command: %s\n' "${SPECKIT_EXT_PUSH_COMMAND}"
            printf '    enabled: %s\n' "$enabled"
            printf '    optional: false\n'
        done
    } >"$EXT_YML"

    printf 'y\n' >"$ANS"
    run bash -c "$(_preamble)
        printf 'classify=%s\n' \"\$(hookcheck::classify after_analyze)\"
        hookcheck::assess_into
        printf 'overall=%s\n' \"\$HOOKCHECK_OVERALL\"
        printf 'disabled=%s\n' \"\${HOOKCHECK_DISABLED[*]}\"
        declare -g _RECONCILE_HOOKS_WARNED=0
        declare -g DRY_RUN=0
        export HOOKCHECK_FORCE_INTERACTIVE=1 HOOKCHECK_TTY=/dev/null HOOKCHECK_TTY_IN='${ANS}'
        hookcheck::reconcile_check"
    [ "$status" -eq 0 ]
    [[ "$output" == *"classify=disabled"* ]]
    [[ "$output" == *"overall=present"* ]]
    [[ "$output" == *"disabled=after_analyze"* ]]
    # Still exactly one entry for after_analyze, still disabled.
    [ "$(grep -c '^    enabled: false$' "$EXT_YML")" -eq 1 ]
    [ "$(grep -c "^  - extension: ${SPECKIT_EXT_ID}\$" "$EXT_YML")" -eq 6 ]
}
