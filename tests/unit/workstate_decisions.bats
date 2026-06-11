#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/workstate_decisions.bats  (feature 005, T004 — FR-011)
#
# The workstate item carries a neutral `decisions[]` array built from the spec's
# research.md (via workstate::_decisions_json, wired into item assembly next to
# _notes_json). Empty `[]` when research.md is absent or has no decision blocks.
# The produced array validates against the schema's new optional floor field.
#
# Neutral: decisions[] carries no Jira vocabulary. Placeholders only (IX).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/parser.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/workstate.sh"
  FIX="$REPO_ROOT/tests/fixtures/specs"
}

@test "_decisions_json builds decisions[] from research.md (bold-lead)" {
  run workstate::_decisions_json "$FIX/005-adr-bold"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'length')" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].id')" = "R1" ]
}

@test "_decisions_json is [] when research.md has no blocks" {
  run workstate::_decisions_json "$FIX/007-adr-empty"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "_decisions_json is [] when research.md is absent" {
  run workstate::_decisions_json "$FIX/008-adr-noresearch"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "item_for_spec carries decisions[] on the assembled item" {
  run workstate::item_for_spec "$FIX/005-adr-bold"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decisions | length')" -eq 2 ]
  # coexists with notes[] (clarify channel) — disjoint arrays.
  [ "$(printf '%s' "$output" | jq -r 'has("notes")')" = "true" ]
}

@test "item_for_spec carries decisions:[] when the spec has no research decisions" {
  run workstate::item_for_spec "$FIX/007-adr-empty"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decisions | length')" -eq 0 ]
}

# --- schema validity of the produced decisions[] -----------------------------

@test "the item with decisions[] validates against the workstate schema" {
  # shellcheck source=tests/helpers/schema.bash
  source "$REPO_ROOT/tests/helpers/schema.bash"
  schema::available \
    || skip "no jsonschema-capable runner — schema check skipped"
  local schema
  schema="$(schema::path)" || skip "workstate.schema.json not found"

  local item doc
  item="$(workstate::item_for_spec "$FIX/005-adr-bold")"
  doc="$(jq -n --argjson it "$item" \
    '{schema_version:"0.1.0", source:{system:"spec-kit",repo:"example-repo"}, items:[$it]}')"

  local docfile; docfile="$BATS_TEST_TMPDIR/doc.json"
  printf '%s' "$doc" >"$docfile"
  run schema::run "$schema" "$docfile" <<'PY'
import json, sys, jsonschema
s = json.load(open(sys.argv[1])); d = json.load(open(sys.argv[2]))
jsonschema.Draft202012Validator.check_schema(s)
errs = list(jsonschema.Draft202012Validator(s).iter_errors(d))
if errs:
    for e in errs[:8]: print(list(e.path), e.message)
    sys.exit(1)
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}
