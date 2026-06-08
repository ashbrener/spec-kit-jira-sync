#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/compose_payload.bats  (feature-003 US-Foundational, T002)
#
# Unit tests for reconcile::compose_payload — the NEUTRAL per-level payload the
# generic projection consumes. It reproduces exactly what the 001 orchestrators
# emitted (repo Epic summary, spec Story summary/labels/state, phase tasks),
# referencing only workstate fields + config label prefixes (no Jira issue-type
# id / artifact name / relationship term, FR-006). Placeholders only.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL=x JIRA_EMAIL=x JIRA_API_TOKEN=x DRY_RUN=0
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  ITEM='{"id":"001-sample","title":"Sample Spec","state":"implementing","body":"The body.","labels":["extra:x"],"children":[{"id":"task-phase:1","title":"Phase 1 — Setup","extensions":{"tasks":[{"text":"a","done":true},{"text":"b","done":false}]}}]}'
}

@test "compose_payload repo → 'Specs — <slug>' summary, no description field" {
  run reconcile::compose_payload repo "$ITEM" "myrepo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.summary == "Specs — myrepo"'
  echo "$output" | jq -e 'has("body") | not'   # repo Epic carries no description (matches ensure_repo_epic)
}

@test "compose_payload spec → summary 'NNN — title', state, and labels excl. identity" {
  run reconcile::compose_payload spec "$ITEM" "myrepo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.summary == "001 — Sample Spec"'
  echo "$output" | jq -e '.body == "The body."'
  echo "$output" | jq -e '.state == "implementing"'
  # labels = [phase:<state>] + item.labels (the identity spec_label is added by the sink)
  echo "$output" | jq -e '.labels == ["extra:x","phase:implementing"] or .labels == ["phase:implementing","extra:x"]'
  echo "$output" | jq -e '(.labels | index("speckit-spec:001")) == null'
}

@test "compose_payload phase → child title + neutral tasks array" {
  run reconcile::compose_payload phase "$ITEM" "myrepo" 1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.summary == "Phase 1 — Setup"'
  echo "$output" | jq -e '.tasks == [{"text":"a","done":true},{"text":"b","done":false}]'
  echo "$output" | jq -e '(.labels | length) == 0'
}

@test "compose_payload is vendor-neutral (no Jira artifact/type/relationship tokens)" {
  # The composed payloads must never name a Jira issue type or relationship.
  local all
  all="$(reconcile::compose_payload repo "$ITEM" myrepo; reconcile::compose_payload spec "$ITEM" myrepo; reconcile::compose_payload phase "$ITEM" myrepo 1)"
  ! printf '%s' "$all" | grep -qE 'Epic|Story|Subtask|Epic-link|issuetype'
}
