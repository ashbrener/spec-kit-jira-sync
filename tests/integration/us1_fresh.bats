#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us1_fresh.bats — the US1 MVP gate.
#
# Proves the fresh-mirror CREATE path end-to-end over the MOCKED Jira REST
# (curl-shim, decision D10): a reconcile of a repo whose specs are not yet
# mirrored creates a per-repo Epic, a Story per spec, and a Subtask per task
# phase. Offline + deterministic — no network, no real Jira coordinates.
#
# Setup makes every READ report ABSENT (so the engine proceeds to create) and
# every WRITE / transition succeed, then drives reconcile::process_spec against
# the committed 001-sample fixture spec and asserts the recorded curl requests.
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"

  # bats enables `set -o functrace`, which makes a function's RETURN trap be
  # INHERITED by the functions it calls. jira_rest::_request sets a RETURN trap
  # that cleans up its response tempfiles; under functrace that trap fires when
  # the (shimmed) curl function returns, deleting the body file BEFORE _request
  # reads it — so reads come back empty. Production bash does not inherit the
  # trap. Disable functrace here so the shim-backed transport behaves as it does
  # in production (the assertion below would otherwise see empty reads).
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  # --- Edge env (placeholders only; Principle IX) ---------------------------
  # jira_rest reads these; the shim shadows curl so they never leave the test.
  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  # Keep the run fast + deterministic if any retry path were hit.
  export JIRA_MAX_RETRIES=0

  # --- Stage the sample spec under a specs/ root the engine can enumerate ----
  WORKDIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORKDIR/specs"
  cp -R "$REPO_ROOT/tests/fixtures/specs/001-sample" "$WORKDIR/specs/001-sample"

  # The engine derives recency from git; pin it via the env override so the
  # fixture needs no commits and the run stays deterministic offline.
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  # --- Source the engine (guard skips main on source) -----------------------
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  # Load the placeholder config fixture.
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate

  # --- Install the shim and register canned responses -----------------------
  jira_shim::install

  # READS: every JQL search returns ABSENT (total 0, empty issues[]) so the
  # idempotency + drift reads report "no existing issue" → the engine CREATES.
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  # Transition list resolves for the Story's status POST.
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  # WRITES: issue create + transition POST succeed.
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204

  # Quiet per-mutation chatter; the summary still emits.
  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

@test "fresh reconcile creates Epic + Story + Subtask-per-phase over the mock" {
  cd "$WORKDIR"

  # Drive the per-spec path directly (offline, deterministic). process_spec
  # runs the drift gate, Epic ensure, Story create, and Subtask creates.
  run reconcile::process_spec "specs/001-sample"
  [ "$status" -eq 0 ]

  # --- Assert the recorded curl requests ------------------------------------
  local reqs
  reqs="$(jira_shim::requests)"

  # A JQL read fired (idempotency/drift) — absent, so creates proceed.
  [[ "$reqs" == *'METHOD GET'* ]]
  [[ "$reqs" == *'/search/jql'* ]]

  # Count the POST /issue creates: one Epic + one Story + one Subtask per phase.
  # The sample spec has two task phases, so three plain-issue creates total.
  local issue_posts
  issue_posts="$(printf '%s\n' "$reqs" \
    | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$')"
  [ "$issue_posts" -eq 4 ] || {
    echo "expected 4 POST /issue (Epic+Story+2 Subtasks), got $issue_posts" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # The Story create carries the spec label and the Epic parent link.
  printf '%s\n' "$reqs" | grep -A2 '^METHOD POST' \
    | grep -q '"speckit-spec:001"'
  printf '%s\n' "$reqs" | grep -q '"parent"'

  # Each Subtask create carries a task-phase label (phases 1 and 2).
  printf '%s\n' "$reqs" | grep -q '"task-phase:1"'
  printf '%s\n' "$reqs" | grep -q '"task-phase:2"'

  # A transition POST fired to set the Story status.
  [[ "$reqs" == *'/transitions'* ]]
}

@test "fresh reconcile summary reports the created counts" {
  cd "$WORKDIR"

  summary::start "us1 fresh"
  reconcile::process_spec "specs/001-sample"

  # Story + 2 Subtasks = 3 created.
  run summary::count created
  [ "$status" -eq 0 ]
  [ "$output" -eq 3 ] || {
    echo "expected 3 created (Story + 2 Subtasks), got $output" >&2
    false
  }

  # No errors on the happy fresh path.
  run summary::count error
  [ "$output" -eq 0 ]
}

@test "the Epic is created with the repo-slug label before the Story" {
  cd "$WORKDIR"

  reconcile::process_spec "specs/001-sample" >/dev/null 2>&1

  local reqs
  reqs="$(jira_shim::requests)"

  # An Epic create carries a speckit-repo:<slug> label (the per-repo container).
  printf '%s\n' "$reqs" | grep -q '"speckit-repo:'

  # The Epic create (issuetype 10001) precedes the Story create (issuetype 10002).
  local epic_line story_line
  epic_line="$(printf '%s\n' "$reqs" | grep -n '"id":"10001"' | head -1 | cut -d: -f1)"
  story_line="$(printf '%s\n' "$reqs" | grep -n '"id":"10002"' | head -1 | cut -d: -f1)"
  [ -n "$epic_line" ]
  [ -n "$story_line" ]
  [ "$epic_line" -lt "$story_line" ]
}
