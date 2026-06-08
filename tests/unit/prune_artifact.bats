#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/prune_artifact.bats  (feature-004 Foundational, T006)
#
# jira_sink::prune_artifact — the prune mechanic dispatched on the configured
# destruction model:
#   * hard-delete (default) → DELETE /issue/<key>
#   * hard-delete under DRY_RUN → ZERO writes (REST no-op; contract I-3)
#   * archive without an archive_status id → hard-error rc 2 (Principle V/VIII)
#   * an unknown model → rc 2
# Placeholders only (Principle IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL="https://example.atlassian.net" JIRA_EMAIL="o@e.com" \
         JIRA_API_TOKEN="placeholder" JIRA_MAX_RETRIES=0
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  jira_shim::install
  EMPTY="$BATS_TEST_TMPDIR/empty.json"; : >"$EMPTY"
}
teardown() { jira_shim::uninstall; }

@test "prune_artifact: hard-delete issues a DELETE for the key" {
  export DRY_RUN=0
  CONFIG_VALUES[remode.destruction]="hard-delete"
  jira_shim::set_response DELETE "*/issue/SKJS-9" "$EMPTY" 204
  run jira_sink::prune_artifact "SKJS-9"
  [ "$status" -eq 0 ]
  jira_shim::requests | grep -q '^METHOD DELETE$'
  jira_shim::requests | grep -q '/issue/SKJS-9$'
}

@test "prune_artifact: hard-delete under DRY_RUN performs ZERO writes" {
  export DRY_RUN=1
  CONFIG_VALUES[remode.destruction]="hard-delete"
  jira_shim::set_response DELETE "*/issue/SKJS-9" "$EMPTY" 204
  run jira_sink::prune_artifact "SKJS-9"
  [ "$status" -eq 0 ]
  local deletes
  deletes="$(jira_shim::requests | grep -c '^METHOD DELETE$' || true)"
  [ "$deletes" -eq 0 ]
}

@test "prune_artifact: archive without an archive_status id hard-errors (rc 2)" {
  export DRY_RUN=0
  CONFIG_VALUES[remode.destruction]="archive"
  unset 'CONFIG_VALUES[remode.archive_status]' 2>/dev/null || true
  run jira_sink::prune_artifact "SKJS-9"
  [ "$status" -eq 2 ]
}

@test "prune_artifact: an unknown destruction model is a config error (rc 2)" {
  export DRY_RUN=0
  CONFIG_VALUES[remode.destruction]="banish"
  run jira_sink::prune_artifact "SKJS-9"
  [ "$status" -eq 2 ]
}

@test "prune_artifact: an empty key is a config error (rc 2)" {
  export DRY_RUN=0
  run jira_sink::prune_artifact ""
  [ "$status" -eq 2 ]
}
