#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/comments_links.bats — US4 sink units (FR-007: at-most-once
# comments + idempotent cross-spec issue links).
#
# Proves the two READ probes and the two WRITE orchestrators the US4 paths drive:
#   * query_existing_comment_body <issue_key> <marker>  (the comment dedup probe)
#   * query_issue_blocks <issue_key>                     (the link-set baseline)
#   * sync_clarify_comments  <story_key> <item_json>     (post a note at-most-once)
#   * sync_inter_phase_blocks <story_key> <item_json>    (link a dep at-most-once)
#
# Marker scheme under test (jira_sink::_note_marker): a stable hidden token
# `[speckit-note:<hex>]` derived from the note's (timestamp_iso + body) via
# cksum, embedded as a trailing ADF paragraph text run on the posted comment.
# query_existing_comment_body substring-matches that marker on re-run → SKIP.
#
# Link idempotency: query_issue_blocks reports the Story's already-linked target
# KEYS (both inward + outward neighbours); sync_inter_phase_blocks POSTs
# /issueLink ONLY for a dep target not already in that set.
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

  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX"

  # A single workstate note (a clarify session) + its stable marker.
  CL_NOTE="$(jq -cn '{timestamp_iso:"2026-05-20T00:00:00+00:00", body:"### Session 2026-05-20\n\n- Q: scope? A: yes"}')"
  CL_ITEM="$(jq -cn --argjson n "$CL_NOTE" '{notes:[$n], links:[]}')"
  CL_MARKER="$(jira_sink::_note_marker "$CL_NOTE")"

  # A comments list that CARRIES the marker (the already-posted comment).
  jq -n --arg m "$CL_MARKER" '{comments:[
     {id:"30001", body:{type:"doc",version:1,content:[
        {type:"paragraph",content:[{type:"text",text:"### Session 2026-05-20"}]},
        {type:"paragraph",content:[{type:"text",text:$m}]}
     ]}}]}' >"$FIX/comments_present.json"

  # A comments list that does NOT carry the marker (a foreign comment only).
  jq -n '{comments:[
     {id:"30000", body:{type:"doc",version:1,content:[
        {type:"paragraph",content:[{type:"text",text:"unrelated chatter"}]}
     ]}}]}' >"$FIX/comments_absent.json"

  # An issuelinks read where target PROJ-201 is ALREADY linked (outward).
  jq -n '{fields:{issuelinks:[
     {type:{name:"Blocks"}, outwardIssue:{key:"PROJ-201"}}
  ]}}' >"$FIX/links_present.json"

  # An issuelinks read with NO links (the target is unlinked).
  jq -n '{fields:{issuelinks:[]}}' >"$FIX/links_absent.json"

  # A spec-Story search that resolves a dep target NNN → its Story key PROJ-201.
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
     {id:"10201",key:"PROJ-201",fields:{
        summary:"002 — dep", labels:["speckit-spec:002"],
        status:{id:"20001",name:"Mapped"}, updated:"2026-05-31T00:00:00.000+0000"
     }}]}' >"$FIX/dep_search.json"

  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

# =============================================================================
# query_existing_comment_body — the comment dedup probe
# =============================================================================

@test "query_existing_comment_body finds the comment carrying the marker (present)" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" "$FIX/comments_present.json" 200

  run query_existing_comment_body "PROJ-101" "$CL_MARKER"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(printf '%s' "$output" | jq -r '.id')" = "30001" ]
}

@test "query_existing_comment_body returns empty (rc 0) when no comment carries the marker (absent)" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" "$FIX/comments_absent.json" 200

  run query_existing_comment_body "PROJ-101" "$CL_MARKER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "query_existing_comment_body propagates an unreadable read as rc 3" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" error_401.json 401

  run query_existing_comment_body "PROJ-101" "$CL_MARKER"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# =============================================================================
# query_issue_blocks — the link-set baseline
# =============================================================================

@test "query_issue_blocks returns the already-linked edges with type + direction (present)" {
  jira_shim::set_response GET "*/issue/PROJ-101*" "$FIX/links_present.json" 200

  run query_issue_blocks "PROJ-101"
  [ "$status" -eq 0 ]
  # Edge shape {type,dir,key} retains link TYPE + DIRECTION (data-model dedup by
  # (rel,target)), not just the bare neighbour key.
  [ "$(printf '%s' "$output" | jq -r 'any(.[]; .type == "Blocks" and .dir == "outward" and .key == "PROJ-201")')" = "true" ]
}

@test "query_issue_blocks returns an empty array (rc 0) when the issue has no links (absent)" {
  jira_shim::set_response GET "*/issue/PROJ-101*" "$FIX/links_absent.json" 200

  run query_issue_blocks "PROJ-101"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'length')" -eq 0 ]
}

@test "query_issue_blocks propagates an unreadable read as rc 3" {
  jira_shim::set_response GET "*/issue/PROJ-101*" error_401.json 401

  run query_issue_blocks "PROJ-101"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# =============================================================================
# sync_clarify_comments — post a note at-most-once
# =============================================================================

@test "sync_clarify_comments posts ONE comment carrying the stable marker (absent → create)" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" "$FIX/comments_absent.json" 200
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201

  run sync_clarify_comments "PROJ-101" "$CL_ITEM"
  [ "$status" -eq 0 ]

  local reqs posts
  reqs="$(jira_shim::requests)"
  posts="$(printf '%s\n' "$reqs" \
    | grep -B2 '^URL .*/issue/PROJ-101/comment$' | grep -c '^METHOD POST$' || true)"
  [ "$posts" -eq 1 ] || { echo "expected 1 comment POST, got $posts" >&2; printf '%s\n' "$reqs" >&2; false; }

  # The posted comment body carries the stable hidden marker. `grep -F` so the
  # marker's literal `[...]` is not read as a character range.
  printf '%s\n' "$reqs" | grep -A2 '^METHOD POST' | grep -qF -- "$CL_MARKER" \
    || { echo "comment POST body missing marker $CL_MARKER" >&2; printf '%s\n' "$reqs" >&2; false; }
}

@test "sync_clarify_comments SKIPS (no POST) when the marker is already present (re-run)" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" "$FIX/comments_present.json" 200
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201

  run sync_clarify_comments "PROJ-101" "$CL_ITEM"
  [ "$status" -eq 0 ]

  local posts
  posts="$(jira_shim::requests \
    | grep -B2 '^URL .*/issue/PROJ-101/comment$' | grep -c '^METHOD POST$' || true)"
  [ "$posts" -eq 0 ] || { echo "expected 0 comment POSTs on re-run, got $posts" >&2; false; }
}

@test "sync_clarify_comments fails closed (rc 3) when the comment read is unreadable" {
  jira_shim::set_response GET "*/issue/PROJ-101/comment*" error_401.json 401
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201

  run sync_clarify_comments "PROJ-101" "$CL_ITEM"
  [ "$status" -eq 3 ]

  # Fail-closed: no blind comment POST on an unreadable read.
  local posts
  posts="$(jira_shim::requests \
    | grep -B2 '^URL .*/issue/PROJ-101/comment$' | grep -c '^METHOD POST$' || true)"
  [ "$posts" -eq 0 ] || { echo "expected 0 comment POSTs on fail-closed, got $posts" >&2; false; }
}

# =============================================================================
# sync_inter_phase_blocks — link a dep at-most-once
# =============================================================================

@test "sync_inter_phase_blocks posts ONE /issueLink for an unlinked dep (absent → create)" {
  local item
  item="$(jq -cn '{notes:[], links:[{rel:"depends_on", target:"002"}]}')"

  jira_shim::set_response GET "*/issue/PROJ-101?fields=issuelinks*" "$FIX/links_absent.json" 200
  jira_shim::set_response GET "*/search/jql*" "$FIX/dep_search.json" 200
  jira_shim::set_response POST "*/issueLink" issue_create_ok.json 201

  run sync_inter_phase_blocks "PROJ-101" "$item"
  [ "$status" -eq 0 ]

  local reqs links
  reqs="$(jira_shim::requests)"
  links="$(printf '%s\n' "$reqs" \
    | grep -B2 '^URL .*/issueLink$' | grep -c '^METHOD POST$' || true)"
  [ "$links" -eq 1 ] || { echo "expected 1 issueLink POST, got $links" >&2; printf '%s\n' "$reqs" >&2; false; }

  # The link payload names the resolved target Story key.
  printf '%s\n' "$reqs" | grep -A2 '^URL .*/issueLink$' | grep -q 'PROJ-201' \
    || { echo "issueLink body missing target PROJ-201" >&2; printf '%s\n' "$reqs" >&2; false; }
}

@test "sync_inter_phase_blocks adds NO /issueLink when the dep is already linked (re-run)" {
  local item
  item="$(jq -cn '{notes:[], links:[{rel:"depends_on", target:"002"}]}')"

  jira_shim::set_response GET "*/issue/PROJ-101?fields=issuelinks*" "$FIX/links_present.json" 200
  jira_shim::set_response GET "*/search/jql*" "$FIX/dep_search.json" 200
  jira_shim::set_response POST "*/issueLink" issue_create_ok.json 201

  run sync_inter_phase_blocks "PROJ-101" "$item"
  [ "$status" -eq 0 ]

  local links
  links="$(jira_shim::requests \
    | grep -B2 '^URL .*/issueLink$' | grep -c '^METHOD POST$' || true)"
  [ "$links" -eq 0 ] || { echo "expected 0 issueLink POSTs on re-run, got $links" >&2; false; }
}

@test "sync_inter_phase_blocks fails closed (rc 3) when the link read is unreadable" {
  local item
  item="$(jq -cn '{notes:[], links:[{rel:"depends_on", target:"002"}]}')"

  jira_shim::set_response GET "*/issue/PROJ-101?fields=issuelinks*" error_401.json 401
  jira_shim::set_response GET "*/search/jql*" "$FIX/dep_search.json" 200
  jira_shim::set_response POST "*/issueLink" issue_create_ok.json 201

  run sync_inter_phase_blocks "PROJ-101" "$item"
  [ "$status" -eq 3 ]

  local links
  links="$(jira_shim::requests \
    | grep -B2 '^URL .*/issueLink$' | grep -c '^METHOD POST$' || true)"
  [ "$links" -eq 0 ] || { echo "expected 0 issueLink POSTs on fail-closed, got $links" >&2; false; }
}

# =============================================================================
# US4 P2 — comment pagination: a marker living BEYOND page 1 is still found, so
# the note is NOT re-posted (no duplicate comment on re-run).
# =============================================================================

@test "query_existing_comment_body paginates: marker on page 2 is found (rc 0, non-empty)" {
  # Page 1 (startAt=0): a single foreign comment, total=2 → a second page exists.
  jq -n '{startAt:0, maxResults:1, total:2, comments:[
     {id:"40000", body:{type:"doc",version:1,content:[
        {type:"paragraph",content:[{type:"text",text:"page one chatter"}]}
     ]}}]}' >"$FIX/comments_page1.json"
  # Page 2 (startAt=1): the comment CARRYING the marker.
  jq -n --arg m "$CL_MARKER" '{startAt:1, maxResults:1, total:2, comments:[
     {id:"40001", body:{type:"doc",version:1,content:[
        {type:"paragraph",content:[{type:"text",text:$m}]}
     ]}}]}' >"$FIX/comments_page2.json"

  jira_shim::set_response GET "*/issue/PROJ-101/comment?startAt=0*" "$FIX/comments_page1.json" 200
  jira_shim::set_response GET "*/issue/PROJ-101/comment?startAt=1*" "$FIX/comments_page2.json" 200

  run query_existing_comment_body "PROJ-101" "$CL_MARKER"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(printf '%s' "$output" | jq -r '.id')" = "40001" ]
}

@test "sync_clarify_comments posts ZERO comments when the marker is on page 2 (no duplicate)" {
  jq -n '{startAt:0, maxResults:1, total:2, comments:[
     {id:"40000", body:{type:"doc",version:1,content:[
        {type:"paragraph",content:[{type:"text",text:"page one chatter"}]}
     ]}}]}' >"$FIX/comments_page1.json"
  jq -n --arg m "$CL_MARKER" '{startAt:1, maxResults:1, total:2, comments:[
     {id:"40001", body:{type:"doc",version:1,content:[
        {type:"paragraph",content:[{type:"text",text:$m}]}
     ]}}]}' >"$FIX/comments_page2.json"

  jira_shim::set_response GET "*/issue/PROJ-101/comment?startAt=0*" "$FIX/comments_page1.json" 200
  jira_shim::set_response GET "*/issue/PROJ-101/comment?startAt=1*" "$FIX/comments_page2.json" 200
  jira_shim::set_response POST "*/issue/PROJ-101/comment" comment_create_ok.json 201

  run sync_clarify_comments "PROJ-101" "$CL_ITEM"
  [ "$status" -eq 0 ]

  # The marker was found on page 2 → at-most-once: NO new comment POST. Without
  # pagination, page 1 alone reads as absent and the note is wrongly re-posted.
  local posts
  posts="$(jira_shim::requests \
    | grep -B2 '^URL .*/issue/PROJ-101/comment$' | grep -c '^METHOD POST$' || true)"
  [ "$posts" -eq 0 ] || { echo "expected 0 comment POSTs (marker on page 2), got $posts" >&2; false; }
}

# =============================================================================
# US4 P2 — link dedup by (rel, target): an UNRELATED existing link type to the
# same neighbour must NOT skip the desired dependency.
# =============================================================================

@test "sync_inter_phase_blocks still creates the dep when only an UNRELATED link type names the target" {
  local item
  item="$(jq -cn '{notes:[], links:[{rel:"depends_on", target:"002"}]}')"

  # PROJ-201 is already linked, but via an UNRELATED type ("Relates"), not the
  # dependency type ("Blocks"). The (rel,target) dedup must NOT treat that as the
  # desired dependency → it must still POST the Blocks link.
  jq -n '{fields:{issuelinks:[
     {type:{name:"Relates"}, outwardIssue:{key:"PROJ-201"}}
  ]}}' >"$FIX/links_unrelated_type.json"

  jira_shim::set_response GET "*/issue/PROJ-101?fields=issuelinks*" "$FIX/links_unrelated_type.json" 200
  jira_shim::set_response GET "*/search/jql*" "$FIX/dep_search.json" 200
  jira_shim::set_response POST "*/issueLink" issue_create_ok.json 201

  run sync_inter_phase_blocks "PROJ-101" "$item"
  [ "$status" -eq 0 ]

  local links
  links="$(jira_shim::requests \
    | grep -B2 '^URL .*/issueLink$' | grep -c '^METHOD POST$' || true)"
  [ "$links" -eq 1 ] || { echo "expected 1 issueLink POST (unrelated type must not skip), got $links" >&2; jira_shim::requests >&2; false; }
}

# =============================================================================
# US4 P2 — duplicate-dep-same-run: two dep bullets resolving to the SAME
# (rel,target) must POST /issueLink exactly ONCE in one run.
# =============================================================================

@test "sync_inter_phase_blocks posts ONE /issueLink for duplicate deps to the same target in one run" {
  local item
  # Two dependency bullets resolving to the SAME target (the id form and its bare
  # feature number both normalise to 002 → PROJ-201).
  item="$(jq -cn '{notes:[], links:[
     {rel:"depends_on", target:"002-other"},
     {rel:"depends_on", target:"002"}
  ]}')"

  jira_shim::set_response GET "*/issue/PROJ-101?fields=issuelinks*" "$FIX/links_absent.json" 200
  jira_shim::set_response GET "*/search/jql*" "$FIX/dep_search.json" 200
  jira_shim::set_response POST "*/issueLink" issue_create_ok.json 201

  run sync_inter_phase_blocks "PROJ-101" "$item"
  [ "$status" -eq 0 ]

  # The mid-run baseline update dedups the second bullet → exactly ONE POST.
  local links
  links="$(jira_shim::requests \
    | grep -B2 '^URL .*/issueLink$' | grep -c '^METHOD POST$' || true)"
  [ "$links" -eq 1 ] || { echo "expected 1 issueLink POST (same-run dedup), got $links" >&2; jira_shim::requests >&2; false; }
}
