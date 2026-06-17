#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/title_ladder.bats  (feature-009 — FR-001..FR-009, C-1..C-12)
#
# The VENDOR-NEUTRAL issue-title source ladder. Title derivation lives wholly in
# the producer half (parser.sh / workstate.sh), reads only operator-written
# spec.md prose, carries NO Jira vocabulary, and resolves the existing
# `item.title` field. The ladder (first-match-wins):
#   1. an explicit `Title:` line in spec.md,
#   2. else a real, concise `# Feature Specification:` H1 (not the placeholder,
#      not empty, not byte-equal to the kebab short-name, within the 120 cap),
#   3. else the first prose sentence of `## Summary` (capped),
#   4. else the kebab directory short-name (today's last resort).
#
# PURE filesystem parsing — no network, no live Jira, no PII. Every fixture is
# placeholder-only (neutral text + example dirs); no real name/email/coordinate.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/src/workstate.sh"   # sources parser.sh
}

# Write a placeholder spec.md into a fresh `009-<slug>` dir (so short_name
# resolves) and echo the dir path. Body is supplied on stdin.
_mkspec() {
  local slug="$1"
  local dir="${BATS_TEST_TMPDIR}/${slug}"
  mkdir -p "$dir"
  cat >"${dir}/spec.md"
  printf '%s' "$dir"
}

# ===========================================================================
# Phase 2 — parser::spec_title_line  (the `Title:` rung)  [T003]
# ===========================================================================

@test "spec_title_line: echoes a plain 'Title:' line value, trimmed" {
  local md="${BATS_TEST_TMPDIR}/spec.md"
  printf '# Feature\n\nTitle:   Foo Bar  \n\n## Summary\n' >"$md"
  run parser::spec_title_line "$md"
  [ "$status" -eq 0 ]
  [ "$output" = "Foo Bar" ]
}

@test "spec_title_line: echoes a bold '**Title:**' line value" {
  local md="${BATS_TEST_TMPDIR}/spec.md"
  printf '# Feature\n\n**Title:**  Foo Bar\n' >"$md"
  run parser::spec_title_line "$md"
  [ "$status" -eq 0 ]
  [ "$output" = "Foo Bar" ]
}

@test "spec_title_line: is case-insensitive on the key" {
  local md="${BATS_TEST_TMPDIR}/spec.md"
  printf '# Feature\n\ntitle: Lower Key\n' >"$md"
  run parser::spec_title_line "$md"
  [ "$status" -eq 0 ]
  [ "$output" = "Lower Key" ]
}

@test "spec_title_line: empty when there is no 'Title:' line" {
  local md="${BATS_TEST_TMPDIR}/spec.md"
  printf '# Feature\n\n## Summary\n\nNo title here.\n' >"$md"
  run parser::spec_title_line "$md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spec_title_line: empty when the 'Title:' value is empty" {
  local md="${BATS_TEST_TMPDIR}/spec.md"
  printf '# Feature\n\nTitle:   \n' >"$md"
  run parser::spec_title_line "$md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spec_title_line: empty (no error) on a missing file" {
  run parser::spec_title_line "${BATS_TEST_TMPDIR}/nope.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===========================================================================
# Phase 2 — workstate::_cap_title  (the 120 cap)  [T005]
# ===========================================================================

@test "_cap_title: a <=120-char string is echoed verbatim" {
  run workstate::_cap_title "Short and sweet"
  [ "$status" -eq 0 ]
  [ "$output" = "Short and sweet" ]
}

@test "_cap_title: a 120-char string is echoed verbatim (boundary)" {
  local s
  s="$(printf 'a%.0s' {1..120})"
  run workstate::_cap_title "$s"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 120 ]
  [ "$output" = "$s" ]
}

@test "_cap_title: a >120 multi-word string is cut at a word boundary, no ellipsis" {
  # Build a long multi-word string; the cut must land at a space <=120, the
  # output a prefix of the input, and the char after the cut a space.
  local word="alpha " s
  s=""
  while [ "${#s}" -lt 140 ]; do s+="$word"; done
  s="${s% }"   # drop trailing space
  run workstate::_cap_title "$s"
  [ "$status" -eq 0 ]
  [ "${#output}" -le 120 ]
  # output is a prefix of the input
  [ "${s:0:${#output}}" = "$output" ]
  # the character immediately after the cut in the input is a space (word boundary)
  [ "${s:${#output}:1}" = " " ]
  # no inserted ellipsis
  case "$output" in *...) false ;; *) true ;; esac
  case "$output" in *"…") false ;; *) true ;; esac
}

@test "_cap_title: a >120 single-token string is hard-cut to exactly 120" {
  local s
  s="$(printf 'x%.0s' {1..200})"
  run workstate::_cap_title "$s"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 120 ]
  [ "$output" = "${s:0:120}" ]
}

# --- D1: locale-stable cap (determinism FR-003/FR-004) ---------------------

@test "_cap_title: multibyte input caps IDENTICALLY under LANG=C and LANG=en_US.UTF-8" {
  # A title with an em-dash and accents; the cap measure/slice must be
  # locale-stable (LC_ALL=C byte cap) so the same input always caps the same.
  local s="Café — naïve façade — a deterministic résumé of a feature that goes on and on and on past the one hundred and twenty byte readability cap here"
  local out_c out_utf
  out_c="$(LANG=C LC_ALL=C workstate::_cap_title "$s")"
  out_utf="$(LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 workstate::_cap_title "$s" 2>/dev/null \
             || LANG=en_US.UTF-8 workstate::_cap_title "$s")"
  [ "$out_c" = "$out_utf" ]
}

# ===========================================================================
# Phase 2 — workstate::_summary_first_sentence  (the Summary rung)  [T007]
# ===========================================================================

@test "_summary_first_sentence: first prose sentence of '## Summary'" {
  local dir
  dir="$(_mkspec 009-summary-one <<'EOF'
# Feature Specification: [FEATURE NAME]

## Summary

Does X. More text follows here.
EOF
)"
  run workstate::_summary_first_sentence "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "Does X." ]
}

@test "_summary_first_sentence: skips leading markup to the first prose line (C-10)" {
  local dir
  dir="$(_mkspec 009-summary-markup <<'EOF'
# Feature Specification: [FEATURE NAME]

## Summary

> a blockquote intro
- a list item
![an image](x.png)
The real prose begins here. And continues.
EOF
)"
  run workstate::_summary_first_sentence "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "The real prose begins here." ]
}

@test "_summary_first_sentence: empty when the Summary has only markup / no prose" {
  local dir
  dir="$(_mkspec 009-summary-nomprose <<'EOF'
# Feature Specification: [FEATURE NAME]

## Summary

> only a blockquote
- only a list
EOF
)"
  run workstate::_summary_first_sentence "$dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_summary_first_sentence: a single prose line with no terminator -> whole line" {
  local dir
  dir="$(_mkspec 009-summary-noterm <<'EOF'
# Feature Specification: [FEATURE NAME]

## Summary

One line with no terminal punctuation
EOF
)"
  run workstate::_summary_first_sentence "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "One line with no terminal punctuation" ]
}

@test "_summary_first_sentence: a '?' terminator is honored" {
  local dir
  dir="$(_mkspec 009-summary-q <<'EOF'
# Feature Specification: [FEATURE NAME]

## Summary

Why X? Because Y.
EOF
)"
  run workstate::_summary_first_sentence "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "Why X?" ]
}

# --- D2: abbreviation behavior is PINNED (accepted, not "fixed") ------------

@test "_summary_first_sentence: naive period-then-space split on 'e.g.' is pinned/accepted" {
  # Known limitation: the deterministic split treats 'e.g.' as a terminator.
  # This test PINS the accepted behavior (no abbreviation handling — would be a
  # fallback rung over-engineering). 'Uses e.g. the X pattern. More.' -> 'Uses e.g.'
  local dir
  dir="$(_mkspec 009-summary-abbr <<'EOF'
# Feature Specification: [FEATURE NAME]

## Summary

Uses e.g. the X pattern. More.
EOF
)"
  run workstate::_summary_first_sentence "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "Uses e.g." ]
}
