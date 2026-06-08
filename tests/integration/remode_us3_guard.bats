#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/remode_us3_guard.bats  (T026/T027, US3 — the GUARD suite)
#
# US3 = "destruction is opt-in and previewable." Three load-bearing guarantees,
# proven offline over the same curl-shim board the US1 re-mode tests use (D10):
#
#   SC-004 / FR-004 — the ORDINARY reconcile (no --remode) performs ZERO
#     destructive operations in EVERY mapping mode (3-level AND 2-level).
#   FR-003 — `--remode --dry-run` previews the exact prune + regenerate set and
#     performs ZERO writes (no DELETE, no POST/PUT).
#   SC-003 — `--remode` (no --dry-run) prunes EXACTLY the set the dry-run
#     previewed (preview fidelity: the dry-run and the real run derive the orphan
#     set from the SAME computation, so the previewed keys == the deleted keys).
#
# The board is a 3-level mirror (repo Epic + spec Story + 2 phase Subtasks) plus
# an operator issue; the config is switched to a 2-level checklist so the two
# phase Subtasks are the orphans. Offline + deterministic; placeholders only
# (Principle IX).
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

_repo_slug() { printf 'repo'; }

_load_config() {
  config::load "$1"; config::validate; mapping::parse; mapping::validate
}

# $1=target file. $2 = "2level" | "3level": the CURRENT mapping mode.
#   2level → phase+task render in-body (the 2 phase Subtasks are orphans).
#   3level → phase→Subtask (no orphans; the board already mirrors this shape).
_write_config() {
  local out="$1" mode="$2" phase_line task_line
  if [[ "$mode" == "2level" ]]; then
    phase_line='phase: { artifact: "checklist", relationship_to_parent: "checklist" }'
    task_line='task:  { artifact: "checklist", relationship_to_parent: "checklist" }'
  else
    phase_line='phase: { artifact: "Subtask", relationship_to_parent: "parent" }'
    task_line='task:  { artifact: "checklist", relationship_to_parent: "checklist" }'
  fi
  cat > "$out" <<YAML
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
      ${phase_line}
      ${task_line}
YAML
}

# The 3-level board (same as US1): repo Epic + spec Story + 2 phase Subtasks
# (bridge-owned) + an operator issue under the same Epic (no identity label).
_register_3level_board() {
  local slug; slug="$(_repo_slug)"

  jq -n --arg l "speckit-repo:${slug}" '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{summary:"Specs — repo",
        labels:[$l],status:{id:"10000"},updated:"2026-05-31T00:00:00.000+0000",
        parent:null}}]}' >"$FX/repo_search.json"

  jq -n --arg l "speckit-repo:${slug}" '{summary:"Specs — repo",description:null,
       labels:[$l],status:{id:"10000"},parent:null}' >"$FX/root_get.json"

  jq -n '{startAt:0,maxResults:50,total:2,issues:[
       {id:"10101",key:"PROJ-101",fields:{summary:"001 — Sample Spec",
        labels:["speckit-spec:001"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-100"}}},
       {id:"10900",key:"PROJ-900",fields:{summary:"Operator chore (lookalike)",
        labels:["backend","needs-review"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-100"}}}]}' \
    >"$FX/children_of_root.json"

  jq -n '{startAt:0,maxResults:50,total:2,issues:[
       {id:"10201",key:"PROJ-201",fields:{summary:"Phase 1: Setup",
        labels:["task-phase:1"],status:{id:"10000"},
        updated:"2026-05-31T00:00:00.000+0000",parent:{key:"PROJ-101"}}},
       {id:"10202",key:"PROJ-202",fields:{summary:"Phase 2: Core",
        labels:["task-phase:2"],status:{id:"10000"},
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
  jira_shim::set_response GET "*search/jql*parent%20%3D%20%22PROJ-900%22*" \
    "$FX/children_none.json" 200
  jira_shim::set_response GET "*/issue/PROJ-100?fields=*" "$FX/root_get.json" 200
}

# Wire the regenerate-phase reads/writes (Story search/get/transitions, create/
# put) so a real --remode can complete after its prune loop.
_register_regenerate() {
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

# Count DELETEs to a given issue key in the recorded requests.
_delete_count_for() {
  local key="$1" reqs; reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | awk -v k="/issue/${key}$" '
    /^METHOD DELETE$/ { d=1; next }
    /^URL / { if (d && $2 ~ k) c++; d=0 }
    END { print c+0 }'
}

_total_deletes() { jira_shim::requests | grep -c '^METHOD DELETE$' || true; }
_total_writes() {
  # Any mutating verb counts as a write.
  jira_shim::requests | grep -cE '^METHOD (DELETE|POST|PUT)$' || true
}

# =============================================================================
# SC-004 — the ORDINARY reconcile performs ZERO destructive ops in EVERY mode.
# =============================================================================
@test "T026 SC-004 ordinary reconcile (2-level mode, stale 3-level board) issues ZERO DELETEs" {
  cd "$WORKDIR"
  CONF="$BATS_TEST_TMPDIR/conf.yml"; _write_config "$CONF" 2level
  jira_shim::install
  _load_config "$CONF"
  _register_3level_board
  _register_regenerate

  # ORDINARY reconcile (no --remode) over the per-spec loop + the FR-014 warn.
  ARG_DRY_RUN=0
  summary::start "t026-2level"
  reconcile::process_spec "$WORKDIR/specs/001-sample" || true
  reconcile::warn_orphans "$WORKDIR/specs/001-sample"

  [ "$(_total_deletes)" -eq 0 ] || {
    echo "ordinary reconcile (2-level) issued $(_total_deletes) DELETE(s)" >&2
    jira_shim::requests >&2; false; }
}

@test "T026 SC-004 ordinary reconcile (3-level mode, matching board) issues ZERO DELETEs" {
  cd "$WORKDIR"
  CONF="$BATS_TEST_TMPDIR/conf.yml"; _write_config "$CONF" 3level
  jira_shim::install
  _load_config "$CONF"
  _register_3level_board
  _register_regenerate

  ARG_DRY_RUN=0
  summary::start "t026-3level"
  reconcile::process_spec "$WORKDIR/specs/001-sample" || true
  reconcile::warn_orphans "$WORKDIR/specs/001-sample"

  [ "$(_total_deletes)" -eq 0 ] || {
    echo "ordinary reconcile (3-level) issued $(_total_deletes) DELETE(s)" >&2
    jira_shim::requests >&2; false; }
}

# =============================================================================
# FR-003 — `--remode --dry-run` previews the exact set with ZERO writes.
# =============================================================================
@test "T027 FR-003 --remode --dry-run previews the exact prune set with ZERO writes" {
  cd "$WORKDIR"
  CONF="$BATS_TEST_TMPDIR/conf.yml"; _write_config "$CONF" 2level
  jira_shim::install
  _load_config "$CONF"
  _register_3level_board

  ARG_DRY_RUN=1
  summary::start "t027-dry"
  reconcile::remode

  # Zero writes of ANY kind (no DELETE/POST/PUT) in the dry-run.
  [ "$(_total_writes)" -eq 0 ] || {
    echo "--remode --dry-run issued $(_total_writes) write(s)" >&2
    jira_shim::requests >&2; false; }

  # The preview names EXACTLY the two phase Subtasks (the orphan set).
  local previews
  previews="$(printf '%s\n' "${_SUMMARY_INFOS[@]}" | grep 'would prune' || true)"
  [[ "$previews" == *"PROJ-201"* ]] || { echo "preview omits PROJ-201" >&2; printf '%s\n' "${_SUMMARY_INFOS[@]}" >&2; false; }
  [[ "$previews" == *"PROJ-202"* ]] || { echo "preview omits PROJ-202" >&2; printf '%s\n' "${_SUMMARY_INFOS[@]}" >&2; false; }
  [[ "$previews" != *"PROJ-900"* ]] || { echo "preview names the operator issue" >&2; false; }
  [[ "$previews" != *"PROJ-101"* ]] || { echo "preview names the spec Story" >&2; false; }
}

# =============================================================================
# SC-003 — `--remode` prunes EXACTLY the dry-run-previewed set (preview fidelity).
# We derive the dry-run preview set and the real-run pruned set from the SAME
# board+config and assert they are identical (same computation, FR-003/SC-003).
# =============================================================================
@test "T027 SC-003 --remode prunes EXACTLY the dry-run-previewed set (preview fidelity)" {
  cd "$WORKDIR"
  CONF="$BATS_TEST_TMPDIR/conf.yml"; _write_config "$CONF" 2level

  # --- Pass 1: DRY-RUN — capture the previewed key set. -----------------------
  jira_shim::install
  _load_config "$CONF"
  _register_3level_board
  ARG_DRY_RUN=1
  summary::start "t027-fidelity-dry"
  reconcile::remode
  local preview_keys
  preview_keys="$(printf '%s\n' "${_SUMMARY_INFOS[@]}" \
    | grep 'would prune' \
    | grep -oE 'PROJ-[0-9]+' | sort -u | paste -sd, -)"
  jira_shim::uninstall

  # --- Pass 2: REAL --remode — capture the actually-deleted key set. ----------
  jira_shim::install
  _load_config "$CONF"
  _register_3level_board
  _register_regenerate
  jira_shim::set_response DELETE "*/issue/*" "$EMPTY" 204
  ARG_DRY_RUN=0
  summary::start "t027-fidelity-real"
  run reconcile::remode
  [ "$status" -eq 0 ] || { echo "remode exit=$status" >&2; printf '%s\n' "$output" >&2; false; }

  local deleted_keys
  deleted_keys="$(jira_shim::requests | awk '
      /^METHOD DELETE$/ { d=1; next }
      /^URL / { if (d) print $2; d=0 }' \
    | grep -oE 'PROJ-[0-9]+' | sort -u | paste -sd, -)"

  # Preview fidelity: the dry-run-previewed set == the actually-pruned set.
  [ "$preview_keys" = "$deleted_keys" ] || {
    echo "preview fidelity broke: preview={$preview_keys} deleted={$deleted_keys}" >&2
    jira_shim::requests >&2; false; }
  # And concretely that set is the two phase Subtasks (operator/Story untouched).
  [ "$preview_keys" = "PROJ-201,PROJ-202" ] || { echo "set was {$preview_keys}, want PROJ-201,PROJ-202" >&2; false; }
  [ "$(_delete_count_for PROJ-900)" -eq 0 ]
  [ "$(_delete_count_for PROJ-101)" -eq 0 ]
  [ "$(_delete_count_for PROJ-100)" -eq 0 ]
}
