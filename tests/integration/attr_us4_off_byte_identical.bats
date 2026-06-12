#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/attr_us4_off_byte_identical.bats  (feature-007 US4 — T020)
#
# The backward-compat regression anchor. With `attribution.enabled` ABSENT or
# explicitly false, a create/update emits ZERO assignee fields and ZERO author:*
# labels — byte-identical to pre-007 (AS-1, FR-006, SC-004). The off-by-default
# path must short-circuit BEFORE any map load / resolution side-effect, even when
# the neutral input still carries an `author {value,source}` floor.
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

  jira_shim::install
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204
}

teardown() {
  jira_shim::uninstall
}

# A config WITHOUT an attribution block (the pre-007 shape), or with it disabled.
_load_config() {
  local attr="${1:-}"   # "" => absent block; otherwise a snippet
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
    [[ -n "$attr" ]] && printf '%s\n' "$attr"
  } >"$CONF"
  config::load "$CONF"
  config::validate
  mapping::parse
  mapping::validate
}

# A neutral spec input that DOES carry an author floor (would attribute if ON).
_spec_input() {
  jq -cn '{summary:"007 — Author", body:"b", state:"specifying",
           labels:["speckit-spec:007"],
           author:{value:"alice@example.com", source:"owner_line"}}'
}

@test "US4: an ABSENT attribution block -> zero assignee, zero author:* label on create" {
  _load_config ""
  run sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input)"
  [ "$status" -eq 0 ]
  local reqs
  reqs="$(jira_shim::requests)"
  if printf '%s\n' "$reqs" | grep -qE '"assignee"|"author:'; then
    echo "attribution leaked with the block ABSENT (not byte-identical)" >&2
    printf '%s\n' "$reqs" >&2; false
  fi
}

@test "US4: attribution.enabled:false -> zero assignee, zero author:* label" {
  _load_config "  attribution:
    enabled: false
    assignee: true
    label: true"
  run sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input)"
  [ "$status" -eq 0 ]
  local reqs
  reqs="$(jira_shim::requests)"
  if printf '%s\n' "$reqs" | grep -qE '"assignee"|"author:'; then
    echo "attribution leaked with enabled:false" >&2
    printf '%s\n' "$reqs" >&2; false
  fi
}

@test "US4: the create payload with the block absent equals the pre-007 label set" {
  _load_config ""
  sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input)" >/dev/null
  local reqs create_body
  reqs="$(jira_shim::requests)"
  create_body="$(printf '%s\n' "$reqs" | awk '/rest\/api\/3\/issue$/{u=1} u&&/^BODY /{sub(/^BODY /,"");print;u=0}' | head -1)"
  # Labels are exactly the identity + lifecycle set the engine composed — no
  # author:* token added.
  printf '%s\n' "$create_body" | jq -e '[.fields.labels[] | select(startswith("author:"))] | length == 0'
  printf '%s\n' "$create_body" | jq -e '.fields | has("assignee") | not'
}
