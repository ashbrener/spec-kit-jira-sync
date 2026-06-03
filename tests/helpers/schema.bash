# shellcheck shell=bash
# =============================================================================
# tests/helpers/schema.bash
#
# Helpers for the workstate schema-validation gate (decision D9 in
# specs/001-core-bridge/research.md). The authoritative Draft-2020-12 check is
# python3 + jsonschema; jq cannot do full schema validation, so the contract
# gate (tests/unit/workstate_schema.bats) leans on these resolvers.
#
# Toolchain selection mirrors the schema repo's validate.sh (decision #4): never
# touch system pip, never depend on a pre-built pip `.venv`. Resolution order:
#   (a) $WORKSTATE_PYTHON — an explicit interpreter, if it imports jsonschema;
#   (b) uv (preferred) — `uv run --with jsonschema python ...`, an ephemeral,
#       PEP 668-safe environment with no global install;
#   (c) a throwaway `python3 -m venv` + jsonschema, as a last resort;
#   (d) otherwise "unavailable", so the bats gate `skip`s cleanly (CI without a
#       python toolchain still passes — D9: no runtime python dependency).
#
# Public API:
#   schema::available
#       Return 0 if a jsonschema-capable runner can be resolved (and cache it),
#       else return 1. Call this before schema::run; the bats gate uses it to
#       decide whether to `skip`.
#   schema::run [args...]
#       Run a python script (read from stdin) via the resolved runner, forwarding
#       args as the script's argv and stdin as the script body. Mirrors the
#       previous `"$py" - "$args"...` invocation. Returns the script's status.
#   schema::path
#       Print the absolute path to the published workstate.schema.json, and
#       return 0. Return 1 (printing nothing) if it cannot be located.
#
# Overridable via the environment (handy for CI or relocated checkouts):
#   WORKSTATE_PYTHON        explicit interpreter to try first
#   WORKSTATE_SCHEMA        explicit schema path to use
#   WORKSTATE_SCHEMA_REPO   root of the workstate-schema checkout
# =============================================================================

# Root of the sibling workstate-schema checkout (where the schema lives).
WORKSTATE_SCHEMA_REPO="${WORKSTATE_SCHEMA_REPO:-${HOME}/Code/AI/workstate-schema}"

# Cache of the resolved runner: one of "python:<path>", "uv", or "venv:<path>".
# Empty means "not yet resolved"; "none" means "resolved, unavailable".
_SCHEMA_RUNNER=""

# -----------------------------------------------------------------------------
# _schema::resolve — pick a jsonschema-capable runner once and cache the choice.
# Sets _SCHEMA_RUNNER and returns 0 on success; sets it to "none" and returns 1
# if no runner can be provisioned. Idempotent (safe to call repeatedly).
# -----------------------------------------------------------------------------
_schema::resolve() {
  # Already resolved? Honour the cache.
  if [[ -n "$_SCHEMA_RUNNER" ]]; then
    [[ "$_SCHEMA_RUNNER" != "none" ]]
    return
  fi

  # (a) An explicit interpreter that already imports jsonschema.
  if [[ -n "${WORKSTATE_PYTHON:-}" ]] \
    && command -v "$WORKSTATE_PYTHON" >/dev/null 2>&1 \
    && "$WORKSTATE_PYTHON" -c 'import jsonschema' >/dev/null 2>&1; then
    _SCHEMA_RUNNER="python:${WORKSTATE_PYTHON}"
    return 0
  fi

  # (b) uv (preferred): ephemeral env, no global install, PEP 668-safe.
  if command -v uv >/dev/null 2>&1 \
    && uv run --with jsonschema python -c 'import jsonschema' >/dev/null 2>&1; then
    _SCHEMA_RUNNER="uv"
    return 0
  fi

  # (c) Throwaway venv as a last resort — never touches system pip.
  if command -v python3 >/dev/null 2>&1; then
    local venv
    venv="$(mktemp -d)/venv"
    if python3 -m venv "$venv" >/dev/null 2>&1 \
      && "$venv/bin/python" -m pip install --quiet jsonschema >/dev/null 2>&1; then
      _SCHEMA_RUNNER="venv:${venv}/bin/python"
      return 0
    fi
  fi

  # (d) Nothing available.
  _SCHEMA_RUNNER="none"
  return 1
}

# -----------------------------------------------------------------------------
# schema::available — true if a jsonschema-capable runner can be resolved.
# -----------------------------------------------------------------------------
schema::available() {
  _schema::resolve
}

# -----------------------------------------------------------------------------
# schema::run — execute a stdin python script via the resolved runner.
# Usage:  schema::run "$schema" "$doc" <<'PY' ... PY
# The script body is read from stdin; positional args become the script's argv.
# -----------------------------------------------------------------------------
schema::run() {
  _schema::resolve || return 127
  case "$_SCHEMA_RUNNER" in
    uv)
      uv run --with jsonschema python - "$@"
      ;;
    python:*)
      "${_SCHEMA_RUNNER#python:}" - "$@"
      ;;
    venv:*)
      "${_SCHEMA_RUNNER#venv:}" - "$@"
      ;;
    *)
      return 127
      ;;
  esac
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
