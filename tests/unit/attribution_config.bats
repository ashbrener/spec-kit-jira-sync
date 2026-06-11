#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/attribution_config.bats  (feature-007 T007 — FR-006, R7)
#
# Config accessors for the opt-in `attribution:` block. The whole block is
# OPTIONAL: when absent OR `enabled: false` the feature is OFF (default), which
# the engine short-circuits to byte-identical-to-today behavior (US4/SC-004).
#
# PURE config tests: no network, no live Jira, placeholders only.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

_load_with() {
  # Write a jira-config.yml with the given attribution snippet appended under
  # `jira:` and source config.sh; echo accessor results for assertions.
  local snippet="$1"
  CONF="${BATS_TEST_TMPDIR}/jira-config.yml"
  {
    cat <<'BASE'
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
BASE
    printf '%s\n' "$snippet"
  } >"$CONF"
}

@test "attribution::enabled: absent block => disabled (default OFF)" {
  _load_with ""
  run bash -c 'source "$1"; config::load "$2"; if config::attribution_enabled; then echo ON; else echo OFF; fi' \
    _ "${REPO_ROOT}/src/config.sh" "$CONF"
  [ "$status" -eq 0 ]
  [ "$output" = "OFF" ]
}

@test "attribution::enabled: enabled:false => disabled" {
  _load_with "  attribution:
    enabled: false"
  run bash -c 'source "$1"; config::load "$2"; if config::attribution_enabled; then echo ON; else echo OFF; fi' \
    _ "${REPO_ROOT}/src/config.sh" "$CONF"
  [ "$status" -eq 0 ]
  [ "$output" = "OFF" ]
}

@test "attribution::enabled: enabled:true => enabled" {
  _load_with "  attribution:
    enabled: true"
  run bash -c 'source "$1"; config::load "$2"; if config::attribution_enabled; then echo ON; else echo OFF; fi' \
    _ "${REPO_ROOT}/src/config.sh" "$CONF"
  [ "$status" -eq 0 ]
  [ "$output" = "ON" ]
}

@test "attribution::assignee/label: default to true when enabled" {
  _load_with "  attribution:
    enabled: true"
  run bash -c 'source "$1"; config::load "$2"; if config::attribution_assignee; then echo A; fi; if config::attribution_label; then echo L; fi' \
    _ "${REPO_ROOT}/src/config.sh" "$CONF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"A"* ]]
  [[ "$output" == *"L"* ]]
}

@test "attribution::assignee: assignee:false disables only the assignee track" {
  _load_with "  attribution:
    enabled: true
    assignee: false
    label: true"
  run bash -c 'source "$1"; config::load "$2"; if config::attribution_assignee; then echo A; else echo noA; fi; if config::attribution_label; then echo L; fi' \
    _ "${REPO_ROOT}/src/config.sh" "$CONF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"noA"* ]]
  [[ "$output" == *"L"* ]]
}

@test "attribution::label: label:false disables only the label track" {
  _load_with "  attribution:
    enabled: true
    assignee: true
    label: false"
  run bash -c 'source "$1"; config::load "$2"; if config::attribution_label; then echo L; else echo noL; fi; if config::attribution_assignee; then echo A; fi' \
    _ "${REPO_ROOT}/src/config.sh" "$CONF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"noL"* ]]
  [[ "$output" == *"A"* ]]
}

@test "attribution::authors_file: returns the configured path, else the default" {
  _load_with "  attribution:
    enabled: true
    authors_file: \".specify/extensions/jira/custom-authors.yml\""
  run bash -c 'source "$1"; config::load "$2"; config::attribution_authors_file' \
    _ "${REPO_ROOT}/src/config.sh" "$CONF"
  [ "$status" -eq 0 ]
  [ "$output" = ".specify/extensions/jira/custom-authors.yml" ]
}

@test "attribution::authors_file: defaults to the canonical gitignored path" {
  _load_with "  attribution:
    enabled: true"
  run bash -c 'source "$1"; config::load "$2"; config::attribution_authors_file' \
    _ "${REPO_ROOT}/src/config.sh" "$CONF"
  [ "$status" -eq 0 ]
  [ "$output" = ".specify/extensions/jira/jira-authors.local.yml" ]
}
