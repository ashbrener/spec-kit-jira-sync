#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/privacy_gate_us4.bats  (feature-006 Polish, T029 — SC-002 / VR-8 / C-4)
#
# Byte-identical clean pass: on a placeholder-clean tree (no BLOCK signal AND no
# broad-shape match) the gate is a SILENT pass — it adds NO privacy summary row
# (neither a fail-closed "forbidden" error nor an "advisory" WARN) — and the
# reconcile proceeds to its normal create/update/skip outcome over the shim.
# This locks the "no behavior change on a clean tree" guarantee. Placeholders
# only (Privacy IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  WORKDIR="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$WORKDIR/specs" "$WORKDIR/.specify/extensions/jira"
  cp -R "$REPO_ROOT/tests/fixtures/specs/001-sample" "$WORKDIR/specs/001-sample"
  # Strip the only broad-shape signal in the fixture (the Owner: email) so the
  # tree carries NEITHER a BLOCK nor a WARN match — a genuinely clean tree.
  grep -v '@' "$WORKDIR/specs/001-sample/spec.md" >"$WORKDIR/specs/001-sample/spec.md.clean"
  mv "$WORKDIR/specs/001-sample/spec.md.clean" "$WORKDIR/specs/001-sample/spec.md"
  cp "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml" \
     "$WORKDIR/.specify/extensions/jira/jira-config.yml"

  ( cd "$WORKDIR"
    git init -q .
    git config user.email "test@example.com"
    git config user.name "Test"
    printf '.env\n.specify/extensions/jira/jira-config.yml\n.specify/extensions/jira/jira-authors.local.yml\n' >.gitignore
    printf 'TOKEN=placeholder\n' >.env
    git add specs .gitignore
    git commit -q -m seed )

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  jira_shim::install
  jira_shim::set_response GET "*/project/PROJ*" issuetype_meta/project_scrum.json 200
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204
}

teardown() {
  jira_shim::uninstall
}

_mutating_count() {
  jira_shim::requests | grep -cE '^METHOD (POST|PUT)$' || true
}

@test "US4: a clean tree ⇒ the gate is a silent pass (no privacy summary rows)" {
  cd "$WORKDIR"
  run reconcile::main --all
  # Not fail-closed.
  [ "$status" -ne 4 ]
  # No fail-closed remediation row and no advisory WARN row from the gate.
  [[ "$output" != *"forbidden"* ]]
  [[ "$output" != *"advisory"* ]]
}

@test "US4: a clean tree still reconciles normally (creates fire over the shim)" {
  cd "$WORKDIR"
  run reconcile::main --all
  [ "$status" -ne 4 ]
  [ "$(_mutating_count)" -gt 0 ]
}
