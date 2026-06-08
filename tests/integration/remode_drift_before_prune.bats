#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/remode_drift_before_prune.bats  (T019, US1 — FR-010)
#
# Backward-drift-before-prune: before a to-be-pruned bridge-owned orphan is
# deleted, the re-mode surfaces a WARNING when the orphan's tracker `updated`
# timestamp is meaningfully newer than the disk baseline (the newest in-scope
# spec-dir commit / WORKSTATE_LAST_COMMIT_ISO) — the neutral signal that a human
# edited the artifact since the source-of-truth was last committed. Under
# `--on-drift=abort` the drifted orphan is LEFT IN PLACE (not pruned), surfaced;
# the default disposition warns-and-proceeds (Principle IV — surface, don't
# block). A non-drifted orphan is pruned silently.
#
# Board: 3-level mirror, config switched to 2-level (phase→checklist) so the two
# phase Subtasks are orphans. One Subtask (PROJ-202) carries a recent `updated`
# (human-edited); the other (PROJ-201) is at the disk baseline (untouched).
# Offline + deterministic; no real coordinates (Principle IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL="https://example.atlassian.net" JIRA_EMAIL="o@e.com" \
         JIRA_API_TOKEN="placeholder" DRY_RUN=0 JIRA_MAX_RETRIES=0
  # Disk baseline = this commit time; PROJ-201 sits exactly here, PROJ-202 is
  # hours ahead (a human edit after the last commit).
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  WORKDIR="$BATS_TEST_TMPDIR/repo"; mkdir -p "$WORKDIR/specs"
  cp -R "$REPO_ROOT/tests/fixtures/specs/001-sample" "$WORKDIR/specs/001-sample"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX"
  EMPTY="$BATS_TEST_TMPDIR/empty.json"; : >"$EMPTY"
  ARG_QUIET=1

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

  # Board reads. PROJ-202 carries a recent `updated` (human-edited orphan).
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{summary:"Specs — repo",
        labels:["speckit-repo:repo"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:null}}]}' >"$FX/repo_search.json"
  jq -n '{summary:"Specs — repo",description:null,labels:["speckit-repo:repo"],
       status:{id:"10000"},parent:null}' >"$FX/root_get.json"
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10101",key:"PROJ-101",fields:{summary:"001 — Sample Spec",
        labels:["speckit-spec:001"],status:{id:"20001"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-100"}}}]}' \
    >"$FX/children_of_root.json"
  jq -n '{startAt:0,maxResults:50,total:2,issues:[
       {id:"10201",key:"PROJ-201",fields:{summary:"Phase 1",
        labels:["task-phase:1"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-101"}}},
       {id:"10202",key:"PROJ-202",fields:{summary:"Phase 2 (human-edited)",
        labels:["task-phase:2"],status:{id:"10000"},
        updated:"2026-05-31T06:00:00.000+0000",parent:{key:"PROJ-101"}}}]}' \
    >"$FX/children_of_spec.json"
  jq -n '{startAt:0,maxResults:50,total:0,issues:[]}' >"$FX/children_none.json"

  jira_shim::set_response GET "*search/jql*labels%20%3D%20%22speckit-repo*" \
    "$FX/repo_search.json" 200
  jira_shim::set_response GET "*search/jql*labels%20%3D%20%22speckit-spec*" \
    "$FX/children_of_root.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-100%22*" \
    "$FX/children_of_root.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-101%22*" \
    "$FX/children_of_spec.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-20*" \
    "$FX/children_none.json" 200
  jira_shim::set_response GET "*/issue/PROJ-100?fields=*" "$FX/root_get.json" 200
  jira_shim::set_response GET "*/issue/PROJ-101?fields=*" "$FX/root_get.json" 200
  jira_shim::set_response GET "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response DELETE "*/issue/*" "$EMPTY" 204
}
teardown() { jira_shim::uninstall; }

_delete_count_for() {
  local key="$1"; jira_shim::requests | awk -v k="/issue/${key}$" '
    /^METHOD DELETE$/ { d=1; next }
    /^URL / { if (d && $2 ~ k) c++; d=0 }
    END { print c+0 }'
}

@test "T019 default disposition: human-edited orphan is WARNED but still pruned" {
  cd "$WORKDIR"
  ARG_ON_DRIFT=""

  summary::start "t019-default"
  run reconcile::remode
  [ "$status" -eq 0 ]
  # Both Subtasks pruned (the warned one proceeds under the default disposition).
  [ "$(_delete_count_for PROJ-201)" -eq 1 ]
  [ "$(_delete_count_for PROJ-202)" -eq 1 ]

  # The human-edit WARNING names the drifted orphan.
  summary::start "t019-default-warn"
  reconcile::remode
  run summary::count warned
  [ "$output" -ge 1 ] || { echo "expected a backward-drift WARNING (warned>=1)" >&2; false; }
}

@test "T019 --on-drift=abort: human-edited orphan is LEFT IN PLACE; the clean orphan still pruned" {
  cd "$WORKDIR"
  ARG_ON_DRIFT="abort"

  summary::start "t019-abort"
  run reconcile::remode
  [ "$status" -eq 0 ]

  # The drifted orphan (PROJ-202) is NOT deleted; the untouched one (PROJ-201) is.
  [ "$(_delete_count_for PROJ-202)" -eq 0 ] || { echo "PROJ-202 (human-edited) was pruned under --on-drift=abort" >&2; jira_shim::requests >&2; false; }
  [ "$(_delete_count_for PROJ-201)" -eq 1 ] || { echo "PROJ-201 (clean orphan) was NOT pruned" >&2; jira_shim::requests >&2; false; }
}

@test "T019 --on-drift=abort: a skipped row surfaces the left-in-place orphan" {
  cd "$WORKDIR"
  ARG_ON_DRIFT="abort"

  summary::start "t019-abort-skip"
  reconcile::remode
  run summary::count skipped
  [ "$output" -ge 1 ] || { echo "expected a skipped row for the left-in-place orphan" >&2; false; }
}
