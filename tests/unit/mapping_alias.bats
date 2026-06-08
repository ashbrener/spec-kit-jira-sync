#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/mapping_alias.bats  (T004)
#
# Unit tests for the alias layer in src/config.sh
# (`mapping::synthesize_default`). PURE tests: no network, no curl, no live
# Jira. Placeholders only (Privacy IX).
#
# Coverage (FR-001, FR-002, US1 scenario 3):
#   - an ABSENT `mapping:` block synthesizes today's DEFAULT mapping
#     (repo→Epic, spec→Story, phase→Subtask, task→checklist; initiative + rollup
#     off);
#   - the alias layer adds the new `labels.task_prefix` default (Q9);
#   - a pre-feature config (no mapping block, no task_prefix) loads byte-for-byte
#     unchanged for every existing key;
#   - an EXPLICIT default block resolves identically to the synthesized one
#     (alias equivalence).
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

# --- absent mapping synthesizes today's default ------------------------------

@test "alias: absent mapping synthesizes repo→Epic" {
  _run_config 'config::load "$1"; mapping::parse; mapping::resolve_level repo' "$FIXTURE"
  [ "$status" -eq 0 ]
  local tab=$'\t'
  [ "$output" = "Epic${tab}none" ]
}

@test "alias: absent mapping synthesizes spec→Story (parent)" {
  _run_config 'config::load "$1"; mapping::parse; mapping::resolve_level spec' "$FIXTURE"
  [ "$status" -eq 0 ]
  local tab=$'\t'
  [ "$output" = "Story${tab}parent" ]
}

@test "alias: absent mapping synthesizes phase→Subtask (parent)" {
  _run_config 'config::load "$1"; mapping::parse; mapping::resolve_level phase' "$FIXTURE"
  [ "$status" -eq 0 ]
  local tab=$'\t'
  [ "$output" = "Subtask${tab}parent" ]
}

@test "alias: absent mapping synthesizes task→checklist (checklist)" {
  _run_config 'config::load "$1"; mapping::parse; mapping::resolve_level task' "$FIXTURE"
  [ "$status" -eq 0 ]
  local tab=$'\t'
  [ "$output" = "checklist${tab}checklist" ]
}

@test "alias: initiative + status_rollup default OFF" {
  _run_config 'config::load "$1"; mapping::parse; printf "%s/%s\n" "$(config::get mapping.initiative.enabled)" "$(config::get mapping.status_rollup.enabled)"' "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "false/false" ]
}

@test "alias: synthesizes the new labels.task_prefix default (Q9)" {
  _run_config 'config::load "$1"; mapping::parse; config::get labels.task_prefix' "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "speckit-task:" ]
}

# --- pre-feature config loads byte-for-byte unchanged ------------------------

@test "alias: a pre-feature config leaves every existing key unchanged" {
  # The shipped sample has NO mapping block and NO task_prefix. After parse, the
  # alias layer must not disturb any pre-existing value.
  _run_config '
    config::load "$1"; mapping::parse
    printf "%s|%s|%s|%s|%s\n" \
      "$(config::get project_key)" \
      "$(config::get issue_types.epic)" \
      "$(config::get phase_status.implementing)" \
      "$(config::get labels.spec_prefix)" \
      "$(config::get labels.repo_prefix)"
  ' "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "PROJ|10001|20004|speckit-spec:|speckit-repo:" ]
}

@test "alias: a pre-feature config still validates clean (existing config::validate)" {
  _run_config 'config::load "$1"; mapping::parse; config::validate' "$FIXTURE"
  [ "$status" -eq 0 ]
}

@test "alias: mapping::is_explicit is false for a no-mapping (aliased) config" {
  _run_config 'config::load "$1"; mapping::parse; if mapping::is_explicit; then echo explicit; else echo aliased; fi' "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "aliased" ]
}

# --- explicit default block == synthesized (alias equivalence) ----------------

@test "alias: explicit default block resolves identically to the synthesized one" {
  local tmp="${BATS_TEST_TMPDIR}/explicit-default.yml"
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
    task_prefix: "speckit-task:"
  mapping:
    initiative:
      enabled: false
      artifact: "Initiative"
      on_absent: "degrade"
      source: "spec_input"
    project_style: "team-managed"
    levels:
      repo:   { artifact: "Epic",      relationship_to_parent: "none" }
      spec:   { artifact: "Story",     relationship_to_parent: "parent" }
      phase:  { artifact: "Subtask",   relationship_to_parent: "parent" }
      task:   { artifact: "checklist", relationship_to_parent: "checklist" }
    status_rollup:
      enabled: false
YAML
  _run_config '
    config::load "$1"; mapping::parse
    for lvl in repo spec phase task; do mapping::resolve_level "$lvl"; done
    printf "init=%s rollup=%s\n" \
      "$(config::get mapping.initiative.enabled)" \
      "$(config::get mapping.status_rollup.enabled)"
  ' "$tmp"
  [ "$status" -eq 0 ]
  local tab=$'\t'
  local expected="Epic${tab}none
Story${tab}parent
Subtask${tab}parent
checklist${tab}checklist
init=false rollup=false"
  [ "$output" = "$expected" ]
}
