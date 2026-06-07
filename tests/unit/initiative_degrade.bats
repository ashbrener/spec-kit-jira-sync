#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/initiative_degrade.bats  (feature-002 US6, T043)
#
# Unit tests for initiative::degrade_onto_epic (src/jira_sink.sh) — when the
# instance lacks the Initiative type, the narrative folds onto the repo Epic
# behind a STABLE marker and the repo grouping rides the existing repo_prefix
# label; it NEVER hard-fails (Q5, FR-013, SC-007):
#   - a fresh degrade writes the Epic body = preamble + marker + narrative;
#   - a re-run in the degraded state is ZERO churn (byte-identical section);
#   - the narrative section is isolated by the marker (unrelated Epic body edits
#     do not trigger a rewrite).
#
# Offline + deterministic over the curl-shim; no real coordinates (Principle IX).
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
  mapping::parse
  mapping::validate

  jira_shim::install
  NARR="A narrative from the spec Input line."
}

teardown() {
  jira_shim::uninstall
}

# An Epic GET fixture whose description is <content-array>.
_epic_with() {
  local dest="$1" content="$2"
  jq -n --argjson c "$content" \
    '{key:"PROJ-100",fields:{summary:"Specs — repo",labels:["speckit-repo:repo"],
       description:{version:1,type:"doc",content:$c},status:{id:"10000"}}}' >"$dest"
}

@test "degrade_onto_epic: a fresh degrade writes the marker + narrative, preserving prose" {
  local fx="$BATS_TEST_TMPDIR/epic_fresh.json"
  _epic_with "$fx" '[{"type":"paragraph","content":[{"type":"text","text":"Epic prose."}]}]'
  jira_shim::set_response GET "*/issue/PROJ-100*" "$fx" 200
  jira_shim::set_response PUT "*/issue/PROJ-100*" issue_create_ok.json 204

  local rc=0
  initiative::degrade_onto_epic "PROJ-100" "$NARR" "repo" || rc=$?
  [ "$rc" -eq 0 ]

  local body
  body="$(jira_shim::requests | sed -n 's/^BODY //p' | tail -1)"
  # Prose preserved, exactly one marker, narrative text present.
  printf '%s' "$body" | jq -e '.fields.description.content[0].content[0].text == "Epic prose."'
  local markers
  markers="$(printf '%s' "$body" | jq --arg m "$ADF_INITIATIVE_MARKER" \
    '[.fields.description.content[] | select(.type=="paragraph") | select(([.content[]?.text]|join(""))==$m)] | length')"
  [ "$markers" -eq 1 ]
  printf '%s' "$body" | jq -e --arg n "$NARR" '[.. | .text? // empty] | any(. == $n)'
}

@test "degrade_onto_epic: a re-run in the degraded state is ZERO churn (no PUT)" {
  # Build the already-degraded Epic body = prose + the rendered narrative section.
  local section
  section="$(adf::render_initiative_section "$NARR")"
  local fx="$BATS_TEST_TMPDIR/epic_degraded.json"
  jq -n --argjson sec "$section" \
    '{key:"PROJ-100",fields:{summary:"Specs — repo",labels:["speckit-repo:repo"],
       description:{version:1,type:"doc",
         content:([{type:"paragraph",content:[{type:"text",text:"Epic prose."}]}] + $sec)},
       status:{id:"10000"}}}' >"$fx"
  jira_shim::set_response GET "*/issue/PROJ-100*" "$fx" 200
  jira_shim::set_response PUT "*/issue/PROJ-100*" issue_create_ok.json 204

  local rc=0
  initiative::degrade_onto_epic "PROJ-100" "$NARR" "repo" || rc=$?
  [ "$rc" -eq 0 ]

  local puts
  puts="$(jira_shim::requests | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 0 ] || { echo "expected 0 PUTs on a degraded re-run, got $puts" >&2; jira_shim::requests >&2; false; }
}

@test "degrade_onto_epic: an unrelated Epic body edit does NOT trigger a rewrite" {
  local section
  section="$(adf::render_initiative_section "$NARR")"
  local fx="$BATS_TEST_TMPDIR/epic_edited.json"
  # The prose above the marker was edited by a human — same narrative section.
  jq -n --argjson sec "$section" \
    '{key:"PROJ-100",fields:{summary:"Specs — repo",labels:["speckit-repo:repo"],
       description:{version:1,type:"doc",
         content:([{type:"paragraph",content:[{type:"text",text:"HUMAN EDIT."}]}] + $sec)},
       status:{id:"10000"}}}' >"$fx"
  jira_shim::set_response GET "*/issue/PROJ-100*" "$fx" 200
  jira_shim::set_response PUT "*/issue/PROJ-100*" issue_create_ok.json 204

  local rc=0
  initiative::degrade_onto_epic "PROJ-100" "$NARR" "repo" || rc=$?
  [ "$rc" -eq 0 ]
  local puts
  puts="$(jira_shim::requests | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 0 ]
}

@test "degrade_onto_epic: an unreadable Epic read fails closed (rc 3, no write)" {
  jira_shim::set_response GET "*/issue/PROJ-100*" error_401.json 401
  run initiative::degrade_onto_epic "PROJ-100" "$NARR" "repo"
  [ "$status" -eq 3 ]
}
