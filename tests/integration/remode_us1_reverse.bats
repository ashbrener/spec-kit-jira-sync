#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/remode_us1_reverse.bats  (T015, US1 — checklist→issue)
#
# The REVERSE mode transition: a board mirrored 2-level (the spec Story carries
# an in-body checklist; NO phase child issues) and the config switched to 3-level
# (phase→Subtask). Re-mode must converge the board to the new shape.
#
# C2 FINDING (why this case is distinct from T014): the stale artifact here is
# NOT an issue — it is the in-body checklist sub-tree ON THE KEPT spec Story.
# enumerate_bridge_descendants sees {repo Epic, spec Story}; the 3-level D =
# {repo, spec, phase:1, phase:2}. So O = E \ D = ∅ — there is NOTHING for
# prune_artifact to delete. The stale checklist is removed NOT by a prune call
# but by the REGENERATE step's description-overwrite (the bridge fully owns the
# Story body and rewrites it without the checklist marker), and the per-phase
# child issues are CREATED by the regenerate. This proves the two halves of the
# re-mode (prune the issue orphans, regenerate to converge in-body shape) and
# that a checklist→issue flip needs zero prune calls.
#
# Offline + deterministic; no real coordinates (Principle IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL="https://example.atlassian.net" JIRA_EMAIL="o@e.com" \
         JIRA_API_TOKEN="placeholder" DRY_RUN=0 JIRA_MAX_RETRIES=0
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  WORKDIR="$BATS_TEST_TMPDIR/repo"; mkdir -p "$WORKDIR/specs"
  cp -R "$REPO_ROOT/tests/fixtures/specs/001-sample" "$WORKDIR/specs/001-sample"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX"
  EMPTY="$BATS_TEST_TMPDIR/empty.json"; : >"$EMPTY"
  ARG_QUIET=1

  # The NEW config is 3-level: phase → Subtask (the default mapping).
  CONF="$BATS_TEST_TMPDIR/conf-3level.yml"
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
YAML
  jira_shim::install
  config::load "$CONF"; config::validate; mapping::parse; mapping::validate
}
teardown() { jira_shim::uninstall; }

# Register a 2-level board: repo Epic + spec Story (with an in-body checklist that
# carries the stable marker); NO phase child issues exist yet.
_register_2level_board() {
  local slug="repo"  # WORKDIR is non-git → remode falls back to basename(pwd).

  # The mirrored Story body = prose + an in-body checklist sub-tree (the stale
  # artifact the regenerate must overwrite away).
  local item body prose subtree story_desc
  item="$(workstate::item_for_spec "$WORKDIR/specs/001-sample")"
  body="$(printf '%s' "$item" | jq -r '.body // ""')"
  prose="$(adf::from_markdown "$body")"
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
  subtree="$(adf::render_checklist_subtree "$tasks_json")"
  story_desc="$(jq -cn --argjson prose "$prose" --argjson st "$subtree" \
    '{version:1, type:"doc", content: ((($prose.content) // []) + $st)}')"

  # 1. repo lookup.
  jq -n --arg l "speckit-repo:${slug}" '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{summary:"Specs — repo",labels:[$l],
        status:{id:"10000"},updated:"2026-05-31T00:00:00.000+0000",parent:null}}]}' \
    >"$FX/repo_search.json"
  # 2a. root full read.
  jq -n --arg l "speckit-repo:${slug}" '{summary:"Specs — repo",description:null,
       labels:[$l],status:{id:"10000"},parent:null}' >"$FX/root_get.json"
  # 2b. children of the repo Epic = the spec Story ONLY (2-level: no Subtasks).
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10101",key:"PROJ-101",fields:{summary:"001 — Sample Spec",
        labels:["speckit-spec:001"],status:{id:"20001"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-100"}}}]}' \
    >"$FX/children_of_root.json"
  # 2c. children of the spec Story = NONE (no phase issues in 2-level mode).
  jq -n '{startAt:0,maxResults:50,total:0,issues:[]}' >"$FX/children_none.json"

  # The spec Story present-state (search + full read) carries the stale checklist.
  jq -n --arg desc "x" '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10101",key:"PROJ-101",fields:{summary:"001 — Sample Spec",
        labels:["speckit-spec:001"],status:{id:"20001"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-100"}}}]}' \
    >"$FX/story_search.json"
  jq -n --argjson desc "$story_desc" '{summary:"001 — Sample Spec",
       description:$desc,labels:["speckit-spec:001"],status:{id:"20001"},
       parent:{key:"PROJ-100"}}' >"$FX/story_get.json"

  # --- READ wiring ----------------------------------------------------------
  jira_shim::set_response GET "*search/jql*labels%20%3D%20%22speckit-repo*" \
    "$FX/repo_search.json" 200
  jira_shim::set_response GET "*search/jql*labels%20%3D%20%22speckit-spec*" \
    "$FX/story_search.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-100%22*" \
    "$FX/children_of_root.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-101%22*" \
    "$FX/children_none.json" 200
  jira_shim::set_response GET "*/issue/PROJ-100?fields=*" "$FX/root_get.json" 200
  jira_shim::set_response GET "*/issue/PROJ-101?fields=*" "$FX/story_get.json" 200
  jira_shim::set_response GET "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  # Phase-Subtask searches during regenerate find none (they're being created).
  jira_shim::set_response GET "*search/jql*task-phase*" "$FX/children_none.json" 200
  # Writes.
  jira_shim::set_response POST "*/rest/api/3/issue" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response DELETE "*/issue/*" "$EMPTY" 204
}

@test "T015 remode checklist→issue: NO prune call; new phase child issues created" {
  cd "$WORKDIR"
  _register_2level_board

  summary::start "t015"
  run reconcile::remode
  [ "$status" -eq 0 ] || { echo "remode exit=$status" >&2; printf '%s\n' "$output" >&2; false; }

  local reqs; reqs="$(jira_shim::requests)"

  # C2: O = E \ D = ∅ — zero prune calls (the checklist→issue flip needs none).
  local deletes; deletes="$(printf '%s\n' "$reqs" | grep -c '^METHOD DELETE$' || true)"
  [ "$deletes" -eq 0 ] || { echo "expected 0 DELETEs (no prune on checklist→issue), got $deletes" >&2; printf '%s\n' "$reqs" >&2; false; }

  # New per-phase child issues (Subtask type 10003) ARE created by the regenerate.
  if ! printf '%s\n' "$reqs" | grep -q '"id":"10003"'; then
    echo "expected new phase Subtask (10003) creates in the checklist→issue regenerate" >&2
    printf '%s\n' "$reqs" >&2; false
  fi
}

@test "T015 remode checklist→issue: regenerate overwrites the Story body, dropping the stale checklist marker" {
  cd "$WORKDIR"
  _register_2level_board

  summary::start "t015-body"
  run reconcile::remode
  [ "$status" -eq 0 ]

  local reqs; reqs="$(jira_shim::requests)"

  # The Story body is rewritten by the regenerate. The new 3-level body carries
  # NO in-body checklist marker (the tasks now live in the phase Subtasks). Find
  # the PUT(s) against the Story and assert the marker is gone from the last one.
  local put_body
  put_body="$(printf '%s\n' "$reqs" | awk '
    /^METHOD PUT$/ { p=1; next }
    /^URL / { if (p && $2 ~ /\/issue\/PROJ-101/) { want=1 } else { want=0 } p=0; next }
    /^BODY / { if (want) { sub(/^BODY /,""); last=$0 } }
    END { print last }')"
  if [[ -n "$put_body" ]]; then
    if printf '%s' "$put_body" | grep -qF "$ADF_CHECKLIST_MARKER"; then
      echo "the regenerated Story body still carries the stale checklist marker" >&2
      printf '%s' "$put_body" >&2; false
    fi
  fi
  # And no Story body PUT is the failure case we still tolerate only if the Story
  # was matched as already-correct; but in checklist→issue the body MUST change,
  # so we require at least one Story-targeted PUT.
  local story_puts
  story_puts="$(printf '%s\n' "$reqs" | awk '
    /^METHOD PUT$/ { p=1; next }
    /^URL / { if (p && $2 ~ /\/issue\/PROJ-101/) c++; p=0 }
    END { print c+0 }')"
  [ "$story_puts" -ge 1 ] || { echo "expected the Story body to be overwritten (>=1 PUT to PROJ-101)" >&2; printf '%s\n' "$reqs" >&2; false; }
}
