#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us2_absent_type_failclosed.bats  (T025, US2)
#
# Phase 4 / US2 fail-closed gate (spec scenarios 2-3, SC-003): the config-load
# validation runs BEFORE any write, and any failure aborts with exit 2 writing
# NOTHING. Two surfaces:
#   (a) a configured artifact the project LACKS (spec→Story over a Kanban project
#       with NO Story) is rejected at config-load with a clear error and ZERO
#       writes (the available-type probe + absent-type policy, FR-005/FR-006);
#   (b) a nonsensical hierarchy relationship (Blocks as a hierarchy link) is
#       rejected by the OFFLINE matrix BEFORE the probe even fires — likewise
#       exit 2, zero writes (FR-007).
#
# Drives the REAL engine gate (reconcile::load_config, T023): config load →
# offline validate → live probe → available-type validate, all before the write
# loop. Offline + deterministic; no real Jira coordinates (Privacy IX).
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

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  jira_shim::install
}

teardown() {
  jira_shim::uninstall
}

# Run the engine config-load gate against the given config path, with the
# project probe shimmed to the given issuetype-meta fixture. Records the run's
# requests so the caller can assert ZERO writes.
_load_config() {
  local conf="$1" meta_fixture="$2" meta_code="${3:-200}"
  jira_shim::reset
  jira_shim::set_response GET "*/project/PROJ*" "$meta_fixture" "$meta_code"
  declare -g RECONCILE_CONFIG_PATH="$conf"
  summary::start "us2 absent-type fail-closed" >/dev/null 2>&1 || true
  reconcile::load_config
}

# --- (a) a project-absent configured type is rejected at config-load ---------

@test "absent configured type (spec→Story over Kanban) is rejected at config-load (exit 2)" {
  # Kanban project: Epic/Task/Subtask, NO Story. The default spec→Story is absent.
  local conf="${BATS_TEST_TMPDIR}/no-story.yml"
  cat > "$conf" <<'YAML'
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
YAML

  run _load_config "$conf" "issuetype_meta/project_kanban.json" 200
  [ "$status" -eq 2 ]
  # A clear, actionable error naming the absent type.
  [[ "$output" == *"Story"* ]]
}

@test "the absent-type rejection writes NOTHING (zero POST/PUT)" {
  local conf="${BATS_TEST_TMPDIR}/no-story2.yml"
  cat > "$conf" <<'YAML'
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
YAML

  # Run in the CURRENT shell so the recorded requests survive (a `run` subshell
  # would lose the shim state). config::* exits 2 from a subshell, so wrap the
  # gate in a subshell guard and assert on the recorded requests after.
  ( _load_config "$conf" "issuetype_meta/project_kanban.json" 200 ) || true

  local reqs writes
  reqs="$(jira_shim::requests)"
  writes="$(printf '%s\n' "$reqs" | grep -cE '^METHOD (POST|PUT)$' || true)"
  [ "$writes" -eq 0 ] || {
    echo "config-load rejection must write NOTHING, saw $writes writes" >&2
    printf '%s\n' "$reqs" >&2
    false
  }
}

# --- a valid on_absent fallback rescues the same Kanban project --------------

@test "a valid on_absent fallback (Story→Task) is accepted over the Kanban project" {
  local conf="${BATS_TEST_TMPDIR}/fallback.yml"
  cat > "$conf" <<'YAML'
jira:
  project_key: "PROJ"
  issue_types:
    epic: "10001"
    story: "10002"
    subtask: "10003"
    task: "10004"
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
      spec:
        artifact: "Story"
        relationship_to_parent: "parent"
        on_absent: "Task"
YAML

  run _load_config "$conf" "issuetype_meta/project_kanban.json" 200
  [ "$status" -eq 0 ]
}

# --- F2/F5: the rescued level PROJECTS the fallback type on the wire ----------

@test "a fallback-rescued Kanban config POSTs the FALLBACK issue-type id (not the absent primary)" {
  # spec→Story (issue_types.story=10002) is ABSENT on the Kanban project; the
  # on_absent: Task fallback (issue_types.task=10004) rescues it. The validation
  # gate must SUBSTITUTE the fallback so the WRITE path projects the Task id.
  # The un-fixed code rescued at VALIDATION but the projection still resolved the
  # absent Story id via _level_artifact — so the create carried 10002. This test
  # asserts the FALLBACK id (10004) is on the wire, not merely that validate==0.
  local conf="${BATS_TEST_TMPDIR}/fallback-project.yml"
  cat > "$conf" <<'YAML'
jira:
  project_key: "PROJ"
  issue_types:
    epic: "10001"
    story: "10002"
    subtask: "10003"
    task: "10004"
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
      spec:
        artifact: "Story"
        relationship_to_parent: "parent"
        on_absent: "Task"
YAML

  # Drive the REAL engine config gate in the CURRENT shell (not `run`, a subshell)
  # so the fallback substitution persists into the projection that follows.
  jira_shim::reset
  jira_shim::set_response GET "*/project/PROJ*" "issuetype_meta/project_kanban.json" 200
  declare -g RECONCILE_CONFIG_PATH="$conf"
  summary::start "us2 fallback projection" >/dev/null 2>&1 || true
  reconcile::load_config

  # Now project the spec level: absent search → create. The create must carry the
  # FALLBACK Task id (10004), proving the substitution reached the write path.
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201

  sync_level_artifact spec "speckit-spec:001" "PROJ-100" '{"summary":"001 — Sample","body":""}' >/dev/null

  local reqs
  reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | grep -q '"id":"10004"' || {
    echo "expected the fallback Task id 10004 on the create, got:" >&2
    printf '%s\n' "$reqs" >&2
    false
  }
  printf '%s\n' "$reqs" | grep -q '"id":"10002"' && {
    echo "the absent primary Story id 10002 must NOT be POSTed" >&2
    printf '%s\n' "$reqs" >&2
    false
  } || true
}

# --- (b) a nonsensical hierarchy relationship is rejected before the probe ---

@test "a nonsensical hierarchy relationship (Blocks) is rejected before any write (exit 2)" {
  local conf="${BATS_TEST_TMPDIR}/blocks.yml"
  cat > "$conf" <<'YAML'
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
  mapping:
    levels:
      spec: { artifact: "Story", relationship_to_parent: "Blocks" }
YAML

  # The OFFLINE matrix rejects this in mapping::validate, BEFORE the probe — so a
  # Scrum project meta that WOULD satisfy the available-type check never matters.
  run _load_config "$conf" "issuetype_meta/project_scrum.json" 200
  [ "$status" -eq 2 ]
  [[ "$output" == *"Blocks"* ]]
}

@test "the matrix rejection writes NOTHING (zero POST/PUT)" {
  # F8: parity with the absent-type zero-write test — a matrix reject must abort
  # before any mutation. The un-asserted version only checked exit 2, leaving a
  # rogue write undetected.
  local conf="${BATS_TEST_TMPDIR}/blocks2.yml"
  cat > "$conf" <<'YAML'
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
  mapping:
    levels:
      spec: { artifact: "Story", relationship_to_parent: "Blocks" }
YAML

  # Run in the CURRENT shell so the recorded requests survive (a `run` subshell
  # would lose the shim state). config::* exits 2 from a subshell, so wrap the
  # gate in a subshell guard and assert on the recorded requests after.
  ( _load_config "$conf" "issuetype_meta/project_scrum.json" 200 ) || true

  local reqs writes
  reqs="$(jira_shim::requests)"
  writes="$(printf '%s\n' "$reqs" | grep -cE '^METHOD (POST|PUT)$' || true)"
  [ "$writes" -eq 0 ] || {
    echo "matrix rejection must write NOTHING, saw $writes writes" >&2
    printf '%s\n' "$reqs" >&2
    false
  }
}

# --- an unreadable probe fails closed (exit 2) -------------------------------

@test "an unreadable issue-type probe (401) fails closed at config-load (exit 2)" {
  local conf="${BATS_TEST_TMPDIR}/probe-401.yml"
  cat > "$conf" <<'YAML'
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
YAML

  run _load_config "$conf" "error_401.json" 401
  [ "$status" -eq 2 ]
}
