#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/adr_us2_idempotent.bats — feature 005 US2 (T016-T019).
#
# End-to-end over the MOCKED Jira REST: ADR mirroring is idempotent +
# update-in-place + fail-closed.
#
#   T016 (AS-1, FR-004, SC-002): re-run against an already-mirrored, UNCHANGED
#         corpus → 0 ADR creates, 0 edits (digest match → skip).
#   T017 (AS-2, FR-005, SC-003): one ADR's text changed on disk → exactly 1
#         comment UPDATED in place (PUT), 0 new comments.
#   T018 (AS-3, FR-006): a NEW ADR added → exactly 1 create, existing untouched.
#   T019 (FR-010, edge): an unreadable comment probe → rc 3 fail-closed (no blind
#         duplicate); a DRY-0 placeholder (dry-run of an unmirrored spec) → the
#         ADR probe is skipped (no 404).
#
# The PRESENT comment reads are built from the SAME rendered body the sink
# produces (computed in setup), so a "match" is a true match and a "mismatch" is
# a true content edit. Placeholders only (Principle IX).
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
  cp "$REPO_ROOT/tests/fixtures/specs/005-adr-bold/research.md" \
     "$WORKDIR/specs/002-updates/research.md"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  jira_shim::install

  FIX="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$FIX"
  jq -n '{fields:{issuelinks:[]}}' >"$FIX/issuelinks_absent.json"

  # The item the sink projects (spec 002) → its two decisions + rendered bodies.
  ITEM="$(workstate::item_for_spec "$WORKDIR/specs/002-updates")"
  local d0 d1
  d0="$(printf '%s' "$ITEM" | jq -c '.decisions[0]')"   # R1 (explicit id)
  d1="$(printf '%s' "$ITEM" | jq -c '.decisions[1]')"   # caching-layer
  BODY0="$(jira_sink::_render_adr_body "$d0" "002")"
  BODY1="$(jira_sink::_render_adr_body "$d1" "002")"

  # A comments page carrying BOTH ADR comments with the CURRENT (matching) body.
  jq -n --argjson b0 "$BODY0" --argjson b1 "$BODY1" \
    '{comments:[{id:"40001",body:$b0},{id:"40002",body:$b1}]}' \
    >"$FIX/comments_match.json"

  # A comments page where the FIRST ADR (R1) carries a STALE body (digest
  # mismatch → in-place update); the second matches (skip).
  local stale0; stale0="$(printf '%s' "$d0" | jq -c '.decision = "A stale, superseded decision text."')"
  local stale_body0; stale_body0="$(jira_sink::_render_adr_body "$stale0" "002")"
  jq -n --argjson b0 "$stale_body0" --argjson b1 "$BODY1" \
    '{comments:[{id:"40001",body:$b0},{id:"40002",body:$b1}]}' \
    >"$FIX/comments_stale.json"

  # No ADR markers present at all (absent → both create).
  jq -n '{comments:[{id:"30000",body:{type:"doc",version:1,content:[
    {type:"paragraph",content:[{type:"text",text:"unrelated chatter"}]}]}}]}' \
    >"$FIX/comments_absent.json"

  ARG_QUIET=1
}

teardown() { jira_shim::uninstall; }

# Register a full process_spec sweep; <comments_fixture> selects the ADR state.
adr::register() {
  local comments_fixture="$1"
  jira_shim::set_response GET "*?fields=issuelinks*" "$FIX/issuelinks_absent.json" 200
  jira_shim::set_response GET "*/comment*" "$comments_fixture" 200
  jira_shim::set_response GET "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response GET "*/search/jql*" "$REPO_ROOT/tests/fixtures/jira_responses/search_absent.json" 200
  jira_shim::set_response POST "*/issueLink" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response POST "*/issue/*/comment" "$REPO_ROOT/tests/fixtures/jira_responses/comment_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*/comment/*" "$REPO_ROOT/tests/fixtures/jira_responses/comment_create_ok.json" 200
  jira_shim::set_response POST "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/rest/api/3/issue" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
}

# ADR comment CREATE POSTs (count bodies carrying the ADR marker).
_adr_creates() { jira_shim::requests | grep -A2 '^METHOD POST' | grep -cF 'speckit-adr:' || true; }
# ADR comment UPDATE PUTs (PUT against /comment/<id>).
_adr_updates() {
  jira_shim::requests | grep -B2 '^URL .*/comment/[0-9]*$' | grep -c '^METHOD PUT$' || true
}

# --- T016: zero churn on an unchanged corpus ---------------------------------

@test "re-run against an unchanged, already-mirrored corpus → 0 creates, 0 edits (SC-002)" {
  cd "$WORKDIR"
  adr::register "$FIX/comments_match.json"

  summary::start "adr us2 zerochurn"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]

  [ "$(_adr_creates)" -eq 0 ] || { echo "expected 0 ADR creates, got $(_adr_creates)" >&2; jira_shim::requests >&2; false; }
  [ "$(_adr_updates)" -eq 0 ] || { echo "expected 0 ADR updates, got $(_adr_updates)" >&2; jira_shim::requests >&2; false; }
}

# --- T017: a changed ADR → 1 update in place, 0 creates ----------------------

@test "one ADR changed on disk → exactly 1 in-place update, 0 new comments (SC-003)" {
  cd "$WORKDIR"
  adr::register "$FIX/comments_stale.json"

  summary::start "adr us2 update"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]

  [ "$(_adr_creates)" -eq 0 ] || { echo "expected 0 ADR creates, got $(_adr_creates)" >&2; jira_shim::requests >&2; false; }
  [ "$(_adr_updates)" -eq 1 ] || { echo "expected 1 ADR update, got $(_adr_updates)" >&2; jira_shim::requests >&2; false; }
  # The PUT targets the EXISTING comment id (40001), not a new comment.
  jira_shim::requests | grep -qF '/comment/40001'
}

# --- T018: a new ADR → 1 create, existing untouched --------------------------

@test "a new ADR added → exactly 1 create, existing ADR comments untouched (FR-006)" {
  cd "$WORKDIR"
  # The match fixture already mirrors R1 + caching-layer. Add a THIRD decision on
  # disk → only it is absent → exactly one create, zero updates.
  cat >>"$WORKDIR/specs/002-updates/research.md" <<'EOF'

## D9 — Observability sink

**Decision.** Emit structured logs to stdout only.

**Rationale.** Keeps the deploy free of a log-shipping sidecar.
EOF
  adr::register "$FIX/comments_match.json"

  summary::start "adr us2 add"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]

  [ "$(_adr_creates)" -eq 1 ] || { echo "expected 1 ADR create, got $(_adr_creates)" >&2; jira_shim::requests >&2; false; }
  [ "$(_adr_updates)" -eq 0 ] || { echo "expected 0 ADR updates, got $(_adr_updates)" >&2; jira_shim::requests >&2; false; }
  # The new comment is the added decision (D9).
  jira_shim::requests | grep -A2 '^METHOD POST' | grep -qF 'speckit-adr:002-D9'
}

# --- T019: fail-closed + DRY-0 placeholder skip ------------------------------

@test "an unreadable ADR comment probe fails closed (no blind duplicate, FR-010)" {
  cd "$WORKDIR"
  # Register the unreadable (401) comment read FIRST (first-match wins), so the
  # comment probe fails closed → rc 3. The rest of the sweep reads absent/create.
  jira_shim::set_response GET "*/comment*" "$REPO_ROOT/tests/fixtures/jira_responses/error_401.json" 401
  jira_shim::set_response GET "*?fields=issuelinks*" "$FIX/issuelinks_absent.json" 200
  jira_shim::set_response GET "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response GET "*/search/jql*" "$REPO_ROOT/tests/fixtures/jira_responses/search_absent.json" 200
  jira_shim::set_response POST "*/issue/*/comment" "$REPO_ROOT/tests/fixtures/jira_responses/comment_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*/comment/*" "$REPO_ROOT/tests/fixtures/jira_responses/comment_create_ok.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204

  summary::start "adr us2 failclosed"
  RECONCILE_EXIT_CODE=0
  reconcile::process_spec "specs/002-updates" || true
  # process_spec swallows the per-spec rc into the promoted exit (resolved in
  # main()); the fail-closed read promotes RECONCILE_EXIT_CODE to 3.
  [ "$RECONCILE_EXIT_CODE" -eq 3 ] || {
    echo "expected promoted exit 3, got $RECONCILE_EXIT_CODE" >&2; jira_shim::requests >&2; false; }

  # Fail-closed: NO ADR comment create/update written on an unreadable probe.
  [ "$(_adr_creates)" -eq 0 ] || { echo "blind ADR create on fail-closed: $(_adr_creates)" >&2; jira_shim::requests >&2; false; }
  [ "$(_adr_updates)" -eq 0 ] || { echo "blind ADR update on fail-closed: $(_adr_updates)" >&2; false; }
}

@test "DRY-0 placeholder (dry-run of an unmirrored spec) skips the ADR probe (no 404)" {
  cd "$WORKDIR"
  export DRY_RUN=1
  # Everything reads absent so the dry-run synthesizes the DRY-0 placeholder key.
  jira_shim::set_response GET "*?fields=issuelinks*" "$FIX/issuelinks_absent.json" 200
  jira_shim::set_response GET "*/comment*" "$FIX/comments_absent.json" 200
  jira_shim::set_response GET "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response GET "*/search/jql*" "$REPO_ROOT/tests/fixtures/jira_responses/search_absent.json" 200

  summary::start "adr us2 dry0"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]

  # No comment GET against the placeholder DRY-0 key (the probe was skipped).
  ! jira_shim::requests | grep -F 'DRY-0/comment'
  # And no writes under dry-run.
  [ "$(_adr_creates)" -eq 0 ]
  [ "$(_adr_updates)" -eq 0 ]
}
