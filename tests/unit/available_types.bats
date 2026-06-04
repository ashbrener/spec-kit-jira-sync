#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/available_types.bats  (T015, US2)
#
# Unit tests for the available-issue-type probe in src/config.sh
# (`mapping::detect_available_types`). It probes the target project's issue-type
# metadata over the curl-shim (issuetype_meta/ fixtures) and echoes the
# available-type NAME set (one per line). A real unreadable read fails CLOSED
# (rc 3) so the engine never validates against an empty/partial set (FR-005,
# Q10).
#
# Offline + deterministic over the curl-shim (decision D10); no network, no real
# Jira coordinates (Privacy IX). The Kanban fixture deliberately ships
# Task/Epic/Subtask with NO Story so the absent-type policy (T017) has a real
# missing-type surface to validate against.
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"

  # bats `set -o functrace` makes jira_rest's RETURN cleanup trap be inherited by
  # the shimmed curl, deleting the response body before it is read. Production
  # bash does not inherit it; disable functrace so reads behave.
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0

  # config.sh owns the probe; jira_rest.sh is its transport. Source both.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/jira_rest.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/config.sh"

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"

  jira_shim::install
}

teardown() {
  jira_shim::uninstall
}

# --- the probe returns the project's available-type NAME set ------------------

@test "detect_available_types returns the Scrum project's type names" {
  jira_shim::set_response GET "*/project/PROJ*" issuetype_meta/project_scrum.json 200

  run mapping::detect_available_types
  [ "$status" -eq 0 ]
  [[ "$output" == *"Epic"* ]]
  [[ "$output" == *"Story"* ]]
  [[ "$output" == *"Task"* ]]
  [[ "$output" == *"Subtask"* ]]
}

@test "detect_available_types probes the project issue-type metadata endpoint" {
  jira_shim::set_response GET "*/project/PROJ*" issuetype_meta/project_scrum.json 200

  run mapping::detect_available_types
  [ "$status" -eq 0 ]

  local url
  url="$(jira_shim::requests | awk '/^URL / && /project/ {print; exit}')"
  [[ "$url" == *"/rest/api/3/project/PROJ"* ]] || {
    echo "probe did not hit the project metadata endpoint: $url" >&2
    false
  }
}

# --- the Kanban template ships NO Story (Q10 missing-type surface) ------------

@test "detect_available_types: a Kanban template ships Task/Epic/Subtask, NO Story" {
  jira_shim::set_response GET "*/project/PROJ*" issuetype_meta/project_kanban.json 200

  run mapping::detect_available_types
  [ "$status" -eq 0 ]
  [[ "$output" == *"Epic"* ]]
  [[ "$output" == *"Task"* ]]
  [[ "$output" == *"Subtask"* ]]
  # The defining Kanban property: no Story type at all. NF5-class HARD guard
  # (plain `if`, no `|| true`) so a stray Story actually fails the test.
  if printf '%s\n' "$output" | grep -qx "Story"; then
    echo "Kanban fixture must NOT contain Story" >&2
    false
  fi
}

# --- a real unreadable read fails closed (rc 3) ------------------------------

@test "detect_available_types: an unreadable probe (401) returns rc 3 (fail-closed)" {
  jira_shim::set_response GET "*/project/PROJ*" error_401.json 401

  run mapping::detect_available_types
  [ "$status" -eq 3 ]
}

@test "detect_available_types: a malformed probe body returns rc 3 (fail-closed)" {
  # A 200 with a body that carries no issueTypes array is unreadable — we cannot
  # prove the available-type set, so fail closed rather than validate against an
  # empty set.
  local tmp="${BATS_TEST_TMPDIR}/garbage.json"
  printf 'not json at all' > "$tmp"
  jira_shim::set_response GET "*/project/PROJ*" "$tmp" 200

  run mapping::detect_available_types
  [ "$status" -eq 3 ]
}

# --- F7: a VALID 200 whose issueTypes is empty/absent fails closed (rc 3) ------

@test "detect_available_types: a valid 200 with an EMPTY issueTypes returns rc 3 (fail-closed)" {
  # A well-formed JSON project resource whose issueTypes is [] proves NOTHING
  # about the available set (we'd validate every configured artifact as absent,
  # or — worse if treated as success — skip the gate entirely). Fail closed.
  jira_shim::set_response GET "*/project/PROJ*" issuetype_meta/project_no_types.json 200

  run mapping::detect_available_types
  [ "$status" -eq 3 ]
}

@test "detect_available_types: a valid 200 with NO issueTypes key returns rc 3 (fail-closed)" {
  # The issueTypes array is entirely absent (a partial/wrong project resource) —
  # also unprovable → fail closed rather than treat as an empty available set.
  local tmp="${BATS_TEST_TMPDIR}/no-issuetypes-key.json"
  jq -n '{id:"10400", key:"PROJ", name:"Sample Project Missing Issue Types"}' > "$tmp"
  jira_shim::set_response GET "*/project/PROJ*" "$tmp" 200

  run mapping::detect_available_types
  [ "$status" -eq 3 ]
}
