#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/mapping_parse.bats  (T003)
#
# Unit tests for the new `mapping:` block parse in src/config.sh
# (`mapping::parse`). PURE tests: no network, no curl, no live Jira. They drive
# config::load + mapping::parse + mapping::resolve_level against PLACEHOLDER
# fixtures only (Privacy IX).
#
# Coverage (contracts/mapping-config.md schema):
#   - both the inline-map form (`repo: { artifact: ..., ... }`) and the expanded
#     block form parse into the same flattened keys;
#   - initiative / project_style / levels / status_rollup parse;
#   - malformed enum values are config errors (exit 2):
#       initiative.on_absent != degrade, initiative.source != spec_input,
#       project_style not in {team-managed, classic}.
#
# As in config.bats, config.sh's fatal paths `exit 2` from inside the sourced
# function, so each snippet runs in a `bash -c` subshell.
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

# A minimal, valid base config (placeholders only) plus a `mapping:` block.
# The caller appends/overrides the mapping body via heredoc.
_base_with_mapping() {
  cat <<'YAML'
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
}

# --- inline-map form (contract schema literal) -------------------------------

@test "parse: inline-map levels form parses each child key" {
  local tmp="${BATS_TEST_TMPDIR}/inline.yml"
  _base_with_mapping > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    project_style: "team-managed"
    levels:
      repo:   { artifact: "Epic",      relationship_to_parent: "none" }
      spec:   { artifact: "Story",     relationship_to_parent: "parent" }
      phase:  { artifact: "Subtask",   relationship_to_parent: "parent" }
      task:   { artifact: "checklist", relationship_to_parent: "checklist" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::resolve_level repo' "$tmp"
  [ "$status" -eq 0 ]
  local tab=$'\t'
  [ "$output" = "Epic${tab}none" ]
}

@test "parse: inline-map spec level resolves artifact + relationship" {
  local tmp="${BATS_TEST_TMPDIR}/inline2.yml"
  _base_with_mapping > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      spec:   { artifact: "Story",     relationship_to_parent: "parent" }
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::resolve_level spec' "$tmp"
  [ "$status" -eq 0 ]
  local tab=$'\t'
  [ "$output" = "Story${tab}parent" ]
}

# --- expanded block form -----------------------------------------------------

@test "parse: expanded block form parses initiative + status_rollup levers" {
  local tmp="${BATS_TEST_TMPDIR}/block.yml"
  _base_with_mapping > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    initiative:
      enabled: false
      artifact: "Initiative"
      on_absent: "degrade"
      source: "spec_input"
    project_style: "classic"
    levels:
      repo:
        artifact: "Epic"
        relationship_to_parent: "none"
    status_rollup:
      enabled: false
YAML
  _run_config 'config::load "$1"; mapping::parse; config::get mapping.project_style' "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "classic" ]
}

@test "parse: an explicit mapping block reports mapping::is_explicit true" {
  local tmp="${BATS_TEST_TMPDIR}/explicit.yml"
  _base_with_mapping > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      spec: { artifact: "Story", relationship_to_parent: "parent" }
YAML
  _run_config 'config::load "$1"; mapping::parse; if mapping::is_explicit; then echo explicit; else echo aliased; fi' "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "explicit" ]
}

@test "parse: per-level on_absent fallback is captured" {
  local tmp="${BATS_TEST_TMPDIR}/onabsent.yml"
  _base_with_mapping > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    levels:
      spec:
        artifact: "Story"
        relationship_to_parent: "parent"
        on_absent: "Task"
YAML
  _run_config 'config::load "$1"; mapping::parse; mapping::resolve_level spec' "$tmp"
  [ "$status" -eq 0 ]
  local tab=$'\t'
  [ "$output" = "Story${tab}parent${tab}Task" ]
}

# --- malformed enum values are config errors (exit 2) ------------------------

@test "parse: initiative.on_absent != degrade is a config error (exit 2)" {
  local tmp="${BATS_TEST_TMPDIR}/bad-onabsent.yml"
  _base_with_mapping > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    initiative:
      enabled: true
      on_absent: "fail"
      source: "spec_input"
YAML
  _run_config 'config::load "$1"; mapping::parse' "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"initiative.on_absent"* ]]
}

@test "parse: initiative.source != spec_input is a config error (exit 2)" {
  local tmp="${BATS_TEST_TMPDIR}/bad-source.yml"
  _base_with_mapping > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    initiative:
      enabled: true
      on_absent: "degrade"
      source: "inferred"
YAML
  _run_config 'config::load "$1"; mapping::parse' "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"initiative.source"* ]]
}

@test "parse: project_style not in {team-managed,classic} is a config error (exit 2)" {
  local tmp="${BATS_TEST_TMPDIR}/bad-style.yml"
  _base_with_mapping > "$tmp"
  cat >> "$tmp" <<'YAML'
  mapping:
    project_style: "nextgen"
    levels:
      repo: { artifact: "Epic", relationship_to_parent: "none" }
YAML
  _run_config 'config::load "$1"; mapping::parse' "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"project_style"* ]]
}
