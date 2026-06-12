#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/attr_us3_idempotent.bats  (feature-007 US3 — T018)
#
# Idempotency + manual-reassignment safety. The assignee is a CREATE-only
# attribution: an UPDATE of an already-created spec issue sends NO assignee field
# (FR-003/SC-003, Linear FR-034) so a manual reassignment in Jira survives. The
# author:<handle> label is strip-stale-then-set: a re-run leaves exactly ONE
# author:* label (no stacking), and a changed author REPLACES it (FR-004).
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
    accountId: "0000aaaa1111bbbb2222cccc"
    handle: "alice"
  "bob@example.com":
    accountId: "1111bbbb2222cccc3333dddd"
    handle: "bob"
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
}

teardown() {
  jira_shim::uninstall
}

_spec_input() {
  local value="${1:-alice@example.com}"
  jq -cn --arg v "$value" \
    '{summary:"007 — Author", body:"b", state:"specifying",
      labels:["speckit-spec:007"], author:{value:$v, source:"owner_line"}}'
}

# An EXISTING spec issue (found by the identity search), already carrying a
# stale author:* label (a previous author) so strip-stale-then-set is exercised.
# Its summary/body differ so a benign field PUT may or may not fire; the
# assertions only inspect whether assignee/author-label behave correctly.
_install_existing() {
  local found="${BATS_TEST_TMPDIR}/found.json"
  cat >"$found" <<'JSON'
{
  "startAt": 0, "maxResults": 50, "total": 1,
  "issues": [
    { "id": "10007", "key": "PROJ-107",
      "fields": { "labels": ["speckit-spec:007", "phase:specifying", "author:stale"] } }
  ]
}
JSON
  local full="${BATS_TEST_TMPDIR}/full.json"
  cat >"$full" <<'JSON'
{
  "summary": "007 — Author",
  "description": {"version":1,"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"b"}]}]},
  "labels": ["speckit-spec:007", "phase:specifying", "author:stale"],
  "parent": {"key": "PROJ-100"},
  "status": {"id": "20001"},
  "assignee": {"accountId": "manual-reassigned-account"}
}
JSON
  jira_shim::set_response GET "*/search/jql*" "$found" 200
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  jira_shim::set_response GET "*/rest/api/3/issue/PROJ-107*" "$full" 200
  jira_shim::set_response PUT "*/rest/api/3/issue/*" issue_create_ok.json 204
}

@test "US3 (AS-1): the UPDATE payload contains NO assignee field (manual reassignment survives)" {
  _install_existing
  run sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input)"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  # A PUT (update) fired, and NO PUT body carries an assignee field.
  printf '%s\n' "$reqs" | grep -q '^METHOD PUT$'
  local put_bodies
  put_bodies="$(printf '%s\n' "$reqs" | awk '/^METHOD PUT$/{p=1} p&&/^BODY /{print; p=0}')"
  if printf '%s\n' "$put_bodies" | grep -q '"assignee"'; then
    echo "the UPDATE payload leaked an assignee field (would clobber a manual reassignment)" >&2
    printf '%s\n' "$put_bodies" >&2; false
  fi
}

@test "US3 (AS-2): a re-run leaves exactly ONE author:* label (stale stripped, not stacked)" {
  _install_existing
  run sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input)"
  [ "$status" -eq 0 ]

  local reqs put_bodies
  reqs="$(jira_shim::requests)"
  put_bodies="$(printf '%s\n' "$reqs" | awk '/^METHOD PUT$/{p=1} p&&/^BODY /{sub(/^BODY /,"");print; p=0}')"

  # The labels PUT must carry the CURRENT author:alice, and NOT the stale one.
  printf '%s\n' "$put_bodies" | grep -q '"author:alice"' || {
    echo "the update did not set the current author label" >&2
    printf '%s\n' "$put_bodies" >&2; false; }
  if printf '%s\n' "$put_bodies" | grep -q '"author:stale"'; then
    echo "the stale author label was not stripped (would stack)" >&2
    printf '%s\n' "$put_bodies" >&2; false
  fi

  # Exactly one author:* token in the labels array of the PUT.
  local count
  count="$(printf '%s\n' "$put_bodies" | jq -r '[.fields.labels[]? | select(startswith("author:"))] | length' 2>/dev/null | head -1)"
  [ "$count" = "1" ] || {
    echo "expected exactly one author:* label, got ${count}" >&2
    printf '%s\n' "$put_bodies" >&2; false; }
}

@test "US3: a CHANGED author replaces the label (alice -> bob)" {
  _install_existing
  run sync_level_artifact spec "speckit-spec:007" "PROJ-100" "$(_spec_input bob@example.com)"
  [ "$status" -eq 0 ]

  local reqs put_bodies
  reqs="$(jira_shim::requests)"
  put_bodies="$(printf '%s\n' "$reqs" | awk '/^METHOD PUT$/{p=1} p&&/^BODY /{sub(/^BODY /,"");print; p=0}')"
  printf '%s\n' "$put_bodies" | grep -q '"author:bob"'
  if printf '%s\n' "$put_bodies" | grep -qE '"author:stale"|"author:alice"'; then
    echo "a non-current author label survived" >&2
    printf '%s\n' "$put_bodies" >&2; false
  fi
}
