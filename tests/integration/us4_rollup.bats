#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us4_rollup.bats  (T037, US4)
#
# End-to-end (curl-shim) proof of the off-by-default status rollup wired into
# reconcile.sh (Q11, FR-011/FR-012, spec scenarios 1–4):
#
#   * REPO rollup (post-loop): every spec merged ⇒ the repo Epic transitions to
#     done; a re-run on unchanged completion fires no transition; a regressed
#     completion (was done, now partial) transitions the Epic back to active.
#   * PHASE rollup (per-spec): a fully-checked phase ⇒ its Subtask transitions
#     to done; an already-done Subtask fires no transition.
#   * OFF (the default): rollup makes ZERO transition calls — only the
#     spec-level status is ever set (today's behavior).
#
# The rollup target statuses reuse the 001 lifecycle map (merged→done id 20006,
# implementing→active id 20004 — the latter pinned to transition 30004 in the
# sample config). Offline + deterministic; no real coordinates (Principle IX).
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

  # A rollup-ON config (otherwise the sample's default: rollup off).
  CONF="$BATS_TEST_TMPDIR/jira-config.yml"
  cat > "$CONF" <<'YAML'
jira:
  project_key: "PROJ"
  issue_types:
    epic: "10001"
    story: "10002"
    subtask: "10003"
  phase_status:
    specifying: "20001"
    planning: "20002"
    tasking: "20003"
    implementing: "20004"
    ready_to_merge: "20005"
    merged: "20006"
  transitions:
    implementing: "30004"
  labels:
    spec_prefix: "speckit-spec:"
    repo_prefix: "speckit-repo:"
    phase_prefix: "task-phase:"
    lifecycle_prefix: "phase:"
  mapping:
    status_rollup:
      enabled: true
YAML
  config::load "$CONF"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::install

  # Transitions list reaching BOTH the done (20006) and active (20004) statuses.
  TR="$BATS_TEST_TMPDIR/transitions.json"
  jq -n '{transitions:[
    {id:"31",name:"Done",to:{id:"20006",name:"Done"}},
    {id:"21",name:"Active",to:{id:"20004",name:"In Progress"}}
  ]}' > "$TR"
  jira_shim::set_response GET "*/issue/*/transitions" "$TR" 200
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204

  US4="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$US4"
}

teardown() {
  jira_shim::uninstall
}

# Write an Epic search fixture (so ensure_repo_epic reuses PROJ-100) and an Epic
# GET fixture carrying <status_id> (so the rollup derives `prior`).
us4::register_epic() {
  local status_id="$1"
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{
         summary:"Specs — repo",labels:["speckit-repo:repo"],
         status:{id:"10000",name:"To Do"},updated:"2026-05-31T00:00:00.000+0000"
       }}]}' >"$US4/epic_search.json"
  jq -n --arg s "$status_id" \
    '{key:"PROJ-100",fields:{summary:"Specs — repo",labels:["speckit-repo:repo"],
       status:{id:$s,name:"X"},parent:null}}' >"$US4/epic_get.json"
  jira_shim::set_response GET "*speckit-repo%3A*" "$US4/epic_search.json" 200
  jira_shim::set_response GET "*/issue/PROJ-100*" "$US4/epic_get.json" 200
}

_transition_posts() {
  jira_shim::requests | grep -B2 '/transitions$' | grep -c '^METHOD POST$' || true
}

# --- REPO rollup: forward (all specs merged ⇒ Epic to done) ------------------

@test "repo rollup: every spec merged transitions the Epic to done (scenario 2)" {
  _RECONCILE_REPO_SLUG="repo"
  _RECONCILE_LIFECYCLE_ROWS=$'merged\t0'
  us4::register_epic "10000"   # Epic currently NOT done → prior=partial

  local rc=0
  reconcile::rollup_repo_epic || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(_transition_posts)" -eq 1 ]
  # The transition reaching the done status (id 31 → 20006).
  jira_shim::requests | grep -q '"id":"31"'
}

@test "repo rollup: a re-run on unchanged completion fires NO transition (scenario 3)" {
  _RECONCILE_REPO_SLUG="repo"
  _RECONCILE_LIFECYCLE_ROWS=$'merged\t0'
  us4::register_epic "20006"   # Epic already at the done status → prior=complete

  reconcile::rollup_repo_epic
  [ "$(_transition_posts)" -eq 0 ]
}

@test "repo rollup: a regressed completion transitions the Epic back to active" {
  _RECONCILE_REPO_SLUG="repo"
  _RECONCILE_LIFECYCLE_ROWS=$'implementing\t0'   # not all merged → computed=partial
  us4::register_epic "20006"   # Epic was done → prior=complete; partial≠complete

  local rc=0
  reconcile::rollup_repo_epic || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(_transition_posts)" -eq 1 ]
  # Active direction uses the pinned implementing transition id (30004).
  jira_shim::requests | grep -q '"id":"30004"'
}

# --- PHASE rollup: a fully-checked phase ⇒ Subtask to done -------------------

@test "phase rollup: a fully-checked phase transitions its Subtask to done (scenario 1)" {
  local item
  item="$(jq -n '{id:"001-x",children:[
    {id:"task-phase:1",extensions:{tasks:[{text:"a",done:true},{text:"b",done:true}]}}
  ]}')"
  jq -n '{key:"SUB-1",fields:{summary:"Phase 1",labels:["task-phase:1"],
     status:{id:"10000",name:"To Do"}}}' >"$US4/sub1_get.json"
  jira_shim::set_response GET "*/issue/SUB-1*" "$US4/sub1_get.json" 200

  reconcile::rollup_phases "$item" '{"1":"SUB-1"}' "001"
  [ "$(_transition_posts)" -eq 1 ]
  jira_shim::requests | grep -q '"id":"31"'
}

@test "phase rollup: an already-done Subtask with a complete phase fires NO transition" {
  local item
  item="$(jq -n '{id:"001-x",children:[
    {id:"task-phase:1",extensions:{tasks:[{text:"a",done:true}]}}
  ]}')"
  jq -n '{key:"SUB-1",fields:{summary:"Phase 1",labels:["task-phase:1"],
     status:{id:"20006",name:"Done"}}}' >"$US4/sub1_get.json"
  jira_shim::set_response GET "*/issue/SUB-1*" "$US4/sub1_get.json" 200

  reconcile::rollup_phases "$item" '{"1":"SUB-1"}' "001"
  [ "$(_transition_posts)" -eq 0 ]
}

@test "phase rollup: a partial phase does not transition a not-done Subtask" {
  local item
  item="$(jq -n '{id:"001-x",children:[
    {id:"task-phase:1",extensions:{tasks:[{text:"a",done:true},{text:"b",done:false}]}}
  ]}')"
  jq -n '{key:"SUB-1",fields:{summary:"Phase 1",labels:["task-phase:1"],
     status:{id:"10000",name:"To Do"}}}' >"$US4/sub1_get.json"
  jira_shim::set_response GET "*/issue/SUB-1*" "$US4/sub1_get.json" 200

  reconcile::rollup_phases "$item" '{"1":"SUB-1"}' "001"
  [ "$(_transition_posts)" -eq 0 ]   # computed=partial, prior=partial → noop
}

# --- OFF (default): rollup makes ZERO transition calls -----------------------

@test "rollup OFF (default): repo rollup is a no-op with zero requests (scenario 4)" {
  # Reload the plain sample config (no status_rollup block → off by default).
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  mapping::validate
  run reconcile::_rollup_enabled
  [ "$status" -ne 0 ]   # gate is OFF

  jira_shim::reset
  _RECONCILE_REPO_SLUG="repo"
  _RECONCILE_LIFECYCLE_ROWS=$'merged\t0'
  reconcile::rollup_repo_epic
  # No reads, no transitions — the rollup short-circuits before any request.
  [ -z "$(jira_shim::requests)" ]
}
