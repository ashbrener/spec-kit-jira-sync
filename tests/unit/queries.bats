#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/queries.bats — sink READ contract units (engine-sink-interface.md
# §Read). Proves the two idempotency lookups the US2 sync paths drive:
#   * query_spec_issue       <spec_label> <project>
#   * query_subissue_for_phase <parent_key> <phase_label>
#
# For each: the JQL request SHAPE (so the lookup actually scopes by label /
# project / parent), the ABSENT result (rc 0 + `[]` → the engine then CREATES),
# the PRESENT result (rc 0 + the matching issue), and UNREADABLE propagation
# (a 401 → rc 3, so the engine fails closed rather than blind-creating).
#
# Offline + deterministic over the curl-shim (decision D10); no network, no real
# Jira coordinates (Principle IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"

  # bats `set -o functrace` makes jira_rest::_request's RETURN cleanup trap be
  # inherited by the shimmed curl, deleting the response body before it is read.
  # Production bash does not inherit it; disable functrace so reads behave.
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0

  # Source the engine (its tail guard skips main on source); pulls in the sink.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate

  jira_shim::install
}

teardown() {
  jira_shim::uninstall
}

# --- query_spec_issue --------------------------------------------------------

@test "query_spec_issue scopes the JQL by label AND project" {
  jira_shim::set_response GET "*/search/jql*" search_found_story.json 200

  run query_spec_issue "speckit-spec:001" "PROJ"
  [ "$status" -eq 0 ]

  local url
  url="$(jira_shim::requests | awk '/^URL / && /search\/jql/ {print; exit}')"
  local decoded
  decoded="$(python3 - "$url" <<'PY' 2>/dev/null || true
import sys, urllib.parse
print(urllib.parse.unquote(sys.argv[1]))
PY
)"
  # Fall back to raw-encoded checks if python3 is unavailable.
  if [[ -n "$decoded" ]]; then
    [[ "$decoded" == *'labels = "speckit-spec:001"'* ]]
    [[ "$decoded" == *'project = "PROJ"'* ]]
    [[ "$decoded" == *'ORDER BY updated DESC'* ]]
  else
    [[ "$url" == *'labels'* ]]
    [[ "$url" == *'project'* ]]
  fi
}

# REGRESSION GUARD (real-Jira bug): the MODERN /search/jql endpoint returns
# issues WITHOUT `.key`/`.fields` unless `fields` is requested. Every idempotency
# lookup reads `.key` + `.fields.*`, so a fields-less search re-creates the whole
# board on each run. Assert search_jql ALWAYS pins the field set + a bounded page
# so we can never silently regress to the fieldless query the mock hid.
@test "query_spec_issue requests an explicit fields set (so key+fields return)" {
  jira_shim::set_response GET "*/search/jql*" search_found_story.json 200

  run query_spec_issue "speckit-spec:001" "PROJ"
  [ "$status" -eq 0 ]

  local url
  url="$(jira_shim::requests | awk '/^URL / && /search\/jql/ {print; exit}')"
  # fields= is the load-bearing token: without it Jira omits key + fields.
  [[ "$url" == *'fields=summary,status,updated,labels,parent'* ]] || {
    echo "search request lacks the fields param: $url" >&2
    false
  }
  # A bounded page (the lookups only need the freshest match).
  [[ "$url" == *'maxResults=100'* ]] || {
    echo "search request lacks maxResults: $url" >&2
    false
  }
}

@test "query_spec_issue returns the matching Story (present)" {
  jira_shim::set_response GET "*/search/jql*" search_found_story.json 200

  run query_spec_issue "speckit-spec:001" "PROJ"
  [ "$status" -eq 0 ]

  # rc 0 + a one-element array carrying the issue key + fields.
  local key
  key="$(printf '%s' "$output" | jq -r '.[0].key')"
  [ "$key" = "PROJ-101" ]
  local len
  len="$(printf '%s' "$output" | jq -r 'length')"
  [ "$len" -eq 1 ]
}

@test "query_spec_issue reports ABSENT as rc 0 + empty array" {
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200

  run query_spec_issue "speckit-spec:404" "PROJ"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'length')" -eq 0 ]
}

@test "query_spec_issue propagates an unreadable read as rc 3" {
  jira_shim::set_response GET "*/search/jql*" error_401.json 401

  run query_spec_issue "speckit-spec:001" "PROJ"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# --- query_subissue_for_phase ------------------------------------------------

@test "query_subissue_for_phase scopes the JQL by parent AND phase label" {
  jira_shim::set_response GET "*/search/jql*" search_found_story.json 200

  run query_subissue_for_phase "PROJ-101" "task-phase:1"
  [ "$status" -eq 0 ]

  local url
  url="$(jira_shim::requests | awk '/^URL / && /search\/jql/ {print; exit}')"
  local decoded
  decoded="$(python3 - "$url" <<'PY' 2>/dev/null || true
import sys, urllib.parse
print(urllib.parse.unquote(sys.argv[1]))
PY
)"
  if [[ -n "$decoded" ]]; then
    [[ "$decoded" == *'parent = "PROJ-101"'* ]]
    [[ "$decoded" == *'labels = "task-phase:1"'* ]]
  else
    [[ "$url" == *'parent'* ]]
    [[ "$url" == *'labels'* ]]
  fi
}

@test "query_subissue_for_phase reports ABSENT as rc 0 + empty array" {
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200

  run query_subissue_for_phase "PROJ-101" "task-phase:9"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'length')" -eq 0 ]
}

@test "query_subissue_for_phase propagates an unreadable read as rc 3" {
  jira_shim::set_response GET "*/search/jql*" error_401.json 401

  run query_subissue_for_phase "PROJ-101" "task-phase:1"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# -----------------------------------------------------------------------------
# Regression — REAL-JIRA ADF round-trip (found by the live dogfood). Two real
# behaviors: (1) Jira drops empty paragraphs on store, so an empty body POSTed as
# {doc:[{paragraph,content:[]}]} reads back as {doc:content:[]}; (2) right after a
# fresh CREATE, Jira returns the description as `null` until a later write settles
# it. All three forms (null, empty-content doc, empty-paragraph doc) are
# SEMANTICALLY EMPTY and MUST normalize equal — else the Story description churns
# one write per fresh create before settling (SC-017 zero-write violation).
# -----------------------------------------------------------------------------
@test "normalize_adf: null, empty-content doc, and empty-paragraph doc all canonicalize equal (no churn)" {
  local n e p
  n="$(jira_sink::_normalize_adf "null")"
  e="$(jira_sink::_normalize_adf '{"type":"doc","version":1,"content":[]}')"
  p="$(jira_sink::_normalize_adf '{"version":1,"type":"doc","content":[{"type":"paragraph","content":[]}]}')"
  [ "$n" = "$e" ]
  [ "$e" = "$p" ]
}

@test "normalize_adf: a paragraph with real text is preserved and differs from empty" {
  local doc out empty
  doc='{"version":1,"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"hi"}]}]}'
  out="$(jira_sink::_normalize_adf "$doc")"
  empty="$(jira_sink::_normalize_adf '{"type":"doc","version":1,"content":[]}')"
  [[ "$out" == *'"text":"hi"'* ]]
  [ "$out" != "$empty" ]
}
