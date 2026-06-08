#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/remode_args.bats  (feature-004 Foundational, T007)
#
# --remode parsing: the explicit, opt-in destructive flag. Absent ⇒ ARG_REMODE=0
# (the ordinary non-destructive reconcile). Composes with --dry-run (preview),
# --spec/--all (scope), and --on-drift. Placeholders only (Principle IX).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL=x JIRA_EMAIL=x JIRA_API_TOKEN=x DRY_RUN=0
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"
}

@test "parse_args: --remode sets ARG_REMODE=1" {
  reconcile::parse_args --remode
  [ "$ARG_REMODE" -eq 1 ]
}

@test "parse_args: no --remode leaves ARG_REMODE=0 (ordinary reconcile)" {
  reconcile::parse_args --all
  [ "$ARG_REMODE" -eq 0 ]
}

@test "parse_args: --remode --dry-run sets both (preview)" {
  reconcile::parse_args --remode --dry-run
  [ "$ARG_REMODE" -eq 1 ]
  [ "$ARG_DRY_RUN" -eq 1 ]
}

@test "parse_args: --remode composes with --spec" {
  reconcile::parse_args --remode --spec 003
  [ "$ARG_REMODE" -eq 1 ]
  [ "$ARG_SPEC" = "003" ]
}

@test "parse_args: --remode composes with --on-drift=abort" {
  reconcile::parse_args --remode --on-drift=abort
  [ "$ARG_REMODE" -eq 1 ]
  [ "$ARG_ON_DRIFT" = "abort" ]
}
