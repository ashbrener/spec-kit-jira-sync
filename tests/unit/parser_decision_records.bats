#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/parser_decision_records.bats  (feature 005, T003 — FR-001/003/007)
#
# parser::decision_records <research_md> extracts one record per research.md
# decision block from BOTH grammars (bold-lead `**Decision.**` and the stock
# bullet/plain `- Decision:` / `Decision:`), case-insensitive, multi-line values.
# It derives a stable id (explicit `R<N>`/`D<N>`/`ADR-<N>` heading id else a
# title slug, positionally disambiguated on a duplicate slug), omits absent
# sub-parts, and NEVER errors — absence is `[]`, not a failure (FR-007).
#
# Neutral parser unit: filesystem in, JSON array out, no Jira vocabulary.
# Placeholders only (Principle IX).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/parser.sh"
  FIX="$REPO_ROOT/tests/fixtures/specs"
  BOLD="$FIX/005-adr-bold/research.md"
  BULLET="$FIX/006-adr-bullet/research.md"
  EMPTY="$FIX/007-adr-empty/research.md"
}

# --- both grammars extract every block ---------------------------------------

@test "bold-lead grammar: extracts both decision blocks" {
  run parser::decision_records "$BOLD"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'length')" -eq 2 ]
}

@test "bullet grammar: extracts all three decision blocks" {
  run parser::decision_records "$BULLET"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'length')" -eq 3 ]
}

# --- stable id: explicit heading id ------------------------------------------

@test "bold-lead: explicit heading id R1 is used as the decision id" {
  run parser::decision_records "$BOLD"
  [ "$(printf '%s' "$output" | jq -r '.[0].id')" = "R1" ]
}

@test "bullet: explicit heading id D2 is used as the decision id" {
  run parser::decision_records "$BULLET"
  [ "$(printf '%s' "$output" | jq -r '.[0].id')" = "D2" ]
}

# --- stable id: title slug fallback ------------------------------------------

@test "bold-lead: un-headed block keys by a title slug" {
  run parser::decision_records "$BOLD"
  [ "$(printf '%s' "$output" | jq -r '.[1].id')" = "caching-layer" ]
}

# --- positional disambiguation on a duplicate slug ---------------------------

@test "bullet: duplicate title slug is positionally disambiguated" {
  run parser::decision_records "$BULLET"
  # Two un-headed "Retry policy" blocks → retry-policy and retry-policy-2.
  local ids
  ids="$(printf '%s' "$output" | jq -r '[.[].id] | sort | join(",")')"
  [ "$ids" = "D2,retry-policy,retry-policy-2" ] \
    || { echo "got ids: $ids" >&2; false; }
}

# --- title / fields ----------------------------------------------------------

@test "bold-lead: title is the heading text after the id" {
  run parser::decision_records "$BOLD"
  [ "$(printf '%s' "$output" | jq -r '.[0].title')" = "Storage engine choice" ]
}

@test "bold-lead: decision value is captured (multi-line, case-insensitive label)" {
  run parser::decision_records "$BOLD"
  local dec
  dec="$(printf '%s' "$output" | jq -r '.[0].decision')"
  printf '%s' "$dec" | grep -q "embedded store" \
    || { echo "decision text: $dec" >&2; false; }
  # Multi-line value retained.
  printf '%s' "$dec" | grep -q "multi-line values" \
    || { echo "multi-line not retained: $dec" >&2; false; }
}

@test "bullet: rationale + alternatives captured from bullet labels" {
  run parser::decision_records "$BULLET"
  [ "$(printf '%s' "$output" | jq -r '.[0].title')" = "Transport protocol" ]
  printf '%s' "$output" | jq -er '.[0].rationale | test("Multiplexing")' >/dev/null
  printf '%s' "$output" | jq -er '.[0].alternatives | test("HTTP/1.1")' >/dev/null
}

# --- omit absent sub-parts ---------------------------------------------------

@test "bold-lead: block without Alternatives omits the alternatives key" {
  run parser::decision_records "$BOLD"
  # The "Caching layer" block has no Alternatives.
  [ "$(printf '%s' "$output" | jq -r '.[1] | has("alternatives")')" = "false" ]
  # but it does have a rationale.
  [ "$(printf '%s' "$output" | jq -r '.[1] | has("rationale")')" = "true" ]
}

# --- source back-reference ---------------------------------------------------

@test "source is the repo-relative research.md#<id> (no host/URL)" {
  run parser::decision_records "$BOLD"
  [ "$(printf '%s' "$output" | jq -r '.[0].source')" = "research.md#R1" ]
  printf '%s' "$output" | jq -er '[.[].source] | all(test("^research\\.md#"))' >/dev/null
  printf '%s' "$output" | jq -er '[.[].source] | all(test("https?://") | not)' >/dev/null
}

# --- graceful absence (FR-007) -----------------------------------------------

@test "research.md with no decision blocks → [] (rc 0)" {
  run parser::decision_records "$EMPTY"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "absent research.md → [] (rc 0, never errors)" {
  run parser::decision_records "$REPO_ROOT/tests/fixtures/specs/008-adr-noresearch/research.md"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}
