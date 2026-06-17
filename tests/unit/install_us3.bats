#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/install_us3.bats  (feature 008 — US3, T026-T028)
#
# Dependency verification / fail-closed: a missing precondition makes install
# halt with exact remediation and ZERO bytes written.
#   - C-5: missing/blank .env (no JIRA_*) ⇒ exit 2, names the var(s) + the exact
#     .env lines, no jira-config.yml written.
#   - C-6: present but non-authenticating credential (shim myself 401/403) ⇒
#     exit 3 (Jira unreadable), zero bytes written.
#   - C-7 e2e: install with the target == the bridge checkout ⇒ exit 2, nothing
#     written.
#
# Offline + deterministic over the curl-shim; placeholder-only (Privacy IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export JIRA_MAX_RETRIES=0
  export DRY_RUN=0
  export CONFIG_TEMPLATE_PATH="$REPO_ROOT/config-template.yml"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/install.sh"

  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER/specs"
  cd "$CONSUMER"
  TARGET="$CONSUMER/jira-config.yml"

  jira_shim::install
}

teardown() {
  jira_shim::uninstall
}

@test "T026 missing .env (no JIRA_*) ⇒ exit 2, names the var + remediation, zero bytes (C-5)" {
  unset JIRA_BASE_URL JIRA_EMAIL JIRA_API_TOKEN

  run install::main --project PROJ --non-interactive --no-seed --config "$TARGET"
  [ "$status" -eq 2 ]
  [[ "$output" == *"JIRA_API_TOKEN"* ]]
  [[ "$output" == *".env"* ]]
  # Zero bytes written.
  [ ! -e "$TARGET" ]
}

@test "T027 non-authenticating credential (myself 401) ⇒ exit 3, zero bytes (C-6)" {
  jira_shim::set_response GET "*/myself*" "error_401.json" 401

  run install::main --project PROJ --non-interactive --no-seed --config "$TARGET"
  [ "$status" -eq 3 ]
  [ ! -e "$TARGET" ]
}

@test "T028 source==target (run from the bridge checkout) ⇒ exit 2, nothing written (C-7)" {
  # Run install FROM the bridge's own checkout — the source≠target guard must
  # halt before any probe or write.
  cd "$REPO_ROOT"
  local bridge_target="$BATS_TEST_TMPDIR/should-not-exist.yml"

  run install::main --project PROJ --non-interactive --no-seed --config "$bridge_target"
  [ "$status" -eq 2 ]
  [ ! -e "$bridge_target" ]
}
