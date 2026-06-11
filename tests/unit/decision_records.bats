#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/decision_records.bats
#
# Unit tests for parser::decision_records — tolerant extraction of ADR /
# decision records from a spec-kit `research.md` (the stock `/speckit-plan`
# Phase-0 format). The parser emits one NUL-terminated record per decision
# block, fields split by the ASCII Unit Separator (U+001F):
#     id  US  title  US  decision  US  rationale  US  alternatives
#
# Mirrors the parser::clarify_* test posture: PURE transform, no network, no
# live Jira. The driving fixture (tests/fixtures/research/) carries placeholders
# only (Principle IX).
#
# NOTE: the parser's output is NUL-framed, and bats `run`/command-substitution
# strips NUL bytes. So we capture to a FILE and read it byte-faithfully with a
# python helper rather than asserting against `$output`.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  RESEARCH="${REPO_ROOT}/tests/fixtures/research/research.md"
  NO_DECISIONS="${REPO_ROOT}/tests/fixtures/research/no-decisions.md"
  OUT="$BATS_TEST_TMPDIR/records.bin"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/src/parser.sh"
}

# Count NUL-terminated records in a file.
_record_count() {
  tr -cd '\000' <"$1" | wc -c | tr -d '[:space:]'
}

# Echo field <fld> (1-based) of record <rec> (1-based) from a NUL/US file.
_field() {
  local file="$1" rec="$2" fld="$3"
  python3 -c "
import sys
data=open('$file','rb').read()
recs=[r for r in data.split(b'\0') if r.strip()]
print(recs[int('$rec')-1].decode().split('\x1f')[int('$fld')-1])
"
}

# =============================================================================
# Extraction: N records from a stock-format research.md
# =============================================================================

@test "decision_records: extracts one record per decision block" {
  parser::decision_records "$RESEARCH" >"$OUT"
  # Three decision blocks (D1, R5, ADR-3); the trailing no-decision section is
  # skipped — a block must carry a Decision statement to count.
  [ "$(_record_count "$OUT")" -eq 3 ]
}

@test "decision_records: derives a stable id from the heading token" {
  parser::decision_records "$RESEARCH" >"$OUT"
  # The id tokens come straight from the headings: `D1.`, `R5 —`, `ADR-3:`.
  [ "$(_field "$OUT" 1 1)" = "D1" ]
  [ "$(_field "$OUT" 2 1)" = "R5" ]
  [ "$(_field "$OUT" 3 1)" = "ADR-3" ]
}

@test "decision_records: strips the leading id token from the title" {
  parser::decision_records "$RESEARCH" >"$OUT"
  [ "$(_field "$OUT" 1 2)" = "Storage format for the widget cache" ]
  [ "$(_field "$OUT" 2 2)" = "Retry policy for the upstream fetch" ]
}

@test "decision_records: tolerates the **Decision**:, - Decision:, Decision — spellings" {
  parser::decision_records "$RESEARCH" >"$OUT"
  # D1 uses **Decision**: ; R5 uses `- Decision:` ; ADR-3 uses `Decision —`.
  _field "$OUT" 1 3 | grep -q 'flat JSON file'
  _field "$OUT" 2 3 | grep -q 'exponential backoff'
  _field "$OUT" 3 3 | grep -q 'Bearer token'
}

@test "decision_records: captures rationale + alternatives by label" {
  parser::decision_records "$RESEARCH" >"$OUT"
  _field "$OUT" 1 4 | grep -q 'no schema migration'
  _field "$OUT" 1 5 | grep -q 'SQLite'
}

@test "decision_records: preserves multi-line values" {
  parser::decision_records "$RESEARCH" >"$OUT"
  # D1's Decision spans three source lines; the captured value must contain a
  # newline (folded continuation), not be truncated at the first line.
  local dec
  dec="$(_field "$OUT" 1 3)"
  printf '%s' "$dec" | grep -q 'self-heals'
  [ "$(printf '%s\n' "$dec" | wc -l | tr -d '[:space:]')" -ge 2 ]
}

# =============================================================================
# Robustness contract
# =============================================================================

@test "decision_records: no research.md → rc 0, empty output" {
  run parser::decision_records "/nonexistent/research.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "decision_records: research.md with no decision blocks → rc 0, empty" {
  parser::decision_records "$NO_DECISIONS" >"$OUT"
  [ "$(_record_count "$OUT")" -eq 0 ]
}

@test "decision_records: a heading with no Decision token falls back to a slug id" {
  local tmp="$BATS_TEST_TMPDIR/slug.md"
  cat >"$tmp" <<'EOF'
# Research

## Choice of color scheme

**Decision**: Use a dark theme by default.
EOF
  parser::decision_records "$tmp" >"$OUT"
  [ "$(_record_count "$OUT")" -eq 1 ]
  [ "$(_field "$OUT" 1 1)" = "choice-of-color-scheme" ]
}
