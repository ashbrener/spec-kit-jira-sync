#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/authors_map.bats  (feature-007 T006 — FR-002/FR-004, R3)
#
# The SINK-SIDE author identity map loader. `jira_sink::_load_authors <path>`
# parses the gitignored `jira-authors.local.yml` into a NEUTRAL JSON object on
# stdout:
#   { "authors": { "<email>": {"accountId": <id|null>, "handle": "<h>"} ... },
#     "default_assignee": <id|null> }
# A null accountId is label-only; an absent file → an empty map (no error). A
# known author missing `handle` is flagged (it is a config error — no PII
# fallback). PURE parse test: no network, no live Jira, placeholders only.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # Source the engine (its tail guard skips main on source) so the sink fns +
  # config are present.
  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/src/jira_sink.sh"
}

_write_map() {
  local path="$1"
  cat >"$path" <<'YAML'
schema_version: 1
authors:
  "dev-one@example.com":
    accountId: "0000aaaa1111bbbb2222cccc"
    handle: "dev-one"
  "dev-two@example.com":
    accountId: null
    handle: "dev-two"
default_assignee: null
YAML
}

@test "_load_authors: parses email -> {accountId, handle}" {
  local map="${BATS_TEST_TMPDIR}/authors.yml"
  _write_map "$map"
  run jira_sink::_load_authors "$map"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.authors["dev-one@example.com"].accountId == "0000aaaa1111bbbb2222cccc"'
  echo "$output" | jq -e '.authors["dev-one@example.com"].handle == "dev-one"'
}

@test "_load_authors: a null accountId is preserved (label-only author)" {
  local map="${BATS_TEST_TMPDIR}/authors.yml"
  _write_map "$map"
  run jira_sink::_load_authors "$map"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.authors["dev-two@example.com"].accountId == null'
  echo "$output" | jq -e '.authors["dev-two@example.com"].handle == "dev-two"'
}

@test "_load_authors: default_assignee is carried (null = unassigned)" {
  local map="${BATS_TEST_TMPDIR}/authors.yml"
  _write_map "$map"
  run jira_sink::_load_authors "$map"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.default_assignee == null'
}

@test "_load_authors: an absent file yields an empty map (no error)" {
  run jira_sink::_load_authors "${BATS_TEST_TMPDIR}/does-not-exist.yml"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.authors | length) == 0'
}

@test "_load_authors: a default_assignee with a real id is carried" {
  local map="${BATS_TEST_TMPDIR}/authors2.yml"
  cat >"$map" <<'YAML'
schema_version: 1
authors:
  "dev-three@example.com":
    accountId: "1111dddd2222eeee3333ffff"
    handle: "dev-three"
default_assignee: "9999zzzz8888yyyy7777xxxx"
YAML
  run jira_sink::_load_authors "$map"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.default_assignee == "9999zzzz8888yyyy7777xxxx"'
}

# --- a known author missing a handle is flagged (FR-004, no PII fallback) -----

@test "jira_sink::_author_handle: a mapped author with no handle is a config error" {
  local map="${BATS_TEST_TMPDIR}/nohandle.yml"
  cat >"$map" <<'YAML'
schema_version: 1
authors:
  "dev-four@example.com":
    accountId: "2222aaaa3333bbbb4444cccc"
default_assignee: null
YAML
  local loaded
  loaded="$(jira_sink::_load_authors "$map")"
  # A mapped author whose entry has no handle → no label token (rc != 0),
  # surfaced to the operator rather than falling back to a PII email.
  run jira_sink::_author_handle "$loaded" "dev-four@example.com"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "jira_sink::_author_handle: a mapped author with a handle returns it" {
  local map="${BATS_TEST_TMPDIR}/authors.yml"
  _write_map "$map"
  local loaded
  loaded="$(jira_sink::_load_authors "$map")"
  run jira_sink::_author_handle "$loaded" "dev-one@example.com"
  [ "$status" -eq 0 ]
  [ "$output" = "dev-one" ]
}

@test "jira_sink::_author_accountId: a mapped author returns the accountId" {
  local map="${BATS_TEST_TMPDIR}/authors.yml"
  _write_map "$map"
  local loaded
  loaded="$(jira_sink::_load_authors "$map")"
  run jira_sink::_author_accountId "$loaded" "dev-one@example.com"
  [ "$status" -eq 0 ]
  [ "$output" = "0000aaaa1111bbbb2222cccc" ]
}

@test "jira_sink::_author_accountId: a null-accountId author returns empty (label-only)" {
  local map="${BATS_TEST_TMPDIR}/authors.yml"
  _write_map "$map"
  local loaded
  loaded="$(jira_sink::_load_authors "$map")"
  run jira_sink::_author_accountId "$loaded" "dev-two@example.com"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "jira_sink::_author_handle: an unknown author returns empty (graceful no-op)" {
  local map="${BATS_TEST_TMPDIR}/authors.yml"
  _write_map "$map"
  local loaded
  loaded="$(jira_sink::_load_authors "$map")"
  run jira_sink::_author_handle "$loaded" "stranger@example.com"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
