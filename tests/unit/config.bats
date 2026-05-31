#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/config.bats
#
# Unit tests for src/config.sh — the loader + validator for the gitignored
# `.specify/extensions/jira/jira-config.yml`. PURE tests: no network, no curl,
# no live Jira. They drive load / get / get_status_transition / validate against
# a PLACEHOLDER fixture (project key PROJ, fake numeric ids).
#
# Privacy (Principle IX): the fixture uses placeholders only — never real Jira
# coordinates or PII.
#
# Note: config.sh's fatal paths `exit 2` from inside the sourced function. We
# run each accessor in a `bash -c` subshell that sources the module, so a fatal
# exit is captured as a non-zero `status` instead of aborting the bats run.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  FIXTURE="${REPO_ROOT}/tests/fixtures/config/jira-config.sample.yml"
}

# Run a config snippet in a fresh subshell with config.sh sourced. Args after
# the snippet are passed through as positional params ($1, $2, ...).
_run_config() {
  local snippet="$1"; shift
  run bash -c '
    set -euo pipefail
    source "$0"
    '"${snippet}"'
  ' "${REPO_ROOT}/src/config.sh" "$@"
}

# --- config::load ------------------------------------------------------------

@test "load: valid fixture loads cleanly" {
  _run_config 'config::load "$1"' "$FIXTURE"
  [ "$status" -eq 0 ]
}

@test "load: missing file is a project-level error (exit 2)" {
  _run_config 'config::load "$1"' "${REPO_ROOT}/tests/fixtures/config/does-not-exist.yml"
  [ "$status" -eq 2 ]
  [[ "$output" == *"file not found"* ]]
}

@test "load: default path used when no argument given" {
  # No such file at the default relative path from REPO_ROOT -> exit 2 naming
  # the default location (proves the default is wired without needing a real
  # gitignored config present).
  _run_config 'cd "$1"; config::load' "$REPO_ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *".specify/extensions/jira/jira-config.yml"* ]]
}

# --- config::get -------------------------------------------------------------

@test "get: top-level scalar (project_key)" {
  _run_config 'config::load "$1"; config::get project_key' "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "PROJ" ]
}

@test "get: nested scalar (issue_types.story)" {
  _run_config 'config::load "$1"; config::get issue_types.story' "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "10002" ]
}

@test "get: label prefix preserves trailing colon" {
  _run_config 'config::load "$1"; config::get labels.spec_prefix' "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "speckit-spec:" ]
}

@test "get: missing key halts with precise error (exit 2)" {
  _run_config 'config::load "$1"; config::get issue_types.nope' "$FIXTURE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"issue_types.nope is missing"* ]]
}

@test "get: before load halts" {
  _run_config 'config::get project_key'
  [ "$status" -eq 2 ]
  [[ "$output" == *"no config loaded"* ]]
}

# --- config::get_status_transition (the vendor lever) ------------------------

@test "get_status_transition: phase with no explicit transition -> status id only" {
  _run_config 'config::load "$1"; config::get_status_transition specifying' "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "20001" ]
}

@test "get_status_transition: phase with explicit transition -> status TAB transition" {
  _run_config 'config::load "$1"; config::get_status_transition implementing' "$FIXTURE"
  [ "$status" -eq 0 ]
  # Two TAB-separated fields: target status id, then explicit transition id.
  local tab=$'\t'
  [ "$output" = "20004${tab}30004" ]
}

@test "get_status_transition: unknown phase halts (exit 2)" {
  _run_config 'config::load "$1"; config::get_status_transition bogus' "$FIXTURE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown lifecycle phase: bogus"* ]]
}

@test "get_status_transition: missing phase_status mapping halts (exit 2)" {
  # A config that omits phase_status.merged.
  local tmp="${BATS_TEST_TMPDIR}/partial.yml"
  cat > "$tmp" <<'YAML'
jira:
  phase_status:
    specifying: "20001"
YAML
  _run_config 'config::load "$1"; config::get_status_transition merged' "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"phase_status.merged is missing"* ]]
}

# --- config::validate --------------------------------------------------------

@test "validate: complete fixture passes" {
  _run_config 'config::load "$1"; config::validate' "$FIXTURE"
  [ "$status" -eq 0 ]
}

@test "validate: missing required keys surface precise errors (exit 2)" {
  # Minimal config missing project_key, two issue types, most phases, all labels.
  local tmp="${BATS_TEST_TMPDIR}/incomplete.yml"
  cat > "$tmp" <<'YAML'
jira:
  issue_types:
    epic: "10001"
  phase_status:
    specifying: "20001"
YAML
  _run_config 'config::load "$1"; config::validate' "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"project_key: missing"* ]]
  [[ "$output" == *"issue_types.story: missing"* ]]
  [[ "$output" == *"issue_types.subtask: missing"* ]]
  [[ "$output" == *"phase_status.merged: missing"* ]]
  [[ "$output" == *"labels.spec_prefix: missing"* ]]
}

@test "validate: transitions: {} inline empty map does not break parsing" {
  local tmp="${BATS_TEST_TMPDIR}/empty-transitions.yml"
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
YAML
  _run_config 'config::load "$1"; config::validate && config::get labels.lifecycle_prefix' "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "phase:" ]
}
