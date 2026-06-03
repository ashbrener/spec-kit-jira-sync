#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/jira_rest_retry.bats
#
# Regression test for the cross-model (codex) review P1 finding:
#   A non-idempotent POST must NOT be retried on an AMBIGUOUS failure (network
#   timeout or 5xx), because the server may already have committed the write —
#   retrying could duplicate an issue/comment/link (violates FR-008 idempotency).
#   Idempotent methods (GET/PUT) DO retry on ambiguous failures. HTTP 429 is
#   rejected before processing, so it is safe to retry for ANY method.
# =============================================================================

load '../helpers/jira-shim'

setup() {
  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token-value"
  export JIRA_MAX_RETRIES=2
  export JIRA_BACKOFF_BASE=0   # instant backoff so the test is fast
  export JIRA_BACKOFF_CAP=0
  # shellcheck source=/dev/null
  source "${BATS_TEST_DIRNAME}/../../src/jira_rest.sh"
  jira_shim::install
}

teardown() {
  jira_shim::uninstall 2>/dev/null || true
}

_count() { jira_shim::requests | grep -c "^METHOD ${1}\$" || true; }

@test "POST is NOT retried on 5xx (avoids a duplicate write)" {
  jira_shim::set_response POST '*/issue' myself_ok.json 503
  run jira_rest::post "issue" '{"summary":"x"}'
  [ "$status" -ne 0 ]
  [ "$(_count POST)" -eq 1 ]
}

@test "POST is NOT retried on a network failure (ambiguous)" {
  # No rule registered for this URL -> the shim treats it as a transport failure.
  run jira_rest::post "issue" '{"summary":"x"}'
  [ "$status" -ne 0 ]
  [ "$(_count POST)" -eq 1 ]
}

@test "GET IS retried on 5xx up to the bound" {
  jira_shim::set_response GET '*/myself' myself_ok.json 503
  run jira_rest::get "myself"
  [ "$status" -ne 0 ]
  [ "$(_count GET)" -eq $(( JIRA_MAX_RETRIES + 1 )) ]
}

@test "POST IS retried on 429 (safe — rejected before processing)" {
  jira_shim::set_response POST '*/issue' myself_ok.json 429
  run jira_rest::post "issue" '{"summary":"x"}'
  [ "$status" -ne 0 ]
  [ "$(_count POST)" -eq $(( JIRA_MAX_RETRIES + 1 )) ]
}
