#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/reconcile_orphan_warning.bats  (T028/T029, US3 — FR-014)
#
# The ordinary (non-`--remode`) reconcile MUST WARN when it detects bridge-owned
# orphans left over from a prior mapping shape — listing them and suggesting
# `--remode` — but MUST NOT prune them (FR-004/FR-014). Proven offline over the
# same curl-shim board the US1 re-mode tests use (decision D10): a 3-level board
# mirrored under spec→Story, with the config now switched to a 2-level checklist
# so the two phase Subtasks are orphans the current mapping no longer projects.
#
# Assertions:
#   - reconcile::warn_orphans emits EXACTLY ONE warned row that names BOTH orphan
#     keys and suggests --remode.
#   - ZERO DELETE requests are issued (the ordinary path never prunes).
#   - The operator issue is never named in the warning (label-scoped diff).
#
# Offline + deterministic; placeholder coordinates only (Principle IX).
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
  ARG_QUIET=1
}
teardown() { jira_shim::uninstall; }

# The repo slug the engine derives (basename of the git toplevel). WORKDIR is not
# a git repo, so the resolver falls back to basename "$(pwd)" = "repo".
_repo_slug() { printf 'repo'; }

_load_config() {
  config::load "$1"; config::validate; mapping::parse; mapping::validate
}

# A 2-level config: phase + task render in-body (checklist), so the existing
# board's two phase Subtasks are orphans the current mapping no longer projects.
_write_2level_config() {
  cat > "$1" <<'YAML'
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
}

# The 3-level board: repo Epic + spec Story + 2 phase Subtasks (bridge-owned),
# plus an operator-created issue under the same Epic (no identity label).
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

# =============================================================================
# T028 — warn on detected prior-shape orphans: list them + suggest --remode.
# =============================================================================
@test "T028 ordinary reconcile WARNS on prior-shape orphans (lists both, suggests --remode)" {
  cd "$WORKDIR"
  CONF="$BATS_TEST_TMPDIR/conf-2level.yml"; _write_2level_config "$CONF"
  jira_shim::install
  _load_config "$CONF"
  _register_3level_board

  summary::start "t028"
  run reconcile::warn_orphans "$WORKDIR/specs/001-sample"
  [ "$status" -eq 0 ] || { echo "warn_orphans exit=$status" >&2; printf '%s\n' "$output" >&2; false; }

  # warn_orphans ran in a subshell (`run`); re-run in-process so we can inspect
  # the summary warnings array directly.
  summary::start "t028b"
  reconcile::warn_orphans "$WORKDIR/specs/001-sample"

  # Exactly ONE warning row, naming BOTH orphan keys + suggesting --remode.
  [ "${#_SUMMARY_WARNINGS[@]}" -eq 1 ] || {
    echo "want 1 warning, got ${#_SUMMARY_WARNINGS[@]}:" >&2
    printf '  %s\n' "${_SUMMARY_WARNINGS[@]}" >&2; false; }
  local w="${_SUMMARY_WARNINGS[0]}"
  [[ "$w" == *"PROJ-201"* ]] || { echo "warning omits PROJ-201: $w" >&2; false; }
  [[ "$w" == *"PROJ-202"* ]] || { echo "warning omits PROJ-202: $w" >&2; false; }
  [[ "$w" == *"--remode"* ]] || { echo "warning omits --remode remedy: $w" >&2; false; }
  # The operator issue is NEVER named (label-scoped diff).
  [[ "$w" != *"PROJ-900"* ]] || { echo "operator issue named in warning: $w" >&2; false; }
}

# =============================================================================
# T029 — the ordinary warning path PRUNES NOTHING (FR-004/FR-014).
# =============================================================================
@test "T029 ordinary reconcile orphan-warning issues ZERO DELETEs (never prunes)" {
  cd "$WORKDIR"
  CONF="$BATS_TEST_TMPDIR/conf-2level.yml"; _write_2level_config "$CONF"
  jira_shim::install
  _load_config "$CONF"
  _register_3level_board

  summary::start "t029"
  run reconcile::warn_orphans "$WORKDIR/specs/001-sample"
  [ "$status" -eq 0 ]

  local total_deletes
  total_deletes="$(jira_shim::requests | grep -c '^METHOD DELETE$' || true)"
  [ "$total_deletes" -eq 0 ] || {
    echo "ordinary warning path issued $total_deletes DELETE(s) (want 0)" >&2
    jira_shim::requests >&2; false; }
}

# =============================================================================
# T029b — fail-SOFT: an unreadable advisory read degrades to NO warning and
# does NOT break the ordinary reconcile (no error, no delete).
# =============================================================================
@test "T029b orphan-warning is fail-soft: unreadable read → no warning, no error, no delete" {
  cd "$WORKDIR"
  CONF="$BATS_TEST_TMPDIR/conf-2level.yml"; _write_2level_config "$CONF"
  jira_shim::install
  _load_config "$CONF"
  # Repo lookup returns 500 (unreadable). The advisory read must degrade silently.
  : >"$FX/empty.json"
  jira_shim::set_response GET "*search/jql*labels%20%3D%20%22speckit-repo*" \
    "$FX/empty.json" 500

  summary::start "t029b"
  reconcile::warn_orphans "$WORKDIR/specs/001-sample"

  # No warning row was emitted (degraded to silence).
  [ "${#_SUMMARY_WARNINGS[@]}" -eq 0 ] || {
    echo "fail-soft expected 0 warnings, got ${#_SUMMARY_WARNINGS[@]}:" >&2
    printf '  %s\n' "${_SUMMARY_WARNINGS[@]}" >&2; false; }
  # And it never pruned.
  local total_deletes
  total_deletes="$(jira_shim::requests | grep -c '^METHOD DELETE$' || true)"
  [ "$total_deletes" -eq 0 ]
}
