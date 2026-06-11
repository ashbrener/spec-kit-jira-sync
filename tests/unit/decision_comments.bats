#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/decision_comments.bats — ADR / decision-record mirroring.
#
# Proves sync_decision_records mirrors each of a spec's research.md decision
# records (carried on the neutral item's extensions.decisions[]) as ONE
# at-most-once comment on the spec Issue, keyed by the STABLE id-based hidden
# marker `[speckit-adr:<spec>-<id>]`:
#
#   * ABSENT → create exactly one comment per ADR, each carrying its marker.
#   * PRESENT (re-run) → ZERO new comments (idempotent at-most-once).
#   * unreadable comment read → fail closed rc 3, NO blind post.
#   * DRY_RUN → no write.
#
# Offline + deterministic over the curl-shim (decision D10); no network, no real
# Jira coordinates (Principle IX — PROJ / example.atlassian.net placeholders).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"

  # See comments_links.bats: bats functrace makes the shimmed curl inherit
  # jira_rest's RETURN cleanup trap, deleting the response body early. Disable.
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate

  jira_shim::install

  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX"

  # A spec item carrying TWO decision records (ADRs) on extensions.decisions[],
  # plus its speckit-spec identity label (the marker's spec-number source).
  ADR_ITEM="$(jq -cn '{
     labels: ["speckit-spec:001"],
     notes: [], links: [],
     extensions: { decisions: [
        { id:"D1", title:"Storage format", decision:"Use a flat JSON file.",
          rationale:"No migration.", alternatives:"SQLite.",
          source:"research.md#D1" },
        { id:"R5", title:"Retry policy", decision:"Bounded backoff.",
          rationale:"Matches throttling.", alternatives:"Immediate fail.",
          source:"research.md#R5" }
     ] }
  }')"
  MARKER_D1="$(jira_sink::_adr_marker "001" "D1")"
  MARKER_R5="$(jira_sink::_adr_marker "001" "R5")"

  # A comments list that already CARRIES both markers (the re-run case).
  jq -n --arg m1 "$MARKER_D1" --arg m2 "$MARKER_R5" '{comments:[
     {id:"50001", body:{type:"doc",version:1,content:[
        {type:"paragraph",content:[{type:"text",text:$m1}]}]}},
     {id:"50002", body:{type:"doc",version:1,content:[
        {type:"paragraph",content:[{type:"text",text:$m2}]}]}}
  ]}' >"$FIX/adr_present.json"

  # A comments list with NEITHER marker (the fresh case).
  jq -n '{comments:[
     {id:"50000", body:{type:"doc",version:1,content:[
        {type:"paragraph",content:[{type:"text",text:"unrelated chatter"}]}]}}
  ]}' >"$FIX/adr_absent.json"

  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

# Count comment POSTs to the spec Issue in the recorded request log.
_comment_posts() {
  jira_shim::requests \
    | grep -B2 '^URL .*/issue/PROJ-101/comment$' | grep -c '^METHOD POST$' || true
}

# =============================================================================
# Absent → create one comment per ADR, each carrying its stable marker.
# =============================================================================

@test "sync_decision_records posts ONE comment per ADR with its [speckit-adr:…] marker (absent → create)" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" "$FIX/adr_absent.json" 200
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201

  run sync_decision_records "PROJ-101" "$ADR_ITEM"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"
  [ "$(_comment_posts)" -eq 2 ] \
    || { echo "expected 2 ADR comment POSTs, got $(_comment_posts)" >&2; printf '%s\n' "$reqs" >&2; false; }

  # Both stable id-based markers are embedded in the posted comment bodies.
  printf '%s\n' "$reqs" | grep -A2 '^METHOD POST' | grep -qF -- "$MARKER_D1" \
    || { echo "D1 comment missing marker $MARKER_D1" >&2; printf '%s\n' "$reqs" >&2; false; }
  printf '%s\n' "$reqs" | grep -A2 '^METHOD POST' | grep -qF -- "$MARKER_R5" \
    || { echo "R5 comment missing marker $MARKER_R5" >&2; printf '%s\n' "$reqs" >&2; false; }

  # The comment body renders the ADR title line.
  printf '%s\n' "$reqs" | grep -A2 '^METHOD POST' | grep -q 'ADR D1' \
    || { echo "comment body missing 'ADR D1' title line" >&2; printf '%s\n' "$reqs" >&2; false; }
}

# =============================================================================
# Re-run: both markers present → ZERO new comments (idempotent at-most-once).
# =============================================================================

@test "sync_decision_records posts ZERO comments on re-run when both markers are present (idempotent)" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" "$FIX/adr_present.json" 200
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201

  run sync_decision_records "PROJ-101" "$ADR_ITEM"
  [ "$status" -eq 0 ]

  [ "$(_comment_posts)" -eq 0 ] \
    || { echo "expected 0 ADR comment POSTs on re-run, got $(_comment_posts)" >&2; jira_shim::requests >&2; false; }
}

# =============================================================================
# Fail-closed: an unreadable comment read returns rc 3 with no blind post.
# =============================================================================

@test "sync_decision_records fails closed (rc 3) when the comment read is unreadable" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" error_401.json 401
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201

  run sync_decision_records "PROJ-101" "$ADR_ITEM"
  [ "$status" -eq 3 ]

  [ "$(_comment_posts)" -eq 0 ] \
    || { echo "expected 0 ADR comment POSTs on fail-closed, got $(_comment_posts)" >&2; false; }
}

# =============================================================================
# DRY_RUN: no write, even when the ADRs are absent.
# =============================================================================

@test "sync_decision_records posts nothing under DRY_RUN" {
  export DRY_RUN=1
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" "$FIX/adr_absent.json" 200
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201

  run sync_decision_records "PROJ-101" "$ADR_ITEM"
  [ "$status" -eq 0 ]

  # mutate_comment_create no-ops under DRY_RUN — no real POST is issued.
  [ "$(_comment_posts)" -eq 0 ] \
    || { echo "expected 0 ADR comment POSTs under DRY_RUN, got $(_comment_posts)" >&2; jira_shim::requests >&2; false; }
}

# =============================================================================
# No decisions → sink no-op (no read, no write).
# =============================================================================

@test "sync_decision_records is a no-op when the item has no decisions" {
  local item
  item="$(jq -cn '{labels:["speckit-spec:001"], notes:[], links:[]}')"

  jira_shim::set_response GET "*/issue/PROJ-101/comment*" "$FIX/adr_absent.json" 200
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201

  run sync_decision_records "PROJ-101" "$item"
  [ "$status" -eq 0 ]
  [ "$(_comment_posts)" -eq 0 ]
}
