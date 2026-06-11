#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/attr_bad_assignee_failsoft.bats  (feature-007 — T022/FR-008)
#
# Fail-soft on a rejected assignee write. A create whose assignee.accountId is
# stale/deactivated is rejected by Jira (400). The sink MUST surface it (warned,
# with _error_detail) and RETRY the create WITHOUT the assignee so the spec still
# completes WITH its author:<handle> label — it MUST NOT abort the whole reconcile.
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
  "alice@example.com":
    accountId: "0000staleaccountid000000"
    handle: "alice"
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
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204

  # A 400 error body that names the bad assignee field (Jira-shaped).
  ERRBODY="${BATS_TEST_TMPDIR}/err400.json"
  cat >"$ERRBODY" <<'JSON'
{"errorMessages":[],"errors":{"assignee":"User does not exist or is deactivated"}}
JSON
}

teardown() {
  jira_shim::uninstall
}

_spec_input() {
  jq -cn '{summary:"007 — Author", body:"b", state:"specifying",
           labels:["speckit-spec:007"],
           author:{value:"alice@example.com", source:"owner_line"}}'
}

@test "fail-soft: a rejected assignee create is retried without the assignee, label lands, no abort" {
  # FIRST POST /issue (with assignee) → 400; SECOND POST /issue (retry, no
  # assignee) → 201. push_response queues the per-call answers in order.
  jira_shim::push_response POST "*/rest/api/3/issue" "$ERRBODY" 400
  jira_shim::push_response POST "*/rest/api/3/issue" issue_create_ok.json 201

  # Call DIRECTLY (not via `run`, which subshells) so the fail-soft global
  # survives for the assertion below.
  JIRA_SINK_LEVEL_ASSIGNEE_FAILED=0
  local rc=0
  sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input)" >/dev/null 2>&1 || rc=$?
  # The spec STILL completes (rc 0) — not aborted by the bad assignee.
  [ "$rc" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"

  # TWO create POSTs fired: the first WITH the assignee, the second WITHOUT.
  local creates
  creates="$(printf '%s\n' "$reqs" | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$')"
  [ "$creates" -eq 2 ] || {
    echo "expected 2 create POSTs (assignee attempt + no-assignee retry), got $creates" >&2
    printf '%s\n' "$reqs" >&2; false; }

  # Gather the create bodies in order.
  local bodies
  bodies="$(printf '%s\n' "$reqs" | awk '/rest\/api\/3\/issue$/{u=1} u&&/^BODY /{sub(/^BODY /,"");print;u=0}')"
  local first second
  first="$(printf '%s\n' "$bodies" | sed -n 1p)"
  second="$(printf '%s\n' "$bodies" | sed -n 2p)"

  # First attempt carried the assignee; the retry did NOT.
  printf '%s\n' "$first" | jq -e '.fields | has("assignee")'
  printf '%s\n' "$second" | jq -e '.fields | has("assignee") | not'
  # The author:<handle> label is present on BOTH (the label is the durable
  # guarantee — it lands regardless of the assignee outcome).
  printf '%s\n' "$second" | jq -e '[.fields.labels[] | select(. == "author:alice")] | length == 1'

  # The fail-soft flag was raised for the engine to surface.
  [ "${JIRA_SINK_LEVEL_ASSIGNEE_FAILED}" = "1" ]
}

@test "fail-soft: the rejection is surfaced with the field-level error detail" {
  jira_shim::push_response POST "*/rest/api/3/issue" "$ERRBODY" 400
  jira_shim::push_response POST "*/rest/api/3/issue" issue_create_ok.json 201

  run sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input)"
  [ "$status" -eq 0 ]
  # The warning line (stderr, captured by `run`) names the stale assignee and
  # quotes the Jira field error (diagnosable, not silent).
  printf '%s\n' "$output" | grep -q 'assignee write rejected'
  printf '%s\n' "$output" | grep -q 'deactivated'
}
