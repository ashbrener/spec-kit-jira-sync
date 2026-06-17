#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/seed_us2.bats  (feature 008 — US2, T021-T022)
#
# Seed validates the phase:* / task-phase:N label prefixes and confirms every
# configured phase_status id is reachable on the project's workflow
# (GET project/<key>/statuses), capturing/confirming the ids via
# config::write_binding. It NEVER pre-creates labels and NEVER mutates the
# admin-scoped workflow. Fail-closed (exit 2) names the unreachable lifecycle
# step and writes no partial binding; a healthy re-run is a byte-identical
# no-op (C-8). An unreachable status ⇒ exit 2 (C-9).
#
# Offline + deterministic over the curl-shim; placeholder-only (Privacy IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export JIRA_MAX_RETRIES=0
  export DRY_RUN=0
  export CONFIG_TEMPLATE_PATH="$REPO_ROOT/config-template.yml"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/seed.sh"

  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER/specs"
  cd "$CONSUMER"
  TARGET="$CONSUMER/jira-config.yml"

  # A bound config whose 6 phase_status ids are the project's status ids.
  cat > "$TARGET" <<'YAML'
jira:
  project_key: "PROJ"
  issue_types:
    epic: "12001"
    story: "12002"
    subtask: "12003"
  phase_status:
    specifying: "31001"
    planning: "31001"
    tasking: "31002"
    implementing: "31002"
    ready_to_merge: "31003"
    merged: "31003"
  transitions: {}
  labels:
    spec_prefix: "speckit-spec:"
    repo_prefix: "speckit-repo:"
    phase_prefix: "task-phase:"
    lifecycle_prefix: "phase:"
YAML

  jira_shim::install
}

teardown() {
  jira_shim::uninstall
}

_statuses_all_present() {
  local f="$BATS_TEST_TMPDIR/stat_all.json"
  jq -n '[ { "id":"10000","name":"Story","statuses":[
      {"id":"31001","name":"To Do","statusCategory":{"key":"new"}},
      {"id":"31002","name":"In Progress","statusCategory":{"key":"indeterminate"}},
      {"id":"31003","name":"Done","statusCategory":{"key":"done"}}
  ]} ]' >"$f"
  jira_shim::set_response GET "*/project/PROJ/statuses*" "$f" 200
}

@test "T021 seed validates labels + confirms reachability; re-run byte-identical (C-8)" {
  _statuses_all_present

  run seed::main --config "$TARGET"
  [ "$status" -eq 0 ]

  cp "$TARGET" "$BATS_TEST_TMPDIR/first.yml"

  # Re-run unchanged ⇒ byte-identical no-op.
  jira_shim::reset
  _statuses_all_present
  run seed::main --config "$TARGET"
  [ "$status" -eq 0 ]

  run cmp "$BATS_TEST_TMPDIR/first.yml" "$TARGET"
  [ "$status" -eq 0 ]
}

@test "T022 seed fails closed on an unreachable status (exit 2), names it, no partial write (C-9)" {
  # Statuses missing the Done-category id (31003) that ready_to_merge + merged
  # point at ⇒ those phases are unreachable.
  local f="$BATS_TEST_TMPDIR/stat_missing.json"
  jq -n '[ { "id":"10000","name":"Story","statuses":[
      {"id":"31001","name":"To Do","statusCategory":{"key":"new"}},
      {"id":"31002","name":"In Progress","statusCategory":{"key":"indeterminate"}}
  ]} ]' >"$f"
  jira_shim::set_response GET "*/project/PROJ/statuses*" "$f" 200

  cp "$TARGET" "$BATS_TEST_TMPDIR/before.yml"

  run seed::main --config "$TARGET"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ready_to_merge"* ]] || [[ "$output" == *"merged"* ]] || [[ "$output" == *"31003"* ]]

  # No partial write — the binding is unchanged byte-for-byte.
  run cmp "$BATS_TEST_TMPDIR/before.yml" "$TARGET"
  [ "$status" -eq 0 ]
}
