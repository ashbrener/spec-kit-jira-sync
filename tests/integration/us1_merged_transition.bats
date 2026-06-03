#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us1_merged_transition.bats — merged→Done lifecycle gate.
#
# Regression test for the bug where a spec whose feature branch is MERGED to the
# trunk was logged as `lifecycle=merged` by the repo-level aggregate, yet its
# Story stayed In Progress because the per-spec workstate ITEM state was computed
# WITHOUT the git merge hint — so `item.state` stalled at `implementing`, the
# desired status equalled the current status, and the merged→Done transition
# never fired.
#
# This drives reconcile::process_spec over the MOCKED Jira REST (curl-shim) with
# git_helpers::pr_state stubbed to report `merged` (no live git/gh, deterministic
# offline). The existing Story is mirrored with the disk-inferred In-Progress
# status (id 20004, the `implementing` mapping). The merged phase maps to status
# 20006 (Done) in the placeholder config, so the fix MUST issue exactly ONE
# transition to 20006. Without the fix the item state is `implementing`, the
# status already matches, and ZERO transitions fire — the assertion below catches
# that regression.
#
# Privacy (Principle IX): placeholders only — fake project key + numeric ids.
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

  # --- Stub the merge signal -------------------------------------------------
  # The bug's trigger is git reporting the feature branch as merged. Stub
  # git_helpers::pr_state to report `merged` for the spec's feature branch so the
  # engine resolves lifecycle=merged WITHOUT a live git/gh dependency (offline +
  # deterministic). reconcile::pr_state_hint maps the bare `merged` word through.
  # shellcheck disable=SC2317  # invoked indirectly by the engine under test.
  git_helpers::pr_state() { printf 'merged\n'; }
  # Keep the drift recency probe quiet/deterministic (no commit touches the
  # tmp spec dir, so this returns empty → recency unavailable, no spurious drift).

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate

  jira_shim::install

  # --- Synthesize the already-mirrored Jira state ---------------------------
  # Build the SAME desired Story/Subtask bodies the sink composes from disk, but
  # with the IMPLEMENTING status (id 20004) on the current Story — exactly the
  # state a spec sits in right before its branch lands. Computed from the writer's
  # own composition so only the status differs from the merged-desired state.
  MERGED_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$MERGED_FIXTURES"

  local item
  item="$(workstate::item_for_spec "$WORKDIR/specs/001-sample")"

  local title body
  title="$(printf '%s' "$item" | jq -r '.title // ""')"
  body="$(printf '%s' "$item" | jq -r '.body // ""')"

  local story_summary="001 — ${title}"
  local story_desc
  story_desc="$(adf::from_markdown "$body")"

  # IMPORTANT: the mirrored Story's labels carry the MERGED phase label so the
  # only owed change is the STATUS transition (a label diff would also flip the
  # disposition to updated, masking the transition-specific assertion). The merge
  # hint drives the item to state=merged, so the desired labels carry phase:merged.
  local story_labels
  story_labels="$(printf '%s' "$item" | jq -c \
    --arg spec "speckit-spec:001" --arg phase "phase:merged" \
    '([$spec, $phase] + (.labels // [])) | unique')"

  # The current (In Progress) status id = the `implementing` mapping (20004).
  IMPLEMENTING_STATUS_ID="$(config::get_status_transition "implementing" | cut -f1)"
  # The desired (Done) status id = the `merged` mapping (20006).
  MERGED_STATUS_ID="$(config::get_status_transition "merged" | cut -f1)"

  # Repo-Epic SEARCH fixture → reuse the existing Epic (no Epic create).
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{
         summary:"Specs — repo",labels:["speckit-repo:repo"],
         status:{id:"10000",name:"To Do"},updated:"2026-05-31T00:00:00.000+0000"
       }}]}' >"$MERGED_FIXTURES/epic_search.json"

  # Story SEARCH fixture (newest-first issues[]) — resolves the Story key.
  jq -n \
    --arg key "PROJ-101" \
    --arg summary "$story_summary" \
    --argjson labels "$story_labels" \
    --arg status "$IMPLEMENTING_STATUS_ID" \
    '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10101",key:$key,fields:{
         summary:$summary,labels:$labels,
         status:{id:$status,name:"In Progress"},updated:"2026-05-31T00:00:00.000+0000"
       }}]}' >"$MERGED_FIXTURES/story_search.json"

  # Story GET fixture — the FULL current state: matches the merged-desired body
  # and labels, but is still parked at the In-Progress status. So the ONLY owed
  # change is the merged→Done transition.
  jq -n \
    --arg key "PROJ-101" \
    --arg summary "$story_summary" \
    --argjson desc "$story_desc" \
    --argjson labels "$story_labels" \
    --arg status "$IMPLEMENTING_STATUS_ID" \
    --arg epic "PROJ-100" \
    '{id:"10101",key:$key,fields:{
       summary:$summary,description:$desc,labels:$labels,
       status:{id:$status,name:"In Progress"},
       parent:{key:$epic}
     }}' >"$MERGED_FIXTURES/story_get.json"

  # Per-phase Subtask SEARCH + GET fixtures (matching desired → zero diff), so
  # the Subtasks stay unchanged and do not muddy the Story-transition assertion.
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
         }}]}' >"$MERGED_FIXTURES/sub${phase_index}_search.json"

    jq -n --arg key "$sub_key" --arg summary "$child_title" \
      --argjson desc "$sub_desc" --arg label "task-phase:${phase_index}" \
      '{key:$key,fields:{
         summary:$summary,description:$desc,labels:[$label]
       }}' >"$MERGED_FIXTURES/sub${phase_index}_get.json"
  done

  # --- Wire the shim: every read reports the already-mirrored (In Progress)
  # state; the transitions list offers a transition to the merged status (20006).
  jira_shim::set_response GET "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/transitions_merged.json" 200
  jira_shim::set_response GET "*task-phase%3A1*" "$MERGED_FIXTURES/sub1_search.json" 200
  jira_shim::set_response GET "*task-phase%3A2*" "$MERGED_FIXTURES/sub2_search.json" 200
  jira_shim::set_response GET "*speckit-repo%3A*" "$MERGED_FIXTURES/epic_search.json" 200
  jira_shim::set_response GET "*/search/jql*" "$MERGED_FIXTURES/story_search.json" 200
  jira_shim::set_response GET "*/issue/SUB-1*" "$MERGED_FIXTURES/sub1_get.json" 200
  jira_shim::set_response GET "*/issue/SUB-2*" "$MERGED_FIXTURES/sub2_get.json" 200
  jira_shim::set_response GET "*/issue/PROJ-101*" "$MERGED_FIXTURES/story_get.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204

  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

# The merge hint must reach the per-spec workstate item's state (the unit-level
# root cause: item_for_spec was ignoring the engine's resolved lifecycle token).
@test "item_for_spec carries state=merged when given the merged lifecycle hint" {
  cd "$WORKDIR"
  run workstate::item_for_spec "$WORKDIR/specs/001-sample" "" "merged"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.state == "merged"'
}

@test "a merged spec transitions its Story to the mapped Done status" {
  cd "$WORKDIR"

  summary::start "merged transition"
  run reconcile::process_spec "specs/001-sample"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"

  # The run resolved the merged lifecycle (the aggregate log + the item state).
  # NO duplicate Story (or any create) — the existing Story was matched.
  local creates
  creates="$(printf '%s\n' "$reqs" \
    | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  [ "$creates" -eq 0 ] || {
    echo "expected 0 creates (Story already mirrored), got $creates" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # Exactly ONE transition POST fired to move the Story to Done. Before the fix
  # the item state stayed `implementing`, desired==current, and ZERO transitions
  # fired — so this count is the regression guard.
  local transition_posts
  transition_posts="$(printf '%s\n' "$reqs" \
    | grep -B2 '^URL .*/transitions$' | grep -c '^METHOD POST$' || true)"
  [ "$transition_posts" -eq 1 ] || {
    echo "expected exactly 1 merged→Done transition POST, got $transition_posts" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # The transition POST carries the Done transition id (31 → to.id 20006) the
  # merged-transitions fixture maps. Confirms the merged status, not a stray one.
  printf '%s\n' "$reqs" | grep -A3 '^METHOD POST' \
    | grep -q '"transition":{"id":"31"}' || {
    echo "expected the transition POST to target the Done transition (id 31)" >&2
    printf '%s\n' "$reqs" >&2
    false
  }
}

@test "the merged Story transition is reported as updated, not created" {
  cd "$WORKDIR"

  summary::start "merged transition"
  reconcile::process_spec "specs/001-sample"

  # The Story status is corrected (merged) → updated; the 2 Subtasks unchanged.
  run summary::count updated
  [ "$output" -eq 1 ] || { echo "updated=$output (want 1)" >&2; false; }

  run summary::count created
  [ "$output" -eq 0 ] || { echo "created=$output (want 0)" >&2; false; }

  run summary::count error
  [ "$output" -eq 0 ]
}
