#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us_fullstack_nondefault_zerochurn.bats  (T056, US3 / SC-004)
#
# The full-stack analogue of the sink-level zero-churn assertions: a configured
# NON-DEFAULT shape (custom identity-label prefixes + an operator label on the
# spec, projected through the WIRED engine `process_spec`), then a re-run against
# the already-mirrored board, asserts **0 created / 0 updated (PUT) / 0
# transition across every parent-bearing level** (repo Epic, spec Story, phase
# Subtasks). Proves the unified engine drive is byte-for-byte idempotent for a
# non-default mapping, not only the default.
#
# The already-mirrored state is synthesized from the SAME engine composition
# (`compose_payload` + the sink render), so the desired-vs-current diff is a true
# zero. Offline + deterministic; no real coordinates (Principle IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL="https://example.atlassian.net" JIRA_EMAIL="o@e.com" \
         JIRA_API_TOKEN="placeholder" DRY_RUN=0 JIRA_MAX_RETRIES=0

  WORKDIR="$BATS_TEST_TMPDIR/repo"; mkdir -p "$WORKDIR/specs"
  cp -R "$REPO_ROOT/tests/fixtures/specs/001-sample" "$WORKDIR/specs/001-sample"
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  # NON-DEFAULT shape: custom identity-label prefixes (not the speckit-* defaults).
  CONF="$BATS_TEST_TMPDIR/jira-config.yml"
  cat > "$CONF" <<'YAML'
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
    spec_prefix: "feat-spec/"
    repo_prefix: "feat-repo/"
    phase_prefix: "feat-phase/"
    lifecycle_prefix: "lc/"
YAML
  config::load "$CONF"; config::validate; mapping::parse; mapping::validate
  jira_shim::install

  # --- Synthesize the already-mirrored Jira state from the engine composition ---
  local item title state body
  item="$(workstate::item_for_spec "$WORKDIR/specs/001-sample")"
  title="$(printf '%s' "$item" | jq -r '.title // ""')"
  state="$(printf '%s' "$item" | jq -r '.state // ""')"
  body="$(printf '%s' "$item" | jq -r '.body // ""')"

  local spec_payload story_summary story_desc story_labels status_id
  spec_payload="$(reconcile::compose_payload spec "$item" "repo")"
  story_summary="$(printf '%s' "$spec_payload" | jq -r '.summary')"
  story_desc="$(adf::from_markdown "$body")"
  # Desired Story labels = the identity (feat-spec/001) ∪ the payload labels.
  story_labels="$(printf '%s' "$spec_payload" | jq -c '([("feat-spec/001")] + (.labels // [])) | unique')"
  status_id="$(config::get_status_transition "$state" | cut -f1)"

  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX"
  jq -n '{startAt:0,maxResults:50,total:1,issues:[{id:"10100",key:"PROJ-100",fields:{
       summary:"Specs — repo",labels:["feat-repo/repo"],status:{id:"10000"},
       updated:"2026-05-31T00:00:00.000+0000"}}]}' >"$FX/epic_search.json"
  jq -n --arg s "$story_summary" --argjson l "$story_labels" --arg st "$status_id" \
    '{startAt:0,maxResults:50,total:1,issues:[{id:"10101",key:"PROJ-101",fields:{
       summary:$s,labels:$l,status:{id:$st},updated:"2026-05-31T00:00:00.000+0000"}}]}' >"$FX/story_search.json"
  jq -n --arg s "$story_summary" --argjson d "$story_desc" --argjson l "$story_labels" \
    --arg st "$status_id" '{id:"10101",key:"PROJ-101",fields:{summary:$s,description:$d,
       labels:$l,status:{id:$st},parent:{key:"PROJ-100"}}}' >"$FX/story_get.json"

  local n i
  n="$(printf '%s' "$item" | jq -r '(.children // []) | length')"
  for (( i = 0; i < n; i++ )); do
    local child ctitle pidx pp psum ptasks pdesc
    child="$(printf '%s' "$item" | jq -c --argjson k "$i" '.children[$k]')"
    pidx="$(( i + 1 ))"
    pp="$(reconcile::compose_payload phase "$item" "" "$pidx")"
    psum="$(printf '%s' "$pp" | jq -r '.summary')"
    ptasks="$(printf '%s' "$pp" | jq -c '.tasks // []')"
    pdesc="$(jq -cn --argjson tl "$(adf::task_list "$ptasks")" '{version:1,type:"doc",content:[$tl]}')"
    jq -n --arg s "$psum" --arg l "feat-phase/${pidx}" \
      '{startAt:0,maxResults:50,total:1,issues:[{id:("201"+($l|ltrimstr("feat-phase/"))),
         key:("SUB-"+($l|ltrimstr("feat-phase/"))),fields:{summary:$s,labels:[$l]}}]}' >"$FX/sub${pidx}_search.json"
    jq -n --arg s "$psum" --argjson d "$pdesc" --arg l "feat-phase/${pidx}" \
      '{key:("SUB-"+($l|ltrimstr("feat-phase/"))),fields:{summary:$s,description:$d,labels:[$l]}}' >"$FX/sub${pidx}_get.json"
  done

  ARG_QUIET=1
}
teardown() { jira_shim::uninstall; }

_register_present() {
  jira_shim::set_response GET "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response GET "*feat-phase%2F1*" "$FX/sub1_search.json" 200
  jira_shim::set_response GET "*feat-phase%2F2*" "$FX/sub2_search.json" 200
  jira_shim::set_response GET "*feat-repo%2F*" "$FX/epic_search.json" 200
  jira_shim::set_response GET "*/search/jql*" "$FX/story_search.json" 200
  jira_shim::set_response GET "*/issue/SUB-1*" "$FX/sub1_get.json" 200
  jira_shim::set_response GET "*/issue/SUB-2*" "$FX/sub2_get.json" 200
  jira_shim::set_response GET "*/issue/PROJ-101*" "$FX/story_get.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
}

@test "non-default shape RE-RUN through the wired engine: 0 created / 0 PUT / 0 transition" {
  cd "$WORKDIR"
  _register_present
  summary::start "t056"
  run reconcile::process_spec "specs/001-sample"
  [ "$status" -eq 0 ]

  local reqs creates puts trans
  reqs="$(jira_shim::requests)"
  creates="$(printf '%s\n' "$reqs" | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  puts="$(printf '%s\n' "$reqs" | grep -c '^METHOD PUT$' || true)"
  trans="$(printf '%s\n' "$reqs" | grep -c '/transitions$' || true)"
  [ "$creates" -eq 0 ] || { echo "creates=$creates (want 0)" >&2; printf '%s\n' "$reqs" >&2; false; }
  [ "$puts" -eq 0 ]    || { echo "PUTs=$puts (want 0)" >&2; printf '%s\n' "$reqs" >&2; false; }
  [ "$trans" -eq 0 ]   || { echo "transitions=$trans (want 0)" >&2; printf '%s\n' "$reqs" >&2; false; }
}

@test "non-default shape RE-RUN reports 0 created / 0 updated (all skipped)" {
  cd "$WORKDIR"
  _register_present
  summary::start "t056"
  reconcile::process_spec "specs/001-sample"
  run summary::count created; [ "$output" -eq 0 ] || { echo "created=$output" >&2; false; }
  run summary::count updated; [ "$output" -eq 0 ] || { echo "updated=$output" >&2; false; }
}
