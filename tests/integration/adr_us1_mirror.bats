#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/adr_us1_mirror.bats — feature 005 US1 (T012-T014).
#
# End-to-end over the MOCKED Jira REST (curl-shim): a reconcile mirrors a spec's
# research.md decision records as ONE comment per ADR on the spec's issue,
# coexisting with the clarify-session comments, and is a graceful no-op when
# there are no decisions.
#
#   T012 (AS-1, SC-001): a research.md with 2 decisions → exactly 2 ADR comment
#         POSTs, each carrying id/title/status/decision/rationale/source + the
#         [speckit-adr:…] marker.
#   T013 (AS-3, FR-008): a spec already carrying a clarify session → the ADR
#         comments are ADDED while the clarify (speckit-note:) comment is also
#         posted; the two marker streams are disjoint.
#   T014 (AS-2, FR-007, SC-004): a spec whose research.md has no decisions (and
#         a spec with no research.md) → ZERO ADR comments, ZERO errors.
#
# Driven through reconcile::process_spec over a 002-updates copy augmented with a
# research.md. Placeholders only (Principle IX).
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
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  WORKDIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORKDIR/specs"
  cp -R "$REPO_ROOT/tests/fixtures/specs/002-updates" "$WORKDIR/specs/002-updates"
  # Augment the spec with a research.md carrying two decisions (one explicit-id,
  # one un-headed/title-slug). Source-of-truth for the ADR comment stream.
  cp "$REPO_ROOT/tests/fixtures/specs/005-adr-bold/research.md" \
     "$WORKDIR/specs/002-updates/research.md"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  jira_shim::install

  FIX="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$FIX"
  jq -n '{comments:[
    {id:"30000", body:{type:"doc",version:1,content:[
      {type:"paragraph",content:[{type:"text",text:"unrelated chatter"}]}]}}]}' \
    >"$FIX/comments_absent.json"
  jq -n '{fields:{issuelinks:[]}}' >"$FIX/issuelinks_absent.json"

  ARG_QUIET=1
}

teardown() { jira_shim::uninstall; }

# Register a full process_spec sweep with all comment reads ABSENT (→ create).
adr::register_absent() {
  jira_shim::set_response GET "*?fields=issuelinks*" "$FIX/issuelinks_absent.json" 200
  jira_shim::set_response GET "*/comment*" "$FIX/comments_absent.json" 200
  jira_shim::set_response GET "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response GET "*/search/jql*" "$REPO_ROOT/tests/fixtures/jira_responses/search_absent.json" 200
  jira_shim::set_response POST "*/issueLink" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response POST "*/issue/*/comment" "$REPO_ROOT/tests/fixtures/jira_responses/comment_create_ok.json" 201
  jira_shim::set_response POST "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/rest/api/3/issue" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
}

# Count the ADR-marker-carrying comment POST bodies.
_adr_posts() {
  jira_shim::requests | grep -A2 '^METHOD POST' | grep -cF 'speckit-adr:' || true
}
_note_posts() {
  jira_shim::requests | grep -A2 '^METHOD POST' | grep -cF 'speckit-note:' || true
}

# --- T012: 2 decisions → 2 ADR comments --------------------------------------

@test "a research.md with two decisions posts exactly two ADR comments (SC-001)" {
  cd "$WORKDIR"
  adr::register_absent

  summary::start "adr us1"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]

  [ "$(_adr_posts)" -eq 2 ] || {
    echo "expected 2 ADR comment POSTs, got $(_adr_posts)" >&2
    jira_shim::requests >&2; false; }

  # Each ADR's marker + key fields are present in the POST stream.
  local reqs; reqs="$(jira_shim::requests | grep -A2 '^METHOD POST')"
  printf '%s' "$reqs" | grep -qF 'speckit-adr:002-R1'
  printf '%s' "$reqs" | grep -qF 'speckit-adr:002-caching-layer'
  printf '%s' "$reqs" | grep -qF 'ADR R1'
  printf '%s' "$reqs" | grep -qF 'Status:'
  printf '%s' "$reqs" | grep -qF 'Decision:'
  printf '%s' "$reqs" | grep -qF 'Rationale:'
  printf '%s' "$reqs" | grep -qF 'research.md#R1'
}

# --- T013: ADR comments coexist with the clarify comment ---------------------

@test "ADR comments are added alongside the clarify comment (disjoint streams, FR-008)" {
  cd "$WORKDIR"
  adr::register_absent

  summary::start "adr us1 coexist"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]

  # Both streams post: the clarify session (speckit-note:) AND the 2 ADRs.
  [ "$(_note_posts)" -ge 1 ] || { echo "clarify comment not posted" >&2; jira_shim::requests >&2; false; }
  [ "$(_adr_posts)" -eq 2 ] || { echo "expected 2 ADR posts, got $(_adr_posts)" >&2; false; }
  # No ADR POST carries a clarify marker and vice-versa (disjoint).
  ! jira_shim::requests | grep -A2 '^METHOD POST' | grep -F 'speckit-adr:' | grep -qF 'speckit-note:'
}

# --- T014: graceful no-op when there are no decisions ------------------------

@test "a research.md with no decision blocks posts ZERO ADR comments, no error (SC-004)" {
  cd "$WORKDIR"
  cp "$REPO_ROOT/tests/fixtures/specs/007-adr-empty/research.md" \
     "$WORKDIR/specs/002-updates/research.md"
  adr::register_absent

  summary::start "adr us1 empty"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]
  [ "$(_adr_posts)" -eq 0 ] || { echo "expected 0 ADR posts, got $(_adr_posts)" >&2; false; }
}

@test "a spec with no research.md posts ZERO ADR comments, no error (FR-007)" {
  cd "$WORKDIR"
  rm -f "$WORKDIR/specs/002-updates/research.md"
  adr::register_absent

  summary::start "adr us1 noresearch"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]
  [ "$(_adr_posts)" -eq 0 ] || { echo "expected 0 ADR posts, got $(_adr_posts)" >&2; false; }
}
