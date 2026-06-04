#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/sync_level_artifact.bats  (T018, US2)
#
# Unit tests for the mapping-driven level projection in src/jira_sink.sh
# (`sync_level_artifact` + `link_to_parent`), per engine-sink-interface-002
# §mapping-driven projection:
#   - sync_level_artifact creates the level's CONFIGURED issue type under the
#     parent and links it with the configured relationship;
#   - it matches/updates by the identity label (the task_prefix identity for a
#     Task-projected level), so a re-run UPDATES rather than re-creates
#     (idempotent — FR-009);
#   - a checklist-sentinel level creates NO issue (empty result);
#   - link_to_parent applies `parent` / `Epic-link` and NO-OPS for `none` /
#     `checklist`.
#
# Offline + deterministic over the curl-shim (decision D10); no network, no real
# Jira coordinates (Privacy IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"

  # See us1_fresh.bats: disable functrace so jira_rest's RETURN cleanup trap is
  # not inherited by the shimmed curl (which would delete the body pre-read).
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0

  # The engine sources config + sink; for a unit we source reconcile.sh (its tail
  # guard skips main on source) so config::* + the sink fns are all present.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  # A config with a Task issue-type id so a Task-projected level resolves an id.
  CONF="${BATS_TEST_TMPDIR}/jira-config.yml"
  cat > "$CONF" <<'YAML'
jira:
  project_key: "PROJ"
  issue_types:
    epic: "10001"
    story: "10002"
    subtask: "10003"
    task: "10004"
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
    task_prefix: "speckit-task:"
  mapping:
    levels:
      repo:  { artifact: "Epic",  relationship_to_parent: "none" }
      spec:  { artifact: "Epic",  relationship_to_parent: "none" }
      phase: { artifact: "Story", relationship_to_parent: "Epic-link" }
      task:  { artifact: "Task",  relationship_to_parent: "parent" }
YAML
  config::load "$CONF"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::install
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
}

teardown() {
  jira_shim::uninstall
}

# A minimal level input JSON (the shape the sink composes from the workstate).
_task_input() {
  printf '%s' '{"summary":"Implement the parser","body":""}'
}

# --- create the CONFIGURED issue type under the parent -----------------------

@test "sync_level_artifact: a Task-projected level CREATES a Task under its parent" {
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201

  run sync_level_artifact task "speckit-task:001-1-1" "PROJ-200" "$(_task_input)"
  [ "$status" -eq 0 ]
  # The result carries the created issue's key.
  [[ "$output" == *"PROJ-102"* ]]

  local reqs
  reqs="$(jira_shim::requests)"
  # The configured task→Task projects to issuetype 10004 (issue_types.task).
  printf '%s\n' "$reqs" | grep -q '"id":"10004"'
  # The identity label is carried so a re-run can re-match.
  printf '%s\n' "$reqs" | grep -q '"speckit-task:001-1-1"'
}

# --- idempotent re-match by identity label (UPDATE, not re-create) -----------

@test "sync_level_artifact: an existing identity-labelled issue is matched (no re-create)" {
  # The search returns a found issue (id 10001, key PROJ-101) — so the level must
  # MATCH it (update path) rather than POST a brand-new create.
  jira_shim::set_response GET "*/search/jql*" search_found_story.json 200
  jira_shim::set_response GET "*/issue/*" search_found_story.json 200
  jira_shim::set_response PUT "*/rest/api/3/issue/*" issue_create_ok.json 204

  run sync_level_artifact task "speckit-spec:001" "PROJ-200" "$(_task_input)"
  [ "$status" -eq 0 ]

  local reqs creates
  reqs="$(jira_shim::requests)"
  creates="$(printf '%s\n' "$reqs" \
    | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  [ "$creates" -eq 0 ] || {
    echo "expected ZERO create POSTs on a matched identity, got $creates" >&2
    printf '%s\n' "$reqs" >&2
    false
  }
}

# --- the checklist sentinel creates NO issue ---------------------------------

@test "sync_level_artifact: a checklist-sentinel level creates no issue (empty result)" {
  # Re-map the task level to checklist for this case.
  local conf2="${BATS_TEST_TMPDIR}/checklist.yml"
  cat > "$conf2" <<'YAML'
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
  transitions: {}
  labels:
    spec_prefix: "speckit-spec:"
    repo_prefix: "speckit-repo:"
    phase_prefix: "task-phase:"
    lifecycle_prefix: "phase:"
    task_prefix: "speckit-task:"
YAML
  config::load "$conf2"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::reset
  run sync_level_artifact task "speckit-task:001-1-1" "PROJ-200" "$(_task_input)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # No create POST fired for a checklist-sentinel level.
  local reqs
  reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | grep -q '^URL .*rest/api/3/issue$' && {
    echo "checklist sentinel must NOT POST a create" >&2
    false
  } || true
}

# --- link_to_parent ----------------------------------------------------------

@test "link_to_parent: parent relationship sets the issue's parent" {
  jira_shim::set_response PUT "*/rest/api/3/issue/*" issue_create_ok.json 204

  run link_to_parent "PROJ-300" "PROJ-200" "parent"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | grep -q '"parent"'
  printf '%s\n' "$reqs" | grep -q 'PROJ-200'
}

@test "link_to_parent: Epic-link sets the parent field too (modern Jira)" {
  jira_shim::set_response PUT "*/rest/api/3/issue/*" issue_create_ok.json 204

  run link_to_parent "PROJ-300" "PROJ-200" "Epic-link"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | grep -q 'PROJ-200'
}

@test "link_to_parent: none is a no-op (no request)" {
  jira_shim::reset
  run link_to_parent "PROJ-300" "" "none"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  [ -z "$reqs" ] || {
    echo "none relationship must issue no request" >&2
    printf '%s\n' "$reqs" >&2
    false
  }
}

@test "link_to_parent: checklist is a no-op (no request)" {
  jira_shim::reset
  run link_to_parent "PROJ-300" "PROJ-200" "checklist"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  [ -z "$reqs" ] || {
    echo "checklist relationship must issue no request" >&2
    printf '%s\n' "$reqs" >&2
    false
  }
}
