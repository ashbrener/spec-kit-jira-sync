#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/remode_partial_failure.bats  (T033, US4 / FR-009 / R7)
#
# Partial failure mid-prune: when one orphan's DELETE fails (the shim returns a
# 5xx for that key), the re-mode MUST surface it (a warned row naming the key) and
# still prune the other orphans — never abort the whole prune on a single failure
# AFTER the fail-closed read gate passed (R7). A re-run (the failed orphan still
# present in O) retries it: re-mode is resumable / idempotent.
#
# Staging (curl-shim, decision D10): a 3-level board re-moded under a 2-level
# (checklist) mapping makes BOTH phase Subtasks orphans, O = {PROJ-201, PROJ-202}.
# A key-specific standing DELETE rule for PROJ-201 → HTTP 500 is registered BEFORE
# the generic DELETE → 204, so (first-match-wins) PROJ-201's prune fails while
# PROJ-202's succeeds. With JIRA_MAX_RETRIES=0 a 5xx DELETE is not retried and
# jira_rest::delete returns non-zero → prune_artifact rc 1 → remode surfaces +
# continues. Placeholders only (PROJ / example.atlassian.net).
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

  # The current (target) mapping is 2-level: phase + task → checklist, so the
  # board's two phase Subtasks become orphans.
  CONF="$BATS_TEST_TMPDIR/conf-2level.yml"
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
  jira_shim::install
  config::load "$CONF"; config::validate; mapping::parse; mapping::validate
}
teardown() { jira_shim::uninstall; }

# Register the 3-level board (repo Epic + spec Story + 2 phase Subtasks). All
# READ wiring + the regenerate-phase writes; the DELETE wiring is per-test so each
# can stage a different failure key.
_register_3level_board() {
  local slug="repo"

  jq -n --arg l "speckit-repo:${slug}" '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{summary:"Specs — repo",
        labels:[$l],status:{id:"20001"},updated:"2026-05-31T00:00:00.000+0000",
        parent:null}}]}' >"$FX/repo_search.json"
  jq -n --arg l "speckit-repo:${slug}" '{summary:"Specs — repo",description:null,
       labels:[$l],status:{id:"20001"},parent:null}' >"$FX/root_get.json"
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10101",key:"PROJ-101",fields:{summary:"001 — Sample Spec",
        labels:["speckit-spec:001"],status:{id:"20001"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-100"}}}]}' \
    >"$FX/children_of_root.json"
  jq -n '{startAt:0,maxResults:50,total:2,issues:[
       {id:"10201",key:"PROJ-201",fields:{summary:"Phase 1: Setup",
        labels:["task-phase:1"],status:{id:"20001"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-101"}}},
       {id:"10202",key:"PROJ-202",fields:{summary:"Phase 2: Core",
        labels:["task-phase:2"],status:{id:"20001"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-101"}}}]}' \
    >"$FX/children_of_spec.json"
  jq -n '{startAt:0,maxResults:50,total:0,issues:[]}' >"$FX/children_none.json"

  jira_shim::set_response GET "*search/jql*labels%20%3D%20%22speckit-repo*" \
    "$FX/repo_search.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-100%22*" \
    "$FX/children_of_root.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-101%22*" \
    "$FX/children_of_spec.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-201%22*" \
    "$FX/children_none.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-202%22*" \
    "$FX/children_none.json" 200
  jira_shim::set_response GET "*/issue/PROJ-100?fields=*" "$FX/root_get.json" 200

  # Regenerate reads: the present spec Story by label, plus generic transitions.
  jq -n --arg l "speckit-spec:001" '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10101",key:"PROJ-101",fields:{summary:"001 — Sample Spec",
        labels:[$l],status:{id:"20001"},updated:"2026-05-31T00:00:00.000+0000",
        parent:{key:"PROJ-100"}}}]}' >"$FX/story_search.json"
  jira_shim::set_response GET "*search/jql*labels%20%3D%20%22speckit-spec*" \
    "$FX/story_search.json" 200
  jira_shim::set_response GET "*/issue/PROJ-101?fields=*" "$FX/root_get.json" 200
  jira_shim::set_response GET "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
}

# Count DELETEs to a given issue key.
_delete_count_for() {
  local key="$1" reqs; reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | awk -v k="/issue/${key}$" '
    /^METHOD DELETE$/ { d=1; next }
    /^URL / { if (d && $2 ~ k) c++; d=0 }
    END { print c+0 }'
}

# =============================================================================
# FR-009 — one prune fails (5xx), the failure is SURFACED naming the key, and the
# other orphan is still pruned. Then a re-run retries the still-present failure.
# =============================================================================
@test "T033 remode partial-failure: failed prune is surfaced (named) and the other orphan still prunes" {
  cd "$WORKDIR"
  _register_3level_board

  # PROJ-201's DELETE fails (HTTP 500); the generic rule lets PROJ-202 succeed.
  # Register the specific failure rule FIRST (first-match-wins).
  jira_shim::set_response DELETE "*/issue/PROJ-201" "$EMPTY" 500
  jira_shim::set_response DELETE "*/issue/*"        "$EMPTY" 204

  # Run IN-PROCESS (not via `run`, whose subshell would discard the summary
  # state) so the warned rows survive for the surfacing assertion below.
  summary::start "t033-partial"
  reconcile::remode
  rc=$?
  # The re-mode does not abort on a single post-read prune failure (R7): it
  # returns 0 from the function, having surfaced the failure into the summary.
  [ "$rc" -eq 0 ] || { echo "remode exit=$rc" >&2; false; }

  # The failing orphan WAS attempted (a DELETE was issued for it) — not skipped.
  [ "$(_delete_count_for PROJ-201)" -eq 1 ] || { echo "PROJ-201 deletes=$(_delete_count_for PROJ-201) (want 1 attempt)" >&2; jira_shim::requests >&2; false; }
  # The OTHER orphan still pruned (the loop continued past the failure).
  [ "$(_delete_count_for PROJ-202)" -eq 1 ] || { echo "PROJ-202 deletes=$(_delete_count_for PROJ-202) (want 1 success)" >&2; jira_shim::requests >&2; false; }

  # The failure is SURFACED (not silent): emit the summary and assert a warned row
  # names the failed key. FR-008/FR-009 — no removal is silent.
  local emitted; emitted="$(summary::emit 2>&1)"
  printf '%s\n' "$emitted" | grep -qE 'PROJ-201' || { echo "summary did not surface PROJ-201" >&2; printf '%s\n' "$emitted" >&2; false; }
  printf '%s\n' "$emitted" | grep -qiE 'prune of PROJ-201 failed|failed.*PROJ-201|PROJ-201.*failed' \
    || { echo "summary did not surface PROJ-201's prune FAILURE specifically" >&2; printf '%s\n' "$emitted" >&2; false; }

  # Observability: at least one Warned row was counted (the failure).
  [ "$(summary::count warned)" -ge 1 ] || { echo "expected >=1 warned, got $(summary::count warned)" >&2; false; }
}

@test "T033 remode partial-failure: a re-run (orphan still present) RETRIES the failed prune" {
  cd "$WORKDIR"
  _register_3level_board

  # First run: PROJ-201 fails, PROJ-202 succeeds.
  jira_shim::set_response DELETE "*/issue/PROJ-201" "$EMPTY" 500
  jira_shim::set_response DELETE "*/issue/*"        "$EMPTY" 204
  summary::start "t033-run1"
  run reconcile::remode
  [ "$status" -eq 0 ]
  [ "$(_delete_count_for PROJ-201)" -eq 1 ]

  # Re-run models the resumable property: the still-present PROJ-201 reappears in
  # O (live read recomputes the set) and is retried. We re-seed the shim with a
  # board where ONLY PROJ-201 remains a child of the Story (PROJ-202 already
  # pruned) and this time PROJ-201's DELETE succeeds. The recomputed O = {PROJ-201}
  # is retried and converges (R7 / FR-009 resumable).
  jira_shim::reset
  # Now only PROJ-201 remains under the spec Story (PROJ-202 gone after run 1).
  # Register the after-state child search FIRST so it wins over the both-Subtasks
  # rule that _register_3level_board would otherwise install (first-match-wins).
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10201",key:"PROJ-201",fields:{summary:"Phase 1: Setup",
        labels:["task-phase:1"],status:{id:"20001"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-101"}}}]}' \
    >"$FX/children_of_spec_after.json"
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-101%22*" \
    "$FX/children_of_spec_after.json" 200
  _register_3level_board
  jira_shim::set_response DELETE "*/issue/*" "$EMPTY" 204

  summary::start "t033-run2"
  run reconcile::remode
  [ "$status" -eq 0 ] || { echo "remode exit=$status" >&2; printf '%s\n' "$output" >&2; false; }

  # The retry pruned the previously-failed orphan (it was still in O).
  [ "$(_delete_count_for PROJ-201)" -eq 1 ] || { echo "retry PROJ-201 deletes=$(_delete_count_for PROJ-201) (want 1)" >&2; jira_shim::requests >&2; false; }
  # PROJ-202 is already gone → never re-pruned (converged, idempotent).
  [ "$(_delete_count_for PROJ-202)" -eq 0 ] || { echo "PROJ-202 was re-pruned on a converged board" >&2; jira_shim::requests >&2; false; }
}
