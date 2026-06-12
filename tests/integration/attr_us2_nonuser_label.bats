#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/attr_us2_nonuser_label.bats  (feature-007 US2 — T016)
#
# The universal-label track. A KNOWN author with NO Jira account (accountId:
# null in the map) → the CREATE omits the assignee but STILL labels
# `author:<handle>` (AS-1, SC-002). An UNRESOLVABLE author (no Owner: line, no
# git history) → no label, no assignee, the run completes (AS-2, FR-007 graceful
# — not an error).
#
# Offline + deterministic over the curl-shim; no network, no PII (Principle IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  AUTHORS="${BATS_TEST_TMPDIR}/jira-authors.local.yml"
  cat >"$AUTHORS" <<'YAML'
schema_version: 1
authors:
  "nonuser@example.com":
    accountId: null
    handle: "nonuser"
default_assignee: null
YAML

  CONF="${BATS_TEST_TMPDIR}/jira-config.yml"
  cat >"$CONF" <<YAML
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
  attribution:
    enabled: true
    assignee: true
    label: true
    authors_file: "${AUTHORS}"
YAML
  config::load "$CONF"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::install
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204
}

teardown() {
  jira_shim::uninstall
}

_spec_input() {
  # An author value + source; empty value => unresolvable (no .author at all).
  local value="${1:-}" source="${2:-git_first_add}"
  if [[ -z "$value" ]]; then
    jq -cn '{summary:"007 — X", body:"b", state:"specifying", labels:["speckit-spec:007"]}'
  else
    jq -cn --arg v "$value" --arg s "$source" \
      '{summary:"007 — X", body:"b", state:"specifying",
        labels:["speckit-spec:007"], author:{value:$v, source:$s}}'
  fi
}

@test "US2 (AS-1): a null-accountId author -> NO assignee but author:<handle> label" {
  run sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input nonuser@example.com)"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  # The label still lands (the universal guarantee).
  printf '%s\n' "$reqs" | grep -q '"author:nonuser"' || {
    echo "the author:<handle> label was not applied for a non-Jira-user" >&2
    printf '%s\n' "$reqs" >&2; false; }
  # NO assignee field on the create (the non-member cannot be an assignee).
  if printf '%s\n' "$reqs" | grep -q '"assignee"'; then
    echo "an assignee was set for a null-accountId author" >&2
    printf '%s\n' "$reqs" >&2; false
  fi
}

@test "US2 (AS-2): an unresolvable author -> NO label, NO assignee, run completes" {
  run sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input)"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  # A create still fired (the spec is mirrored) — but with neither attribution.
  printf '%s\n' "$reqs" | grep -q '^URL https://example.atlassian.net/rest/api/3/issue$'
  if printf '%s\n' "$reqs" | grep -q '"assignee"'; then
    echo "an assignee was set for an unresolvable author" >&2
    printf '%s\n' "$reqs" >&2; false
  fi
  if printf '%s\n' "$reqs" | grep -q '"author:'; then
    echo "an author:* label was set for an unresolvable author" >&2
    printf '%s\n' "$reqs" >&2; false
  fi
}

@test "US2: an author absent from the map -> NO label, NO assignee (graceful no-op)" {
  run sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input stranger@example.com git_first_add)"
  [ "$status" -eq 0 ]
  local reqs
  reqs="$(jira_shim::requests)"
  if printf '%s\n' "$reqs" | grep -qE '"assignee"|"author:'; then
    echo "attribution leaked for an unmapped author" >&2
    printf '%s\n' "$reqs" >&2; false
  fi
}
