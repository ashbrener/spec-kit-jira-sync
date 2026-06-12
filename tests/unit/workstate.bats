#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/workstate.bats
#
# Unit tests for src/workstate.sh — the producer that turns parsed spec-kit
# specs into schema-valid `workstate` JSON (the neutral internal contract).
# These are PURE transform tests: no network, no live Jira. Structural shape
# is asserted with jq (the same floor the sink consumes).
#
# Privacy (Principle IX): the driving fixture (tests/fixtures/specs/001-sample)
# carries placeholders only — no real Jira coordinates or PII.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SPEC_DIR="${REPO_ROOT}/tests/fixtures/specs/001-sample"
  SPECS_ROOT="${REPO_ROOT}/tests/fixtures/specs"
  # Fixture spec dirs are not committed as standalone history, so pin the
  # recency key deterministically rather than shelling out to git.
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T12:00:00+00:00"
  export WORKSTATE_GENERATED_ISO="2026-05-31T12:34:56+00:00"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/src/workstate.sh"
}

# --- workstate::item_for_spec -----------------------------------------------

@test "item_for_spec: emits a spec item with stable NNN-short-name id" {
  run workstate::item_for_spec "$SPEC_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.kind == "spec"'
  echo "$output" | jq -e '.id == "001-sample"'
  echo "$output" | jq -e '.title == "Sample Spec"'
}

@test "item_for_spec: state is the parser lifecycle token" {
  run workstate::item_for_spec "$SPEC_DIR"
  [ "$status" -eq 0 ]
  # The fixture has checked tasks → parser infers "implementing".
  echo "$output" | jq -e '.state == "implementing"'
}

@test "item_for_spec: a lifecycle state hint overrides the artifact ladder" {
  # The filesystem ladder cannot see git merge/PR state; the engine resolves it
  # and passes the token in as the 3rd arg. A `merged` hint must win over the
  # disk-inferred `implementing` so the sink's merged→Done transition can fire.
  run workstate::item_for_spec "$SPEC_DIR" "" "merged"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.state == "merged"'
}

@test "item_for_spec: an empty state hint falls back to the artifact ladder" {
  # Guard the back-compat path: a blank hint must not blank out the state.
  run workstate::item_for_spec "$SPEC_DIR" "" ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.state == "implementing"'
}

@test "item_for_spec: carries the derived speckit-spec:NNN label" {
  run workstate::item_for_spec "$SPEC_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.labels | index("speckit-spec:001") != null'
}

@test "item_for_spec: item_source records path and last_commit_iso" {
  run workstate::item_for_spec "$SPEC_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.item_source.path | endswith("001-sample/")'
  echo "$output" | jq -e '.item_source.last_commit_iso == "2026-05-31T12:00:00+00:00"'
}

@test "item_for_spec: body is populated from the Summary section" {
  run workstate::item_for_spec "$SPEC_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.body | test("neutral `workstate` shape|placeholder spec")'
}

@test "item_for_spec: each task phase becomes a kind=task child" {
  run workstate::item_for_spec "$SPEC_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.children | length == 2'
  echo "$output" | jq -e '.children | all(.kind == "task")'
  echo "$output" | jq -e '.children[0].id == "001-phase-1"'
  echo "$output" | jq -e '.children[0].title == "Phase 1 — Setup"'
}

@test "item_for_spec: a phase carries an extensions.tasks checklist" {
  run workstate::item_for_spec "$SPEC_DIR"
  [ "$status" -eq 0 ]
  # Phase 1: both tasks checked.
  echo "$output" | jq -e '.children[0].extensions.tasks | length == 2'
  echo "$output" | jq -e '.children[0].extensions.tasks | all(.done == true)'
  echo "$output" | jq -e '.children[0].extensions.tasks[0].text | test("skeleton directories")'
  echo "$output" | jq -e '.children[0].state == "done"'
}

@test "item_for_spec: a partially-done phase is in_progress with mixed checklist" {
  run workstate::item_for_spec "$SPEC_DIR"
  [ "$status" -eq 0 ]
  # Phase 2: one checked, one unchecked.
  echo "$output" | jq -e '.children[1].state == "in_progress"'
  echo "$output" | jq -e '[.children[1].extensions.tasks[] | .done] == [true, false]'
}

@test "item_for_spec: empty/absent spec.md returns non-zero" {
  local empty_dir="${BATS_TEST_TMPDIR}/002-empty"
  mkdir -p "$empty_dir"
  : > "${empty_dir}/spec.md"
  run workstate::item_for_spec "$empty_dir"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- workstate::document_for_repo -------------------------------------------

@test "document_for_repo: builds a schema-shaped document with source block" {
  run workstate::document_for_repo "$SPECS_ROOT" "sample-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.schema_version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")'
  echo "$output" | jq -e '.source.system == "spec-kit"'
  echo "$output" | jq -e '.source.repo == "sample-repo"'
  echo "$output" | jq -e '.source.generated_iso == "2026-05-31T12:34:56+00:00"'
  echo "$output" | jq -e '.items | length >= 1'
  echo "$output" | jq -e '.items[0].id == "001-sample"'
}

@test "document_for_repo: never calls date — generated_iso is passed in" {
  # Override env to prove the explicit arg wins and no date(1) is invoked.
  run workstate::document_for_repo "$SPECS_ROOT" "sample-repo" "1999-01-01T00:00:00Z"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source.generated_iso == "1999-01-01T00:00:00Z"'
}

@test "document_for_repo: validates against the floor schema constraints" {
  run workstate::document_for_repo "$SPECS_ROOT" "sample-repo"
  [ "$status" -eq 0 ]

  # Document floor: required keys present, no stray top-level keys.
  echo "$output" | jq -e 'has("schema_version") and has("items")'
  echo "$output" | jq -e '(keys - ["schema_version","source","items"]) == []'

  # Every item satisfies the item floor: required id/title/state, and only
  # schema-known keys (additionalProperties:false on the item).
  echo "$output" | jq -e '
    .items | all(
      (has("id") and has("title") and has("state"))
      and ((keys - [
        "id","title","kind","state","body","coverage",
        "children","notes","links","decisions","labels","item_source","extensions",
        "author"
      ]) == [])
    )
  '

  # Children obey the same item floor (recursive def).
  echo "$output" | jq -e '
    [.items[].children[]] | all(
      (has("id") and has("title") and has("state"))
      and ((keys - [
        "id","title","kind","state","body","coverage",
        "children","notes","links","decisions","labels","item_source","extensions",
        "author"
      ]) == [])
    )
  '
}

# --- artifact emission ------------------------------------------------------

@test "document_for_repo: writes the sample workstate artifact to fixtures" {
  local out="${REPO_ROOT}/tests/fixtures/workstate/sample-spec.workstate.json"
  mkdir -p "$(dirname "$out")"
  # Run from the repo root with a RELATIVE specs root so the committed artifact
  # carries portable, repo-relative item_source paths (no absolute home leak).
  cd "$REPO_ROOT"
  workstate::document_for_repo "tests/fixtures/specs" "sample-repo" \
    "2026-05-31T12:34:56+00:00" > "$out"
  [ -s "$out" ]
  jq -e '.source.system == "spec-kit" and (.items | length >= 1)' "$out"
  jq -e '.items[0].item_source.path == "tests/fixtures/specs/001-sample/"' "$out"
}
