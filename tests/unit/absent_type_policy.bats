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
  # Name-only set (legacy caller): the Kanban template ships Epic/Task/Subtask,
  # NO Story. With no ids supplied the validator matches by NAME, so the default
  # spec→Story is absent → hard-error, no write.
  local tmp="${BATS_TEST_TMPDIR}/no-story.yml"
  _base > "$tmp"
  _run_config \
    'config::load "$1"; mapping::parse; mapping::validate_available Epic Task Subtask' \
    "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Story"* ]]
}

# --- REGRESSION (live-dogfood): id-match where the alias NAME is absent -------

@test "available: spec->Story PASSES when issue_types.story's id IS a live type (id-match)" {
  # The live Kanban board has NO type NAMED "Story", but the operator pointed
  # issue_types.story at an available type's id (here id 10002, surfaced live as
  # "Task"). With `<name>\t<id>` probe rows the validator matches by the RESOLVED
  # id (10002 ∈ the live id set) — so the no-config default PASSES instead of
  # failing on the absent alias name. This is the byte-for-byte-001 guarantee
  # (US1) holding on a Kanban project, the bug the live dogfood surfaced (the
  # mock's project fixture had a literal "Story" type and hid it). FR-005/FR-006.
  local tmp="${BATS_TEST_TMPDIR}/kanban-id.yml"
  _base > "$tmp"
  local r1=$'Epic\t10001' r2=$'Task\t10002' r3=$'Subtask\t10003'
  _run_config \
    'config::load "$1"; mapping::parse; mapping::validate_available "$2" "$3" "$4"' \
    "$tmp" "$r1" "$r2" "$r3"
  [ "$status" -eq 0 ] || { echo "default should pass by id-match; output: $output" >&2; false; }
}

@test "available: a configured id genuinely absent from the live id set hard-errors" {
  # issue_types.story = 10002, but the live id set lacks 10002 (only 10001/10003)
  # → the resolved id is genuinely absent → hard-error, no write (FR-006 intent
  # preserved under id-matching).
  local tmp="${BATS_TEST_TMPDIR}/id-absent.yml"
  _base > "$tmp"
  local r1=$'Epic\t10001' r2=$'Subtask\t10003'
  _run_config \
    'config::load "$1"; mapping::parse; mapping::validate_available "$2" "$3"' \
    "$tmp" "$r1" "$r2"
  [ "$status" -eq 2 ]
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
