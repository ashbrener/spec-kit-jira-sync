#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/rollup_completion.bats  (feature-002 US4, T032)
#
# Unit tests for rollup::compute_completion (src/jira_sink.sh) — the off-by-
# default status-rollup completion calculus (Q11, FR-011):
#   - phase level: `complete` iff the phase has tasks AND every task is checked;
#   - repo/top level: `complete` iff there are specs AND every spec is done
#     (terminal lifecycle state `merged`); else `partial`.
#
# Pure calculus, no network. Placeholders only (Principle IX).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # The rollup helpers live in the sink; source it (it pulls adf + jira_rest).
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/jira_sink.sh"
}

@test "compute_completion: a phase with every task checked is complete" {
  run rollup::compute_completion phase '[{"done":true},{"done":true}]'
  [ "$status" -eq 0 ]
  [ "$output" = "complete" ]
}

@test "compute_completion: a phase with any task unchecked is partial" {
  run rollup::compute_completion phase '[{"done":true},{"done":false}]'
  [ "$output" = "partial" ]
}

@test "compute_completion: a phase with NO tasks is partial (no vacuous done)" {
  run rollup::compute_completion phase '[]'
  [ "$output" = "partial" ]
}

@test "compute_completion: a missing done flag counts as not-done (partial)" {
  run rollup::compute_completion phase '[{"text":"no flag"}]'
  [ "$output" = "partial" ]
}

@test "compute_completion: repo complete when every spec is merged (done)" {
  run rollup::compute_completion repo '["merged","merged"]'
  [ "$output" = "complete" ]
}

@test "compute_completion: repo partial when any spec is not yet merged" {
  run rollup::compute_completion repo '["merged","implementing"]'
  [ "$output" = "partial" ]
}

@test "compute_completion: repo with no specs is partial" {
  run rollup::compute_completion repo '[]'
  [ "$output" = "partial" ]
}

@test "compute_completion: an unknown kind is partial (fail-safe)" {
  run rollup::compute_completion bogus '[{"done":true}]'
  [ "$output" = "partial" ]
}
