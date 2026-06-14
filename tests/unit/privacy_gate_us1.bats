#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/privacy_gate_us1.bats  (feature-006 US1, T016-T018b + T028)
#
# US1 integration: a BLOCK-tier leak in the consumer's tracked tree fails the
# whole reconcile closed (exit 4) with ZERO Jira writes — proven via the
# curl-shim (no POST/PUT recorded). A WARN-only tree proceeds. A non-git target
# fails closed. Every leak is fabricated/placeholder-shaped (Privacy IX): the
# non-example Atlassian site hosts are assembled at runtime and the example.com
# email is reserved/non-real.
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace   # keep jira_rest's RETURN trap off the shimmed curl

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  # Build a throwaway CONSUMER git repo: a spec tree + a gitignored config + .env.
  WORKDIR="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$WORKDIR/specs" "$WORKDIR/.specify/extensions/jira"
  cp -R "$REPO_ROOT/tests/fixtures/specs/001-sample" "$WORKDIR/specs/001-sample"
  cp "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml" \
     "$WORKDIR/.specify/extensions/jira/jira-config.yml"

  ( cd "$WORKDIR"
    git init -q .
    git config user.email "test@example.com"
    git config user.name "Test"
    # The credential + resolved config are gitignored (the clean baseline).
    printf '.env\n.specify/extensions/jira/jira-config.yml\n.specify/extensions/jira/jira-authors.local.yml\n' >.gitignore
    printf 'JIRA_API_TOKEN=placeholder-token\n' >.env
    git add specs .gitignore
    git commit -q -m seed
  )

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  jira_shim::install
  # The config-load probe + the (clean-path) reconcile reads/creates.
  jira_shim::set_response GET "*/project/PROJ*" issuetype_meta/project_scrum.json 200
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204
}

teardown() {
  jira_shim::uninstall
}

# Count mutating (POST/PUT) requests the shim recorded.
_mutating_count() {
  jira_shim::requests | grep -cE '^METHOD (POST|PUT)$' || true
}

# A fabricated NON-example BLOCK site host, assembled at runtime so no real
# site-host literal sits in this committed file (it would self-match the dogfood
# scan, C-11). Only the reserved `example.atlassian.net` host is allowed as a
# literal in the tracked tree.
_block_host() {  # _block_host <leading-label>
  printf '%s.atlas''sian.net' "$1"
}

# =============================================================================
# T016 — a BLOCK site shape ⇒ exit 4, file+class named, zero writes (C-1)
# =============================================================================

@test "US1: a tracked non-example Atlassian site host ⇒ exit 4 + site named + zero writes" {
  ( cd "$WORKDIR"
    printf 'see https://%s/browse/X for details\n' "$(_block_host leaky-site)" >README.md
    git add README.md && git commit -q -m leak )
  cd "$WORKDIR"
  run reconcile::main --all
  [ "$status" -eq 4 ]
  [[ "$output" == *"README.md"* ]]
  [[ "$output" == *"site"* ]]
  [ "$(_mutating_count)" -eq 0 ]
}

# =============================================================================
# T017 — a known-value (exact $JIRA_EMAIL) ⇒ exit 4 + email named (C-2)
# =============================================================================

@test "US1: a tracked file with the exact \$JIRA_EMAIL ⇒ exit 4 + email + zero writes" {
  ( cd "$WORKDIR"
    printf 'contact: operator@example.com\n' >notes.txt
    git add notes.txt && git commit -q -m leak )
  cd "$WORKDIR"
  run reconcile::main --all
  [ "$status" -eq 4 ]
  [[ "$output" == *"notes.txt"* ]]
  [[ "$output" == *"email"* ]]
  [ "$(_mutating_count)" -eq 0 ]
}

# =============================================================================
# T018 — the gate fires in --dry-run too (C-8)
# =============================================================================

@test "US1: a BLOCK tree under --dry-run still fails closed (exit 4, zero writes)" {
  ( cd "$WORKDIR"
    printf 'host: %s\n' "$(_block_host tenant)" >config-dump.txt
    git add config-dump.txt && git commit -q -m leak )
  cd "$WORKDIR"
  run reconcile::main --all --dry-run
  [ "$status" -eq 4 ]
  [ "$(_mutating_count)" -eq 0 ]
}

# =============================================================================
# T018b — a WARN-only tree proceeds (no exit 4); the WARN is surfaced (C-10/SC-007)
# =============================================================================

@test "US1: a tracked file with ONLY broad shapes ⇒ proceeds (not exit 4), WARN surfaced" {
  ( cd "$WORKDIR"
    # A generic email + a fabricated UUID — broad shapes only, no BLOCK signal.
    printf 'reviewer: somebody@example.org\nbuild-id: 11111111-2222-3333-4444-555555555555\n' >meta.txt
    git add meta.txt && git commit -q -m warn )
  cd "$WORKDIR"
  run reconcile::main --all
  # Proceeds (reconcile runs; exit is NOT 4). A clean create run exits 0.
  [ "$status" -ne 4 ]
  # The advisory WARN row names the file + a broad class.
  [[ "$output" == *"meta.txt"* ]]
  [[ "$output" == *"advisory"* ]]
}

# =============================================================================
# Clean baseline: no BLOCK signal ⇒ the gate is a silent pass + reconcile runs
# =============================================================================

@test "US1: a tree with no BLOCK signal passes the gate and the reconcile proceeds" {
  cd "$WORKDIR"
  run reconcile::main --all
  [ "$status" -ne 4 ]
  # No BLOCK finding ⇒ no fail-closed remediation row.
  [[ "$output" != *"forbidden"* ]]
  # The reconcile actually did its work (issue creates fired over the shim).
  [ "$(_mutating_count)" -gt 0 ]
}

# =============================================================================
# T028 — C-6 end-to-end: a non-git target ⇒ exit 4, "not a git repo", zero writes
# =============================================================================

@test "US1: cwd is NOT a git repo ⇒ exit 4 + 'not a git repo' + zero writes (C-6)" {
  local nongit="$BATS_TEST_TMPDIR/plain"
  mkdir -p "$nongit/.specify/extensions/jira"
  cp "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml" \
     "$nongit/.specify/extensions/jira/jira-config.yml"
  cp -R "$REPO_ROOT/tests/fixtures/specs/001-sample" "$nongit/specs-001"
  cd "$nongit"
  run reconcile::main --all
  [ "$status" -eq 4 ]
  [[ "$output" == *"not a git repo"* ]]
  [ "$(_mutating_count)" -eq 0 ]
}
