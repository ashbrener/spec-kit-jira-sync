#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/bridge_owned_predicate.bats  (feature-004 Foundational, T004)
#
# jira_sink::is_bridge_owned — the SOLE ownership test (FR-002/FR-015). True iff
# a label begins with a configured IDENTITY prefix (repo/spec/phase/task). The
# lifecycle prefix (phase:*) is a status label, NOT an identity, and must NOT
# qualify. An operator issue (no identity label) must read false. Placeholders
# only (Principle IX).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL=x JIRA_EMAIL=x JIRA_API_TOKEN=x DRY_RUN=0
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
}

@test "is_bridge_owned: a repo identity label is bridge-owned" {
  run jira_sink::is_bridge_owned '["speckit-repo:myrepo"]'
  [ "$status" -eq 0 ]
}

@test "is_bridge_owned: a spec identity label is bridge-owned" {
  run jira_sink::is_bridge_owned '["speckit-spec:001"]'
  [ "$status" -eq 0 ]
}

@test "is_bridge_owned: a phase identity label is bridge-owned" {
  run jira_sink::is_bridge_owned '["task-phase:2"]'
  [ "$status" -eq 0 ]
}

@test "is_bridge_owned: a task identity label is bridge-owned" {
  run jira_sink::is_bridge_owned '["speckit-task:1.3"]'
  [ "$status" -eq 0 ]
}

@test "is_bridge_owned: ONLY a lifecycle (phase:*) label does NOT qualify" {
  run jira_sink::is_bridge_owned '["phase:implementing"]'
  [ "$status" -eq 1 ]
}

@test "is_bridge_owned: an empty label set is not bridge-owned" {
  run jira_sink::is_bridge_owned '[]'
  [ "$status" -eq 1 ]
}

@test "is_bridge_owned: an operator label (no identity prefix) is not bridge-owned" {
  run jira_sink::is_bridge_owned '["backend","needs-review"]'
  [ "$status" -eq 1 ]
}

@test "is_bridge_owned: a mix of operator + one identity label IS bridge-owned" {
  run jira_sink::is_bridge_owned '["backend","speckit-spec:007","phase:planning"]'
  [ "$status" -eq 0 ]
}

@test "is_bridge_owned: a stale prior-shape identity family (prefix match) still qualifies" {
  # An old speckit-task:* value the current mapping no longer mints is still
  # recognized as bridge-owned (prefix, not exact) so it can be pruned.
  run jira_sink::is_bridge_owned '["speckit-task:9.9"]'
  [ "$status" -eq 0 ]
}
