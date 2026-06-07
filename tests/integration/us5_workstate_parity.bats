#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us5_workstate_parity.bats  (T041, US5)
#
# End-to-end (curl-shim) proof of --workstate direct input (FR-015/FR-016,
# SC-005, workstate-input.md):
#
#   (1) PARITY vs specs/-tree — a workstate document derived from the sample
#       specs tree projects the IDENTICAL artifacts (Epic+Story+2 Subtasks, same
#       types/labels/parent) as running the specs/-tree path over the same tree.
#   (2) STDIN == FILE — the same document piped on `--workstate -` produces the
#       identical projection to the file case.
#   (3) FAIL-CLOSED — a malformed document is rejected on entry (exit 2) with
#       ZERO writes.
#
# The document is built from the sample via workstate::document_for_repo, so the
# items match item_for_spec and equivalence holds by construction. Offline +
# deterministic; no real Jira coordinates (Principle IX).
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
  cp -R "$REPO_ROOT/tests/fixtures/specs/001-sample" "$WORKDIR/specs/001-sample"
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::install
  # Fresh path: reads absent → CREATE; transitions resolve; writes succeed.
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204

  # The workstate document equivalent to the sample specs/-tree.
  DOC="$BATS_TEST_TMPDIR/sample.workstate.json"
  workstate::document_for_repo "$WORKDIR/specs" "repo" "2026-05-31T00:00:00Z" >"$DOC"

  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

# Count plain-issue CREATE posts + extract the issue-type ids posted.
_creates() {
  jira_shim::requests \
    | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true
}

# --- (1) PARITY vs the specs/-tree projection --------------------------------

@test "workstate-direct (file) projects the SAME artifacts as the specs/-tree run" {
  cd "$WORKDIR"

  # Baseline: the specs/-tree projection.
  reconcile::process_spec "specs/001-sample" >/dev/null 2>&1
  local tree_reqs; tree_reqs="$(jira_shim::requests)"
  local tree_creates; tree_creates="$(_creates)"

  jira_shim::reset
  jira_shim::set_response GET "*/search/jql*" "$REPO_ROOT/tests/fixtures/jira_responses/search_absent.json" 200
  jira_shim::set_response GET "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response POST "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204

  # Workstate-direct projection of the equivalent document.
  ARG_WORKSTATE="$DOC"
  ARG_WORKSTATE_SET=1
  summary::start "us5 file"
  reconcile::run_workstate
  local ws_reqs; ws_reqs="$(jira_shim::requests)"
  local ws_creates; ws_creates="$(_creates)"

  # Same number of creates (Epic + Story + 2 Subtasks = 4) in both runs.
  [ "$tree_creates" -eq 4 ] || { echo "tree creates=$tree_creates" >&2; printf '%s\n' "$tree_reqs" >&2; false; }
  [ "$ws_creates" -eq "$tree_creates" ] || {
    echo "workstate creates=$ws_creates != tree=$tree_creates" >&2
    printf '%s\n' "$ws_reqs" >&2; false; }

  # Same artifact types + identity labels + parent link.
  printf '%s\n' "$ws_reqs" | grep -q '"id":"10001"'   # Epic
  printf '%s\n' "$ws_reqs" | grep -q '"id":"10002"'   # Story
  printf '%s\n' "$ws_reqs" | grep -q '"id":"10003"'   # Subtask
  printf '%s\n' "$ws_reqs" | grep -q '"speckit-spec:001"'
  printf '%s\n' "$ws_reqs" | grep -q '"speckit-repo:repo"'
  printf '%s\n' "$ws_reqs" | grep -q '"task-phase:1"'
  printf '%s\n' "$ws_reqs" | grep -q '"task-phase:2"'
  printf '%s\n' "$ws_reqs" | grep -q '"parent"'
}

# --- (2) STDIN == FILE -------------------------------------------------------

@test "workstate-direct (stdin -) projects identically to the file case" {
  cd "$WORKDIR"

  ARG_WORKSTATE="-"
  ARG_WORKSTATE_SET=1
  summary::start "us5 stdin"
  reconcile::run_workstate <"$DOC"

  local creates; creates="$(_creates)"
  [ "$creates" -eq 4 ] || { echo "stdin creates=$creates (want 4)" >&2; jira_shim::requests >&2; false; }
  local reqs; reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | grep -q '"id":"10001"'
  printf '%s\n' "$reqs" | grep -q '"id":"10002"'
  printf '%s\n' "$reqs" | grep -q '"id":"10003"'
  printf '%s\n' "$reqs" | grep -q '"speckit-spec:001"'
}

# --- (3) FAIL-CLOSED on a malformed document ---------------------------------

@test "workstate-direct rejects a malformed document on entry (exit 2, zero writes)" {
  cd "$WORKDIR"
  local bad="$BATS_TEST_TMPDIR/bad.json"
  printf '%s' '{ not valid json' >"$bad"

  RECONCILE_EXIT_CODE=0
  ARG_WORKSTATE="$bad"
  ARG_WORKSTATE_SET=1
  summary::start "us5 malformed"
  reconcile::run_workstate

  # Promoted to a config/input error (exit 2)…
  [ "$RECONCILE_EXIT_CODE" -eq 2 ] || { echo "exit=$RECONCILE_EXIT_CODE (want 2)" >&2; false; }
  # …and NOTHING was written.
  local writes
  writes="$(jira_shim::requests | grep -Ec '^METHOD (POST|PUT)$' || true)"
  [ "$writes" -eq 0 ] || { echo "expected 0 writes on malformed input, got $writes" >&2; jira_shim::requests >&2; false; }
}

# --- (4) ZERO-CHURN re-run (idempotency, the constitutional differentiator) --

@test "workstate-direct RE-RUN against an already-mirrored state is zero churn" {
  cd "$WORKDIR"

  # Synthesize the already-mirrored Jira state from the SAME item the document
  # carries (so the desired-vs-current diff is a true zero), mirroring the
  # us2_idempotent approach.
  local item title state body story_summary story_desc story_labels status_id
  item="$(jq -c '.items[0]' "$DOC")"
  title="$(printf '%s' "$item" | jq -r '.title // ""')"
  state="$(printf '%s' "$item" | jq -r '.state // ""')"
  body="$(printf '%s' "$item" | jq -r '.body // ""')"
  story_summary="001 — ${title}"
  story_desc="$(adf::from_markdown "$body")"
  story_labels="$(printf '%s' "$item" | jq -c \
    --arg spec "speckit-spec:001" --arg phase "phase:${state}" \
    '([$spec, $phase] + (.labels // [])) | unique')"
  status_id="$(config::get_status_transition "$state" | cut -f1)"

  local fx="$BATS_TEST_TMPDIR/present"
  mkdir -p "$fx"
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{summary:"Specs — repo",
        labels:["speckit-repo:repo"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000"}}]}' >"$fx/epic_search.json"
  jq -n --arg s "$story_summary" --argjson l "$story_labels" --arg st "$status_id" \
    '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10101",key:"PROJ-101",fields:{summary:$s,labels:$l,
        status:{id:$st},updated:"2026-05-31T00:00:00.000+0000"}}]}' >"$fx/story_search.json"
  jq -n --arg s "$story_summary" --argjson d "$story_desc" --argjson l "$story_labels" \
    --arg st "$status_id" \
    '{id:"10101",key:"PROJ-101",fields:{summary:$s,description:$d,labels:$l,
       status:{id:$st},parent:{key:"PROJ-100"}}}' >"$fx/story_get.json"

  local i n
  n="$(printf '%s' "$item" | jq -r '(.children // []) | length')"
  for (( i = 0; i < n; i++ )); do
    local child child_title tasks sub_body sub_desc pidx
    child="$(printf '%s' "$item" | jq -c --argjson k "$i" '.children[$k]')"
    child_title="$(printf '%s' "$child" | jq -r '.title // ""')"
    pidx="$(( i + 1 ))"
    tasks="$(printf '%s' "$child" | jq -c '(.extensions.tasks) // []')"
    sub_body="$(adf::task_list "$tasks")"
    sub_desc="$(jq -cn --argjson tl "$sub_body" '{version:1,type:"doc",content:[$tl]}')"
    jq -n --arg s "$child_title" --arg l "task-phase:${pidx}" \
      '{startAt:0,maxResults:50,total:1,issues:[
         {id:("201"+($l|ltrimstr("task-phase:"))),key:("SUB-"+($l|ltrimstr("task-phase:"))),
          fields:{summary:$s,labels:[$l]}}]}' >"$fx/sub${pidx}_search.json"
    jq -n --arg s "$child_title" --argjson d "$sub_desc" --arg l "task-phase:${pidx}" \
      '{key:("SUB-"+($l|ltrimstr("task-phase:"))),fields:{summary:$s,description:$d,labels:[$l]}}' \
      >"$fx/sub${pidx}_get.json"
  done

  jira_shim::reset
  jira_shim::set_response GET "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response GET "*task-phase%3A1*" "$fx/sub1_search.json" 200
  jira_shim::set_response GET "*task-phase%3A2*" "$fx/sub2_search.json" 200
  jira_shim::set_response GET "*speckit-repo%3A*" "$fx/epic_search.json" 200
  jira_shim::set_response GET "*/search/jql*" "$fx/story_search.json" 200
  jira_shim::set_response GET "*/issue/SUB-1*" "$fx/sub1_get.json" 200
  jira_shim::set_response GET "*/issue/SUB-2*" "$fx/sub2_get.json" 200
  jira_shim::set_response GET "*/issue/PROJ-101*" "$fx/story_get.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204

  ARG_WORKSTATE="$DOC"
  ARG_WORKSTATE_SET=1
  summary::start "us5 zero-churn"
  reconcile::run_workstate

  local reqs creates puts
  reqs="$(jira_shim::requests)"
  creates="$(printf '%s\n' "$reqs" | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  puts="$(printf '%s\n' "$reqs" | grep -c '^METHOD PUT$' || true)"
  [ "$creates" -eq 0 ] || { echo "expected 0 creates on workstate re-run, got $creates" >&2; printf '%s\n' "$reqs" >&2; false; }
  [ "$puts" -eq 0 ] || { echo "expected 0 PUTs on workstate re-run, got $puts" >&2; printf '%s\n' "$reqs" >&2; false; }
}

@test "workstate-direct rejects an unpinned schema_version (exit 2, zero writes)" {
  cd "$WORKDIR"
  local bad="$BATS_TEST_TMPDIR/unpinned.json"
  jq -c '.schema_version = "9.9.9"' "$DOC" >"$bad"

  RECONCILE_EXIT_CODE=0
  ARG_WORKSTATE="$bad"
  ARG_WORKSTATE_SET=1
  summary::start "us5 unpinned"
  reconcile::run_workstate

  [ "$RECONCILE_EXIT_CODE" -eq 2 ]
  local writes
  writes="$(jira_shim::requests | grep -Ec '^METHOD (POST|PUT)$' || true)"
  [ "$writes" -eq 0 ]
}
