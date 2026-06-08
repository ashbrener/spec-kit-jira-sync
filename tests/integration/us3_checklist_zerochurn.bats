#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us3_checklist_zerochurn.bats  (T031, US3)
#
# End-to-end (curl-shim, decision D10) proof of 2-level (checklist) mode:
#
#   (1) FRESH — with phase+task→checklist, a reconcile creates ONLY the repo
#       Epic + the spec Story (NO Subtask/Task children); the Story description
#       carries the in-body checklist (taskItem nodes + the stable marker)
#       (spec scenario 1).
#
#   (2) ZERO CHURN — re-running against the already-mirrored Story (its body
#       holds the byte-identical checklist sub-tree) performs ZERO writes
#       (0 creates / 0 PUTs) — the SC-004 2-level arm (spec scenario 2).
#
#   (3) COMPLETION TOGGLE — when a task's done flag flips on disk, exactly ONE
#       PUT updates the Story body; the prose preamble is preserved and the
#       marker appears exactly once (no duplicate checklist) (spec scenario 3).
#
# The already-mirrored Jira state is synthesized from the SAME sink/adf
# composition the writer uses (render_checklist_subtree over the flattened
# phases), so the zero-churn diff is a true zero. Offline + deterministic; no
# real Jira coordinates (Principle IX).
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

  # A 2-level config: phase + task both collapse to the in-body checklist.
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
    spec_prefix: "speckit-spec:"
    repo_prefix: "speckit-repo:"
    phase_prefix: "task-phase:"
    lifecycle_prefix: "phase:"
    task_prefix: "speckit-task:"
  mapping:
    levels:
      repo:  { artifact: "Epic",  relationship_to_parent: "none" }
      spec:  { artifact: "Story", relationship_to_parent: "parent" }
      phase: { artifact: "checklist", relationship_to_parent: "checklist" }
      task:  { artifact: "checklist", relationship_to_parent: "checklist" }
YAML
  config::load "$CONF"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::install

  US3_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$US3_FIXTURES"

  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

# Flatten the spec's phases→tasks the SAME way the sink does (stable
# <phase>.<ordinal> ids), then render the keyed checklist sub-tree.
us3::desired_subtree() {
  local item="$1"
  local tasks_json
  tasks_json="$(printf '%s' "$item" | jq -c '
    [ (.children // []) | to_entries[]
      | (.key) as $i | (.value) as $c
      | ( ($c.id // "") | ([match("[0-9]+$")?][0].string) ) as $cap
      | ($cap // (($i + 1) | tostring)) as $p
      | ($c.extensions.tasks // []) | to_entries[]
      | { id: ($p + "." + (.key | tostring)),
          text: (.value.text // ""),
          done: (.value.done // false) } ]')"
  adf::render_checklist_subtree "$tasks_json"
}

# Synthesize the already-mirrored Story whose description = prose + <subtree>.
# Writes the epic-search, story-search and story-get fixtures and registers the
# shim so every read reports that present state.
us3::register_present() {
  local subtree="$1"

  local item title state body story_summary prose status_id labels
  item="$(workstate::item_for_spec "$WORKDIR/specs/001-sample")"
  title="$(printf '%s' "$item" | jq -r '.title // ""')"
  state="$(printf '%s' "$item" | jq -r '.state // ""')"
  body="$(printf '%s' "$item" | jq -r '.body // ""')"
  story_summary="001 — ${title}"
  prose="$(adf::from_markdown "$body")"
  status_id="$(config::get_status_transition "$state" | cut -f1)"
  labels="$(printf '%s' "$item" | jq -c \
    --arg spec "speckit-spec:001" --arg phase "phase:${state}" \
    '([$spec, $phase] + (.labels // [])) | unique')"

  # The current Story body = prose preamble + the supplied checklist sub-tree.
  local story_desc
  story_desc="$(jq -cn --argjson prose "$prose" --argjson st "$subtree" \
    '{version:1, type:"doc", content: ((($prose.content) // []) + $st)}')"

  jq -n '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{
         summary:"Specs — repo",labels:["speckit-repo:repo"],
         status:{id:"10000",name:"To Do"},updated:"2026-05-31T00:00:00.000+0000"
       }}]}' >"$US3_FIXTURES/epic_search.json"

  jq -n --arg key "PROJ-101" --arg summary "$story_summary" \
    --argjson labels "$labels" --arg status "$status_id" \
    '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10101",key:$key,fields:{
         summary:$summary,labels:$labels,
         status:{id:$status,name:"Mapped"},updated:"2026-05-31T00:00:00.000+0000"
       }}]}' >"$US3_FIXTURES/story_search.json"

  jq -n --arg key "PROJ-101" --arg summary "$story_summary" \
    --argjson desc "$story_desc" --argjson labels "$labels" \
    --arg status "$status_id" --arg epic "PROJ-100" \
    '{id:"10101",key:$key,fields:{
       summary:$summary,description:$desc,labels:$labels,
       status:{id:$status,name:"Mapped"},parent:{key:$epic}
     }}' >"$US3_FIXTURES/story_get.json"

  jira_shim::set_response GET "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response GET "*speckit-repo%3A*" "$US3_FIXTURES/epic_search.json" 200
  jira_shim::set_response GET "*/search/jql*" "$US3_FIXTURES/story_search.json" 200
  jira_shim::set_response GET "*/issue/PROJ-101*" "$US3_FIXTURES/story_get.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
}

# --- (1) FRESH ---------------------------------------------------------------

@test "2-level FRESH: creates ONLY Epic+Story (no Subtasks), checklist in body" {
  cd "$WORKDIR"
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204

  run reconcile::process_spec "specs/001-sample"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"

  # Exactly TWO plain-issue creates: the repo Epic + the spec Story. NO Subtask.
  local creates
  creates="$(printf '%s\n' "$reqs" \
    | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  [ "$creates" -eq 2 ] || {
    echo "expected 2 creates (Epic+Story, no Subtasks), got $creates" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # No Subtask issue type (10003) is posted (no per-phase child issues). NOTE:
  # a plain `grep && {…;false;} || true` would be INERT (the trailing || true
  # swallows the failure) — use an explicit `if` so a regression actually fails.
  if printf '%s\n' "$reqs" | grep -q '"id":"10003"'; then
    echo "a Subtask (10003) was created in 2-level mode" >&2
    printf '%s\n' "$reqs" >&2
    false
  fi

  # The Story body carries the checklist: taskItem nodes + the stable marker.
  printf '%s\n' "$reqs" | grep -q '"taskItem"'
  printf '%s\n' "$reqs" | grep -qF "$ADF_CHECKLIST_MARKER"
}

@test "2-level FRESH: summary reports the in-body checklist skip (no Subtask rows)" {
  cd "$WORKDIR"
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204

  summary::start "us3 fresh"
  reconcile::process_spec "specs/001-sample"

  # The in-body checklist emits a `skipped` row ("tasks rendered in-body … no
  # Subtasks") — proving the sub-issue pass was bypassed (no Subtask child rows).
  run summary::count skipped
  [ "$output" -ge 1 ] || { echo "expected the 2-level in-body skip row, skipped=$output" >&2; false; }

  run summary::count error
  [ "$output" -eq 0 ]
}

# --- (2) ZERO CHURN ----------------------------------------------------------

@test "2-level RE-RUN against an unchanged mirror performs ZERO writes" {
  cd "$WORKDIR"
  local item subtree
  item="$(workstate::item_for_spec "$WORKDIR/specs/001-sample")"
  subtree="$(us3::desired_subtree "$item")"
  us3::register_present "$subtree"

  summary::start "us3 zero-churn"
  run reconcile::process_spec "specs/001-sample"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"

  local creates puts
  creates="$(printf '%s\n' "$reqs" \
    | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  puts="$(printf '%s\n' "$reqs" | grep -c '^METHOD PUT$' || true)"
  [ "$creates" -eq 0 ] || { echo "expected 0 creates, got $creates" >&2; printf '%s\n' "$reqs" >&2; false; }
  [ "$puts" -eq 0 ] || { echo "expected 0 PUTs (zero churn), got $puts" >&2; printf '%s\n' "$reqs" >&2; false; }
}

@test "2-level RE-RUN summary reports 0 created / 0 updated" {
  cd "$WORKDIR"
  local item subtree
  item="$(workstate::item_for_spec "$WORKDIR/specs/001-sample")"
  subtree="$(us3::desired_subtree "$item")"
  us3::register_present "$subtree"

  summary::start "us3 zero-churn"
  reconcile::process_spec "specs/001-sample"

  run summary::count created
  [ "$output" -eq 0 ] || { echo "created=$output (want 0)" >&2; false; }
  run summary::count updated
  [ "$output" -eq 0 ] || { echo "updated=$output (want 0)" >&2; false; }
}

# --- (3) COMPLETION TOGGLE ---------------------------------------------------

@test "2-level TOGGLE: one PUT updates the body, preamble preserved, no dup checklist" {
  cd "$WORKDIR"
  # The MIRRORED state holds a checklist where EVERY task is DONE; the disk
  # (the fixture) has at least one task NOT done, so exactly the Story body is
  # owed one update.
  local item all_done_subtree
  item="$(workstate::item_for_spec "$WORKDIR/specs/001-sample")"
  local all_done_tasks
  all_done_tasks="$(printf '%s' "$item" | jq -c '
    [ (.children // []) | to_entries[]
      | (.key) as $i | (.value) as $c
      | ( ($c.id // "") | ([match("[0-9]+$")?][0].string) ) as $cap
      | ($cap // (($i + 1) | tostring)) as $p
      | ($c.extensions.tasks // []) | to_entries[]
      | { id: ($p + "." + (.key | tostring)),
          text: (.value.text // ""),
          done: true } ]')"
  all_done_subtree="$(adf::render_checklist_subtree "$all_done_tasks")"
  us3::register_present "$all_done_subtree"

  summary::start "us3 toggle"
  run reconcile::process_spec "specs/001-sample"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"

  # NO create (Story matched, not re-created).
  local creates
  creates="$(printf '%s\n' "$reqs" \
    | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  [ "$creates" -eq 0 ] || { echo "expected 0 creates on toggle, got $creates" >&2; printf '%s\n' "$reqs" >&2; false; }

  # Exactly ONE PUT (the Story description), and it carries the checklist.
  local puts
  puts="$(printf '%s\n' "$reqs" | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 1 ] || { echo "expected exactly 1 PUT, got $puts" >&2; printf '%s\n' "$reqs" >&2; false; }

  # The PUT body preserves the prose preamble AND carries the marker EXACTLY once
  # (no duplicate checklist appended).
  local put_body markers
  put_body="$(printf '%s\n' "$reqs" | sed -n 's/^BODY //p' | tail -1)"
  printf '%s' "$put_body" | jq -e '.fields.description.content[0].content[0].text != null'
  markers="$(printf '%s' "$put_body" | jq --arg m "$ADF_CHECKLIST_MARKER" \
    '[.fields.description.content[] | select(.type=="paragraph") | select(([.content[]?.text]|join(""))==$m)] | length')"
  [ "$markers" -eq 1 ] || { echo "expected exactly 1 marker (no dup checklist), got $markers" >&2; printf '%s' "$put_body" >&2; false; }
}
