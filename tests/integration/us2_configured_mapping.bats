#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us2_configured_mapping.bats  (T024, US2)
#
# Phase 4 / US2 core-value gate: a NON-default per-level mapping
# (spec→Epic / phase→Story / task→Task) mirrors the CONFIGURED issue types with
# the CONFIGURED parent relationships (spec scenario 1), end-to-end over the
# mocked Jira REST (curl-shim). Then a RE-RUN against the unchanged corpus
# asserts ZERO churn (0 created / 0 updated) — the 3-level arm of SC-004 (analyze
# Next-Action #3).
#
# The configured projection is driven through the mapping-driven sink contract
# (sync_level_artifact + link_to_parent, engine-sink-interface-002): the level's
# CONFIGURED artifact id is created under its parent via the configured
# relationship, and re-matched by the identity label so a re-run UPDATES nothing.
#
# Offline + deterministic; no network, no real Jira coordinates (Privacy IX).
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

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  # A 3-level configured mapping: spec→Epic, phase→Story (Epic-link under the
  # spec Epic), task→Task (parent under the phase Story).
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
  # The Scrum project offers every configured type → the available-type gate
  # passes (the same gate the engine runs at config-load, T023).
  mapping::validate_available Epic Story Task Subtask

  jira_shim::install
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
}

teardown() {
  jira_shim::uninstall
}

_input() {
  printf '%s' '{"summary":"'"$1"'","body":""}'
}

@test "configured mapping projects each level to its CONFIGURED issue type" {
  # READS absent → CREATE; writes succeed.
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201

  # spec→Epic (issue_types.epic = 10001).
  run sync_level_artifact spec "speckit-spec:001" "PROJ-100" "$(_input "001 — Sample")"
  [ "$status" -eq 0 ]
  # phase→Story (issue_types.story = 10002), Epic-link under the spec Epic.
  run sync_level_artifact phase "task-phase:1" "PROJ-101" "$(_input "Phase 1")"
  [ "$status" -eq 0 ]
  # task→Task (issue_types.task = 10004), parent under the phase Story.
  run sync_level_artifact task "speckit-task:001-1-1" "PROJ-102" "$(_input "Task 1")"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  # The configured types appear (spec→Epic 10001, phase→Story 10002, task→Task 10004).
  printf '%s\n' "$reqs" | grep -q '"id":"10001"'
  printf '%s\n' "$reqs" | grep -q '"id":"10002"'
  printf '%s\n' "$reqs" | grep -q '"id":"10004"'
  # The configured identity labels are carried for idempotent re-match.
  printf '%s\n' "$reqs" | grep -q '"speckit-spec:001"'
  printf '%s\n' "$reqs" | grep -q '"task-phase:1"'
  printf '%s\n' "$reqs" | grep -q '"speckit-task:001-1-1"'
}

@test "configured mapping links each level via its CONFIGURED relationship" {
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  jira_shim::set_response PUT "*/rest/api/3/issue/*" issue_create_ok.json 204

  # phase→Story is Epic-link under the spec Epic; the create carries the parent,
  # and an explicit link_to_parent reaffirms it.
  sync_level_artifact phase "task-phase:1" "PROJ-101" "$(_input "Phase 1")" >/dev/null
  run link_to_parent "PROJ-102" "PROJ-101" "Epic-link"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  # The phase Story is parented to the spec Epic (PROJ-101).
  printf '%s\n' "$reqs" | grep -q '"parent"'
  printf '%s\n' "$reqs" | grep -q 'PROJ-101'
}

@test "RE-RUN against the unchanged corpus is ZERO churn (0 created / 0 updated)" {
  # The project already holds an identity-matched issue whose fields equal the
  # desired — so a re-run must CREATE nothing and UPDATE nothing.
  jira_shim::set_response GET "*/search/jql*" search_found_story.json 200

  # Build the already-mirrored issue body the sink composes for an empty body, so
  # the desired-vs-current diff is a true zero. The fixture's current summary is
  # "001 — Sample spec"; match it so summary diffs to nothing too.
  local current="${BATS_TEST_TMPDIR}/current.json"
  local desired_desc
  desired_desc="$(adf::from_markdown "")"
  jq -n \
    --argjson desc "$desired_desc" \
    '{fields:{
        summary: "001 — Sample spec",
        description: $desc,
        labels: ["speckit-spec:001"],
        status: { id: "10000" },
        parent: { key: "PROJ-100" }
     }}' > "$current"
  jira_shim::set_response GET "*/rest/api/3/issue/PROJ-101*" "$current" 200

  # spec→Epic, identity speckit-spec:001, parent PROJ-100 (matches the fixture).
  # Call in the CURRENT shell (not `run`, a subshell) so the disposition global
  # survives for the assertion below.
  JIRA_SINK_LEVEL_DISPOSITION=""
  sync_level_artifact spec "speckit-spec:001" "PROJ-100" "$(_input "001 — Sample spec")" >/dev/null
  [ "$JIRA_SINK_LEVEL_DISPOSITION" = "skipped" ] || {
    echo "expected skipped (zero churn), got '${JIRA_SINK_LEVEL_DISPOSITION}'" >&2
    jira_shim::requests >&2
    false
  }

  local reqs creates updates
  reqs="$(jira_shim::requests)"
  creates="$(printf '%s\n' "$reqs" \
    | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  updates="$(printf '%s\n' "$reqs" | grep -c '^METHOD PUT$' || true)"
  [ "$creates" -eq 0 ] || { echo "expected 0 creates, got $creates" >&2; false; }
  [ "$updates" -eq 0 ] || { echo "expected 0 updates, got $updates" >&2; false; }
}
