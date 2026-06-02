#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us2_idempotent.bats — the US2 SC-017 gate.
#
# Proves the idempotent re-run end-to-end over the MOCKED Jira REST (curl-shim,
# decision D10):
#
#   (a) RE-RUN ZERO CHURN — the shim already holds a Story + Subtasks whose
#       fields EXACTLY match the disk-derived desired state. A reconcile MUST
#       perform ZERO create POSTs, ZERO update PUTs, and ZERO transitions, and
#       the summary MUST report 0 created / 0 updated (FR-008, SC-017).
#
#   (b) MANUAL-EDIT CORRECTION — the shim holds the same Story but with a status
#       DIFFERENT from the disk-derived phase (an operator hand-edited it in
#       Jira). A reconcile MUST issue exactly ONE transition to restore the
#       disk-derived status and MUST NOT create a duplicate Story (US2
#       acceptance #2).
#
# The "already-mirrored" Jira state is synthesized at setup time from the SAME
# sink/adf composition the writer uses, so the desired-vs-current diff is a true
# zero. Offline + deterministic; no real Jira coordinates (Principle IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"

  # See us1_fresh.bats: bats functrace makes jira_rest's RETURN cleanup trap be
  # inherited by the shimmed curl and delete the body before it is read. Disable
  # it so shim-backed reads behave as in production.
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

  # Pin recency via the env override so the fixture needs no commits.
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate

  jira_shim::install

  # --- Synthesize the already-mirrored Jira state ---------------------------
  # Build the SAME desired Story + Subtask bodies the sink composes from disk,
  # so the idempotent diff against them is empty. Computed here, not hand-rolled,
  # so the fixtures can never drift from the writer.
  US2_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$US2_FIXTURES"

  local item
  item="$(workstate::item_for_spec "$WORKDIR/specs/001-sample")"

  local title state body
  title="$(printf '%s' "$item" | jq -r '.title // ""')"
  state="$(printf '%s' "$item" | jq -r '.state // ""')"
  body="$(printf '%s' "$item" | jq -r '.body // ""')"

  local story_summary="001 — ${title}"
  local story_desc
  story_desc="$(adf::from_markdown "$body")"
  # Desired Story labels (deduped) — speckit-spec:001 + phase:<state>.
  local story_labels
  story_labels="$(printf '%s' "$item" | jq -c \
    --arg spec "speckit-spec:001" --arg phase "phase:${state}" \
    '([$spec, $phase] + (.labels // [])) | unique')"
  # Desired status id for the phase (the part before any TAB).
  US2_DESIRED_STATUS_ID="$(config::get_status_transition "$state" | cut -f1)"

  # The repo-Epic SEARCH fixture — so ensure_repo_epic REUSES the existing Epic
  # (PROJ-100) rather than creating one. The Story's desired parent is this key.
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{
         summary:"Specs — repo",labels:["speckit-repo:repo"],
         status:{id:"10000",name:"To Do"},updated:"2026-05-31T00:00:00.000+0000"
       }}]}' >"$US2_FIXTURES/epic_search.json"

  # The Story SEARCH fixture (newest-first issues[]). Carries the Story key the
  # GETs below resolve.
  jq -n \
    --arg key "PROJ-101" \
    --arg summary "$story_summary" \
    --argjson labels "$story_labels" \
    --arg status "$US2_DESIRED_STATUS_ID" \
    '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10101",key:$key,fields:{
         summary:$summary,labels:$labels,
         status:{id:$status,name:"Mapped"},updated:"2026-05-31T00:00:00.000+0000"
       }}]}' >"$US2_FIXTURES/story_search.json"

  # The Story GET fixture — the FULL current state (incl. description + parent),
  # matching the disk-derived desired so the diff is empty.
  jq -n \
    --arg key "PROJ-101" \
    --arg summary "$story_summary" \
    --argjson desc "$story_desc" \
    --argjson labels "$story_labels" \
    --arg status "$US2_DESIRED_STATUS_ID" \
    --arg epic "PROJ-100" \
    '{id:"10101",key:$key,fields:{
       summary:$summary,description:$desc,labels:$labels,
       status:{id:$status,name:"Mapped"},
       parent:{key:$epic}
     }}' >"$US2_FIXTURES/story_get.json"

  # A copy of the Story GET with a DIFFERENT (wrong) status — the operator's
  # manual edit. Everything else still matches, so ONLY a transition is owed.
  jq -n \
    --arg key "PROJ-101" \
    --arg summary "$story_summary" \
    --argjson desc "$story_desc" \
    --argjson labels "$story_labels" \
    --arg epic "PROJ-100" \
    '{id:"10101",key:$key,fields:{
       summary:$summary,description:$desc,labels:$labels,
       status:{id:"99999",name:"Manually Wrong"},
       parent:{key:$epic}
     }}' >"$US2_FIXTURES/story_get_wrongstatus.json"

  # Per-phase Subtask SEARCH + GET fixtures (matching desired → zero diff).
  local children_count i
  children_count="$(printf '%s' "$item" | jq -r '(.children // []) | length')"
  for (( i = 0; i < children_count; i++ )); do
    local child child_title tasks_json sub_body sub_desc phase_index sub_key
    child="$(printf '%s' "$item" | jq -c --argjson n "$i" '.children[$n]')"
    child_title="$(printf '%s' "$child" | jq -r '.title // ""')"
    phase_index="$(( i + 1 ))"
    sub_key="SUB-${phase_index}"
    tasks_json="$(printf '%s' "$child" | jq -c '(.extensions.tasks) // []')"
    sub_body="$(adf::task_list "$tasks_json")"
    sub_desc="$(jq -cn --argjson tl "$sub_body" '{version:1,type:"doc",content:[$tl]}')"

    jq -n --arg key "$sub_key" --arg summary "$child_title" \
      --arg label "task-phase:${phase_index}" \
      '{startAt:0,maxResults:50,total:1,issues:[
         {id:("201"+($key|ltrimstr("SUB-"))),key:$key,fields:{
           summary:$summary,labels:[$label]
         }}]}' >"$US2_FIXTURES/sub${phase_index}_search.json"

    jq -n --arg key "$sub_key" --arg summary "$child_title" \
      --argjson desc "$sub_desc" --arg label "task-phase:${phase_index}" \
      '{key:$key,fields:{
         summary:$summary,description:$desc,labels:[$label]
       }}' >"$US2_FIXTURES/sub${phase_index}_get.json"
  done

  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

# us2::register_present
#   Wire the shim so every read reports the already-mirrored state. First-match
#   wins, so register the SPECIFIC globs (phase-search, per-key GET) before the
#   generic Story search / GET. <story_get_fixture> selects the Story GET body
#   (the matching one for zero-churn, or the wrong-status one for the correction
#   case).
us2::register_present() {
  local story_get_fixture="$1"

  # Transitions list (resolve a transition to the target status) — most specific.
  jira_shim::set_response GET "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200

  # Per-phase Subtask searches (URL carries the encoded phase label).
  jira_shim::set_response GET "*task-phase%3A1*" "$US2_FIXTURES/sub1_search.json" 200
  jira_shim::set_response GET "*task-phase%3A2*" "$US2_FIXTURES/sub2_search.json" 200
  # The repo-Epic search (URL carries the encoded speckit-repo: label) → reuse
  # the existing Epic. Registered before the generic Story search so it wins.
  jira_shim::set_response GET "*speckit-repo%3A*" "$US2_FIXTURES/epic_search.json" 200
  # Generic search → the spec Story lookup. Registered AFTER the specific globs.
  jira_shim::set_response GET "*/search/jql*" "$US2_FIXTURES/story_search.json" 200

  # Per-issue GETs for the diff read (key-specific, before the generic Story).
  jira_shim::set_response GET "*/issue/SUB-1*" "$US2_FIXTURES/sub1_get.json" 200
  jira_shim::set_response GET "*/issue/SUB-2*" "$US2_FIXTURES/sub2_get.json" 200
  jira_shim::set_response GET "*/issue/PROJ-101*" "$story_get_fixture" 200

  # Writes — registered so an UNEXPECTED write still "succeeds" at the transport
  # level; the test asserts on whether they fired, not on a transport error.
  jira_shim::set_response POST "*/rest/api/3/issue" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
}

# --- (a) RE-RUN ZERO CHURN ---------------------------------------------------

@test "re-run against an unchanged mirror performs ZERO writes" {
  cd "$WORKDIR"
  us2::register_present "$US2_FIXTURES/story_get.json"

  summary::start "us2 zero-churn"
  run reconcile::process_spec "specs/001-sample"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"

  # ZERO create POSTs (no duplicate Epic / Story / Subtask).
  local creates
  creates="$(printf '%s\n' "$reqs" \
    | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  [ "$creates" -eq 0 ] || {
    echo "expected 0 POST /issue creates, got $creates" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # ZERO update PUTs.
  local puts
  puts="$(printf '%s\n' "$reqs" | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 0 ] || {
    echo "expected 0 PUT updates, got $puts" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # ZERO transitions (status already matches the disk-derived phase).
  local transitions
  transitions="$(printf '%s\n' "$reqs" | grep -c '/transitions$' || true)"
  # The transitions GET (resolve) only fires when a transition is owed; with a
  # matching status, neither the GET nor the POST should appear.
  [ "$transitions" -eq 0 ] || {
    echo "expected 0 transition requests, got $transitions" >&2
    printf '%s\n' "$reqs" >&2
    false
  }
}

@test "re-run summary reports 0 created / 0 updated" {
  cd "$WORKDIR"
  us2::register_present "$US2_FIXTURES/story_get.json"

  summary::start "us2 zero-churn"
  reconcile::process_spec "specs/001-sample"

  run summary::count created
  [ "$output" -eq 0 ] || { echo "created=$output (want 0)" >&2; false; }

  run summary::count updated
  [ "$output" -eq 0 ] || { echo "updated=$output (want 0)" >&2; false; }

  # The Story + 2 Subtasks are all unchanged → tallied as skipped, not churned.
  run summary::count skipped
  [ "$output" -eq 3 ] || { echo "skipped=$output (want 3)" >&2; false; }

  run summary::count error
  [ "$output" -eq 0 ]
}

# --- (b) MANUAL-EDIT CORRECTION ----------------------------------------------

@test "an operator's manual status edit is corrected by exactly one transition" {
  cd "$WORKDIR"
  us2::register_present "$US2_FIXTURES/story_get_wrongstatus.json"

  summary::start "us2 manual-edit"
  run reconcile::process_spec "specs/001-sample"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"

  # NO duplicate Story (or any create).
  local creates
  creates="$(printf '%s\n' "$reqs" \
    | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  [ "$creates" -eq 0 ] || {
    echo "expected 0 creates on the correction path, got $creates" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # Exactly ONE transition POST restores the disk-derived status.
  local transition_posts
  transition_posts="$(printf '%s\n' "$reqs" \
    | grep -B2 '^URL .*/transitions$' | grep -c '^METHOD POST$' || true)"
  [ "$transition_posts" -eq 1 ] || {
    echo "expected exactly 1 transition POST, got $transition_posts" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # No field PUT (only the status was wrong).
  local puts
  puts="$(printf '%s\n' "$reqs" | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 0 ] || {
    echo "expected 0 PUT updates on the status-only correction, got $puts" >&2
    printf '%s\n' "$reqs" >&2
    false
  }
}

@test "the status correction is reported as updated, not created" {
  cd "$WORKDIR"
  us2::register_present "$US2_FIXTURES/story_get_wrongstatus.json"

  summary::start "us2 manual-edit"
  reconcile::process_spec "specs/001-sample"

  # The Story is updated (status restored); the 2 Subtasks are unchanged.
  run summary::count updated
  [ "$output" -eq 1 ] || { echo "updated=$output (want 1)" >&2; false; }

  run summary::count created
  [ "$output" -eq 0 ] || { echo "created=$output (want 0)" >&2; false; }
}
