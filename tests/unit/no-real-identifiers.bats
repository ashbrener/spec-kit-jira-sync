#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/no-real-identifiers.bats
#
# Privacy guard. spec-kit-jira-sync is (or will become) a PUBLIC repo. NO real
# identifier may ever enter a tracked file: not a company / workspace name, a
# project key, a person's name or email, a Jira Cloud site, an account ID, a
# cloudId / UUID, and above all not a live Atlassian API token.
#
# DESIGN (so this guard never itself leaks what it forbids):
#   1. COMMITTED structural guards below contain ZERO real values — only the
#      *shapes* secrets take (e.g. the Atlassian API-token prefix). Safe to ship
#      in a public repo because they name nobody.
#   2. The operator's REAL literals live ONLY in a gitignored deny-list at
#      tests/.private-deny (one extended-regex per line; blank lines and '#'
#      comments ignored). The guard loads it when present and scans for each
#      entry. Because that file is gitignored, the real strings never reach git
#      — not even split across concatenations (the older fragmented approach
#      still put the real bytes in history; this does not). In CI (no deny-list)
#      the structural guards still run; the operator's pre-push local run is
#      where instance-specific leaks get caught before they can be committed.
#
# Bootstrap: copy tests/.private-deny.example -> tests/.private-deny and fill in
# your real coordinates. The resolved jira-config.yml and .env (which legitimately
# hold real values for local dogfooding) are gitignored, so `git ls-files` never
# sees them — only neutral placeholders ship.
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
DENY_LIST="${REPO_ROOT}/tests/.private-deny"

# Structural guards — SHAPES only, never real values. Each is fragmented across
# string concatenation so this committed file cannot self-match.
_structural_patterns() {
  printf '%s\n' \
    "ATA""TT[A-Za-z0-9_=-]{8,}"
  # ^ Atlassian Cloud API tokens (v3) begin with this prefix. Catches a
  #   committed token regardless of its value, without naming anyone.
}

# Operator's real literals, loaded from the gitignored deny-list if present.
# Blank lines and '#' comments are skipped. Absent (e.g. CI) -> no-op.
_private_patterns() {
  [ -f "$DENY_LIST" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$DENY_LIST" || true
}

@test "no real identifiers leak into the tracked tree (privacy guard)" {
  cd "$REPO_ROOT"
  local pattern hits all_hits=""
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # -I skips binaries; -E for the regex shapes; -i so case variants collapse.
    # `--` terminates options so a tracked path starting with '-' is never read
    # as a grep flag.
    hits="$(git ls-files -z | xargs -0 grep -nIiE -- "$pattern" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      all_hits+="--- pattern: ${pattern} ---"$'\n'"${hits}"$'\n'
    fi
  done < <(_structural_patterns; _private_patterns)

  if [ -n "$all_hits" ]; then
    printf 'Forbidden identifier(s) found in tracked files:\n%s\n' "$all_hits" >&2
    printf 'Real secrets/coordinates belong only in the gitignored .env /\n' >&2
    printf 'jira-config.yml — replace tracked occurrences with placeholders.\n' >&2
    return 1
  fi
}

@test "private deny-list, when present, actually contributes patterns" {
  # Guards against a silently-empty deny-list giving false confidence. Skips
  # cleanly in CI where the gitignored file is absent.
  [ -f "$DENY_LIST" ] || skip "no tests/.private-deny present (expected in CI)"
  run _private_patterns
  [ -n "$output" ] || {
    echo "tests/.private-deny exists but yields no patterns — fill it in." >&2
    return 1
  }
}
