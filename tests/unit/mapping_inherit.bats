#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/mapping_inherit.bats  (T005)
#
# Unit tests for per-level inheritance in src/config.sh. PURE tests:
# placeholders only (Privacy IX).
#
# Coverage (Q4, FR-002 edge case):
#   - a PARTIAL `mapping:` block (only some levels specified) inherits the
#     synthesized default per UNSPECIFIED level — not an all-or-nothing error;
#   - a specified level overrides; sibling unspecified levels keep the default;
#   - inheritance is per-level, so mixing a custom spec with a default phase/task
#     is valid.
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
YAML
}

@test "inherit: a partial block specifying only spec keeps default repo/phase/task" {
  local tmp="${BATS_TEST_TMPDIR}/partial-spec.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      spec: { artifact: "Epic", relationship_to_parent: "none" }
YAML
  _run_config '
    config::load "$1"; mapping::parse
    for lvl in repo spec phase task; do mapping::resolve_level "$lvl"; done
  ' "$tmp"
  [ "$status" -eq 0 ]
  local tab=$'\t'
  local expected="Epic${tab}none
Epic${tab}none
Subtask${tab}parent
checklist${tab}checklist"
  [ "$output" = "$expected" ]
}

@test "inherit: a partial block specifying only task overrides task, defaults elsewhere" {
  local tmp="${BATS_TEST_TMPDIR}/partial-task.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      task: { artifact: "Task", relationship_to_parent: "parent" }
YAML
  _run_config '
    config::load "$1"; mapping::parse
    for lvl in repo spec phase task; do mapping::resolve_level "$lvl"; done
  ' "$tmp"
  [ "$status" -eq 0 ]
  local tab=$'\t'
  local expected="Epic${tab}none
Story${tab}parent
Subtask${tab}parent
Task${tab}parent"
  [ "$output" = "$expected" ]
}

@test "inherit: a partial block is NOT an all-or-nothing error" {
  local tmp="${BATS_TEST_TMPDIR}/partial-mid.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      phase: { artifact: "Story", relationship_to_parent: "parent" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::resolve_level phase' "$tmp"
  [ "$status" -eq 0 ]
  local tab=$'\t'
  [ "$output" = "Story${tab}parent" ]
}

@test "inherit: an empty mapping: block (no levels) inherits ALL defaults" {
  local tmp="${BATS_TEST_TMPDIR}/empty-mapping.yml"
  _base > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    status_rollup:
      enabled: true
YAML
  _run_config '
    config::load "$1"; mapping::parse
    for lvl in repo spec phase task; do mapping::resolve_level "$lvl"; done
    config::get mapping.status_rollup.enabled
  ' "$tmp"
  [ "$status" -eq 0 ]
  local tab=$'\t'
  local expected="Epic${tab}none
Story${tab}parent
Subtask${tab}parent
checklist${tab}checklist
true"
  [ "$output" = "$expected" ]
}
