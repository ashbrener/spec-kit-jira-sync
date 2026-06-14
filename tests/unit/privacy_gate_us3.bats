#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/privacy_gate_us3.bats  (feature-006 US3, T027 — C-5 / FR-006/007 / SC-004)
#
# The failure message is ACTIONABLE and never re-leaks: every BLOCK failure
# names the file + shape class + a remediation (placeholder/scrub), and the
# matched secret BYTES never appear in the summary output. Driven directly
# against reconcile::privacy_gate in a throwaway repo (no shim writes needed —
# the gate never reaches the write fork). Placeholders only (Privacy IX).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  # Host assembled at runtime so no `<name>.atlassian.net` literal is committed
  # (it would self-match the dogfood scan, C-11).
  export JIRA_BASE_URL="https://$(_block_host leaky-known)"
  export JIRA_EMAIL="known.operator@example.com"
  export JIRA_API_TOKEN="ATA""TT""KNOWNTOKEN012345xyz"
  export DRY_RUN=0

  WORKDIR="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$WORKDIR"
  ( cd "$WORKDIR"
    git init -q .
    git config user.email "test@example.com"
    git config user.name "Test"
    printf 'seed\n' >seed.txt
    git add seed.txt && git commit -q -m seed )

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"
}

# A fabricated NON-example BLOCK site host, assembled at runtime so no real
# site-host literal is committed (dogfood, C-11).
_block_host() {  # _block_host <leading-label>
  printf '%s.atlas''sian.net' "$1"
}

# Run the gate over WORKDIR and capture the rendered summary (stderr).
_run_gate_summary() {
  cd "$WORKDIR"
  summary::start "privacy gate test"
  reconcile::privacy_gate || true
  summary::emit 2>&1
}

@test "US3: a BLOCK site shape names file + class + remediation, no matched bytes" {
  local host; host="$(_block_host secret-tenant)"
  ( cd "$WORKDIR"
    printf 'host: %s\n' "$host" >dump.txt
    git add dump.txt && git commit -q -m leak )
  run _run_gate_summary
  [[ "$output" == *"dump.txt"* ]]
  [[ "$output" == *"site"* ]]
  [[ "$output" == *"placeholder"* ]]
  [[ "$output" == *"scrub"* ]]
  # The matched host substring must NOT be echoed.
  [[ "$output" != *"$host"* ]]
}

@test "US3: a BLOCK api-token shape names the class but NOT the token bytes" {
  ( cd "$WORKDIR"
    # A fabricated token-shaped string assembled at runtime.
    local tok="ATA""TT""ZZZZ9999leakleak0000"
    printf 'token=%s\n' "$tok" >creds.txt
    git add creds.txt && git commit -q -m leak )
  run _run_gate_summary
  [[ "$output" == *"creds.txt"* ]]
  [[ "$output" == *"api-token"* ]]
  [[ "$output" == *"placeholder"* ]]
  [[ "$output" != *"ZZZZ9999leakleak0000"* ]]
}

@test "US3: a KNOWN-value email match names class+file, never the email bytes" {
  ( cd "$WORKDIR"
    printf 'reporter: known.operator@example.com\n' >people.txt
    git add people.txt && git commit -q -m leak )
  run _run_gate_summary
  [[ "$output" == *"people.txt"* ]]
  [[ "$output" == *"email"* ]]
  # The known operator email (the matched secret) must NOT be echoed.
  [[ "$output" != *"known.operator@example.com"* ]]
}

@test "US3: a tracked-config violation names the path + remediation" {
  ( cd "$WORKDIR"
    mkdir -p .specify/extensions/jira
    printf 'jira:\n  project_key: PROJ\n' >.specify/extensions/jira/jira-config.yml
    git add -f .specify/extensions/jira/jira-config.yml
    git commit -q -m "tracked config" )
  # The gate resolves the default config path via RECONCILE_CONFIG_PATH.
  RECONCILE_CONFIG_PATH=".specify/extensions/jira/jira-config.yml"
  run _run_gate_summary
  [[ "$output" == *".specify/extensions/jira/jira-config.yml"* ]]
  [[ "$output" == *"scrub"* || "$output" == *"placeholder"* ]]
}
