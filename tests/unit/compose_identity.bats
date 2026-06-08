#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/compose_identity.bats  (feature-003 US-Foundational, T003)
#
# Unit tests for reconcile::compose_identity — the NEUTRAL identity-label
# composer for the level loop. It reproduces the identity labels the 001
# orchestrators matched on, built from config label prefixes only (no Jira
# tokens). Placeholders only (Principle IX).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL=x JIRA_EMAIL=x JIRA_API_TOKEN=x DRY_RUN=0
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  ITEM='{"id":"001-sample","title":"Sample","state":"implementing","body":"b","children":[{"id":"task-phase:1"},{"id":"task-phase:2"}]}'
}

@test "compose_identity repo → repo_prefix + slug" {
  run reconcile::compose_identity repo "$ITEM" "myrepo"
  [ "$output" = "speckit-repo:myrepo" ]
}

@test "compose_identity spec → spec_prefix + feature number" {
  run reconcile::compose_identity spec "$ITEM" "myrepo"
  [ "$output" = "speckit-spec:001" ]
}

@test "compose_identity phase → phase_prefix + phase index" {
  run reconcile::compose_identity phase "$ITEM" "myrepo" 2
  [ "$output" = "task-phase:2" ]
}

@test "compose_identity task (checklist sentinel) → empty" {
  run reconcile::compose_identity task "$ITEM" "myrepo"
  [ -z "$output" ]
}
