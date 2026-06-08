#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/workstate_direct_entry.bats  (feature-002 US5, T038)
#
# Unit tests for the --workstate entry surface (Q8, FR-016, workstate-input.md):
#   - workstate::read_document reads a file or stdin (-); a missing file is an
#     input error (rc 2).
#   - workstate::validate_document accepts a valid, pinned document and rejects
#     malformed JSON / an unpinned schema_version / a structurally schema-invalid
#     document fail-closed (rc 2, nothing written).
#   - reconcile::parse_args rejects --workstate combined with --spec/--all
#     (mutually exclusive → exit 2).
#
# Offline, no network. Placeholders only (Principle IX).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"
  VALID="$REPO_ROOT/tests/fixtures/workstate/minimal.workstate.json"
}

# --- read_document -----------------------------------------------------------

@test "read_document: reads a file path" {
  run workstate::read_document "$VALID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.schema_version == "0.1.0"'
}

@test "read_document: reads from stdin when the arg is -" {
  run bash -c "source '$REPO_ROOT/src/reconcile.sh'; workstate::read_document - < '$VALID'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.items | length >= 1'
}

@test "read_document: a missing file is an input error (rc 2)" {
  run workstate::read_document "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 2 ]
}

# --- validate_document -------------------------------------------------------

@test "validate_document: a valid pinned document is accepted" {
  run workstate::validate_document "$(cat "$VALID")"
  [ "$status" -eq 0 ]
}

@test "validate_document: malformed JSON is rejected (rc 2)" {
  run workstate::validate_document '{ this is not json'
  [ "$status" -eq 2 ]
}

@test "validate_document: an unpinned schema_version is rejected (rc 2)" {
  local doc
  doc="$(jq -c '.schema_version = "9.9.9"' "$VALID")"
  run workstate::validate_document "$doc"
  [ "$status" -eq 2 ]
}

@test "validate_document: an absent schema_version is rejected (rc 2)" {
  local doc
  doc="$(jq -c 'del(.schema_version)' "$VALID")"
  run workstate::validate_document "$doc"
  [ "$status" -eq 2 ]
}

@test "validate_document: an empty items[] is rejected (rc 2)" {
  local doc
  doc="$(jq -c '.items = []' "$VALID")"
  run workstate::validate_document "$doc"
  [ "$status" -eq 2 ]
}

@test "validate_document: an item missing a required floor field is rejected (rc 2)" {
  local doc
  doc="$(jq -c '.items[0] |= del(.id)' "$VALID")"
  run workstate::validate_document "$doc"
  [ "$status" -eq 2 ]
}

@test "validate_document: a missing source.repo is rejected (rc 2)" {
  local doc
  doc="$(jq -c 'del(.source.repo)' "$VALID")"
  run workstate::validate_document "$doc"
  [ "$status" -eq 2 ]
}

# --- mutual exclusion (parse_args) -------------------------------------------

@test "parse_args: --workstate with --all is a config error (exit 2)" {
  run reconcile::parse_args --workstate "$VALID" --all
  [ "$status" -eq 2 ]
}

@test "parse_args: --workstate with --spec is a config error (exit 2)" {
  run reconcile::parse_args --workstate "$VALID" --spec 001
  [ "$status" -eq 2 ]
}

@test "parse_args: --workstate alone is accepted and does NOT default to --all" {
  run bash -c "source '$REPO_ROOT/src/reconcile.sh'; reconcile::parse_args --workstate '$VALID'; echo \"ws=\$ARG_WORKSTATE_SET all=\$ARG_ALL\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"ws=1 all=0"* ]]
}

@test "parse_args: --workstate - (stdin) is accepted" {
  run bash -c "source '$REPO_ROOT/src/reconcile.sh'; reconcile::parse_args --workstate -; echo \"v=\$ARG_WORKSTATE set=\$ARG_WORKSTATE_SET\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"v=- set=1"* ]]
}
