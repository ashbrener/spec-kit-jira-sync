#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/initiative_probe.bats  (feature-002 US6, T042)
#
# Unit tests for the Initiative super-level probe + create (src/jira_sink.sh),
# per engine-sink-interface-002 §Initiative (Q5, FR-013/FR-014):
#   - initiative::probe_available returns present/absent from the issue-type
#     metadata probe; an unreadable probe fails closed (rc 3).
#   - ensure_initiative creates the Initiative (issue_types.initiative, the repo
#     identity label, the narrative as its body) when absent, and matches the
#     existing one on a re-run (idempotent — no duplicate Initiative).
#
# Offline + deterministic over the curl-shim; no real coordinates (Principle IX).
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

  CONF="$BATS_TEST_TMPDIR/jira-config.yml"
  cat > "$CONF" <<'YAML'
jira:
  project_key: "PROJ"
  issue_types:
    epic: "10001"
    story: "10002"
    subtask: "10003"
    initiative: "10005"
  phase_status:
    specifying: "20001"
    planning: "20002"
    tasking: "20003"
    implementing: "20004"
    ready_to_merge: "20005"
    merged: "20006"
  transitions: {}
  labels:
    spec_prefix: "speckit-spec:"
    repo_prefix: "speckit-repo:"
    phase_prefix: "task-phase:"
    lifecycle_prefix: "phase:"
  mapping:
    initiative:
      enabled: true
YAML
  config::load "$CONF"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::install
}

teardown() {
  jira_shim::uninstall
}

# --- probe_available ---------------------------------------------------------

@test "probe_available: present when the project lists the Initiative type" {
  local fx="$BATS_TEST_TMPDIR/proj_with_init.json"
  jq -n '{key:"PROJ",issueTypes:[{name:"Epic"},{name:"Story"},{name:"Initiative"}]}' >"$fx"
  jira_shim::set_response GET "*/project/PROJ*" "$fx" 200

  run initiative::probe_available
  [ "$status" -eq 0 ]
  [ "$output" = "present" ]
}

@test "probe_available: absent when the project lacks the Initiative type" {
  local fx="$BATS_TEST_TMPDIR/proj_no_init.json"
  jq -n '{key:"PROJ",issueTypes:[{name:"Epic"},{name:"Story"},{name:"Subtask"}]}' >"$fx"
  jira_shim::set_response GET "*/project/PROJ*" "$fx" 200

  run initiative::probe_available
  [ "$status" -eq 0 ]
  [ "$output" = "absent" ]
}

@test "probe_available: an unreadable probe fails closed (rc 3)" {
  jira_shim::set_response GET "*/project/PROJ*" error_401.json 401
  run initiative::probe_available
  [ "$status" -eq 3 ]
}

# --- ensure_initiative -------------------------------------------------------

@test "ensure_initiative: creates the Initiative when absent (type + label + body)" {
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201

  run ensure_initiative "A narrative from the spec Input line." "repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROJ-"* ]]

  local reqs
  reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | grep -q '"id":"10005"'        # issue_types.initiative
  printf '%s\n' "$reqs" | grep -q '"speckit-repo:repo"' # repo identity label
  printf '%s\n' "$reqs" | grep -q 'A narrative from the spec Input line.'
}

@test "ensure_initiative: matches the existing Initiative on a re-run (no duplicate)" {
  # The search returns an existing Initiative; ensure_initiative must NOT create.
  local desc
  desc="$(adf::from_markdown "A narrative from the spec Input line.")"
  local found="$BATS_TEST_TMPDIR/init_found.json"
  jq -n --arg k "PROJ-500" \
    '{startAt:0,maxResults:50,total:1,issues:[{id:"105",key:$k,fields:{
       summary:"repo — Initiative",labels:["speckit-repo:repo"],
       status:{id:"10000"},updated:"2026-05-31T00:00:00.000+0000"}}]}' >"$found"
  local get="$BATS_TEST_TMPDIR/init_get.json"
  jq -n --argjson d "$desc" \
    '{key:"PROJ-500",fields:{summary:"repo — Initiative",description:$d,
       labels:["speckit-repo:repo"]}}' >"$get"
  jira_shim::set_response GET "*/search/jql*" "$found" 200
  jira_shim::set_response GET "*/issue/PROJ-500*" "$get" 200
  jira_shim::set_response PUT "*/issue/*" issue_create_ok.json 204

  run ensure_initiative "A narrative from the spec Input line." "repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROJ-500"* ]]

  local creates
  creates="$(jira_shim::requests | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  [ "$creates" -eq 0 ] || { echo "expected 0 creates (matched existing), got $creates" >&2; jira_shim::requests >&2; false; }
}
