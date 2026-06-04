#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/absent_type_policy.bats  (T017, US2)
#
# Unit tests for the absent-type policy in src/config.sh
# (`mapping::validate_available <available-type>...`). It validates every
# configured `artifact` against the detected available-type set passed by the
# caller (the probe lives in T019; this validator is offline so the matrix +
# policy stay pure-testable). Per Q10 / FR-006 / FR-017:
#   - a configured artifact absent from the set HARD-ERRORS (exit 2, no write);
#   - a valid per-level `on_absent` fallback (whose value IS available) is the
#     only escape — honored;
#   - an `on_absent` whose fallback is ITSELF absent STILL hard-errors;
#   - the `checklist` render sentinel is exempt (it projects no issue type);
#   - when every configured artifact is available, the gate passes clean.
#
# PURE tests: placeholders only, NO live Jira. config.sh's fatal paths `exit 2`
# from inside the sourced function, so each snippet runs in a `bash -c` subshell.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

_run_config() {
  local snippet="$1"; shift
  run bash -c '
    set -euo pipefail
    source "$0"
    '"${snippet}"'
  ' "${REPO_ROOT}/src/config.sh" "$@"
}

_base() {
  cat <<'YAML'
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
YAML
}

# --- every configured artifact available => pass -----------------------------

@test "available: the default mapping passes against a Scrum type set" {
  local tmp="${BATS_TEST_TMPDIR}/default.yml"
  _base > "$tmp"
  _run_config \
    'config::load "$1"; mapping::parse; mapping::validate_available Epic Story Subtask Task' \
    "$tmp"
  [ "$status" -eq 0 ]
}

# --- a configured artifact ABSENT from the set hard-errors -------------------

@test "available: spec->Story against a Kanban set (NO Story) hard-errors (exit 2)" {
  # The Kanban template ships Epic/Task/Subtask, NO Story. The default spec→Story
  # configured artifact is therefore absent → hard-error, no write.
  local tmp="${BATS_TEST_TMPDIR}/no-story.yml"
  _base > "$tmp"
  _run_config \
    'config::load "$1"; mapping::parse; mapping::validate_available Epic Task Subtask' \
    "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Story"* ]]
}

# --- a valid on_absent fallback is the only escape ---------------------------

@test "available: a per-level on_absent fallback (Story->Task) is honored" {
  # spec maps Story (absent on Kanban) with on_absent: Task (which IS available)
  # → the fallback rescues the level; the gate passes.
  local tmp="${BATS_TEST_TMPDIR}/fallback-ok.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      spec:
        artifact: "Story"
        relationship_to_parent: "parent"
        on_absent: "Task"
YAML
  _run_config \
    'config::load "$1"; mapping::parse; mapping::validate_available Epic Task Subtask' \
    "$tmp"
  [ "$status" -eq 0 ]
}

# --- an on_absent whose fallback is ITSELF absent still hard-errors -----------

@test "available: an on_absent fallback that is ALSO absent still hard-errors (exit 2)" {
  # spec maps Story (absent) with on_absent: Bug (also absent from the set) →
  # the fallback cannot rescue → hard-error.
  local tmp="${BATS_TEST_TMPDIR}/fallback-bad.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      spec:
        artifact: "Story"
        relationship_to_parent: "parent"
        on_absent: "Bug"
YAML
  _run_config \
    'config::load "$1"; mapping::parse; mapping::validate_available Epic Task Subtask' \
    "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Bug"* ]] || [[ "$output" == *"Story"* ]]
}

# --- the checklist sentinel is exempt ----------------------------------------

@test "available: the checklist task level is exempt from the probe" {
  # The default task→checklist projects no issue type, so it never needs to be in
  # the available set even though "checklist" is obviously not a Jira type.
  local tmp="${BATS_TEST_TMPDIR}/checklist-exempt.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      repo:  { artifact: "Epic",      relationship_to_parent: "none" }
      spec:  { artifact: "Story",     relationship_to_parent: "parent" }
      phase: { artifact: "Subtask",   relationship_to_parent: "parent" }
      task:  { artifact: "checklist", relationship_to_parent: "checklist" }
YAML
  _run_config \
    'config::load "$1"; mapping::parse; mapping::validate_available Epic Story Subtask' \
    "$tmp"
  [ "$status" -eq 0 ]
}
