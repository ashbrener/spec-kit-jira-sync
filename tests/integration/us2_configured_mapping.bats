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
  # link_to_parent reads the child's current parent first (read-before-write,
  # F3). PROJ-102 currently has a DIFFERENT parent → the reaffirming PUT fires.
  local cur="${BATS_TEST_TMPDIR}/proj102_other_parent.json"
  jq -n '{fields:{summary:"Phase 1", description:null, labels:["task-phase:1"], parent:{key:"PROJ-999"}}}' > "$cur"
  jira_shim::set_response GET "*/rest/api/3/issue/PROJ-102*" "$cur" 200

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

  # F1 HARDENING: the already-mirrored issue carries EXTRA labels beyond the
  # identity — a phase label (phase:specified) AND an operator-added label
  # (team:bridge). The desired input carries those SAME extra labels via the
  # `labels` field, so the FIXED sink composes the desired set as
  # ([identity] + input.labels | unique) == the current set → a TRUE zero diff.
  # The un-fixed sink rebuilt desired = [identity] ONLY, so it would diff the two
  # extra labels away and PUT labels:["speckit-spec:001"] — WIPING them — which
  # flips disposition to "updated" and fires a PUT, failing this test.
  local current="${BATS_TEST_TMPDIR}/current.json"
  local desired_desc
  desired_desc="$(adf::from_markdown "")"
  jq -n \
    --argjson desc "$desired_desc" \
    '{fields:{
        summary: "001 — Sample spec",
        description: $desc,
        labels: ["speckit-spec:001", "phase:specified", "team:bridge"],
        status: { id: "10000" },
        parent: { key: "PROJ-100" }
     }}' > "$current"
  jira_shim::set_response GET "*/rest/api/3/issue/PROJ-101*" "$current" 200

  # The desired input carries the phase + operator labels (the sink always adds
  # the identity label itself). spec→Epic, identity speckit-spec:001, parent
  # PROJ-100 (matches the fixture). Call in the CURRENT shell (not `run`, a
  # subshell) so the disposition global survives for the assertion below.
  local desired_input
  desired_input="$(jq -cn '{summary:"001 — Sample spec", body:"", labels:["phase:specified","team:bridge"]}')"
  JIRA_SINK_LEVEL_DISPOSITION=""
  sync_level_artifact spec "speckit-spec:001" "PROJ-100" "$desired_input" >/dev/null
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

# --- F4: re-run zero-churn for the PARENT-BEARING levels ----------------------
# The spec-level above carries relationship `none` (no parent diff). The
# parent-bearing levels — phase (Epic-link under the spec Epic) and task (parent
# under the phase Story) — must ALSO be zero-churn on a re-run whose current
# parent already matches. These assert DISPOSITION=skipped and 0 PUTs, closing
# the gap where only the relationship-`none` level was checked.

@test "RE-RUN zero-churn for the phase (Epic-link) level — 0 PUTs, skipped" {
  jira_shim::set_response GET "*/search/jql*" search_found_story.json 200

  # The already-mirrored phase Story: summary "Phase 1", empty body, the phase
  # identity label, and its parent ALREADY the spec Epic (PROJ-100). The fixed
  # parent-diff must therefore find a match and write nothing.
  local current="${BATS_TEST_TMPDIR}/phase_current.json"
  local desired_desc
  desired_desc="$(adf::from_markdown "")"
  jq -n --argjson desc "$desired_desc" \
    '{fields:{
        summary: "Phase 1",
        description: $desc,
        labels: ["task-phase:1"],
        parent: { key: "PROJ-100" }
     }}' > "$current"
  jira_shim::set_response GET "*/rest/api/3/issue/PROJ-101*" "$current" 200

  JIRA_SINK_LEVEL_DISPOSITION=""
  sync_level_artifact phase "task-phase:1" "PROJ-100" "$(_input "Phase 1")" >/dev/null
  [ "$JIRA_SINK_LEVEL_DISPOSITION" = "skipped" ] || {
    echo "expected skipped (phase zero churn), got '${JIRA_SINK_LEVEL_DISPOSITION}'" >&2
    jira_shim::requests >&2
    false
  }

  local reqs puts
  reqs="$(jira_shim::requests)"
  puts="$(printf '%s\n' "$reqs" | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 0 ] || { echo "expected 0 PUTs on the phase re-run, got $puts" >&2; printf '%s\n' "$reqs" >&2; false; }
}

@test "RE-RUN zero-churn for the task (parent) level — 0 PUTs, skipped" {
  jira_shim::set_response GET "*/search/jql*" search_found_story.json 200

  # The already-mirrored task Task: summary "Task 1", empty body, the task
  # identity label, parent ALREADY the phase Story (PROJ-100, the fixture key).
  local current="${BATS_TEST_TMPDIR}/task_current.json"
  local desired_desc
  desired_desc="$(adf::from_markdown "")"
  jq -n --argjson desc "$desired_desc" \
    '{fields:{
        summary: "Task 1",
        description: $desc,
        labels: ["speckit-task:001-1-1"],
        parent: { key: "PROJ-100" }
     }}' > "$current"
  jira_shim::set_response GET "*/rest/api/3/issue/PROJ-101*" "$current" 200

  JIRA_SINK_LEVEL_DISPOSITION=""
  sync_level_artifact task "speckit-task:001-1-1" "PROJ-100" "$(_input "Task 1")" >/dev/null
  [ "$JIRA_SINK_LEVEL_DISPOSITION" = "skipped" ] || {
    echo "expected skipped (task zero churn), got '${JIRA_SINK_LEVEL_DISPOSITION}'" >&2
    jira_shim::requests >&2
    false
  }

  local reqs puts
  reqs="$(jira_shim::requests)"
  puts="$(printf '%s\n' "$reqs" | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 0 ] || { echo "expected 0 PUTs on the task re-run, got $puts" >&2; printf '%s\n' "$reqs" >&2; false; }
}
