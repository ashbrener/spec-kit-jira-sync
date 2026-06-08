#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/mapping_validate.bats  (T006)
#
# Unit tests for the config-load validation framework in src/config.sh
# (`mapping::validate` + `mapping::validate_relationships`). PURE tests:
# placeholders only, NO live Jira — the live available-issue-type PROBE is
# Phase 4/US2 and is out of scope here; `mapping::validate` runs the OFFLINE
# checks (required-id + relationship matrix) and leaves a clear hook for the
# probe.
#
# Coverage (FR-017, FR-007, mapping-config.md §validation order):
#   - validation is a single fail-closed gate; any failure exits 2 and writes
#     nothing;
#   - the relationship matrix rejects nonsensical hierarchy links
#     (Blocks/Relates/Implements as a hierarchy link);
#   - Epic-link between two non-Epic levels is rejected;
#   - `checklist` paired with a non-checklist relationship is rejected;
#   - a configured Task-projected level with no issue_types.task is a required-id
#     error;
#   - the default (aliased) config validates clean.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  FIXTURE="${REPO_ROOT}/tests/fixtures/config/jira-config.sample.yml"
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
YAML
}

# --- the default (aliased) config validates clean ----------------------------

@test "validate: the default-aliased config passes the offline gate" {
  _run_config 'config::load "$1"; mapping::parse; mapping::validate' "$FIXTURE"
  [ "$status" -eq 0 ]
}

@test "validate: an explicit 3-level (spec→Epic/phase→Story/task→Task) config passes" {
  local tmp="${BATS_TEST_TMPDIR}/three-level.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  labels:
    task_prefix: "speckit-task:"
  mapping:
    levels:
      repo:  { artifact: "Epic",  relationship_to_parent: "none" }
      spec:  { artifact: "Epic",  relationship_to_parent: "none" }
      phase: { artifact: "Story", relationship_to_parent: "Epic-link" }
      task:  { artifact: "Task",  relationship_to_parent: "parent" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::validate' "$tmp"
  [ "$status" -eq 0 ]
}

# --- relationship matrix rejections (hard-halt exit 2, no write) -------------

@test "validate: Blocks as a hierarchy link is rejected (exit 2)" {
  local tmp="${BATS_TEST_TMPDIR}/blocks.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      spec: { artifact: "Story", relationship_to_parent: "Blocks" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::validate' "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Blocks"* ]]
}

@test "validate: Relates as a hierarchy link is rejected (exit 2)" {
  local tmp="${BATS_TEST_TMPDIR}/relates.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      phase: { artifact: "Subtask", relationship_to_parent: "Relates" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::validate' "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Relates"* ]]
}

@test "validate: Implements as a hierarchy link is rejected (exit 2)" {
  local tmp="${BATS_TEST_TMPDIR}/implements.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      spec: { artifact: "Story", relationship_to_parent: "Implements" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::validate' "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Implements"* ]]
}

@test "validate: Epic-link between two NON-Epic levels is rejected (exit 2)" {
  # phase (Subtask) under spec (Story) — neither parent is an Epic, so Epic-link
  # is illegal.
  local tmp="${BATS_TEST_TMPDIR}/epiclink-bad.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      spec:  { artifact: "Story",   relationship_to_parent: "parent" }
      phase: { artifact: "Subtask", relationship_to_parent: "Epic-link" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::validate' "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Epic-link"* ]]
}

@test "validate: Epic-link where the parent IS an Epic is allowed" {
  # spec (Story) under repo (Epic) via Epic-link — the parent projects to Epic.
  local tmp="${BATS_TEST_TMPDIR}/epiclink-ok.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  labels:
    task_prefix: "speckit-task:"
  mapping:
    levels:
      repo: { artifact: "Epic",  relationship_to_parent: "none" }
      spec: { artifact: "Story", relationship_to_parent: "Epic-link" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::validate' "$tmp"
  [ "$status" -eq 0 ]
}

@test "validate: checklist artifact with a non-checklist relationship is rejected (exit 2)" {
  local tmp="${BATS_TEST_TMPDIR}/checklist-bad.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      task: { artifact: "checklist", relationship_to_parent: "parent" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::validate' "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"checklist"* ]]
}

# --- required-id presence ----------------------------------------------------

@test "validate: a Task-projected level with no issue_types.task is a required-id error (exit 2)" {
  # No `task:` id in issue_types, but task level projects to a Task issue.
  local tmp="${BATS_TEST_TMPDIR}/missing-task-id.yml"
  cat > "$tmp" <<'YAML'
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
      task: { artifact: "Task", relationship_to_parent: "parent" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::validate' "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"issue_types.task"* ]]
}

@test "validate: an unknown relationship vocabulary value is rejected (exit 2)" {
  local tmp="${BATS_TEST_TMPDIR}/bad-rel.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      spec: { artifact: "Story", relationship_to_parent: "supersedes" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::validate' "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"supersedes"* ]]
}
