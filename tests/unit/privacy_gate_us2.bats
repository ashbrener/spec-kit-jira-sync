#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/privacy_gate_us2.bats  (feature-006 US2, T024 — C-3 / FR-004 / SC-003)
#
# The gitignore assertion: the resolved jira-config.yml and .env MUST be
# gitignored-and-untracked in the consumer repo. Tracked-or-unignored ⇒ exit 4,
# the path named, zero writes. Placeholders only (Privacy IX).
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

  WORKDIR="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$WORKDIR/specs" "$WORKDIR/.specify/extensions/jira"
  cp -R "$REPO_ROOT/tests/fixtures/specs/001-sample" "$WORKDIR/specs/001-sample"
  cp "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml" \
     "$WORKDIR/.specify/extensions/jira/jira-config.yml"

  ( cd "$WORKDIR"
    git init -q .
    git config user.email "test@example.com"
    git config user.name "Test"
    printf '.env\n.specify/extensions/jira/jira-config.yml\n.specify/extensions/jira/jira-authors.local.yml\n' >.gitignore
    printf 'JIRA_API_TOKEN=placeholder-token\n' >.env
    git add specs .gitignore
    git commit -q -m seed )

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  jira_shim::install
  jira_shim::set_response GET "*/project/PROJ*" issuetype_meta/project_scrum.json 200
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204
}

teardown() {
  jira_shim::uninstall
}

_mutating_count() {
  jira_shim::requests | grep -cE '^METHOD (POST|PUT)$' || true
}

# =============================================================================
# (a) config + .env gitignored ⇒ gate passes (the baseline)
# =============================================================================

@test "US2: resolved config + .env gitignored-and-untracked ⇒ gate passes" {
  cd "$WORKDIR"
  run reconcile::main --all
  [ "$status" -ne 4 ]
}

# =============================================================================
# (b) the resolved jira-config.yml is TRACKED ⇒ exit 4, the config path named
# =============================================================================

@test "US2: a TRACKED resolved jira-config.yml ⇒ exit 4 + config path named + zero writes" {
  ( cd "$WORKDIR"
    # Force-add the gitignored config so it becomes tracked (the leak).
    git add -f .specify/extensions/jira/jira-config.yml
    git commit -q -m "oops tracked config" )
  cd "$WORKDIR"
  run reconcile::main --all
  [ "$status" -eq 4 ]
  [[ "$output" == *".specify/extensions/jira/jira-config.yml"* ]]
  [ "$(_mutating_count)" -eq 0 ]
}

# =============================================================================
# (c) .env not ignored (its ignore rule removed) ⇒ exit 4, .env named
# =============================================================================

@test "US2: .env present but NOT gitignored ⇒ exit 4 + .env named + zero writes" {
  ( cd "$WORKDIR"
    # Drop .env from .gitignore so it is present-but-unignored (one `git add .`
    # from being committed).
    printf '.specify/extensions/jira/jira-config.yml\n.specify/extensions/jira/jira-authors.local.yml\n' >.gitignore
    git add .gitignore && git commit -q -m "unignore .env" )
  cd "$WORKDIR"
  run reconcile::main --all
  [ "$status" -eq 4 ]
  [[ "$output" == *".env"* ]]
  [ "$(_mutating_count)" -eq 0 ]
}
