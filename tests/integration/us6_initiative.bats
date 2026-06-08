#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us6_initiative.bats  (T047, US6)
#
# End-to-end (curl-shim) proof of the off-by-default Initiative super-level wired
# into reconcile.sh (Q5, FR-013/FR-014, SC-007, spec scenarios 1–3):
#
#   (1) ON + PRESENT — the project lists the Initiative type ⇒ an Initiative is
#       created above the repo Epic, carrying the repo identity label + the
#       explicit spec_input narrative.
#   (2) ON + ABSENT  — the project lacks the Initiative type ⇒ the narrative
#       folds onto the repo Epic behind the stable marker, the run SUCCEEDS (no
#       hard fail), and the repo grouping rides the repo_prefix label.
#   (3) OFF (default) — sync_initiative is a no-op: ZERO requests (US1 parity).
#
# Drives the post-loop orchestrator reconcile::sync_initiative directly. The
# Initiative search (JQL carries `issuetype`) is distinguished from the Epic
# search by glob order. Offline + deterministic; no real coordinates (IX).
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

  CONF="$BATS_TEST_TMPDIR/jira-config.yml"
  cat > "$CONF" <<'YAML'
jira:
  project_key: "PROJ"
  issue_types:
    epic: "10001"
    story: "10002"
    subtask: "10003"
    initiative: "10005"
  phase_status:
    specifying: "20001"
    planning: "20002"
    tasking: "20003"
    implementing: "20004"
    ready_to_merge: "20005"
    merged: "20006"
  transitions: {}
  labels:
    spec_prefix: "speckit-spec:"
    repo_prefix: "speckit-repo:"
    phase_prefix: "task-phase:"
    lifecycle_prefix: "phase:"
  mapping:
    initiative:
      enabled: true
YAML
  config::load "$CONF"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::install

  FX="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$FX"
  # The repo Epic (reused by ensure_repo_epic).
  jq -n '{startAt:0,maxResults:50,total:1,issues:[{id:"10100",key:"PROJ-100",
    fields:{summary:"Specs — repo",labels:["speckit-repo:repo"],status:{id:"10000"},
    updated:"2026-05-31T00:00:00.000+0000"}}]}' >"$FX/epic_search.json"

  _RECONCILE_REPO_SLUG="repo"
  _RECONCILE_INITIATIVE_NARRATIVE="A narrative from the spec Input line."
}

teardown() {
  jira_shim::uninstall
}

# --- (1) ON + PRESENT ---------------------------------------------------------

@test "initiative ON + present: an Initiative is created above the Epic" {
  jq -n '{key:"PROJ",issueTypes:[{name:"Epic"},{name:"Story"},{name:"Initiative"}]}' >"$FX/proj.json"
  jira_shim::set_response GET "*/project/PROJ*" "$FX/proj.json" 200
  # Initiative search (JQL carries `issuetype`) → absent ⇒ create. Registered
  # BEFORE the generic Epic search so it wins for the issuetype-bearing query.
  jira_shim::set_response GET "*/search/jql*issuetype*" search_absent.json 200
  jira_shim::set_response GET "*/search/jql*" "$FX/epic_search.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201

  summary::start "us6 present"
  reconcile::sync_initiative

  local reqs
  reqs="$(jira_shim::requests)"
  # An Initiative (issuetype 10005) was created, carrying the repo label + body.
  printf '%s\n' "$reqs" | grep -q '"id":"10005"'
  printf '%s\n' "$reqs" | grep -q '"speckit-repo:repo"'
  printf '%s\n' "$reqs" | grep -q 'A narrative from the spec Input line.'
}

# --- (2) ON + ABSENT (graceful degradation) ----------------------------------

@test "initiative ON + absent: the narrative folds onto the Epic, run succeeds" {
  jq -n '{key:"PROJ",issueTypes:[{name:"Epic"},{name:"Story"},{name:"Subtask"}]}' >"$FX/proj.json"
  jira_shim::set_response GET "*/project/PROJ*" "$FX/proj.json" 200
  jira_shim::set_response GET "*/search/jql*" "$FX/epic_search.json" 200
  # The Epic GET for the degrade read (prose, no marker yet).
  jq -n '{key:"PROJ-100",fields:{summary:"Specs — repo",labels:["speckit-repo:repo"],
    description:{version:1,type:"doc",content:[{type:"paragraph",
      content:[{type:"text",text:"Epic prose."}]}]},status:{id:"10000"}}}' >"$FX/epic_get.json"
  jira_shim::set_response GET "*/issue/PROJ-100*" "$FX/epic_get.json" 200
  jira_shim::set_response PUT "*/issue/PROJ-100*" issue_create_ok.json 204

  summary::start "us6 absent"
  reconcile::sync_initiative

  local reqs
  reqs="$(jira_shim::requests)"
  # NO Initiative create (the type is absent)…
  if printf '%s\n' "$reqs" | grep -q '"id":"10005"'; then
    echo "an Initiative was created despite the type being absent" >&2
    printf '%s\n' "$reqs" >&2; false
  fi
  # …exactly one Epic PUT folding the narrative behind the marker, prose kept.
  local puts; puts="$(printf '%s\n' "$reqs" | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 1 ] || { echo "expected 1 Epic PUT (degrade), got $puts" >&2; printf '%s\n' "$reqs" >&2; false; }
  local body; body="$(printf '%s\n' "$reqs" | sed -n 's/^BODY //p' | tail -1)"
  printf '%s' "$body" | jq -e '.fields.description.content[0].content[0].text == "Epic prose."'
  printf '%s' "$body" | jq -e --arg m "$ADF_INITIATIVE_MARKER" \
    '[.fields.description.content[] | select(.type=="paragraph") | select(([.content[]?.text]|join(""))==$m)] | length == 1'
}

@test "initiative ON + absent + empty narrative (workstate mode) still succeeds" {
  _RECONCILE_INITIATIVE_NARRATIVE=""   # spec_input gracefully absent
  jq -n '{key:"PROJ",issueTypes:[{name:"Epic"},{name:"Story"}]}' >"$FX/proj.json"
  jira_shim::set_response GET "*/project/PROJ*" "$FX/proj.json" 200
  jira_shim::set_response GET "*/search/jql*" "$FX/epic_search.json" 200
  jq -n '{key:"PROJ-100",fields:{summary:"Specs — repo",labels:["speckit-repo:repo"],
    description:{version:1,type:"doc",content:[]},status:{id:"10000"}}}' >"$FX/epic_get.json"
  jira_shim::set_response GET "*/issue/PROJ-100*" "$FX/epic_get.json" 200
  jira_shim::set_response PUT "*/issue/PROJ-100*" issue_create_ok.json 204

  summary::start "us6 empty-narrative"
  reconcile::sync_initiative
  # Marker is still folded (locatable), no hard failure.
  run summary::count error
  [ "$output" -eq 0 ]
}

# --- (3) OFF (default) -------------------------------------------------------

@test "initiative OFF (default): sync_initiative is a no-op (zero requests)" {
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  mapping::validate
  jira_shim::reset

  summary::start "us6 off"
  reconcile::sync_initiative
  [ -z "$(jira_shim::requests)" ]
}
