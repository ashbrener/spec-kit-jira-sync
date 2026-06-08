#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/compute_orphans.bats  (feature-004 Foundational, T005)
#
# reconcile::compute_orphans — the NEUTRAL orphan diff O = E \ D by identity
# label. The sink enumerator is overridden so this unit isolates the DIFF logic:
#   * empty E ⇒ ∅
#   * D == E ⇒ ∅ (every bridge issue is still projected — no-change)
#   * a level the current mapping no longer projects ⇒ its issue is an orphan
#   * an operator issue (no identity-prefix label) is structurally excluded
# Placeholders only (Principle IX).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL=x JIRA_EMAIL=x JIRA_API_TOKEN=x DRY_RUN=0
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  # One spec (001) with two task-phases → D = {repo, spec:001, phase:1, phase:2}
  # under the default 3-level mapping (phase is an issue).
  ITEMS='[{"id":"001-sample","title":"Sample","children":[{"id":"task-phase:1"},{"id":"task-phase:2"}]}]'
}

@test "compute_orphans: empty E yields no orphans" {
  jira_sink::enumerate_bridge_descendants() { printf '[]\n'; }
  run reconcile::compute_orphans "E-100" "myrepo" "$ITEMS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 0'
}

@test "compute_orphans: D == E performs no pruning (all kept)" {
  jira_sink::enumerate_bridge_descendants() {
    printf '%s\n' '[
      {"key":"E-100","labels":["speckit-repo:myrepo"],"parent":null,"updated":null,"status":null},
      {"key":"E-101","labels":["speckit-spec:001"],"parent":"E-100","updated":null,"status":null},
      {"key":"E-102","labels":["task-phase:1"],"parent":"E-101","updated":null,"status":null},
      {"key":"E-103","labels":["task-phase:2"],"parent":"E-101","updated":null,"status":null}
    ]'
  }
  run reconcile::compute_orphans "E-100" "myrepo" "$ITEMS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 0'
}

@test "compute_orphans: a dropped phase is the only orphan; operator + kept excluded" {
  jira_sink::enumerate_bridge_descendants() {
    printf '%s\n' '[
      {"key":"E-100","labels":["speckit-repo:myrepo"],"parent":null,"updated":null,"status":null},
      {"key":"E-101","labels":["speckit-spec:001"],"parent":"E-100","updated":null,"status":null},
      {"key":"E-102","labels":["task-phase:1"],"parent":"E-101","updated":null,"status":null},
      {"key":"E-103","labels":["task-phase:2"],"parent":"E-101","updated":null,"status":null},
      {"key":"E-104","labels":["task-phase:3"],"parent":"E-101","updated":null,"status":null},
      {"key":"E-200","labels":["backend","needs-review"],"parent":"E-101","updated":null,"status":null}
    ]'
  }
  run reconcile::compute_orphans "E-100" "myrepo" "$ITEMS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1'
  echo "$output" | jq -e '.[0].key == "E-104"'
  echo "$output" | jq -e '.[0].identity_label == "task-phase:3"'
  # The operator issue E-200 must NEVER appear (FR-002).
  echo "$output" | jq -e 'any(.[]; .key == "E-200") | not'
}

@test "compute_orphans: an unreadable enumeration fails closed (rc 3)" {
  jira_sink::enumerate_bridge_descendants() { return 3; }
  run reconcile::compute_orphans "E-100" "myrepo" "$ITEMS"
  [ "$status" -eq 3 ]
}
