#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/relationship_matrix.bats  (T016, US2)
#
# Unit tests for the OFFLINE relationship-validation matrix in src/config.sh
# (`mapping::validate_relationships`, exercised through the `mapping::validate`
# gate). Every matrix REJECT hard-halts at config-load with exit 2 and writes
# NOTHING (Q2, FR-007, mapping-config.md §4):
#   - Blocks / Relates / Implements used as ANY hierarchy link;
#   - Epic-link declared between two NON-Epic levels;
#   - checklist artifact paired with a non-checklist relationship;
#   - an unknown relationship vocabulary value.
# The allow cases (parent / none / checklist / Epic-link under an Epic parent)
# pass the gate clean.
#
# PURE tests: placeholders only, NO live Jira — the matrix resolves fully
# OFFLINE at config-load (project_style operator-declared, Q3). config.sh's fatal
# paths `exit 2` from inside the sourced function, so each snippet runs in a
# `bash -c` subshell.
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

# A minimal valid base config (placeholders only). task_prefix is supplied so a
# Task-projected level never trips the required-id check ahead of the matrix.
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

# --- dependency links rejected as hierarchy links (hard-halt exit 2) ---------

@test "matrix: Blocks as a hierarchy link hard-halts (exit 2, no write)" {
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

@test "matrix: Relates as a hierarchy link hard-halts (exit 2, no write)" {
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

@test "matrix: Implements as a hierarchy link hard-halts (exit 2, no write)" {
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

# --- Epic-link between two NON-Epic levels rejected --------------------------

@test "matrix: Epic-link between two non-Epic levels hard-halts (exit 2)" {
  # phase (Subtask) under spec (Story): neither parent is an Epic.
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

@test "matrix: Epic-link where the parent IS an Epic passes the gate" {
  local tmp="${BATS_TEST_TMPDIR}/epiclink-ok.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      repo: { artifact: "Epic",  relationship_to_parent: "none" }
      spec: { artifact: "Story", relationship_to_parent: "Epic-link" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::validate' "$tmp"
  [ "$status" -eq 0 ]
}

# --- checklist artifact must pair with a checklist relationship --------------

@test "matrix: checklist artifact with a non-checklist relationship hard-halts (exit 2)" {
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

@test "matrix: an unknown relationship vocabulary value hard-halts (exit 2)" {
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

# --- the allow set passes clean ----------------------------------------------

@test "matrix: parent / none / checklist (the default) pass the gate clean" {
  local tmp="${BATS_TEST_TMPDIR}/allow.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      repo:  { artifact: "Epic",      relationship_to_parent: "none" }
      spec:  { artifact: "Story",     relationship_to_parent: "parent" }
      phase: { artifact: "Subtask",   relationship_to_parent: "parent" }
      task:  { artifact: "checklist", relationship_to_parent: "checklist" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::validate' "$tmp"
  [ "$status" -eq 0 ]
}
