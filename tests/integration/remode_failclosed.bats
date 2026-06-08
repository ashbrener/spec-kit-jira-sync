#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/remode_failclosed.bats  (T032/T034, US4 / FR-005 / SC-006)
#
# Fail-closed: an unreadable Jira read during the re-mode read-phase MUST abort the
# operation BEFORE any destructive write — never a partial destruction on an
# unreadable read (R6). We exercise each read that builds E/D and assert ZERO
# DELETEs occur when it fails:
#
#   1. the repo lookup (query_spec_issue) is unreadable;
#   2. query_issue_full(root) inside enumerate_bridge_descendants is unreadable;
#   3. a parent=<key> BFS search inside enumerate is unreadable mid-walk.
#
# Each unreadable read maps to rc 3 in the sink (a non-2xx with JIRA_MAX_RETRIES=0,
# or a malformed body), which compute_orphans / remode propagate as a fail-closed
# abort. The generic DELETE rule is wired to 204 in every case, so any prune that
# DID fire would be recorded — the assertion that NONE fired is the SC-006
# guarantee. Placeholders only (PROJ / example.atlassian.net).
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
  # An intentionally MALFORMED body — a read returning this is unreadable (the
  # sink cannot parse it → rc 3 → fail closed), used for the parse-failure case.
  GARBAGE="$BATS_TEST_TMPDIR/garbage.json"; printf 'not-json{' >"$GARBAGE"
  ARG_QUIET=1

  # A target mapping (2-level checklist) under which the board's two phase
  # Subtasks WOULD be orphans — so a non-fail-closed run would prune them. The
  # fail-closed abort must prevent that.
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

# Build all the OK read fixtures for a healthy 3-level board (repo Epic + spec
# Story + 2 phase Subtasks). Individual tests then OVERRIDE exactly one read with
# an unreadable response — but, crucially, register that override FIRST so it wins
# (first-match-wins standing rules).
_ok_board_fixtures() {
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
}

# Wire the standing OK reads (used as the fallback after a per-test override). The
# generic DELETE → 204 is ALWAYS wired so any prune that fired is recorded.
_wire_ok_reads_and_delete() {
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
  # Regenerate-phase reads/writes (should never be reached on a fail-closed abort,
  # but wired so a regression that proceeds is caught by the DELETE assertion, not
  # a missing-rule crash).
  jira_shim::set_response GET "*search/jql*labels%20%3D%20%22speckit-spec*" \
    "$FX/children_of_root.json" 200
  jira_shim::set_response GET "*/issue/PROJ-101?fields=*" "$FX/root_get.json" 200
  jira_shim::set_response GET "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  # The destructive DELETE — wired to SUCCEED, so any prune that fires is recorded
  # and the zero-DELETE assertion is meaningful (no prune may precede the abort).
  jira_shim::set_response DELETE "*/issue/*" "$EMPTY" 204
}

_total_deletes() {
  jira_shim::requests | grep -c '^METHOD DELETE$' || true
}

# =============================================================================
# 1. The repo lookup (query_spec_issue) is unreadable → abort, ZERO DELETEs.
# =============================================================================
@test "T032 remode fail-closed: unreadable repo lookup aborts with 0 destructive writes" {
  cd "$WORKDIR"
  _ok_board_fixtures
  # Override the repo lookup with an unreadable (HTTP 500) response — FIRST so it
  # wins over the OK rule below.
  jira_shim::set_response GET "*search/jql*labels%20%3D%20%22speckit-repo*" \
    "$EMPTY" 500
  _wire_ok_reads_and_delete

  summary::start "t032-repo"
  run reconcile::remode
  # Fail-closed: the function returns non-zero and promotes exit 3 (no prune).
  [ "$status" -ne 0 ] || { echo "expected non-zero (fail-closed abort)" >&2; printf '%s\n' "$output" >&2; false; }
  [ "$(_total_deletes)" -eq 0 ] || { echo "expected 0 DELETEs (fail-closed), got $(_total_deletes)" >&2; jira_shim::requests >&2; false; }
}

# =============================================================================
# 2. query_issue_full(root) inside enumerate is unreadable → abort, 0 DELETEs.
# =============================================================================
@test "T032 remode fail-closed: unreadable root full-read aborts with 0 destructive writes" {
  cd "$WORKDIR"
  _ok_board_fixtures
  # The repo lookup succeeds (so we reach enumerate), but the root full read is a
  # parse-failure (malformed body) → rc 3 → fail closed. Register the override
  # FIRST.
  jira_shim::set_response GET "*/issue/PROJ-100?fields=*" "$GARBAGE" 200
  _wire_ok_reads_and_delete

  summary::start "t032-root"
  run reconcile::remode
  [ "$status" -ne 0 ] || { echo "expected non-zero (fail-closed abort)" >&2; printf '%s\n' "$output" >&2; false; }
  [ "$(_total_deletes)" -eq 0 ] || { echo "expected 0 DELETEs (fail-closed), got $(_total_deletes)" >&2; jira_shim::requests >&2; false; }
}

# =============================================================================
# 3. A parent=<key> BFS search is unreadable mid-walk → abort, 0 DELETEs.
#    This is the load-bearing R6 case: the orphan-bearing level (children of the
#    spec Story) is exactly the read that fails, so a non-fail-closed engine would
#    have an INCOMPLETE E and could mis-prune. It must abort with zero writes.
# =============================================================================
@test "T034 remode fail-closed: unreadable BFS child-search aborts with 0 destructive writes" {
  cd "$WORKDIR"
  _ok_board_fixtures
  # The children-of-Story search (the level that holds the would-be orphans) is
  # unreadable (HTTP 500) → rc 3 mid-enumerate → fail closed. Override FIRST.
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-101%22*" \
    "$EMPTY" 500
  _wire_ok_reads_and_delete

  # Run IN-PROCESS (not via `run`, whose subshell would discard the summary
  # state) so the warned row survives for the surfacing assertion below.
  summary::start "t034-bfs"
  reconcile::remode || rc=$?
  [ "${rc:-0}" -ne 0 ] || { echo "expected non-zero (fail-closed abort)" >&2; false; }
  [ "$(_total_deletes)" -eq 0 ] || { echo "expected 0 DELETEs (fail-closed), got $(_total_deletes)" >&2; jira_shim::requests >&2; false; }

  # The abort is SURFACED (not silent): a warned row names the fail-closed abort.
  local emitted; emitted="$(summary::emit 2>&1)"
  printf '%s\n' "$emitted" | grep -qiE 'fail-closed|unreadable|aborted' \
    || { echo "fail-closed abort was not surfaced in the summary" >&2; printf '%s\n' "$emitted" >&2; false; }
}
