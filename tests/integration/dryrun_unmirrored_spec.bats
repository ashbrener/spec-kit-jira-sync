#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/dryrun_unmirrored_spec.bats
#
# Regression: a `--dry-run` reconcile of a NOT-YET-MIRRORED spec must not
# spuriously exit 3. The dry-run create synthesizes the placeholder key `DRY-0`
# (jira_sink mutate_issue_create), and the post-create reconciles
# (sync_clarify_comments / sync_inter_phase_blocks) used to read against `DRY-0`
# — against LIVE Jira that 404s → fail-closed rc 3 → the whole dry-run exits 3
# even though the board is perfectly readable. (The mocked dryrun_parity suite
# masked this because the shim answers `DRY-0` reads with 200.)
#
# The fix skips those existence-check reads when the key is the `DRY-0`
# placeholder. Here we simulate the LIVE behaviour: the `DRY-0` comment/issue
# reads are registered as 404 (unreadable). With the fix the wrappers never
# issue them, so the run stays clean. Placeholders only (Principle IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL="https://example.atlassian.net" JIRA_EMAIL="o@e.com" \
         JIRA_API_TOKEN="placeholder" JIRA_MAX_RETRIES=0
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  jira_shim::install
  EMPTY="$BATS_TEST_TMPDIR/empty.json"; printf '{}' >"$EMPTY"
  # Simulate LIVE Jira for the placeholder issue: 404 (unreadable) on its reads.
  jira_shim::set_response GET "*/issue/DRY-0/comment*" "$EMPTY" 404
  jira_shim::set_response GET "*/issue/DRY-0*" "$EMPTY" 404
}
teardown() { jira_shim::uninstall; }

@test "dry-run: clarify-comments on the DRY-0 placeholder is skipped (no rc 3)" {
  local item='{"id":"003-x","title":"X","notes":[{"body":"a clarify session","timestamp_iso":"2026-06-01T00:00:00+00:00"}]}'
  run reconcile::sync_clarify_comments "DRY-0" "$item"
  [ "$status" -eq 0 ]
  # The placeholder comment read must NOT have been issued.
  local n
  n="$(jira_shim::requests | grep -c '/issue/DRY-0/comment' || true)"
  [ "$n" -eq 0 ]
}

@test "dry-run: inter-phase blocks on the DRY-0 placeholder is skipped (no rc 3)" {
  local item='{"id":"003-x","title":"X","links":[{"rel":"depends_on","target":"001"}]}'
  run reconcile::sync_inter_phase_blocks "DRY-0" "$item"
  [ "$status" -eq 0 ]
}

@test "guard is specific to the placeholder: a real key still calls through to the sink" {
  # A real key with an unreadable comment read DOES propagate rc 3 (fail-closed) —
  # proving the skip is scoped to DRY-0 only, not a blanket dry-run bypass.
  jira_shim::set_response GET "*/issue/REAL-7/comment*" "$EMPTY" 404
  local item='{"id":"003-x","title":"X","notes":[{"body":"a clarify session","timestamp_iso":"2026-06-01T00:00:00+00:00"}]}'
  run reconcile::sync_clarify_comments "REAL-7" "$item"
  [ "$status" -eq 3 ]
}
