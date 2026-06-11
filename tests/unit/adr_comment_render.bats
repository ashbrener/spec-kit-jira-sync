#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/adr_comment_render.bats  (feature 005, T005 — FR-002/005/009)
#
# The ADR body renderer + the normalized-body comparison helper in jira_sink.sh:
#   * jira_sink::_adr_marker <spec_num> <id>   → [speckit-adr:<spec>-<id>]
#   * jira_sink::_render_adr_body <decision>   → ADF doc (parity layout + marker)
#   * jira_sink::_adr_body_digest <body_adf>   → stable normalized digest
#
# The rendered body MUST follow the parity layout (contracts/adr-comment-layout.md):
# title `ADR <id> — <title>`, Status (default Accepted), Decision, Rationale,
# Alternatives (omitting absent), Source `research.md#<id>`, marker LAST. The
# digest is stable across cosmetic whitespace and changes when content changes
# (M2: the identity marker is stable in both bodies so it doesn't affect compare).
#
# Offline + deterministic; placeholders only (Principle IX).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/adf.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/jira_sink.sh"

  FULL="$(jq -cn '{
    id:"R5", title:"Re-mode destruction model", status:"Accepted",
    decision:"Default hard-delete; archive operator-selectable per project.",
    rationale:"Bridge content is regenerable from the specs.",
    alternatives:"relabel/detach-only — rejected (leaves clutter).",
    source:"research.md#R5"
  }')"
  # No status, no rationale, no alternatives (omit-absent + default status).
  MINIMAL="$(jq -cn '{
    id:"caching-layer", title:"Caching layer",
    decision:"Cache read paths in-process with a bounded LRU.",
    source:"research.md#caching-layer"
  }')"
}

# flatten an ADF doc to its concatenated text (in node order).
_text() { printf '%s' "$1" | jq -r '[.. | .text? // empty] | join("\n")'; }

# --- marker ------------------------------------------------------------------

@test "marker is [speckit-adr:<spec>-<id>], disjoint from speckit-note:" {
  run jira_sink::_adr_marker "005" "R5"
  [ "$status" -eq 0 ]
  [ "$output" = "[speckit-adr:005-R5]" ]
}

# --- field order + content ---------------------------------------------------

@test "render emits the parity layout in order with the marker last" {
  local body text
  body="$(jira_sink::_render_adr_body "$FULL" "005")"
  text="$(_text "$body")"

  # Title line.
  printf '%s' "$text" | grep -qF "ADR R5 — Re-mode destruction model"
  printf '%s' "$text" | grep -qF "Status: Accepted"
  printf '%s' "$text" | grep -qF "Decision: Default hard-delete"
  printf '%s' "$text" | grep -qF "Rationale: Bridge content is regenerable"
  printf '%s' "$text" | grep -qF "Alternatives: relabel/detach-only"
  printf '%s' "$text" | grep -qF "Source: research.md#R5"

  # Order: title < Status < Decision < Rationale < Alternatives < Source < marker.
  local lines; lines="$text"
  _idx() { printf '%s\n' "$lines" | grep -nF "$1" | head -1 | cut -d: -f1; }
  [ "$(_idx 'ADR R5 —')" -lt "$(_idx 'Status:')" ]
  [ "$(_idx 'Status:')" -lt "$(_idx 'Decision:')" ]
  [ "$(_idx 'Decision:')" -lt "$(_idx 'Rationale:')" ]
  [ "$(_idx 'Rationale:')" -lt "$(_idx 'Alternatives:')" ]
  [ "$(_idx 'Alternatives:')" -lt "$(_idx 'Source:')" ]
  [ "$(_idx 'Source:')" -lt "$(_idx '[speckit-adr:005-R5]')" ]
}

@test "render defaults Status to Accepted and omits absent Rationale/Alternatives" {
  local body text
  body="$(jira_sink::_render_adr_body "$MINIMAL" "005")"
  text="$(_text "$body")"
  printf '%s' "$text" | grep -qF "ADR caching-layer — Caching layer"
  printf '%s' "$text" | grep -qF "Status: Accepted"
  printf '%s' "$text" | grep -qF "Decision: Cache read paths"
  printf '%s' "$text" | grep -qF "Source: research.md#caching-layer"
  # Omit-don't-blank: no Rationale / Alternatives labels at all.
  ! printf '%s' "$text" | grep -qF "Rationale:"
  ! printf '%s' "$text" | grep -qF "Alternatives:"
  # Marker present + last.
  printf '%s' "$text" | grep -qF "[speckit-adr:005-caching-layer]"
}

@test "rendered body is valid ADF (doc/version/content)" {
  local body
  body="$(jira_sink::_render_adr_body "$FULL" "005")"
  [ "$(printf '%s' "$body" | jq -r '.type')" = "doc" ]
  [ "$(printf '%s' "$body" | jq -r '.version')" = "1" ]
  printf '%s' "$body" | jq -e '.content | type == "array"' >/dev/null
}

# --- digest stability + sensitivity (M2) -------------------------------------

@test "digest is stable across cosmetic whitespace differences" {
  local b1 b2 d1 d2
  b1="$(jira_sink::_render_adr_body "$FULL" "005")"
  # Same body re-serialized with extra trailing whitespace on text runs.
  b2="$(printf '%s' "$b1" | jq -c '(.. | .text?) |= (if . then . + "  " else . end)')"
  d1="$(jira_sink::_adr_body_digest "$b1")"
  d2="$(jira_sink::_adr_body_digest "$b2")"
  [ -n "$d1" ]
  [ "$d1" = "$d2" ] || { echo "d1=$d1 d2=$d2" >&2; false; }
}

@test "digest changes when the ADR content changes" {
  local edited b1 b2
  edited="$(printf '%s' "$FULL" | jq -c '.decision = "A completely different decision."')"
  b1="$(jira_sink::_render_adr_body "$FULL" "005")"
  b2="$(jira_sink::_render_adr_body "$edited" "005")"
  [ "$(jira_sink::_adr_body_digest "$b1")" != "$(jira_sink::_adr_body_digest "$b2")" ]
}

@test "digest ignores the identity marker (marker text excluded from compare)" {
  # Two bodies identical EXCEPT the trailing marker run → same content digest.
  local b1 b2
  b1="$(jira_sink::_render_adr_body "$FULL" "005")"
  b2="$(jira_sink::_render_adr_body "$FULL" "999")"
  [ "$(jira_sink::_adr_body_digest "$b1")" = "$(jira_sink::_adr_body_digest "$b2")" ] \
    || { echo "marker leaked into digest" >&2; false; }
}
