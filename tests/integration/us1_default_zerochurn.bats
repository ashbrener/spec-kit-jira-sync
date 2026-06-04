#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us1_default_zerochurn.bats  (T012, US1)
#
# Phase 3 / US1: re-running the already-mirrored DEFAULT corpus performs ZERO
# writes (0 created / 0 updated, the Epic reused), AND an EXPLICIT default
# `mapping:` block produces the identical result to the no-block (aliased) case
# (spec scenarios 2–3, SC-001).
#
# Mirrors tests/integration/us2_idempotent.bats's already-mirrored setup, but the
# run path goes THROUGH the mapping layer (mapping::parse + mapping::validate
# before the write loop). A parameterised driver runs the SAME zero-churn
# assertions twice: once with the pre-feature config (no `mapping:` block →
# alias-synthesized default) and once with an explicit default `mapping:` block.
# Both MUST be byte-for-byte identical: zero creates, zero updates, zero
# transitions, the Epic reused.
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
  cp -R "$REPO_ROOT/tests/fixtures/specs/001-sample" "$WORKDIR/specs/001-sample"

  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  # An explicit-default `mapping:` config (spells out repo→Epic / spec→Story /
  # phase→Subtask / task→checklist; initiative + rollup off) — used by the
  # equivalence arm. Same coordinates as the sample, plus the default block.
  EXPLICIT_DEFAULT_CFG="$BATS_TEST_TMPDIR/jira-config.explicit-default.yml"
  cat > "$EXPLICIT_DEFAULT_CFG" <<'YAML'
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
  transitions:
    implementing: "30004"
  labels:
    spec_prefix: "speckit-spec:"
    repo_prefix: "speckit-repo:"
    phase_prefix: "task-phase:"
    lifecycle_prefix: "phase:"
    task_prefix: "speckit-task:"
  mapping:
    initiative:
      enabled: false
      artifact: "Initiative"
      on_absent: "degrade"
      source: "spec_input"
    project_style: "team-managed"
    levels:
      repo:   { artifact: "Epic",      relationship_to_parent: "none" }
      spec:   { artifact: "Story",     relationship_to_parent: "parent" }
      phase:  { artifact: "Subtask",   relationship_to_parent: "parent" }
      task:   { artifact: "checklist", relationship_to_parent: "checklist" }
    status_rollup:
      enabled: false
YAML

  jira_shim::install

  # --- Synthesize the already-mirrored Jira state (same as us2_idempotent) ----
  # The desired Story + Subtask bodies are composed from the SAME sink/adf path
  # the writer uses, so the idempotent diff against them is empty.
  US1_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$US1_FIXTURES"

  # Config must be loaded to compose the desired fixtures (item_for_spec +
  # config::get_status_transition). Load the no-mapping sample for composition;
  # the per-test arm reloads its own config before driving the run.
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate

  local item title state body
  item="$(workstate::item_for_spec "$WORKDIR/specs/001-sample")"
  title="$(printf '%s' "$item" | jq -r '.title // ""')"
  state="$(printf '%s' "$item" | jq -r '.state // ""')"
  body="$(printf '%s' "$item" | jq -r '.body // ""')"

  local story_summary="001 — ${title}"
  local story_desc
  story_desc="$(adf::from_markdown "$body")"
  local story_labels
  story_labels="$(printf '%s' "$item" | jq -c \
    --arg spec "speckit-spec:001" --arg phase "phase:${state}" \
    '([$spec, $phase] + (.labels // [])) | unique')"
  US1_DESIRED_STATUS_ID="$(config::get_status_transition "$state" | cut -f1)"

  # Repo-Epic search → reuse the existing Epic (PROJ-100).
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{
         summary:"Specs — repo",labels:["speckit-repo:repo"],
         status:{id:"10000",name:"To Do"},updated:"2026-05-31T00:00:00.000+0000"
       }}]}' >"$US1_FIXTURES/epic_search.json"

  # Spec Story search (newest-first).
  jq -n \
    --arg key "PROJ-101" \
    --arg summary "$story_summary" \
    --argjson labels "$story_labels" \
    --arg status "$US1_DESIRED_STATUS_ID" \
    '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10101",key:$key,fields:{
         summary:$summary,labels:$labels,
         status:{id:$status,name:"Mapped"},updated:"2026-05-31T00:00:00.000+0000"
       }}]}' >"$US1_FIXTURES/story_search.json"

  # Spec Story GET (full current state, matching desired → empty diff).
  jq -n \
    --arg key "PROJ-101" \
    --arg summary "$story_summary" \
    --argjson desc "$story_desc" \
    --argjson labels "$story_labels" \
    --arg status "$US1_DESIRED_STATUS_ID" \
    --arg epic "PROJ-100" \
    '{id:"10101",key:$key,fields:{
       summary:$summary,description:$desc,labels:$labels,
       status:{id:$status,name:"Mapped"},
       parent:{key:$epic}
     }}' >"$US1_FIXTURES/story_get.json"

  # Per-phase Subtask search + GET (matching desired → empty diff).
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
         }}]}' >"$US1_FIXTURES/sub${phase_index}_search.json"

    jq -n --arg key "$sub_key" --arg summary "$child_title" \
      --argjson desc "$sub_desc" --arg label "task-phase:${phase_index}" \
      '{key:$key,fields:{
         summary:$summary,description:$desc,labels:[$label]
       }}' >"$US1_FIXTURES/sub${phase_index}_get.json"
  done

  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

# us1::register_present
#   Wire the shim so every read reports the already-mirrored DEFAULT state.
#   First-match wins, so specific globs precede the generic Story search/GET.
us1::register_present() {
  jira_shim::set_response GET "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response GET "*task-phase%3A1*" "$US1_FIXTURES/sub1_search.json" 200
  jira_shim::set_response GET "*task-phase%3A2*" "$US1_FIXTURES/sub2_search.json" 200
  jira_shim::set_response GET "*speckit-repo%3A*" "$US1_FIXTURES/epic_search.json" 200
  jira_shim::set_response GET "*/search/jql*" "$US1_FIXTURES/story_search.json" 200
  jira_shim::set_response GET "*/issue/SUB-1*" "$US1_FIXTURES/sub1_get.json" 200
  jira_shim::set_response GET "*/issue/SUB-2*" "$US1_FIXTURES/sub2_get.json" 200
  jira_shim::set_response GET "*/issue/PROJ-101*" "$US1_FIXTURES/story_get.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
}

# us1::assert_zero_churn
#   Run process_spec under the loaded config + mapping and assert ZERO writes:
#   no create POST, no update PUT, no transition. Echoes the request log to the
#   TAP comment stream on failure.
us1::assert_zero_churn() {
  jira_shim::reset
  us1::register_present
  summary::start "us1 default zero-churn"
  reconcile::process_spec "specs/001-sample"

  local reqs
  reqs="$(jira_shim::requests)"

  local creates puts transitions
  creates="$(printf '%s\n' "$reqs" \
    | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  puts="$(printf '%s\n' "$reqs" | grep -c '^METHOD PUT$' || true)"
  transitions="$(printf '%s\n' "$reqs" | grep -c '/transitions$' || true)"

  [ "$creates" -eq 0 ] || { echo "creates=$creates (want 0)" >&2; printf '%s\n' "$reqs" >&2; return 1; }
  [ "$puts" -eq 0 ]    || { echo "puts=$puts (want 0)" >&2; printf '%s\n' "$reqs" >&2; return 1; }
  [ "$transitions" -eq 0 ] || { echo "transitions=$transitions (want 0)" >&2; printf '%s\n' "$reqs" >&2; return 1; }
}

# --- (a) no-mapping (aliased default) re-run is zero churn --------------------

@test "re-run of the default-aliased mirror performs ZERO writes (Epic reused)" {
  cd "$WORKDIR"
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  mapping::validate

  run us1::assert_zero_churn
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "re-run of the default-aliased mirror reports 0 created / 0 updated" {
  cd "$WORKDIR"
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::reset
  us1::register_present
  summary::start "us1 default zero-churn counts"
  reconcile::process_spec "specs/001-sample"

  run summary::count created
  [ "$output" -eq 0 ] || { echo "created=$output (want 0)" >&2; false; }
  run summary::count updated
  [ "$output" -eq 0 ] || { echo "updated=$output (want 0)" >&2; false; }
  run summary::count skipped
  [ "$output" -eq 3 ] || { echo "skipped=$output (want 3)" >&2; false; }
  run summary::count error
  [ "$output" -eq 0 ]
}

# --- (b) explicit default block == aliased (no-block) case -------------------

@test "an explicit default mapping block re-runs zero-churn, identical to no-block" {
  cd "$WORKDIR"
  # Load the explicit-default-block config and run the IDENTICAL zero-churn
  # assertions — an explicit default block must equal the aliased case (SC-001).
  config::load "$EXPLICIT_DEFAULT_CFG"
  config::validate
  mapping::parse
  mapping::validate

  # mapping::is_explicit confirms the block was operator-declared (not aliased).
  run mapping::is_explicit
  [ "$status" -eq 0 ]

  run us1::assert_zero_churn
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "explicit default block reports the same 0/0/3 counts as the aliased case" {
  cd "$WORKDIR"
  config::load "$EXPLICIT_DEFAULT_CFG"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::reset
  us1::register_present
  summary::start "us1 explicit-default counts"
  reconcile::process_spec "specs/001-sample"

  run summary::count created
  [ "$output" -eq 0 ] || { echo "created=$output (want 0)" >&2; false; }
  run summary::count updated
  [ "$output" -eq 0 ] || { echo "updated=$output (want 0)" >&2; false; }
  run summary::count skipped
  [ "$output" -eq 3 ] || { echo "skipped=$output (want 3)" >&2; false; }
  run summary::count error
  [ "$output" -eq 0 ]
}
