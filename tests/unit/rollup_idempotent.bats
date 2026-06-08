#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/rollup_idempotent.bats  (feature-002 US4, T033)
#
# Unit tests for rollup::transition_if_changed (src/jira_sink.sh) — the rollup
# transition is fired ONLY when the computed completion differs from the prior
# (forward AND backward); an unchanged completion fires NO transition (Q11,
# FR-012). Reuses the 001 transition_issue / config::get_status_transition
# levers (no new status surface).
#
# Offline + deterministic over the curl-shim; no real Jira coordinates (IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::install
  # A transitions list that reaches BOTH the done (merged→20006) and the active
  # (implementing→20004) statuses, so the dynamic resolve in transition_issue
  # finds a transition for either rollup direction.
  TR="$BATS_TEST_TMPDIR/transitions.json"
  jq -n '{transitions:[
    {id:"31",name:"Done",to:{id:"20006",name:"Done"}},
    {id:"21",name:"Active",to:{id:"20004",name:"In Progress"}}
  ]}' > "$TR"
  jira_shim::set_response GET "*/issue/*/transitions" "$TR" 200
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204
}

teardown() {
  jira_shim::uninstall
}

_transition_posts() {
  jira_shim::requests | grep -B2 '/transitions$' | grep -c '^METHOD POST$' || true
}

@test "transition_if_changed: unchanged completion fires NO transition (noop)" {
  run rollup::transition_if_changed "PROJ-1" complete complete
  [ "$status" -eq 0 ]
  [ "$output" = "noop" ]
  [ "$(_transition_posts)" -eq 0 ]
}

@test "transition_if_changed: forward partial→complete transitions to done" {
  local out rc=0
  out="$(rollup::transition_if_changed "PROJ-1" complete partial)" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$out" = "transitioned" ]
  [ "$(_transition_posts)" -eq 1 ]
  # The POST used the transition reaching the done status (id 31 → 20006).
  jira_shim::requests | grep -q '"id":"31"'
}

@test "transition_if_changed: backward complete→partial transitions to active" {
  local out rc=0
  out="$(rollup::transition_if_changed "PROJ-1" partial complete)" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$out" = "transitioned" ]
  [ "$(_transition_posts)" -eq 1 ]
  # implementing is pinned in the sample config (transitions.implementing=30004),
  # so the active-direction POST uses that EXPLICIT transition id (not a dynamic
  # resolve) — proving the backward target is the active status.
  jira_shim::requests | grep -q '"id":"30004"'
}

@test "transition_if_changed: a transport failure on the POST returns rc 1" {
  # Re-register so the 401 wins (first-match-wins; setup already set a 204 rule).
  jira_shim::reset
  jira_shim::set_response GET "*/issue/*/transitions" "$TR" 200
  jira_shim::set_response POST "*/issue/*/transitions" error_401.json 401
  run rollup::transition_if_changed "PROJ-1" complete partial
  [ "$status" -eq 1 ]
}
