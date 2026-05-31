#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/workstate_phase.bats
#
# Regression test for the cross-model (codex) review P1 finding:
#   parser::lifecycle_phase emits a richer internal vocabulary (clarifying,
#   red_team, analyzing) than the 6-phase lifecycle the sink's config maps. The
#   producer MUST normalize the intermediate states before emission, or a spec
#   mid-clarify/red-team/analyze would emit a state config rejects with an
#   unknown-phase error. This guards the producer->sink phase contract.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/src/workstate.sh"
}

@test "normalize_phase: clarifying -> specifying" {
  run workstate::_normalize_phase clarifying
  [ "$status" -eq 0 ]
  [ "$output" = "specifying" ]
}

@test "normalize_phase: red_team -> implementing" {
  run workstate::_normalize_phase red_team
  [ "$output" = "implementing" ]
}

@test "normalize_phase: analyzing -> implementing" {
  run workstate::_normalize_phase analyzing
  [ "$output" = "implementing" ]
}

@test "normalize_phase: the six supported phases pass through unchanged" {
  for p in specifying planning tasking implementing ready_to_merge merged; do
    run workstate::_normalize_phase "$p"
    [ "$output" = "$p" ]
  done
}

@test "every parser lifecycle phase maps to a config-supported phase" {
  # End-to-end contract guard: each of the 9 tokens parser::lifecycle_phase can
  # return must normalize to one of the 6 the sink's config accepts.
  local supported=" specifying planning tasking implementing ready_to_merge merged "
  for p in clarifying specifying planning tasking implementing red_team analyzing ready_to_merge merged; do
    run workstate::_normalize_phase "$p"
    [[ "$supported" == *" ${output} "* ]] || { echo "parser phase '$p' normalized to unsupported '$output'"; return 1; }
  done
}
