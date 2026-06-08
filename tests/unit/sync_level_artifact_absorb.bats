#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/sync_level_artifact_absorb.bats  (feature-003 Foundational, T006)
#
# The 001-behavior `sync_level_artifact` absorbs (gated on the neutral input
# fields, so 002 callers are unaffected):
#   - a description-less level (repo Epic: no `body`/`tasks`) creates with NO
#     description field;
#   - a `tasks` level (phase Subtask) creates with an in-body ADF taskList;
#   - a `state` level (spec Story) transitions ONLY on a real status change
#     (zero-churn when the status already matches).
#
# Offline + deterministic over the curl-shim; placeholders only (Privacy IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL="https://example.atlassian.net" JIRA_EMAIL="o@example.com" \
         JIRA_API_TOKEN="placeholder" DRY_RUN=0 JIRA_MAX_RETRIES=0
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  mapping::validate
  jira_shim::install
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
}
teardown() { jira_shim::uninstall; }

@test "repo level (no body/tasks) creates with NO description field" {
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  run sync_level_artifact repo "speckit-repo:r" "" '{"summary":"Specs — r"}'
  [ "$status" -eq 0 ]
  local body; body="$(jira_shim::requests | sed -n 's/^BODY //p' | tail -1)"
  printf '%s' "$body" | jq -e '.fields | has("description") | not'
  printf '%s' "$body" | jq -e '.fields.summary == "Specs — r"'
}

@test "phase level (tasks) creates an in-body ADF taskList description" {
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  run sync_level_artifact phase "task-phase:1" "PROJ-1" '{"summary":"Phase 1","tasks":[{"text":"a","done":true}]}'
  [ "$status" -eq 0 ]
  local body; body="$(jira_shim::requests | sed -n 's/^BODY //p' | tail -1)"
  printf '%s' "$body" | jq -e '.fields.description.content[0].type == "taskList"'
  printf '%s' "$body" | jq -e '.fields.description.content[0].content[0].attrs.state == "DONE"'
}

@test "spec level (state) transitions exactly once on a status mismatch" {
  # Present Story whose status differs from the disk-derived (implementing→20004).
  local fx="$BATS_TEST_TMPDIR/story.json"
  jq -n '{startAt:0,maxResults:50,total:1,issues:[{id:"10101",key:"PROJ-101",
    fields:{summary:"001 — S",labels:["speckit-spec:001","phase:implementing"],
    status:{id:"99999"},updated:"2026-05-31T00:00:00.000+0000"}}]}' >"$fx"
  local get="$BATS_TEST_TMPDIR/story_get.json"
  jq -n --argjson d "$(adf::from_markdown "b")" '{id:"10101",key:"PROJ-101",fields:{
    summary:"001 — S",description:$d,labels:["speckit-spec:001","phase:implementing"],
    status:{id:"99999"},parent:{key:"PROJ-100"}}}' >"$get"
  jira_shim::set_response GET "*/search/jql*" "$fx" 200
  jira_shim::set_response GET "*/issue/PROJ-101*" "$get" 200
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204
  jira_shim::set_response PUT "*/issue/*" issue_create_ok.json 204

  local rc=0
  sync_level_artifact spec "speckit-spec:001" "PROJ-100" \
    '{"summary":"001 — S","body":"b","labels":["phase:implementing"],"state":"implementing"}' || rc=$?
  [ "$rc" -eq 0 ]
  [ "$JIRA_SINK_LEVEL_DISPOSITION" = "updated" ]
  local tposts; tposts="$(jira_shim::requests | grep -B2 '/transitions$' | grep -c '^METHOD POST$' || true)"
  [ "$tposts" -eq 1 ]
}

@test "spec level (state) fires NO transition when the status already matches" {
  local status_id; status_id="$(config::get_status_transition implementing | cut -f1)"
  local fx="$BATS_TEST_TMPDIR/story2.json"
  jq -n --arg st "$status_id" '{startAt:0,maxResults:50,total:1,issues:[{id:"10101",key:"PROJ-101",
    fields:{summary:"001 — S",labels:["speckit-spec:001","phase:implementing"],
    status:{id:$st},updated:"2026-05-31T00:00:00.000+0000"}}]}' >"$fx"
  local get="$BATS_TEST_TMPDIR/story2_get.json"
  jq -n --arg st "$status_id" --argjson d "$(adf::from_markdown "b")" \
    '{id:"10101",key:"PROJ-101",fields:{summary:"001 — S",description:$d,
    labels:["speckit-spec:001","phase:implementing"],status:{id:$st},parent:{key:"PROJ-100"}}}' >"$get"
  jira_shim::set_response GET "*/search/jql*" "$fx" 200
  jira_shim::set_response GET "*/issue/PROJ-101*" "$get" 200
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204

  local rc=0
  sync_level_artifact spec "speckit-spec:001" "PROJ-100" \
    '{"summary":"001 — S","body":"b","labels":["phase:implementing"],"state":"implementing"}' || rc=$?
  [ "$rc" -eq 0 ]
  [ "$JIRA_SINK_LEVEL_DISPOSITION" = "skipped" ]
  local tposts; tposts="$(jira_shim::requests | grep -B2 '/transitions$' | grep -c '^METHOD POST$' || true)"
  [ "$tposts" -eq 0 ]
}
