#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/adr_parity.bats — feature 005 US3 (T021, FR-009 / SC-005).
#
# The parity oracle. Renders an ADR from a fixed research.md fixture and asserts
# the comment body matches contracts/adr-comment-layout.md EXACTLY — the same
# golden shape the Linear sibling (008) asserts against its renderer, so a
# divergence in either sink fails its own parity test.
#
# Golden field order (contracts/adr-comment-layout.md):
#   1. ADR <id> — <title>
#   2. Status: <status>          (default Accepted)
#   3. Decision: <text>
#   4. Rationale: <text>         (omitted if absent)
#   5. Alternatives: <text>      (omitted if absent)
#   6. Source: research.md#<id>
#   7. [speckit-adr:<spec>-<id>] (marker, last)
#
# Placeholders only (Principle IX).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/adf.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/parser.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/jira_sink.sh"
}

# The flattened, in-order text runs of the rendered ADR body.
_render_lines() {
  local decision="$1" spec="$2" body
  body="$(jira_sink::_render_adr_body "$decision" "$spec")"
  printf '%s' "$body" | jq -r '[.. | .text? // empty] | .[]'
}

@test "the golden contract example renders byte-for-byte in field order (SC-005)" {
  # The exact ADR the contract documents (contracts/adr-comment-layout.md §Example).
  local d
  d="$(jq -cn '{
    id:"R5", title:"Re-mode destruction model", status:"Accepted",
    decision:"Default hard-delete; archive operator-selectable per project.",
    rationale:"Bridge content is regenerable from the specs; archive keeps the human layer.",
    alternatives:"relabel/detach-only — rejected (leaves clutter on the board).",
    source:"research.md#R5"
  }')"

  run _render_lines "$d" "004"
  [ "$status" -eq 0 ]

  # The golden lines, in order (the contract's example).
  local expected
  expected="ADR R5 — Re-mode destruction model
Status: Accepted
Decision: Default hard-delete; archive operator-selectable per project.
Rationale: Bridge content is regenerable from the specs; archive keeps the human layer.
Alternatives: relabel/detach-only — rejected (leaves clutter on the board).
Source: research.md#R5
[speckit-adr:004-R5]"

  [ "$output" = "$expected" ] || {
    echo "--- expected ---" >&2; printf '%s\n' "$expected" >&2
    echo "--- got ---" >&2; printf '%s\n' "$output" >&2
    false
  }
}

@test "omit-don't-blank: a decision with no rationale/alternatives skips those lines" {
  local d
  d="$(jq -cn '{
    id:"D2", title:"Transport protocol",
    decision:"Speak HTTP/2 to the upstream.",
    source:"research.md#D2"
  }')"

  run _render_lines "$d" "006"
  [ "$status" -eq 0 ]

  local expected
  expected="ADR D2 — Transport protocol
Status: Accepted
Decision: Speak HTTP/2 to the upstream.
Source: research.md#D2
[speckit-adr:006-D2]"

  [ "$output" = "$expected" ] || {
    echo "--- expected ---" >&2; printf '%s\n' "$expected" >&2
    echo "--- got ---" >&2; printf '%s\n' "$output" >&2
    false
  }
}

@test "the renderer is parity-consistent end-to-end from a research.md fixture" {
  # Parse a real fixture and render its first decision → assert the golden shape.
  local arr d
  arr="$(parser::decision_records "$REPO_ROOT/tests/fixtures/specs/005-adr-bold/research.md")"
  d="$(printf '%s' "$arr" | jq -c '.[0]')"

  run _render_lines "$d" "005"
  [ "$status" -eq 0 ]

  # Title, Status default, Source back-ref, marker-last — the parity invariants.
  printf '%s\n' "$output" | head -1 | grep -qF "ADR R1 — Storage engine choice"
  printf '%s\n' "$output" | grep -qx "Status: Accepted"
  printf '%s\n' "$output" | grep -qx "Source: research.md#R1"
  printf '%s\n' "$output" | tail -1 | grep -qF "[speckit-adr:005-R1]"
}
