#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/reconcile_exit_codes.bats  (feature-006 Foundational, T004)
#
# The exit-code promotion ladder. Exit 4 (consumer-tree privacy leak) is the
# NEW terminal code: once set it is never demoted by a later 1 or 3, exactly
# like the pre-existing terminal 2. This locks the fail-closed-zero-writes
# semantics — a privacy leak must short-circuit the run.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL=x JIRA_EMAIL=x JIRA_API_TOKEN=x DRY_RUN=0
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"
}

@test "promote_exit 4 sets the exit to 4" {
  RECONCILE_EXIT_CODE=0
  reconcile::promote_exit 4
  [ "$RECONCILE_EXIT_CODE" -eq 4 ]
}

@test "promote_exit 1 after a 4 does NOT demote it (4 is terminal)" {
  RECONCILE_EXIT_CODE=0
  reconcile::promote_exit 4
  reconcile::promote_exit 1
  [ "$RECONCILE_EXIT_CODE" -eq 4 ]
}

@test "promote_exit 3 after a 4 does NOT demote it" {
  RECONCILE_EXIT_CODE=0
  reconcile::promote_exit 4
  reconcile::promote_exit 3
  [ "$RECONCILE_EXIT_CODE" -eq 4 ]
}

@test "promote_exit 0 after a 4 does NOT demote it" {
  RECONCILE_EXIT_CODE=0
  reconcile::promote_exit 4
  reconcile::promote_exit 0
  [ "$RECONCILE_EXIT_CODE" -eq 4 ]
}

@test "promote_exit 4 stays >= a previously-set 3" {
  RECONCILE_EXIT_CODE=0
  reconcile::promote_exit 3
  reconcile::promote_exit 4
  [ "$RECONCILE_EXIT_CODE" -eq 4 ]
}

@test "promote_exit 4 stays >= a previously-set 1" {
  RECONCILE_EXIT_CODE=0
  reconcile::promote_exit 1
  reconcile::promote_exit 4
  [ "$RECONCILE_EXIT_CODE" -eq 4 ]
}

@test "promote_exit 2 (terminal) is not overwritten by a later 4" {
  # 2 is the pre-existing terminal code (config error); it co-exists with the
  # 2-is-terminal rule and a later 4 must not clobber it.
  RECONCILE_EXIT_CODE=0
  reconcile::promote_exit 2
  reconcile::promote_exit 4
  [ "$RECONCILE_EXIT_CODE" -eq 2 ]
}
