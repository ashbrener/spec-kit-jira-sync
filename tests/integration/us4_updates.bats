#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us4_updates.bats — the US4 gate (FR-007).
#
# Proves end-to-end over the MOCKED Jira REST (curl-shim, decision D10) that a
# reconcile mirrors a spec's recorded clarify session as an AT-MOST-ONCE comment
# and a cross-spec dependency as an AT-MOST-ONCE issue link:
#
#   (a) CLARIFY COMMENT — a spec carrying a `## Clarifications` session is
#       reconciled. The first run posts EXACTLY ONE comment (carrying the stable
#       hidden marker); a RE-RUN whose comment read already shows that marker
#       posts ZERO additional comments (FR-007 at-most-once).
#
#   (b) CROSS-SPEC LINK — the same spec's `## Dependencies` names depends_on:001.
#       The first run resolves 001 → its mirrored Story and POSTs EXACTLY ONE
#       /issueLink; a RE-RUN whose link read already shows that target adds ZERO
#       (FR-007 idempotent links).
#
# Driven through reconcile::process_spec over the 002-updates fixture spec
# (placeholders only; Principle IX). Distinct new fixture filenames
# (comments_*.json / issuelinks_*.json) carry the canned reads.
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"

  # See us1_fresh.bats: bats functrace makes jira_rest's RETURN cleanup trap be
  # inherited by the shimmed curl and delete the body before it is read. Disable
  # it so shim-backed reads behave as in production.
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0

  WORKDIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORKDIR/specs"
  cp -R "$REPO_ROOT/tests/fixtures/specs/002-updates" "$WORKDIR/specs/002-updates"

  # Pin recency via the env override so the fixture needs no commits.
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate

  jira_shim::install

  # --- Canned US4 reads (distinct fixture filenames) ------------------------
  US4_FIX="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$US4_FIX"

  # The dep-resolve SEARCH: target 001 → its mirrored Story PROJ-201.
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
     {id:"10201",key:"PROJ-201",fields:{
        summary:"001 — dep", labels:["speckit-spec:001"],
        status:{id:"20001",name:"Mapped"}, updated:"2026-05-31T00:00:00.000+0000"
     }}]}' >"$US4_FIX/dep_search.json"

  # issuelinks reads: ABSENT (no link yet) and PRESENT (PROJ-201 already linked).
  jq -n '{fields:{issuelinks:[]}}' >"$US4_FIX/issuelinks_absent.json"
  jq -n '{fields:{issuelinks:[
     {type:{name:"Blocks"}, inwardIssue:{key:"PROJ-201"}}
  ]}}' >"$US4_FIX/issuelinks_present.json"

  # comments reads: ABSENT (no marker) and PRESENT (the already-posted comment
  # carrying the spec's clarify-note marker). The marker is computed from the
  # SAME workstate note the sink derives it from, so the dedup probe is a true
  # match (it can never drift from the producer).
  local item note marker
  item="$(workstate::item_for_spec "$WORKDIR/specs/002-updates")"
  note="$(printf '%s' "$item" | jq -c '.notes[0]')"
  marker="$(jira_sink::_note_marker "$note")"
  US4_MARKER="$marker"

  jq -n '{comments:[
     {id:"30000", body:{type:"doc",version:1,content:[
        {type:"paragraph",content:[{type:"text",text:"unrelated chatter"}]}
     ]}}]}' >"$US4_FIX/comments_absent.json"
  jq -n --arg m "$marker" '{comments:[
     {id:"30001", body:{type:"doc",version:1,content:[
        {type:"paragraph",content:[{type:"text",text:$m}]}
     ]}}]}' >"$US4_FIX/comments_present.json"

  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

# us4::register <issuelinks_fixture> <comments_fixture>
#   Wire the shim for a full process_spec sweep over 002-updates. The Story +
#   Subtask + dep-resolve reads report ABSENT/PRESENT per the args, and the
#   US4 reads (issuelinks GET, comment GET) select the at-most-once state.
#   First-match wins, so the SPECIFIC globs precede the generic ones.
us4::register() {
  local issuelinks_fixture="$1" comments_fixture="$2"

  # --- US4 reads (most specific) --------------------------------------------
  # The Story's existing-link baseline (GET ...?fields=issuelinks).
  jira_shim::set_response GET "*?fields=issuelinks*" "$issuelinks_fixture" 200
  # The comment dedup probe (GET .../comment, now paginated → trailing query).
  jira_shim::set_response GET "*/comment*" "$comments_fixture" 200

  # The dep-resolve search (URL carries the encoded speckit-spec:001 label) →
  # resolves target 001 to PROJ-201. Registered before the generic search.
  jira_shim::set_response GET "*speckit-spec%3A001*" "$US4_FIX/dep_search.json" 200

  # --- Core reconcile reads --------------------------------------------------
  # Transition list resolves for the Story status POST.
  jira_shim::set_response GET "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  # Everything else absent → the engine CREATES the Epic / Story / Subtask, and
  # the spec's OWN Story lookup (speckit-spec:002) reads absent.
  jira_shim::set_response GET "*/search/jql*" "$REPO_ROOT/tests/fixtures/jira_responses/search_absent.json" 200

  # --- Writes ---------------------------------------------------------------
  jira_shim::set_response POST "*/issueLink" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response POST "*/issue/*/comment" "$REPO_ROOT/tests/fixtures/jira_responses/comment_create_ok.json" 201
  jira_shim::set_response POST "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/rest/api/3/issue" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
}

# --- (a) CLARIFY COMMENT -----------------------------------------------------

@test "a clarify session is mirrored as exactly ONE comment POST" {
  cd "$WORKDIR"
  us4::register "$US4_FIX/issuelinks_absent.json" "$US4_FIX/comments_absent.json"

  summary::start "us4 clarify"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]

  local comment_posts
  comment_posts="$(jira_shim::requests \
    | grep -B2 '^URL .*/comment$' | grep -c '^METHOD POST$' || true)"
  [ "$comment_posts" -eq 1 ] || {
    echo "expected exactly 1 comment POST, got $comment_posts" >&2
    jira_shim::requests >&2
    false
  }

  # The posted comment carries the stable hidden marker (`grep -F`: the marker's
  # literal `[...]` must not be read as a character range).
  jira_shim::requests | grep -A2 '^METHOD POST' | grep -qF -- "$US4_MARKER" || {
    echo "comment POST body missing marker $US4_MARKER" >&2
    jira_shim::requests >&2
    false
  }
}

@test "a re-run whose comment marker is already present posts ZERO additional comments" {
  cd "$WORKDIR"
  us4::register "$US4_FIX/issuelinks_absent.json" "$US4_FIX/comments_present.json"

  summary::start "us4 clarify re-run"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]

  local comment_posts
  comment_posts="$(jira_shim::requests \
    | grep -B2 '^URL .*/comment$' | grep -c '^METHOD POST$' || true)"
  [ "$comment_posts" -eq 0 ] || {
    echo "expected 0 comment POSTs on re-run, got $comment_posts" >&2
    jira_shim::requests >&2
    false
  }
}

# --- (b) CROSS-SPEC LINK -----------------------------------------------------

@test "a cross-spec dependency is mirrored as exactly ONE issueLink POST" {
  cd "$WORKDIR"
  us4::register "$US4_FIX/issuelinks_absent.json" "$US4_FIX/comments_absent.json"

  summary::start "us4 link"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]

  local link_posts
  link_posts="$(jira_shim::requests \
    | grep -B2 '^URL .*/issueLink$' | grep -c '^METHOD POST$' || true)"
  [ "$link_posts" -eq 1 ] || {
    echo "expected exactly 1 issueLink POST, got $link_posts" >&2
    jira_shim::requests >&2
    false
  }

  # The link names the resolved dep target Story key.
  jira_shim::requests | grep -A2 '^URL .*/issueLink$' | grep -q 'PROJ-201' || {
    echo "issueLink body missing target PROJ-201" >&2
    jira_shim::requests >&2
    false
  }
}

@test "a re-run whose dep target is already linked adds ZERO issueLink POSTs" {
  cd "$WORKDIR"
  us4::register "$US4_FIX/issuelinks_present.json" "$US4_FIX/comments_absent.json"

  summary::start "us4 link re-run"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]

  local link_posts
  link_posts="$(jira_shim::requests \
    | grep -B2 '^URL .*/issueLink$' | grep -c '^METHOD POST$' || true)"
  [ "$link_posts" -eq 0 ] || {
    echo "expected 0 issueLink POSTs on re-run, got $link_posts" >&2
    jira_shim::requests >&2
    false
  }
}
