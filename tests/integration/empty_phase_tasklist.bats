#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/empty_phase_tasklist.bats
#
# Regression for the empty-taskList → HTTP 400 INVALID_INPUT bug
# (fix/multispec-phase-collision-and-empty-tasklist).
#
# adf::task_list emitted `{type:"taskList", content: []}` for a phase with no
# task lines; Jira rejects a childless taskList with 400 INVALID_INPUT. The fix
# renders a paragraph placeholder instead, and never emits a taskItem with empty
# content.
#
# This drives a fresh reconcile of a spec whose `## Phase 1` has ZERO task lines
# over the curl-shim and asserts the recorded Subtask CREATE body:
#   * is a structurally valid ADF doc;
#   * contains NO `taskList` node whose `content` is empty;
#   * contains NO `taskItem` whose `content` is empty;
#   * the phase Subtask creates (no 400 path).
#
# Offline + deterministic — no real Jira coordinates (Principle IX).
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

  WORKDIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORKDIR/specs"
  cp -R "$REPO_ROOT/tests/fixtures/specs/empty-phase/004-empty" "$WORKDIR/specs/004-empty"

  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate

  jira_shim::install
  # Every read ABSENT → fresh create. Writes + transition succeed.
  jira_shim::set_response GET "*/search/jql*" "$REPO_ROOT/tests/fixtures/jira_responses/search_absent.json" 200
  jira_shim::set_response GET "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response POST "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204

  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

@test "the empty-phase fixture parses to a phase child with zero tasks" {
  local item nphases ntasks
  item="$(workstate::item_for_spec "$WORKDIR/specs/004-empty")"
  nphases="$(printf '%s' "$item" | jq -r '(.children // []) | length')"
  [ "$nphases" -ge 1 ]
  ntasks="$(printf '%s' "$item" | jq -r '.children[0].extensions.tasks | length')"
  [ "$ntasks" -eq 0 ] || { echo "expected 0 tasks in phase 1, got $ntasks"; printf '%s\n' "$item" | jq .; false; }
}

@test "an empty phase renders a paragraph placeholder, never a childless taskList" {
  # The body the sink composes for an empty-task phase (the exact path
  # sync_level_artifact uses: {tasks:[]} → adf::task_list → doc).
  local body desc
  body="$(adf::task_list '[]')"
  desc="$(jq -cn --argjson tl "$body" '{version:1,type:"doc",content:[$tl]}')"

  # Structurally valid ADF doc.
  printf '%s' "$desc" | jq -e '.type == "doc" and (.version == 1) and (.content | type == "array")'
  # No empty taskList anywhere.
  printf '%s' "$desc" | jq -e '[.. | objects | select(.type=="taskList") | select((.content // []) | length == 0)] | length == 0'
  # The placeholder is a non-empty paragraph.
  printf '%s' "$desc" | jq -e '.content[0].type == "paragraph" and (.content[0].content | length > 0)'
}

@test "the recorded Subtask CREATE body has NO empty taskList/taskItem and creates without a 400" {
  cd "$WORKDIR"

  run reconcile::process_spec "specs/004-empty"
  [ "$status" -eq 0 ] || { echo "rc=$status"; printf '%s\n' "$output"; false; }

  local reqs
  reqs="$(jira_shim::requests)"

  # The Subtask create POST (issuetype 10003) fired.
  local sub_bodies
  sub_bodies="$(printf '%s\n' "$reqs" | grep '^BODY ' | grep '"10003"' | sed -E 's/^BODY //')"
  [ -n "$sub_bodies" ] || { echo "no Subtask create POST recorded"; printf '%s\n' "$reqs"; false; }

  # Every write body must be structurally sound: no childless taskList and no
  # empty-content taskItem (the two 400 INVALID_INPUT shapes).
  local b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    printf '%s' "$b" | jq -e \
      '[.. | objects | select(.type=="taskList") | select((.content // []) | length == 0)] | length == 0' \
      || { echo "FOUND an empty taskList in a write body:"; printf '%s\n' "$b"; false; }
    printf '%s' "$b" | jq -e \
      '[.. | objects | select(.type=="taskItem") | select((.content // []) | length == 0)] | length == 0' \
      || { echo "FOUND an empty taskItem in a write body:"; printf '%s\n' "$b"; false; }
  done < <(printf '%s\n' "$reqs" | grep '^BODY ' | sed -E 's/^BODY //')

  # And specifically the Subtask body carries the paragraph placeholder.
  printf '%s\n' "$sub_bodies" | head -1 | jq -e \
    '[.. | objects | select(.type=="paragraph") | select(.content[]?.text == "No tasks in this phase.")] | length >= 1' \
    || { echo "Subtask body missing the placeholder paragraph"; printf '%s\n' "$sub_bodies"; false; }
}
