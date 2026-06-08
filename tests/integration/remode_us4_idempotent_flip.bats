#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/remode_us4_idempotent_flip.bats  (T031, US4)
#
# US4 — experiment freely, idempotently. Two proofs over the curl-shim
# (decision D10), both vendor-neutral and offline (Principle IX):
#
#  1. NO-SHAPE-CHANGE zero-churn (VR-4 / FR-006 / SC-005): a re-mode run against a
#     board that ALREADY mirrors the current mapping computes O = E \ D = ∅, so it
#     prunes nothing (0 DELETEs) and the regenerate is a pure no-op convergence
#     (0 creates — every desired artifact is already present and matched). This is
#     the "re-mode invoked when nothing actually changed" half of FR-006.
#
#  2. B-state convergence + re-mode-back-to-A (the practical stand-in for a full
#     A→B→A flip, which is impractical to stage entirely offline — see the staging
#     note on the second test). We mirror a board in the B shape (3-level,
#     phase→Subtask) and re-mode under mapping A (2-level checklist): the two phase
#     Subtasks (B residue) are pruned and the board converges to A with no orphans
#     left — the "switches to B and re-modes, then back to A" convergence of AS-1.
#
# Read sequence (same as the US1 harness): repo lookup → enumerate_bridge_descendants
# (root full read + parent=<key> BFS) → prune → regenerate (003 projection).
# Globs disambiguate /search/jql by the URL-encoded JQL fragment. Placeholders
# only (PROJ / example.atlassian.net).
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
}
teardown() { jira_shim::uninstall; }

# Load a config from a written file (the engine's config → mapping pipeline).
_load_config() {
  config::load "$1"; config::validate; mapping::parse; mapping::validate
}

# Write a config heredoc to $1 at the requested mapping shape. $2 = "3level"
# (default phase→Subtask) or "2level" (phase+task→checklist).
_write_config() {
  local out="$1" shape="$2"
  cat > "$out" <<'YAML'
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
  if [[ "$shape" == "2level" ]]; then
    cat >> "$out" <<'YAML'
  mapping:
    levels:
      repo:  { artifact: "Epic",  relationship_to_parent: "none" }
      spec:  { artifact: "Story", relationship_to_parent: "parent" }
      phase: { artifact: "checklist", relationship_to_parent: "checklist" }
      task:  { artifact: "checklist", relationship_to_parent: "checklist" }
YAML
  fi
}

# Register a 3-level board exactly matching the DEFAULT mapping's desired set D =
# {repo Epic, spec Story, phase:1 Subtask, phase:2 Subtask} plus one operator
# issue under the Epic. Under the 3-level config this board IS the desired shape
# (O = ∅); under the 2-level config the two phase Subtasks become orphans.
_register_3level_board() {
  local slug="repo"  # WORKDIR is non-git → remode falls back to basename(pwd).

  jq -n --arg l "speckit-repo:${slug}" '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{summary:"Specs — repo",
        labels:[$l],status:{id:"20006"},updated:"2026-05-31T00:00:00.000+0000",
        parent:null}}]}' >"$FX/repo_search.json"

  jq -n --arg l "speckit-repo:${slug}" '{summary:"Specs — repo",description:null,
       labels:[$l],status:{id:"20006"},parent:null}' >"$FX/root_get.json"

  # children of the repo Epic = the spec Story + an OPERATOR issue.
  jq -n '{startAt:0,maxResults:50,total:2,issues:[
       {id:"10101",key:"PROJ-101",fields:{summary:"001 — Sample Spec",
        labels:["speckit-spec:001"],status:{id:"20001"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-100"}}},
       {id:"10900",key:"PROJ-900",fields:{summary:"Operator chore (lookalike)",
        labels:["backend","needs-review"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-100"}}}]}' \
    >"$FX/children_of_root.json"

  # children of the spec Story = the two phase Subtasks (bridge-owned).
  jq -n '{startAt:0,maxResults:50,total:2,issues:[
       {id:"10201",key:"PROJ-201",fields:{summary:"Phase 1: Setup",
        labels:["task-phase:1"],status:{id:"20001"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-101"}}},
       {id:"10202",key:"PROJ-202",fields:{summary:"Phase 2: Core",
        labels:["task-phase:2"],status:{id:"20001"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-101"}}}]}' \
    >"$FX/children_of_spec.json"

  jq -n '{startAt:0,maxResults:50,total:0,issues:[]}' >"$FX/children_none.json"

  # --- READ wiring (method + url-glob) --------------------------------------
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
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-900%22*" \
    "$FX/children_none.json" 200
  jira_shim::set_response GET "*/issue/PROJ-100?fields=*" "$FX/root_get.json" 200

  # Regenerate-phase reads: the spec Story is found by label and already present.
  jq -n --arg l "speckit-spec:001" '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10101",key:"PROJ-101",fields:{summary:"001 — Sample Spec",
        labels:[$l],status:{id:"20001"},updated:"2026-05-31T00:00:00.000+0000",
        parent:{key:"PROJ-100"}}}]}' >"$FX/story_search.json"
  jira_shim::set_response GET "*search/jql*labels%20%3D%20%22speckit-spec*" \
    "$FX/story_search.json" 200
  jira_shim::set_response GET "*/issue/PROJ-101?fields=*" "$FX/root_get.json" 200
  jira_shim::set_response GET "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200

  # Writes (allowed but asserted-on for zero-churn / convergence).
  jira_shim::set_response POST "*/rest/api/3/issue" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response DELETE "*/issue/*" "$EMPTY" 204
}

# Count DELETEs to a given issue key in the recorded requests.
_delete_count_for() {
  local key="$1" reqs; reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | awk -v k="/issue/${key}$" '
    /^METHOD DELETE$/ { d=1; next }
    /^URL / { if (d && $2 ~ k) c++; d=0 }
    END { print c+0 }'
}

_total_deletes() {
  jira_shim::requests | grep -c '^METHOD DELETE$' || true
}

# Count POSTs that create an issue (POST /rest/api/3/issue, NOT a /transitions).
_issue_creates() {
  jira_shim::requests | awk '
    /^METHOD POST$/ { p=1; next }
    /^URL / { if (p && $2 ~ /\/rest\/api\/3\/issue$/) c++; p=0 }
    END { print c+0 }'
}

# =============================================================================
# 1. NO-SHAPE-CHANGE: D == E ⇒ O = ∅ ⇒ 0 DELETEs and 0 creates (zero churn).
#    VR-4 / FR-006 / SC-005.
# =============================================================================
@test "T031 remode no-change: D==E ⇒ O=∅ ⇒ 0 DELETEs, 0 creates (zero churn)" {
  cd "$WORKDIR"

  # Current config == the shape the board is already in (3-level default).
  CONF="$BATS_TEST_TMPDIR/conf-3level.yml"
  _write_config "$CONF" "3level"
  jira_shim::install
  _load_config "$CONF"
  _register_3level_board

  summary::start "t031-nochange"
  run reconcile::remode
  [ "$status" -eq 0 ] || { echo "remode exit=$status" >&2; printf '%s\n' "$output" >&2; false; }

  # O = ∅: NOTHING is pruned (the load-bearing zero-churn assertion).
  [ "$(_total_deletes)" -eq 0 ] || { echo "expected 0 DELETEs (no shape change), got $(_total_deletes)" >&2; jira_shim::requests >&2; false; }

  # And the regenerate creates NOTHING: every desired artifact is already present
  # and matched, so the projection is a pure no-op convergence.
  [ "$(_issue_creates)" -eq 0 ] || { echo "expected 0 issue creates (zero churn), got $(_issue_creates)" >&2; jira_shim::requests >&2; false; }

  # The operator issue is never touched, regardless.
  [ "$(_delete_count_for PROJ-900)" -eq 0 ]
}

# =============================================================================
# 2. B-STATE + RE-MODE-BACK-TO-A convergence. Staging note: a full A→B→A flip
#    (mirror A, re-mode to B mutating the live board, re-mode back to A) needs the
#    shim to model board mutation BETWEEN runs, which the canned-response shim does
#    not — each run reads a fixed snapshot. We therefore stage the END state of the
#    B→A leg directly: a board left in the B shape (3-level, phase Subtasks present)
#    and the config re-applied as A (2-level checklist). Re-mode must converge it to
#    A — prune the two B-residue Subtasks (O = {PROJ-201, PROJ-202}), leaving no
#    residue from the other shape (AS-1). This is the same convergence the final A
#    leg of an A→B→A flip performs.
# =============================================================================
@test "T031 remode B→A: re-mode under A prunes the B-shape Subtask residue, no orphan left" {
  cd "$WORKDIR"

  # Re-apply mapping A (2-level checklist) over a board still in the B (3-level)
  # shape.
  CONF="$BATS_TEST_TMPDIR/conf-2level.yml"
  _write_config "$CONF" "2level"
  jira_shim::install
  _load_config "$CONF"
  _register_3level_board

  summary::start "t031-b2a"
  run reconcile::remode
  [ "$status" -eq 0 ] || { echo "remode exit=$status" >&2; printf '%s\n' "$output" >&2; false; }

  # Exactly the two phase Subtasks (B residue the A mapping no longer projects)
  # are pruned — once each.
  [ "$(_delete_count_for PROJ-201)" -eq 1 ] || { echo "PROJ-201 deletes=$(_delete_count_for PROJ-201)" >&2; jira_shim::requests >&2; false; }
  [ "$(_delete_count_for PROJ-202)" -eq 1 ] || { echo "PROJ-202 deletes=$(_delete_count_for PROJ-202)" >&2; jira_shim::requests >&2; false; }
  [ "$(_total_deletes)" -eq 2 ] || { echo "total DELETEs=$(_total_deletes) (want 2)" >&2; jira_shim::requests >&2; false; }

  # No residue from the other shape touches the kept artifacts / operator issue.
  [ "$(_delete_count_for PROJ-100)" -eq 0 ]
  [ "$(_delete_count_for PROJ-101)" -eq 0 ]
  [ "$(_delete_count_for PROJ-900)" -eq 0 ]

  # The A mapping folds tasks into the Story body — NO new phase Subtask (10003)
  # is created by the regenerate (no oscillation back toward B).
  if jira_shim::requests | grep -q '"id":"10003"'; then
    echo "a Subtask (10003) was created in the A-shape regenerate" >&2
    jira_shim::requests >&2; false
  fi
}
