#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/privacy_dogfood.bats  (feature-006 Polish, T031 — C-11 / FR-009 / SC-005)
#
# The bridge IS its own consumer. Running the REAL Jira shape providers through
# the REAL neutral scanner over THIS repo's own tracked tree MUST yield ZERO
# `block` findings:
#   * the ATATT token prefix + the `.atlassian.net` site shapes are fragmented
#     in the source, so the source never self-matches (FR-009);
#   * the resolved jira-config.yml / .env / authors map are gitignored, so the
#     ignore-target assertion does not trip.
# WARN findings (the reserved example.com emails, fixture UUIDs, accountId
# placeholders) are ALLOWED — they prove the recall tier without failing closed.
# This is the dogfooding edge case + the FR-009 self-match proof, and it must
# agree with the existing no-real-identifiers.bats guard over the same tree.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/privacy_guard.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/jira_sink.sh"
}

# An empty known-value provider — the dogfood scan uses the SHAPE pass only
# (we are not asserting against the operator's resolved coordinates here).
_dogfood_known_empty() { :; }

@test "dogfood: real shapes over this repo's tree yield ZERO block findings" {
  cd "$REPO_ROOT"
  local findings rc=0
  findings="$(privacy_guard::scan \
      jira_sink::privacy_shapes \
      _dogfood_known_empty \
      jira_sink::privacy_ignore_targets)" || rc=$?

  # No block finding ⇒ rc 0 (the scan does not fail closed on its own repo).
  if [ "$rc" -ne 0 ]; then
    echo "DOGFOOD SELF-MATCH — the bridge's own tree produced a block finding:" >&2
    printf '%s\n' "$findings" | grep '^block' >&2
    false
  fi
  # Belt-and-suspenders: assert no line is severity `block`.
  run bash -c "printf '%s\n' \"\$1\" | grep -c '^block' || true" _ "$findings"
  [ "$output" -eq 0 ]
}

@test "dogfood: the scan IS exercised (it surfaces the expected WARN recall tier)" {
  # Sanity guard against a silently-empty scan giving false confidence: this
  # repo legitimately carries reserved example.com placeholders, so the warn
  # tier must find at least one. (If this ever drops to zero, the shape
  # providers or the enumeration regressed.)
  cd "$REPO_ROOT"
  local findings
  findings="$(privacy_guard::scan \
      jira_sink::privacy_shapes \
      _dogfood_known_empty \
      jira_sink::privacy_ignore_targets)" || true
  printf '%s\n' "$findings" | grep -q '^warn'
}
