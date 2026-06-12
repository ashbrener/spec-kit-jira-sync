#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/attr_us1_assignee_label.bats  (feature-007 US1 — T014)
#
# The US1 MVP gate: attribution ENABLED + an author mapped to an accountId +
# handle → on CREATE the spec issue's payload carries `fields.assignee.accountId`
# AND `author:<handle>` in its labels (AS-1, SC-001). An explicit `Owner:` line
# overrides the git author (AS-2).
#
# Offline + deterministic over the curl-shim (decision D10). No network, no real
# Jira coordinates / PII (Principle IX) — the authors map is a placeholder file.
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace   # see us1_fresh.bats — keep the shim transport production-like

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  # A placeholder authors map (gitignored shape; here a temp file).
  AUTHORS="${BATS_TEST_TMPDIR}/jira-authors.local.yml"
  cat >"$AUTHORS" <<'YAML'
schema_version: 1
authors:
  "alice@example.com":
    accountId: "0000aaaa1111bbbb2222cccc"
    handle: "alice"
default_assignee: null
YAML

  # Config WITH attribution enabled, pointing at the placeholder map.
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

# The neutral spec-level input compose_payload would produce, carrying author.
_spec_input() {
  local value="${1:-alice@example.com}" source="${2:-owner_line}"
  jq -cn --arg v "$value" --arg s "$source" \
    '{summary:"007 — Author", body:"b", state:"specifying",
      labels:["speckit-spec:007"], author:{value:$v, source:$s}}'
}

@test "US1: a mapped author -> CREATE carries fields.assignee.accountId AND author:<handle> label" {
  run sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input)"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"

  # The CREATE payload sets the assignee to the mapped accountId.
  printf '%s\n' "$reqs" | grep -q '"assignee":{"accountId":"0000aaaa1111bbbb2222cccc"}' || {
    echo "create payload did not carry the assignee accountId" >&2
    printf '%s\n' "$reqs" >&2; false; }

  # AND the always-on author:<handle> label rides the labels set.
  printf '%s\n' "$reqs" | grep -q '"author:alice"' || {
    echo "create payload did not carry the author:<handle> label" >&2
    printf '%s\n' "$reqs" >&2; false; }
}

@test "US1: the label carries a non-PII handle, never the email (Privacy IX)" {
  sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input)" >/dev/null

  local reqs
  reqs="$(jira_shim::requests)"
  # An author:* label exists, and NO label embeds the raw email.
  printf '%s\n' "$reqs" | grep -q '"author:alice"'
  if printf '%s\n' "$reqs" | grep -q '"author:alice@example.com"'; then
    echo "a label leaked the raw email (PII)" >&2
    printf '%s\n' "$reqs" >&2; false
  fi
}

@test "US1 (AS-2): an Owner: line value drives attribution (overrides git)" {
  # The neutral author here is source=owner_line — exactly what an Owner: line
  # produces; the sink maps that value to the mapped account+handle.
  run sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input alice@example.com owner_line)"
  [ "$status" -eq 0 ]
  local reqs
  reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | grep -q '"assignee":{"accountId":"0000aaaa1111bbbb2222cccc"}'
  printf '%s\n' "$reqs" | grep -q '"author:alice"'
}

@test "US1: the identity + lifecycle labels are preserved alongside author:<handle>" {
  sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input)" >/dev/null
  local reqs
  reqs="$(jira_shim::requests)"
  printf '%s\n' "$reqs" | grep -q '"speckit-spec:007"'
  printf '%s\n' "$reqs" | grep -q '"author:alice"'
}
