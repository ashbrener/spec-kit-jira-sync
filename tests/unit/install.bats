#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/install.bats  (feature 008 — Phase 2 + US1 unit, T009/T011/T014)
#
# Unit tests for the install ceremony's foundational pieces:
#   - install::guard_source_target — FR-007/C-7: halt (non-zero, exit-2 intent)
#     when run from the bridge's own checkout; succeed for a distinct consumer.
#   - install::dependency_report   — FR-004/FR-005: ✓/⚠/✗ rows + remediation;
#     missing JIRA_* ⇒ exit-2 intent; shimmed myself 401/403 ⇒ exit-3 intent;
#     no config written in any failing case.
#   - install::resolve             — FR-001/FR-002/C-2: capture issue-type ids,
#     a default phase→status map by statusCategory, and a story-points field id,
#     all as ids, into in-memory resolution state.
#
# Offline + deterministic over the curl-shim; placeholder-only (Privacy IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export JIRA_MAX_RETRIES=0
  export DRY_RUN=0

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/install.sh"

  jira_shim::install
}

teardown() {
  jira_shim::uninstall
}

# A statuses fixture: To Do (new) / In Progress (indeterminate) / Done (done).
_statuses_fixture() {
  local f="$1"
  jq -n '[
    { "id":"10000","name":"Story","statuses":[
        {"id":"31001","name":"To Do","statusCategory":{"key":"new"}},
        {"id":"31002","name":"In Progress","statusCategory":{"key":"indeterminate"}},
        {"id":"31003","name":"Done","statusCategory":{"key":"done"}}
    ]}
  ]' >"$f"
}

_project_fixture() {
  local f="$1"
  jq -n '{key:"PROJ",issueTypes:[
    {name:"Epic",id:"12001"},
    {name:"Story",id:"12002"},
    {name:"Subtask",id:"12003"}
  ]}' >"$f"
}

_field_with_sp_fixture() {
  local f="$1"
  jq -n '[
    {id:"customfield_10016",name:"Story Points",schema:{custom:"com.atlassian.jira.plugin.system.customfieldtypes:float"}},
    {id:"summary",name:"Summary"}
  ]' >"$f"
}

# --- T009: guard_source_target ----------------------------------------------

@test "T009 guard_source_target: target == bridge checkout ⇒ non-zero" {
  # Run with the target repo root set to the bridge's OWN checkout.
  run install::guard_source_target "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "T009 guard_source_target: distinct target root ⇒ 0" {
  local consumer="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$consumer/specs"
  run install::guard_source_target "$consumer"
  [ "$status" -eq 0 ]
}

# --- T011: dependency_report -------------------------------------------------

@test "T011a dependency_report: all present ⇒ rc 0, no error rows" {
  local proj="$BATS_TEST_TMPDIR/proj.json"
  _project_fixture "$proj"
  jira_shim::set_response GET "*/myself*" "myself_ok.json" 200
  jira_shim::set_response GET "*/project/PROJ*" "$proj" 200

  run install::dependency_report "PROJ"
  [ "$status" -eq 0 ]
}

@test "T011b dependency_report: missing JIRA_* ⇒ exit-2 intent, names the var" {
  unset JIRA_API_TOKEN
  run install::dependency_report "PROJ"
  [ "$status" -eq 2 ]
  [[ "$output" == *"JIRA_API_TOKEN"* ]]
}

@test "T011c dependency_report: myself 401 ⇒ exit-3 intent (Jira unreadable)" {
  jira_shim::set_response GET "*/myself*" "error_401.json" 401
  run install::dependency_report "PROJ"
  [ "$status" -eq 3 ]
}

# --- T014: resolve (US1) -----------------------------------------------------

@test "T014 resolve: captures issue-type ids + phase→status map + sp field as ids (C-2)" {
  local proj="$BATS_TEST_TMPDIR/proj.json" stat="$BATS_TEST_TMPDIR/stat.json" fld="$BATS_TEST_TMPDIR/fld.json"
  _project_fixture "$proj"
  _statuses_fixture "$stat"
  _field_with_sp_fixture "$fld"
  jira_shim::set_response GET "*/project/PROJ/statuses*" "$stat" 200
  jira_shim::set_response GET "*/project/PROJ*" "$proj" 200
  jira_shim::set_response GET "*/field*" "$fld" 200

  INSTALL_RESOLVED=()
  run install::resolve "PROJ"
  [ "$status" -eq 0 ]

  # In a `run` subshell INSTALL_RESOLVED is not visible to the parent; re-run
  # in-process to inspect the populated state.
  INSTALL_RESOLVED=()
  install::resolve "PROJ"
  [ "${INSTALL_RESOLVED[project_key]}" = "PROJ" ]
  [ "${INSTALL_RESOLVED[issue_types.epic]}" = "12001" ]
  [ "${INSTALL_RESOLVED[issue_types.story]}" = "12002" ]
  [ "${INSTALL_RESOLVED[issue_types.subtask]}" = "12003" ]
  # new → specifying/planning ; indeterminate → tasking/implementing ; done → ready_to_merge/merged
  [ "${INSTALL_RESOLVED[phase_status.specifying]}" = "31001" ]
  [ "${INSTALL_RESOLVED[phase_status.planning]}" = "31001" ]
  [ "${INSTALL_RESOLVED[phase_status.tasking]}" = "31002" ]
  [ "${INSTALL_RESOLVED[phase_status.implementing]}" = "31002" ]
  [ "${INSTALL_RESOLVED[phase_status.ready_to_merge]}" = "31003" ]
  [ "${INSTALL_RESOLVED[phase_status.merged]}" = "31003" ]
  [ "${INSTALL_RESOLVED[story_points_field_id]}" = "customfield_10016" ]
}
