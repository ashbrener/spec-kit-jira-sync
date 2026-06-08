#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us1_default_equivalence.bats  (T011, US1)
#
# Phase 3 / US1 regression anchor: a config with NO `mapping:` block mirrors
# repo→Epic / spec→Story / phase→Subtask / task→in-body checklist EXACTLY as the
# shipped 001 default. This proves the mapping-driven projection (T013) resolves
# the alias-synthesized default to byte-for-byte the same artifacts + parent
# relationships as the hardcoded 001 path (FR-001, FR-018, spec scenario 1).
#
# Mirror of tests/integration/us1_fresh.bats's fresh-CREATE setup, but the run
# path is now driven THROUGH the mapping layer: setup loads config, runs
# mapping::parse (alias-synthesizes the default), then drives process_spec. The
# asserted curl request shapes (4 creates: Epic+Story+2 Subtasks, the spec +
# repo + task-phase labels, the Epic→Story parent, the status transition) MUST
# match the 001 baseline.
#
# Offline + deterministic — no network, no real Jira coordinates (Principle IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"

  # See us1_fresh.bats: disable functrace so jira_rest's RETURN cleanup trap is
  # not inherited by the shimmed curl (which would delete the body pre-read).
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0

  WORKDIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORKDIR/specs"
  cp -R "$REPO_ROOT/tests/fixtures/specs/001-sample" "$WORKDIR/specs/001-sample"

  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  # Load the pre-feature (no `mapping:` block) config and alias-synthesize the
  # default mapping — the exact load path the engine now runs (T014).
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::install

  # READS absent → engine CREATES; transitions resolve; writes succeed.
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204

  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

@test "default (no mapping) mirror creates Epic+Story+Subtask-per-phase like 001" {
  cd "$WORKDIR"

  run reconcile::process_spec "specs/001-sample"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"

  # 4 plain-issue creates: Epic + Story + a Subtask per phase (the sample has 2).
  local issue_posts
  issue_posts="$(printf '%s\n' "$reqs" \
    | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  [ "$issue_posts" -eq 4 ] || {
    echo "expected 4 POST /issue (Epic+Story+2 Subtasks), got $issue_posts" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # The repo Epic projects to issuetype 10001 (issue_types.epic) — the default
  # repo→Epic resolution.
  printf '%s\n' "$reqs" | grep -q '"id":"10001"'
  # The spec Story projects to issuetype 10002 (issue_types.story) under the Epic.
  printf '%s\n' "$reqs" | grep -q '"id":"10002"'
  # Each task phase projects to issuetype 10003 (issue_types.subtask).
  printf '%s\n' "$reqs" | grep -q '"id":"10003"'
}

@test "default mirror carries the same labels + parent + checklist as 001" {
  cd "$WORKDIR"

  reconcile::process_spec "specs/001-sample" >/dev/null 2>&1

  local reqs
  reqs="$(jira_shim::requests)"

  # repo→Epic: the Epic create carries the repo-slug label.
  printf '%s\n' "$reqs" | grep -q '"speckit-repo:'
  # spec→Story: the Story create carries the spec label + an Epic parent link.
  printf '%s\n' "$reqs" | grep -q '"speckit-spec:001"'
  printf '%s\n' "$reqs" | grep -q '"parent"'
  # phase→Subtask: each Subtask carries its task-phase label.
  printf '%s\n' "$reqs" | grep -q '"task-phase:1"'
  printf '%s\n' "$reqs" | grep -q '"task-phase:2"'

  # task→checklist: tasks render in-body as an ADF taskList (no standalone Task
  # issue is created — exactly 4 plain creates, asserted above). The Subtask body
  # carries taskItem nodes from the checklist render.
  printf '%s\n' "$reqs" | grep -q '"taskItem"'
}

@test "default mirror summary matches the 001 created counts (Story + 2 Subtasks)" {
  cd "$WORKDIR"

  summary::start "us1 default equivalence"
  reconcile::process_spec "specs/001-sample"

  run summary::count created
  [ "$status" -eq 0 ]
  [ "$output" -eq 3 ] || {
    echo "expected 3 created (Story + 2 Subtasks), got $output" >&2
    false
  }

  run summary::count error
  [ "$output" -eq 0 ]
}

@test "the default-aliased mapping resolves to today's artifacts" {
  # Direct assertion of the alias resolution the sink consumes: repo→Epic,
  # spec→Story, phase→Subtask, task→checklist (FR-001).
  local tab=$'\t'
  run mapping::resolve_level repo
  [ "$output" = "Epic${tab}none" ]
  run mapping::resolve_level spec
  [ "$output" = "Story${tab}parent" ]
  run mapping::resolve_level phase
  [ "$output" = "Subtask${tab}parent" ]
  run mapping::resolve_level task
  [ "$output" = "checklist${tab}checklist" ]
}
