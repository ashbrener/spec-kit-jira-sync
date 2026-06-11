#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/adr_sink.bats  (feature 005, T008b + T009 — FR-002/004/005/010)
#
# The Jira-sink ADR writers:
#   * mutate_comment_update <key> <comment_id> <body_adf>   (NET-NEW, analyze H1)
#       PUT /issue/{key}/comment/{id}; DRY_RUN no-op; malformed-ADF guard; fail
#       logging via _error_detail — mirrors mutate_comment_create.
#   * sync_decision_records <issue_key> <item_json>
#       one comment per item.decisions[]; marker [speckit-adr:<spec>-<id>];
#       query_existing_comment_body → rc 3 fail-closed / ABSENT create / PRESENT
#       digest-compare → update-in-place (same id, no duplicate) or skip.
#
# Offline + deterministic over the curl-shim; placeholders only (Principle IX).
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
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  jira_shim::install

  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX"

  # One ADR on the item. item.id carries the spec number (005).
  ADR="$(jq -cn '{
    id:"R1", title:"Storage engine choice", status:"Accepted",
    decision:"Use the embedded store.", rationale:"Single-binary deploy.",
    source:"research.md#R1"
  }')"
  ITEM="$(jq -cn --argjson d "$ADR" '{id:"005-adr", notes:[], decisions:[$d]}')"
  MARKER="$(jira_sink::_adr_marker "005" "R1")"
  DESIRED_BODY="$(jira_sink::_render_adr_body "$ADR" "005")"
  DESIRED_DIGEST="$(jira_sink::_adr_body_digest "$DESIRED_BODY")"

  # A comments page that does NOT carry the ADR marker (absent → create).
  jq -n '{comments:[
    {id:"50000", body:{type:"doc",version:1,content:[
      {type:"paragraph",content:[{type:"text",text:"unrelated chatter"}]}]}}]}' \
    >"$FIX/absent.json"

  # A comments page carrying the marker AND the up-to-date body (present, match).
  jq -n --argjson b "$DESIRED_BODY" \
    '{comments:[{id:"50001", body:$b}]}' >"$FIX/present_match.json"

  # A comments page carrying the marker but a STALE body (present, mismatch).
  local stale; stale="$(jq -cn --argjson d "$ADR" \
    '($d | .decision = "An old, superseded decision.")')"
  local stale_body; stale_body="$(jira_sink::_render_adr_body "$stale" "005")"
  jq -n --argjson b "$stale_body" \
    '{comments:[{id:"50002", body:$b}]}' >"$FIX/present_stale.json"

  ARG_QUIET=1
}

teardown() { jira_shim::uninstall; }

# =============================================================================
# mutate_comment_update  (T008b — analyze H1, NET-NEW)
# =============================================================================

@test "mutate_comment_update PUTs /issue/<key>/comment/<id> with the ADF body" {
  jira_shim::set_response PUT "*/issue/PROJ-101/comment/50001" comment_create_ok.json 200

  run mutate_comment_update "PROJ-101" "50001" "$DESIRED_BODY"
  [ "$status" -eq 0 ]

  local reqs puts
  reqs="$(jira_shim::requests)"
  puts="$(printf '%s\n' "$reqs" \
    | grep -B2 '^URL .*/issue/PROJ-101/comment/50001$' | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 1 ] || { echo "expected 1 PUT, got $puts" >&2; printf '%s\n' "$reqs" >&2; false; }
}

@test "mutate_comment_update is a no-op under DRY_RUN (no PUT)" {
  export DRY_RUN=1
  jira_shim::set_response PUT "*/issue/PROJ-101/comment/50001" comment_create_ok.json 200

  run mutate_comment_update "PROJ-101" "50001" "$DESIRED_BODY"
  [ "$status" -eq 0 ]

  local puts
  puts="$(jira_shim::requests | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 0 ] || { echo "expected 0 PUTs under DRY_RUN, got $puts" >&2; false; }
}

@test "mutate_comment_update guards a malformed ADF body (no PUT, rc 1)" {
  jira_shim::set_response PUT "*/issue/PROJ-101/comment/50001" comment_create_ok.json 200

  run mutate_comment_update "PROJ-101" "50001" "this is not json"
  [ "$status" -ne 0 ]

  local puts
  puts="$(jira_shim::requests | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 0 ] || { echo "expected 0 PUTs on malformed ADF, got $puts" >&2; false; }
}

# =============================================================================
# sync_decision_records  (T009)
# =============================================================================

@test "sync_decision_records creates ONE comment carrying the ADR marker (absent → create)" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" "$FIX/absent.json" 200
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201

  run sync_decision_records "PROJ-101" "$ITEM"
  [ "$status" -eq 0 ]

  local reqs posts
  reqs="$(jira_shim::requests)"
  posts="$(printf '%s\n' "$reqs" \
    | grep -B2 '^URL .*/issue/PROJ-101/comment$' | grep -c '^METHOD POST$' || true)"
  [ "$posts" -eq 1 ] || { echo "expected 1 POST, got $posts" >&2; printf '%s\n' "$reqs" >&2; false; }
  printf '%s\n' "$reqs" | grep -A2 '^METHOD POST' | grep -qF -- "$MARKER" \
    || { echo "POST body missing marker $MARKER" >&2; printf '%s\n' "$reqs" >&2; false; }
}

@test "sync_decision_records SKIPS when present + digest matches (zero churn)" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" "$FIX/present_match.json" 200
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201
  jira_shim::set_response PUT "*/issue/PROJ-101/comment/*" comment_create_ok.json 200

  run sync_decision_records "PROJ-101" "$ITEM"
  [ "$status" -eq 0 ]

  local writes
  writes="$(jira_shim::requests | grep -cE '^METHOD (POST|PUT)$' || true)"
  [ "$writes" -eq 0 ] || { echo "expected 0 writes (match), got $writes" >&2; jira_shim::requests >&2; false; }
}

@test "sync_decision_records UPDATES in place when present + digest mismatches (no duplicate)" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" "$FIX/present_stale.json" 200
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201
  jira_shim::set_response PUT "*/issue/PROJ-101/comment/50002" comment_create_ok.json 200

  run sync_decision_records "PROJ-101" "$ITEM"
  [ "$status" -eq 0 ]

  local reqs puts posts
  reqs="$(jira_shim::requests)"
  # Exactly one PUT against the EXISTING comment id (50002) — update in place.
  puts="$(printf '%s\n' "$reqs" \
    | grep -B2 '^URL .*/issue/PROJ-101/comment/50002$' | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 1 ] || { echo "expected 1 PUT to 50002, got $puts" >&2; printf '%s\n' "$reqs" >&2; false; }
  # NO new comment created.
  posts="$(printf '%s\n' "$reqs" \
    | grep -B2 '^URL .*/issue/PROJ-101/comment$' | grep -c '^METHOD POST$' || true)"
  [ "$posts" -eq 0 ] || { echo "expected 0 POSTs (update, not create), got $posts" >&2; false; }
}

@test "sync_decision_records fails closed (rc 3) on an unreadable comment probe" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" error_401.json 401
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201

  run sync_decision_records "PROJ-101" "$ITEM"
  [ "$status" -eq 3 ]

  local writes
  writes="$(jira_shim::requests | grep -cE '^METHOD (POST|PUT)$' || true)"
  [ "$writes" -eq 0 ] || { echo "expected 0 writes on fail-closed, got $writes" >&2; false; }
}

@test "sync_decision_records is a no-op for an item with no decisions[]" {
  local item; item="$(jq -cn '{id:"005-adr", notes:[], decisions:[]}')"
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" "$FIX/absent.json" 200

  run sync_decision_records "PROJ-101" "$item"
  [ "$status" -eq 0 ]
  local writes
  writes="$(jira_shim::requests | grep -cE '^METHOD (POST|PUT)$' || true)"
  [ "$writes" -eq 0 ]
}

@test "sync_decision_records does NOT touch clarify (speckit-note:) comments" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" "$FIX/absent.json" 200
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201

  run sync_decision_records "PROJ-101" "$ITEM"
  [ "$status" -eq 0 ]
  # The only marker written is the ADR one — no speckit-note: marker emitted.
  ! jira_shim::requests | grep -A2 '^METHOD POST' | grep -qF "speckit-note:"
}
