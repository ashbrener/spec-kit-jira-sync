#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/remode_us2_failsafe_scoping.bats  (T020–T025, US2)
#
# The ADVERSARIAL fail-safe-scoping suite — the SINGLE load-bearing safety net
# for feature 004. Destruction is destructive-by-default behind --remode (no
# separate confirm; see spec Clarifications 2026-06-08), so the label-scoped
# orphan diff (FR-002/FR-015) is the only thing standing between a mapping
# experiment and an operator's irreplaceable work. This file drives
# `reconcile::remode` through the curl-shim (decision D10) over a board that
# DELIBERATELY mixes bridge-owned orphans with operator issues placed to trip a
# weak scoper, and proves SC-002: ZERO operator issues are ever DELETEd.
#
# The board (2-level config: phase→checklist, so the phase Subtasks ARE orphans
# the current mapping no longer projects). D = {speckit-repo:repo,
# speckit-spec:001}. E = the bridge-owned subtree. O = E \ D:
#
#   PROJ-100  repo Epic        speckit-repo:repo     KEPT (root, in D)
#   ├─ PROJ-101 spec Story      speckit-spec:001      KEPT (in D)
#   │  ├─ PROJ-201 phase Subtask task-phase:1         ORPHAN → pruned
#   │  ├─ PROJ-202 phase Subtask task-phase:2         ORPHAN → pruned
#   │  ├─ PROJ-204 STALE family  speckit-task:legacy-3 ORPHAN → pruned (T024)
#   │  └─ PROJ-902 OPERATOR      [chore]  (lookalike) NEVER (no identity)  (T020/21)
#   ├─ PROJ-900 OPERATOR         [backend]            NEVER (no identity)  (T020)
#   ├─ PROJ-901 OPERATOR         [needs-triage]       NEVER (no identity)  (T021)
#   │            summary "Phase 1: Setup" — a LOOKALIKE of the bridge Subtask
#   └─ PROJ-905 OPERATOR-OPTED-IN speckit-spec:999     ORPHAN → pruned (T023)
#                manually-applied identity label ⇒ bridge-owned by the identity
#                contract (spec Assumptions / edge case), and absent from D, so
#                it is pruned — the documented consequence of opting in.
#
# T020 — operator issue UNDER THE SAME repo Epic / spec Story as the orphans is
#        never deleted or modified.
# T021 — operator issue with a LOOKALIKE summary / same conceptual type as a
#        bridge artifact, but no identity label, is untouched.
# T022 — an issue with NO identity label is never pruned/relabeled regardless of
#        summary / parent / type (the structural FR-002 guarantee).
# T023 — an operator who MANUALLY applied a speckit-* identity label is treated
#        as bridge-owned (opted in) — asserted as the identity-contract
#        consequence (it IS pruned because its identity is not in D).
# T024 — a STALE prior-shape identity family (speckit-task:legacy-3 — a value the
#        current mapping never mints) is still recognized as bridge-owned via the
#        prefix match and pruned.
# T025 — SC-002 roll-up: across the whole run, the count of DELETEs to operator
#        keys is ZERO, and the total DELETE set is EXACTLY the intended orphans.
#
# Offline + deterministic; placeholders only (Principle IX): PROJ /
# example.atlassian.net, no real coordinates.
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

  # The board is mirrored 3-level but the CURRENT config is 2-level
  # (phase→checklist + task→checklist), so the phase issues are orphans.
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

# WORKDIR is not a git repo, so remode falls back to basename "$(pwd)" = "repo".
_repo_slug() { printf 'repo'; }

# -----------------------------------------------------------------------------
# Register the adversarial board against the read endpoints (method + url-glob).
# The read sequence remode exercises:
#   query_spec_issue(repo)          GET /search/jql?…labels = "speckit-repo:repo"…
#   enumerate_bridge_descendants:
#     query_issue_full(root)        GET /issue/PROJ-100?fields=…
#     BFS parent = "<key>"          GET /search/jql?…parent = "<key>"…
# -----------------------------------------------------------------------------
_register_adversarial_board() {
  local slug; slug="$(_repo_slug)"

  # 1. repo lookup → the repo Epic.
  jq -n --arg l "speckit-repo:${slug}" '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{summary:"Specs — repo",
        labels:[$l],status:{id:"10000"},updated:"2026-05-31T00:00:00.000+0000",
        parent:null}}]}' >"$FX/repo_search.json"

  # 2a. query_issue_full(root) — the repo Epic, no parent (no C1 super-level).
  jq -n --arg l "speckit-repo:${slug}" '{summary:"Specs — repo",description:null,
       labels:[$l],status:{id:"10000"},parent:null}' >"$FX/root_get.json"

  # 2b. children of the repo Epic: the spec Story (bridge), TWO operator issues
  #     directly under the same Epic (no identity), and an operator-opted-in
  #     issue carrying a MANUALLY-applied speckit-spec:999 identity label.
  jq -n '{startAt:0,maxResults:50,total:4,issues:[
       {id:"10101",key:"PROJ-101",fields:{summary:"001 — Sample Spec",
        labels:["speckit-spec:001"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-100"}}},
       {id:"10900",key:"PROJ-900",fields:{summary:"Operator backend chore",
        labels:["backend"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-100"}}},
       {id:"10901",key:"PROJ-901",fields:{summary:"Phase 1: Setup",
        labels:["needs-triage"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-100"}}},
       {id:"10905",key:"PROJ-905",fields:{summary:"Operator-owned, mislabeled",
        labels:["speckit-spec:999"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-100"}}}]}' \
    >"$FX/children_of_root.json"

  # 2c. children of the spec Story: the two phase Subtasks (bridge orphans), a
  #     STALE prior-shape identity family member (speckit-task:legacy-3), and an
  #     OPERATOR issue with a lookalike summary but no identity label.
  jq -n '{startAt:0,maxResults:50,total:4,issues:[
       {id:"10201",key:"PROJ-201",fields:{summary:"Phase 1: Setup",
        labels:["task-phase:1"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-101"}}},
       {id:"10202",key:"PROJ-202",fields:{summary:"Phase 2: Core",
        labels:["task-phase:2"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-101"}}},
       {id:"10204",key:"PROJ-204",fields:{summary:"Legacy task item",
        labels:["speckit-task:legacy-3"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-101"}}},
       {id:"10902",key:"PROJ-902",fields:{summary:"Phase 3: Extra (operator)",
        labels:["chore"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-101"}}}]}' \
    >"$FX/children_of_spec.json"

  # leaf parents (bridge orphans + the opted-in issue) return no children.
  jq -n '{startAt:0,maxResults:50,total:0,issues:[]}' >"$FX/children_none.json"

  # --- READ wiring (method + url-glob, most-specific first) ------------------
  jira_shim::set_response GET "*search/jql*labels%20%3D%20%22speckit-repo*" \
    "$FX/repo_search.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-100%22*" \
    "$FX/children_of_root.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-101%22*" \
    "$FX/children_of_spec.json" 200
  # bridge-owned leaves the BFS recurses into → no children.
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-201%22*" \
    "$FX/children_none.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-202%22*" \
    "$FX/children_none.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-204%22*" \
    "$FX/children_none.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-905%22*" \
    "$FX/children_none.json" 200
  # operator issues are NOT bridge-owned, so the BFS never recurses into them;
  # wire their parent searches defensively to none anyway (must never be hit).
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-900%22*" \
    "$FX/children_none.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-901%22*" \
    "$FX/children_none.json" 200
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-902%22*" \
    "$FX/children_none.json" 200
  # query_issue_full(root).
  jira_shim::set_response GET "*/issue/PROJ-100?fields=*" "$FX/root_get.json" 200

  # --- REGENERATE wiring (mirror US1 T014): the spec Story is already mirrored,
  #     so the regenerate is near-zero; allow its reads + any writes.
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
  # The destructive prune (hard-delete default).
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

# Count ANY non-GET request (write: PUT/POST/DELETE) targeting a given issue key.
# Used to prove an operator issue is never MODIFIED (relabeled/edited), not just
# never deleted.
_write_count_for() {
  local key="$1" reqs; reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | awk -v k="/issue/${key}([?/]|$)" '
    /^METHOD / { m=$2; next }
    /^URL / { if (m != "GET" && $2 ~ k) c++ }
    END { print c+0 }'
}

# Run remode and require exit 0 (shared preamble).
_run_remode_ok() {
  cd "$WORKDIR"
  _register_adversarial_board
  summary::start "us2-failsafe"
  run reconcile::remode
  [ "$status" -eq 0 ] || { echo "remode exit=$status" >&2; printf '%s\n' "$output" >&2; \
    jira_shim::requests >&2; false; }
}

# =============================================================================
# T020 — operator issue UNDER THE SAME parent as bridge orphans is never touched.
# =============================================================================
@test "T020 operator issue under the same Epic/Story as orphans is never deleted or modified" {
  _run_remode_ok

  # PROJ-900 sits directly under the repo Epic alongside the (kept) spec Story.
  # PROJ-902 sits under the spec Story alongside the pruned phase Subtasks.
  for k in PROJ-900 PROJ-902; do
    [ "$(_delete_count_for "$k")" -eq 0 ] || { echo "$k was DELETEd" >&2; jira_shim::requests >&2; false; }
    [ "$(_write_count_for  "$k")" -eq 0 ] || { echo "$k was modified (write)" >&2; jira_shim::requests >&2; false; }
  done

  # The bridge orphans sharing those parents ARE pruned (proves the scoping is
  # discriminating, not just inert).
  [ "$(_delete_count_for PROJ-201)" -eq 1 ]
  [ "$(_delete_count_for PROJ-202)" -eq 1 ]
}

# =============================================================================
# T021 — lookalike summary / same conceptual type, no identity label → untouched.
# =============================================================================
@test "T021 operator issue with a lookalike summary / same type as a bridge artifact is untouched" {
  _run_remode_ok

  # PROJ-901 carries the EXACT summary of a bridge phase Subtask ("Phase 1:
  # Setup") and sits as a sibling-adjacent issue, but has no identity label.
  # PROJ-902 mimics a "Phase 3" task under the spec Story. Neither is touched.
  for k in PROJ-901 PROJ-902; do
    [ "$(_delete_count_for "$k")" -eq 0 ] || { echo "$k (lookalike) was DELETEd" >&2; jira_shim::requests >&2; false; }
    [ "$(_write_count_for  "$k")" -eq 0 ] || { echo "$k (lookalike) was modified" >&2; jira_shim::requests >&2; false; }
  done
}

# =============================================================================
# T022 — NO identity label ⇒ never pruned/relabeled regardless of summary/parent/
#        type. The structural FR-002 guarantee (is_bridge_owned excludes them
#        from E, so they can never enter O).
# =============================================================================
@test "T022 an issue with no identity label is never pruned or relabeled, whatever its summary/parent/type" {
  _run_remode_ok

  # All three operator issues — varied parents (Epic vs Story), varied summaries
  # (plain, lookalike, phase-mimic), no identity label — are structurally
  # excluded from the prune set.
  for k in PROJ-900 PROJ-901 PROJ-902; do
    [ "$(_delete_count_for "$k")" -eq 0 ] || { echo "$k was pruned" >&2; jira_shim::requests >&2; false; }
    [ "$(_write_count_for  "$k")" -eq 0 ] || { echo "$k was relabeled/edited" >&2; jira_shim::requests >&2; false; }
  done

  # And is_bridge_owned itself returns FALSE for each operator label set (the
  # client-side predicate that gates everything downstream).
  run jira_sink::is_bridge_owned '["backend"]';      [ "$status" -ne 0 ]
  run jira_sink::is_bridge_owned '["needs-triage"]'; [ "$status" -ne 0 ]
  run jira_sink::is_bridge_owned '["chore"]';        [ "$status" -ne 0 ]
  run jira_sink::is_bridge_owned '[]';               [ "$status" -ne 0 ]
}

# =============================================================================
# T023 — a manually-applied speckit-* identity label ⇒ treated as bridge-owned
#        (opted in). Documented identity-contract consequence (spec Assumptions /
#        edge case): because its identity (speckit-spec:999) is NOT one the
#        current mapping projects, it is an orphan and IS pruned.
# =============================================================================
@test "T023 operator-applied speckit-* identity label is treated as bridge-owned (opted in) and pruned" {
  _run_remode_ok

  # The identity contract: the manual speckit-spec:999 label makes PROJ-905
  # bridge-owned…
  run jira_sink::is_bridge_owned '["speckit-spec:999"]'; [ "$status" -eq 0 ]
  # …and since speckit-spec:999 is absent from D (only speckit-spec:001 is), it
  # is an orphan and is pruned exactly once — the documented consequence.
  [ "$(_delete_count_for PROJ-905)" -eq 1 ] || { echo "opted-in PROJ-905 deletes=$(_delete_count_for PROJ-905)" >&2; jira_shim::requests >&2; false; }
}

# =============================================================================
# T024 — a STALE prior-shape identity family (speckit-task:legacy-3, a value the
#        current mapping never mints) is still recognized as bridge-owned via the
#        configured-prefix match and pruned.
# =============================================================================
@test "T024 a stale prior-shape identity family is recognized as bridge-owned (prefix match) and pruned" {
  _run_remode_ok

  # The current mapping never mints speckit-task:legacy-3 (task→checklist), yet
  # the speckit-task: PREFIX match keeps it in the bridge-owned set E, and its
  # absence from D makes it an orphan → pruned once.
  run jira_sink::is_bridge_owned '["speckit-task:legacy-3"]'; [ "$status" -eq 0 ]
  [ "$(_delete_count_for PROJ-204)" -eq 1 ] || { echo "stale PROJ-204 deletes=$(_delete_count_for PROJ-204)" >&2; jira_shim::requests >&2; false; }
}

# =============================================================================
# T025 — SC-002 roll-up: ZERO operator DELETEs across the whole run, and the
#        total DELETE set is EXACTLY the intended bridge orphans (no more).
# =============================================================================
@test "T025 SC-002: zero operator issues deleted; only the intended bridge orphans pruned" {
  _run_remode_ok

  # SC-002 — the count of DELETEs to ANY operator key is exactly zero.
  local op total_op_deletes=0
  for op in PROJ-900 PROJ-901 PROJ-902; do
    total_op_deletes=$(( total_op_deletes + $(_delete_count_for "$op") ))
  done
  [ "$total_op_deletes" -eq 0 ] || { echo "operator DELETEs=$total_op_deletes (want 0)" >&2; jira_shim::requests >&2; false; }

  # The intended orphans (and ONLY them) are pruned, once each.
  [ "$(_delete_count_for PROJ-201)" -eq 1 ]   # task-phase:1
  [ "$(_delete_count_for PROJ-202)" -eq 1 ]   # task-phase:2
  [ "$(_delete_count_for PROJ-204)" -eq 1 ]   # speckit-task:legacy-3 (stale)
  [ "$(_delete_count_for PROJ-905)" -eq 1 ]   # speckit-spec:999 (opted-in)

  # The kept bridge anchors (in D) are never pruned.
  [ "$(_delete_count_for PROJ-100)" -eq 0 ]   # repo Epic
  [ "$(_delete_count_for PROJ-101)" -eq 0 ]   # spec Story

  # Total DELETEs = EXACTLY 4 (the four orphans) — nothing more reaches the board.
  local total_deletes
  total_deletes="$(jira_shim::requests | grep -c '^METHOD DELETE$' || true)"
  [ "$total_deletes" -eq 4 ] || { echo "total DELETEs=$total_deletes (want 4)" >&2; jira_shim::requests >&2; false; }
}
