# shellcheck shell=bash
# =============================================================================
# tests/helpers/schema.bash
#
# Helpers for the workstate schema-validation gate (decision D9 in
# specs/001-core-bridge/research.md). The authoritative Draft-2020-12 check is
# python3 + jsonschema; jq cannot do full schema validation, so the contract
# gate (tests/unit/workstate_schema.bats) leans on these resolvers.
#
# Resolution strategy mirrors the schema repo's validate.py: prefer the
# workstate-schema venv if present, fall back to a system python3 that has the
# `jsonschema` module importable, else report "unavailable" so the test can
# `skip` cleanly (CI without python still passes).
#
# Public API:
#   schema::python
#       Print the path/command of a python interpreter that can `import
#       jsonschema`, and return 0. Print nothing and return 1 if none is found.
#   schema::path
#       Print the absolute path to the published workstate.schema.json, and
#       return 0. Return 1 (printing nothing) if it cannot be located.
#
# Overridable via the environment (handy for CI or relocated checkouts):
#   WORKSTATE_PYTHON        explicit interpreter to try first
#   WORKSTATE_SCHEMA        explicit schema path to use
#   WORKSTATE_SCHEMA_REPO   root of the workstate-schema checkout
# =============================================================================

# Root of the sibling workstate-schema checkout (where the schema + venv live).
WORKSTATE_SCHEMA_REPO="${WORKSTATE_SCHEMA_REPO:-${HOME}/Code/AI/workstate-schema}"

# -----------------------------------------------------------------------------
# schema::python — resolve a python interpreter with jsonschema importable.
# -----------------------------------------------------------------------------
schema::python() {
  local candidate
  for candidate in \
    "${WORKSTATE_PYTHON:-}" \
    "${WORKSTATE_SCHEMA_REPO}/.venv/bin/python" \
    "python3" \
    "python"; do
    [[ -n "$candidate" ]] || continue
    # An absolute candidate must exist and be executable; a bare name must be
    # on PATH. `command -v` covers both.
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" -c 'import jsonschema' >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# schema::path — resolve the published workstate.schema.json.
# -----------------------------------------------------------------------------
schema::path() {
  local candidate
  for candidate in \
    "${WORKSTATE_SCHEMA:-}" \
    "${WORKSTATE_SCHEMA_REPO}/schema/workstate.schema.json"; do
    [[ -n "$candidate" ]] || continue
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
