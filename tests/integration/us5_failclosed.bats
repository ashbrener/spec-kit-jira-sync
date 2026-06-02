#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us5_failclosed.bats — the US5 fail-closed & observable gate.
#
# Proves the ALREADY-BUILT fail-closed behavior end-to-end over the MOCKED Jira
# REST (curl-shim, decision D10). When the bridge cannot reliably READ the Jira
# side it does not guess and does not write: it records a precise error row,
# fails closed for that spec (no mutation), and promotes the run exit to 3 — yet
# every other processable spec is still mirrored, and a project-level config
# error halts the whole run with exit 2 (contracts/cli.md exit codes:
# 0 clean · 1 warnings · 2 config · 3 fail-closed).
#
# Cases asserted (built behavior):
#   (1) UNREADABLE Jira (401 on the drift /search/jql read) → ZERO mutating
#       requests for that spec, an error row, exit promoted to 3.
#   (2) MISSING spec.md → that dir is a WARNING and OTHER specs still mirror
#       (the run does not abort; per-spec failure is isolated).
#   (3) CONFIG error (--config at a missing path) → halts with exit 2, no
#       partial mutation (asserted via a real subprocess run of reconcile.sh).
#   (4) 429 EXHAUSTION (JIRA_MAX_RETRIES=0, repeated 429 on the read) → the
#       read fails closed (rc 3), same no-write + exit-3 contract as (1).
#
# DEFERRED (need the US5-impl observability fixes in jira_sink.sh, owned by a
# later step): transition-transport-failure surfacing and failed-Subtask-create
# surfacing. Each is left as an explicit `skip` so the coverage gap is VISIBLE,
# not silent (see .claude/rules / review-debt).
#
# Offline + deterministic; no real Jira coordinates (Principle IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"

  # See us1_fresh.bats: bats `set -o functrace` makes jira_rest's RETURN cleanup
  # trap be inherited by the shimmed curl and delete the response body before it
  # is read. Disable it so shim-backed reads behave as in production.
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  # Edge env (placeholders only; Principle IX). The shim shadows curl so these
  # never leave the test.
  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  # A 429 that exhausts immediately must not retry/sleep: initial try only.
  export JIRA_MAX_RETRIES=0

  # Deterministic git identity (recency disk key derives from the spec dir's
  # last git commit, not mtime).
  export GIT_AUTHOR_NAME='Test Author'
  export GIT_AUTHOR_EMAIL='test@example.com'
  export GIT_COMMITTER_NAME='Test Author'
  export GIT_COMMITTER_EMAIL='test@example.com'
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  # A real git repo staging the sample spec under specs/ the engine enumerates.
  WORKDIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORKDIR/specs"
  cp -R "$REPO_ROOT/tests/fixtures/specs/001-sample" "$WORKDIR/specs/001-sample"
  git -C "$WORKDIR" init --initial-branch=main --quiet
  git -C "$WORKDIR" add -A
  GIT_COMMITTER_DATE="2026-05-26T09:31:00+00:00" \
  GIT_AUTHOR_DATE="2026-05-26T09:31:00+00:00" \
    git -C "$WORKDIR" commit --quiet -m "seed 001-sample"

  # Pin the workstate recency env so item composition is stable offline.
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-26T09:31:00+00:00"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate

  jira_shim::install

  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

# us5::count_writes — number of recorded mutating requests (POST/PUT).
us5::count_writes() {
  jira_shim::requests | grep -cE '^METHOD (POST|PUT)$' || true
}

# us5::register_writes_ok — register every write/transition endpoint as a
# transport-level SUCCESS, so a test that asserts ZERO writes proves the bridge
# REFUSED to write (it failed closed), not that a write merely errored.
us5::register_writes_ok() {
  jira_shim::set_response GET "*speckit-repo%3A*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/search_absent.json" 200
  jira_shim::set_response GET "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
}

# --- (1) UNREADABLE Jira (401) → no writes, error row, exit 3 -----------------

@test "unreadable Jira (401 on drift read) → zero writes, error row, exit 3" {
  cd "$WORKDIR"

  # The drift gate's read (_fetch_drift_issue_json → _search_issues →
  # jira_rest::search_jql, a READ) hits 401 → jira_rest returns rc 3
  # (JIRA_REST_RC_UNREADABLE) → the sink propagates rc 3 → process_spec fails
  # closed BEFORE any Epic ensure / Story create.
  jira_shim::set_response GET "*/search/jql*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/error_401.json" 401
  # Writes would succeed if attempted — they must NOT be.
  us5::register_writes_ok

  # process_spec mutates summary state via module globals; call it bare (it
  # returns 0 always) so the add()s land in THIS shell.
  summary::start "us5 unreadable"
  reconcile::process_spec "specs/001-sample"

  # ZERO mutating requests reached Jira — fail-closed, Jira untouched.
  local writes
  writes="$(us5::count_writes)"
  [ "$writes" -eq 0 ] || {
    echo "expected 0 writes on unreadable read, got $writes" >&2
    jira_shim::requests >&2
    false
  }

  # An error row names the spec with remediation context, and the run exit is 3.
  run summary::count error
  [ "$output" -ge 1 ]

  local emitted
  emitted="$(summary::emit 2>&1)"
  [[ "$emitted" == *"spec 001"* ]]
  [[ "$emitted" == *"Jira unreadable"* ]]
  [[ "$emitted" == *"fail-closed"* ]]

  # promote_exit promoted the monotonic run code to 3 (the fail-closed signal).
  [ "$RECONCILE_EXIT_CODE" -eq 3 ]
}

# --- (2) MISSING spec.md → warn + continue ------------------------------------

@test "missing spec.md → warning for that dir, other specs still mirror" {
  cd "$WORKDIR"

  # Add a second spec dir with NO spec.md (an unprocessable spec).
  mkdir -p "$WORKDIR/specs/002-empty"
  : >"$WORKDIR/specs/002-empty/.keep"

  # Every read ABSENT so the good spec CREATES; writes/transitions succeed.
  jira_shim::set_response GET "*/search/jql*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/search_absent.json" 200
  us5::register_writes_ok

  summary::start "us5 missing-spec"

  # Drive the per-spec loop exactly as reconcile::main does: the missing-spec
  # dir is WARNED and skipped (no error, no abort), then the good spec mirrors.
  reconcile::process_spec "specs/002-empty"

  # No write fired for the unprocessable dir, and it is a WARNING not an error.
  [ "$(us5::count_writes)" -eq 0 ]
  run summary::count warned
  [ "$output" -ge 1 ]
  run summary::count error
  [ "$output" -eq 0 ]

  local emitted
  emitted="$(summary::emit 2>&1)"
  [[ "$emitted" == *"002"* ]]
  [[ "$emitted" == *"spec.md missing"* ]]

  # The OTHER, processable spec is still mirrored — the run did not abort.
  reconcile::process_spec "specs/001-sample"
  [ "$(us5::count_writes)" -ge 1 ] || {
    echo "expected the processable spec to still mirror after the missing one" >&2
    jira_shim::requests >&2
    false
  }
  run summary::count created
  [ "$output" -ge 1 ]
}

# --- (3) CONFIG error → halt, exit 2, no partial mutation ---------------------

@test "config error (--config missing path) halts with exit 2, no mutation" {
  cd "$WORKDIR"

  # End-to-end: a project-level config error halts the WHOLE run (it is not a
  # per-spec failure). Run the real reconcile.sh as a subprocess so its main()
  # `exit` is observable. The config halt fires BEFORE any spec is touched, so
  # no curl runs — the in-process shim is irrelevant and no mutation is possible.
  run env \
    JIRA_BASE_URL="$JIRA_BASE_URL" \
    JIRA_EMAIL="$JIRA_EMAIL" \
    JIRA_API_TOKEN="$JIRA_API_TOKEN" \
    bash "$REPO_ROOT/src/reconcile.sh" --all --quiet \
      --config "$WORKDIR/does-not-exist.yml"

  # contracts/cli.md: project-level configuration error → exit 2 (run halted).
  [ "$status" -eq 2 ] || {
    echo "expected exit 2 on config error, got $status" >&2
    printf '%s\n' "$output" >&2
    false
  }
}

# --- (4) 429 EXHAUSTION → fail closed -----------------------------------------

@test "429 exhaustion (JIRA_MAX_RETRIES=0) on the read → fail closed, exit 3" {
  cd "$WORKDIR"

  # The drift read hits 429 with no retry budget (JIRA_MAX_RETRIES=0): jira_rest
  # exhausts immediately (rc 4 = RETRY_EXHAUSTED), the sink's _search_issues maps
  # ANY non-zero jira_rest rc to rc 3 (unreadable), so process_spec fails closed
  # exactly as the 401 case — no hang, no write.
  jira_shim::set_response GET "*/search/jql*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/error_429.json" 429
  us5::register_writes_ok

  summary::start "us5 429-exhausted"
  reconcile::process_spec "specs/001-sample"

  # No write attempted, and the run failed closed (exit 3).
  [ "$(us5::count_writes)" -eq 0 ] || {
    echo "expected 0 writes after 429 exhaustion, got $(us5::count_writes)" >&2
    jira_shim::requests >&2
    false
  }
  run summary::count error
  [ "$output" -ge 1 ]
  [ "$RECONCILE_EXIT_CODE" -eq 3 ]

  local emitted
  emitted="$(summary::emit 2>&1)"
  [[ "$emitted" == *"spec 001"* ]]
  [[ "$emitted" == *"Jira unreadable"* ]]
}

# --- DEFERRED observability placeholders (visible coverage gap) ---------------

@test "transition transport failure is surfaced as an error (DEFERRED)" {
  skip "US5-impl: observability P2 (review-debt.md)"
}

@test "failed Subtask create is surfaced as an error (DEFERRED)" {
  skip "US5-impl: observability P2 (review-debt.md)"
}
