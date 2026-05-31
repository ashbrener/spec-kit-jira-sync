#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/workstate_schema.bats
#
# The workstate contract gate (decision D9 in specs/001-core-bridge/research.md,
# contract in specs/001-core-bridge/contracts/workstate.md): every parser-emitted
# `workstate` document MUST validate against the published Draft-2020-12 schema
# before any write. jq cannot do full JSON-Schema validation, so the authoritative
# check is python3 + jsonschema (the schema repo's validate.py approach).
#
# This gate validates every tests/fixtures/workstate/*.json against the schema and
# FAILS if any does not conform. When python3/jsonschema is unavailable it `skip`s
# cleanly, so CI without python still passes (D9: no runtime python dependency).
#
# Privacy (Principle IX): the shipped fixture uses placeholders only — example-org
# repo slugs, generic spec titles — never real Jira coordinates or PII.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=tests/helpers/schema.bash
  source "${REPO_ROOT}/tests/helpers/schema.bash"
  FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/workstate"
}

# Validate a single JSON document against the schema with python + jsonschema.
# Prints jsonschema's error report on failure. Returns the validator's status.
_validate_one() {
  local py="$1" schema="$2" doc="$3"
  "$py" - "$schema" "$doc" <<'PY'
import json, sys
import jsonschema

schema = json.load(open(sys.argv[1]))
doc = json.load(open(sys.argv[2]))

jsonschema.Draft202012Validator.check_schema(schema)
v = jsonschema.Draft202012Validator(schema)
errs = sorted(v.iter_errors(doc), key=lambda e: list(e.path))
if errs:
    for e in errs[:8]:
        print("   -", list(e.path), e.message)
    sys.exit(1)
sys.exit(0)
PY
}

@test "workstate fixtures conform to the published Draft-2020-12 schema" {
  local py schema
  py="$(schema::python)" \
    || skip "python3 with jsonschema unavailable — authoritative schema check skipped"
  schema="$(schema::path)" \
    || skip "workstate.schema.json not found — set WORKSTATE_SCHEMA to point at it"

  # Glob the fixtures; nullglob-guard so an empty dir is a clear failure, not a
  # literal '*.json' path. There must be at least one fixture to validate.
  local fixtures=()
  local f
  shopt -s nullglob
  for f in "${FIXTURE_DIR}"/*.json; do
    fixtures+=("$f")
  done
  shopt -u nullglob

  [ "${#fixtures[@]}" -gt 0 ] || {
    echo "no workstate fixtures found under ${FIXTURE_DIR}"
    return 1
  }

  local failed=0
  for f in "${fixtures[@]}"; do
    run _validate_one "$py" "$schema" "$f"
    if [ "$status" -ne 0 ]; then
      failed=1
      echo "FAIL: ${f}"
      echo "$output"
    else
      echo "OK:   ${f} conforms"
    fi
  done

  [ "$failed" -eq 0 ]
}
