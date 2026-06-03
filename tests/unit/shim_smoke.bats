#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/shim_smoke.bats
#
# Smoke test for the curl-shim (tests/helpers/jira-shim.bash, decision D10).
# Proves the shim (1) serves a configured fixture for a method+URL, (2) splits
# the http_code off the tail, (3) records the request method/url/body, and
# (4) honours method/URL discrimination + reset.
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  jira_shim::install
  JIRA_BASE_URL="https://example.atlassian.net"
}

teardown() {
  jira_shim::uninstall
}

@test "shim serves a configured fixture and appends the http_code" {
  jira_shim::set_response GET "*/rest/api/3/myself" myself_ok.json 200

  run curl -sS -X GET -u "operator@example.com:token" \
    -w '\n%{http_code}\n' \
    "${JIRA_BASE_URL}/rest/api/3/myself"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"accountType": "atlassian"'* ]]
  [[ "$output" == *'200'* ]]
}

@test "shim records the request method, url, and body" {
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201

  run curl -sS -X POST -u "operator@example.com:token" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"summary":"001 — Sample"}}' \
    -w '\n%{http_code}\n' \
    "${JIRA_BASE_URL}/rest/api/3/issue"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"key": "PROJ-102"'* ]]
  [[ "$output" == *'201'* ]]

  run jira_shim::requests
  [[ "$output" == *'METHOD POST'* ]]
  [[ "$output" == *'URL https://example.atlassian.net/rest/api/3/issue'* ]]
  [[ "$output" == *'BODY {"fields":{"summary":"001 — Sample"}}'* ]]
}

@test "shim discriminates by method and url glob" {
  jira_shim::set_response GET "*/search/jql*" search_found_story.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201

  run curl -sS -X GET "${JIRA_BASE_URL}/rest/api/3/search/jql?jql=labels%3D%22speckit-spec%3A001%22" -w '\n%{http_code}\n'
  [[ "$output" == *'"key": "PROJ-101"'* ]]
  [[ "$output" == *'"speckit-spec:001"'* ]]
}

@test "shim -o writes body to file and emits only the status to stdout" {
  jira_shim::set_response GET "*/rest/api/3/myself" myself_ok.json 200
  local body_file="${BATS_TEST_TMPDIR}/body.json"

  run curl -sS -o "$body_file" -w '%{http_code}' "${JIRA_BASE_URL}/rest/api/3/myself"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
  grep -q '"accountType": "atlassian"' "$body_file"
}

@test "jira_shim::reset clears rules and recorded requests" {
  jira_shim::set_response GET "*/rest/api/3/myself" myself_ok.json 200
  run curl -sS "${JIRA_BASE_URL}/rest/api/3/myself" -w '\n%{http_code}\n'
  [[ "$output" == *'200'* ]]

  jira_shim::reset
  run jira_shim::requests
  [ -z "$output" ]
}
