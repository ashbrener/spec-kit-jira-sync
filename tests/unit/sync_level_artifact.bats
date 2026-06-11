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

# --- parent-scoped find (multi-spec phase collision guard) -------------------

@test "sync_level_artifact: parent_scoped_find=1 issues a parent-scoped JQL, not label+project" {
  # Absent under the parent → CREATE. The find MUST be scoped to the parent so a
  # phase label (unique only within a spec) can't collide across specs.
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201

  # 7th positional arg = parent_scoped_find=1; parent is PROJ-200.
  run sync_level_artifact phase "task-phase:1" "PROJ-200" "$(_task_input)" 0 0 1
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  # The find JQL carries `parent = "PROJ-200"` (url-encoded parent%20%3D%20%22…).
  printf '%s\n' "$reqs" | grep -q 'parent%20%3D%20%22PROJ-200%22' || {
    echo "parent-scoped find did not scope to the parent" >&2
    printf '%s\n' "$reqs" >&2; false; }
  # It must NOT fall back to the label+project search for this find.
  printf '%s\n' "$reqs" | grep -q 'project%20%3D%20%22PROJ%22%20ORDER' && {
    echo "parent-scoped find leaked a label+project search" >&2
    printf '%s\n' "$reqs" >&2; false; } || true
}

@test "sync_level_artifact: parent_scoped_find=0 (default) keeps the label+project find" {
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201

  run sync_level_artifact spec "speckit-spec:001" "PROJ-100" "$(_task_input)"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  # The globally-unique spec identity uses the label+project search (no parent=).
  printf '%s\n' "$reqs" | grep -q 'labels%20%3D%20%22speckit-spec%3A001%22%20AND%20project'
  printf '%s\n' "$reqs" | grep -q 'parent%20%3D%20%22' && {
    echo "default find must NOT be parent-scoped" >&2
    printf '%s\n' "$reqs" >&2; false; } || true
}

# --- a write failure surfaces the Jira error body (diagnosability) ------------

@test "mutate_issue_update: a 400 surfaces errorMessages/errors in the failure line" {
  # The transport captures the response body on a non-2xx write; the sink quotes
  # the errorMessages/errors so a field-level error (INVALID_INPUT) is visible.
  local errbody="${BATS_TEST_TMPDIR}/err400.json"
  cat > "$errbody" <<'JSON'
{"errorMessages":[],"errors":{"description":"INVALID_INPUT"}}
JSON
  jira_shim::set_response PUT "*/issue/*" "$errbody" 400

  run mutate_issue_update "PROJ-101" '{"fields":{"summary":"x"}}'
  [ "$status" -ne 0 ]
  # The failure diagnostic (stderr, captured by `run`) quotes the field error.
  printf '%s\n' "$output" | grep -q 'INVALID_INPUT' || {
    echo "failure line did not surface the Jira error body" >&2
    printf '%s\n' "$output" >&2; false; }
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

  # No create POST fired for a checklist-sentinel level. NF5-class HARD guard
  # (plain `if`, no `|| true`) so a stray create actually fails the test.
  local reqs
  reqs="$(jira_shim::requests)"
  if printf '%s\n' "$reqs" | grep -q '^URL .*rest/api/3/issue$'; then
    echo "checklist sentinel must NOT POST a create" >&2
    printf '%s\n' "$reqs" >&2
    false
  fi
}

# --- F2/F5: a fallback-rescued level POSTs the FALLBACK issue-type id ----------

@test "sync_level_artifact: an on_absent-rescued level creates the FALLBACK type (not the absent primary)" {
  # spec→Story (issue_types.story=10002) is ABSENT on a Kanban project; on_absent:
  # Task (issue_types.task=10004) IS available. validate_available must SUBSTITUTE
  # the fallback so resolve_level/the projection POST the Task id — NOT the absent
  # Story id. On the un-fixed code resolve_level still returns Story, so the POST
  # carries 10002 and this test fails.
  local conf3="${BATS_TEST_TMPDIR}/fallback.yml"
  cat > "$conf3" <<'YAML'
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
      spec:
        artifact: "Story"
        relationship_to_parent: "parent"
        on_absent: "Task"
YAML
  config::load "$conf3"
  config::validate
  mapping::parse
  mapping::validate
  # The Kanban project offers Epic/Task/Subtask, NO Story → the gate honors the
  # Story→Task fallback AND substitutes it into the resolved level.
  mapping::validate_available Epic Task Subtask

  jira_shim::reset
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201

  run sync_level_artifact spec "speckit-spec:001" "PROJ-100" "$(_task_input)"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  # The FALLBACK Task id (10004) is on the wire.
  printf '%s\n' "$reqs" | grep -q '"id":"10004"' || {
    echo "expected the fallback Task id 10004 on the create, got:" >&2
    printf '%s\n' "$reqs" >&2
    false
  }
  # The ABSENT primary Story id (10002) MUST NOT be on the create payload.
  # NF5: a HARD guard — the prior `&& { ...; false; } || true` idiom swallowed the
  # `false`, so the guard could never fail (it passed even when 10002 WAS posted).
  # A plain `if` with no `|| true` lets a leak actually fail the test.
  if printf '%s\n' "$reqs" | grep -q '"id":"10002"'; then
    echo "the absent primary Story id 10002 must NOT be POSTed" >&2
    printf '%s\n' "$reqs" >&2
    false
  fi
}

# --- link_to_parent ----------------------------------------------------------

# A current-issue read whose parent does NOT match the desired one, so the
# read-before-write parent diff (F3) still fires a PUT.
_current_other_parent() {
  local f="${BATS_TEST_TMPDIR}/cur_other_parent.json"
  jq -n '{fields:{summary:"x", description:null, labels:[], parent:{key:"PROJ-999"}}}' > "$f"
  printf '%s' "$f"
}

@test "link_to_parent: parent relationship sets the issue's parent" {
  # Read-before-write: the child currently has a DIFFERENT parent → the PUT fires.
  jira_shim::set_response GET "*/rest/api/3/issue/PROJ-300*" "$(_current_other_parent)" 200
  jira_shim::set_response PUT "*/rest/api/3/issue/*" issue_create_ok.json 204

  run link_to_parent "PROJ-300" "PROJ-200" "parent"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | grep -q '"parent"'
  printf '%s\n' "$reqs" | grep -q 'PROJ-200'
}

@test "link_to_parent: Epic-link sets the parent field too (modern Jira)" {
  jira_shim::set_response GET "*/rest/api/3/issue/PROJ-300*" "$(_current_other_parent)" 200
  jira_shim::set_response PUT "*/rest/api/3/issue/*" issue_create_ok.json 204

  run link_to_parent "PROJ-300" "PROJ-200" "Epic-link"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | grep -q 'PROJ-200'
}

# --- F3 zero-churn: an already-correctly-parented child performs 0 PUTs --------

@test "link_to_parent: an already-correctly-parented issue performs ZERO PUTs (zero churn)" {
  # The child's CURRENT parent already equals the desired one → read-before-write
  # must NO-OP (no PUT). On the un-fixed (unconditional-PUT) code this fires one
  # PUT and the assertion below fails.
  local cur="${BATS_TEST_TMPDIR}/cur_same_parent.json"
  jq -n '{fields:{summary:"x", description:null, labels:[], parent:{key:"PROJ-200"}}}' > "$cur"
  jira_shim::set_response GET "*/rest/api/3/issue/PROJ-300*" "$cur" 200
  jira_shim::set_response PUT "*/rest/api/3/issue/*" issue_create_ok.json 204

  run link_to_parent "PROJ-300" "PROJ-200" "parent"
  [ "$status" -eq 0 ]

  local reqs puts
  reqs="$(jira_shim::requests)"
  puts="$(printf '%s\n' "$reqs" | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 0 ] || {
    echo "expected ZERO PUTs on an already-correctly-parented child, got $puts" >&2
    printf '%s\n' "$reqs" >&2
    false
  }
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
