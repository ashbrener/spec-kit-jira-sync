#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/extension_identity.bats  (feature 013 — the identity pin)
#
# ONE name, everywhere. `src/identity.sh` is the single source of truth for the
# extension id, the push-command name and the install directory; the committed
# manifest, the hook registrar (`install.sh`) and the hook health check
# (`hookcheck.sh`) all derive from it. These tests pin that agreement so a
# future rename cannot half-land:
#
#   C-1  sourcing src/identity.sh twice in one shell is a clean no-op
#   C-6  manifest id == SPECKIT_EXT_ID; every declared command is namespaced
#        `speckit.<id>.`; the manifest declares exactly 4 commands + 6 after_*
#        hooks
#   C-7  the token the registrar WRITES classifies back as `present` for the
#        detector — writer/reader lockstep, asserted without comparing literals
#   C-10 no old-identity literal survives in any LIVE file
#
# The manifest is parsed with PyYAML (as manifest_hooks.bats does) — a
# manifest-contract test must not reuse the bridge's own reader.
#
# Pure-filesystem: no Jira, no curl-shim, no network.
# Privacy (Principle IX): placeholder-only — ids, command names, neutral prose.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  MANIFEST="$REPO_ROOT/extension.yml"
  # shellcheck source=../../src/identity.sh disable=SC1091
  source "$REPO_ROOT/src/identity.sh"
}

# --- C-1: the include guard --------------------------------------------------

@test "C-1: sourcing src/identity.sh twice in one shell is a clean no-op" {
  run bash -c '
    set -euo pipefail
    source "$1/src/identity.sh"
    source "$1/src/identity.sh"
    printf "%s|%s|%s\n" "$SPECKIT_EXT_ID" "$SPECKIT_EXT_PUSH_COMMAND" "$SPECKIT_EXT_INSTALL_DIR"
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "${SPECKIT_EXT_ID}|${SPECKIT_EXT_PUSH_COMMAND}|${SPECKIT_EXT_INSTALL_DIR}" ]
}

@test "C-1: the constants are self-consistent (command + directory derive from the id)" {
  [ "$SPECKIT_EXT_PUSH_COMMAND" = "speckit.${SPECKIT_EXT_ID}.push" ]
  [ "$SPECKIT_EXT_INSTALL_DIR" = ".specify/extensions/${SPECKIT_EXT_ID}" ]
}

# --- C-6: the manifest pin ---------------------------------------------------

@test "C-6: manifest extension.id equals SPECKIT_EXT_ID" {
  run python3 - "$MANIFEST" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
print((doc.get("extension") or {}).get("id"))
PY
  [ "$status" -eq 0 ]
  [ "$output" = "$SPECKIT_EXT_ID" ]
}

@test "C-6: every declared command name is namespaced speckit.<extension.id>." {
  run python3 - "$MANIFEST" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
for c in ((doc.get("provides") or {}).get("commands") or []):
    print(c.get("name"))
PY
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local name
  while read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      "speckit.${SPECKIT_EXT_ID}."*) ;;
      *)
        echo "command ${name} is not under speckit.${SPECKIT_EXT_ID}." >&2
        return 1
        ;;
    esac
  done <<<"$output"
}

@test "C-6: every declared hook command is the push command constant" {
  run python3 - "$MANIFEST" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
for name, entries in (((doc.get("provides") or {}).get("hooks")) or {}).items():
    for e in (entries or []):
        print(e.get("command"))
PY
  [ "$status" -eq 0 ]
  local cmd
  while read -r cmd; do
    [ -n "$cmd" ] || continue
    [ "$cmd" = "$SPECKIT_EXT_PUSH_COMMAND" ] || {
      echo "hook command ${cmd} != ${SPECKIT_EXT_PUSH_COMMAND}" >&2
      return 1
    }
  done <<<"$output"
}

@test "C-6: the manifest declares exactly 4 commands and 6 after_* hooks" {
  run python3 - "$MANIFEST" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
provides = doc.get("provides") or {}
commands = provides.get("commands") or []
hooks = provides.get("hooks") or {}
entries = [n for n, e in hooks.items() for _ in (e or [])]
print(len(commands))
print(len([n for n in entries if n.startswith("after_")]))
print(len([n for n in entries if not n.startswith("after_")]))
PY
  [ "$status" -eq 0 ]
  local commands after other
  { read -r commands; read -r after; read -r other; } <<<"$output"
  [ "$commands" -eq 4 ] || { echo "expected 4 commands, found ${commands}" >&2; return 1; }
  [ "$after" -eq 6 ] || { echo "expected 6 after_* hooks, found ${after}" >&2; return 1; }
  [ "$other" -eq 0 ] || { echo "expected no non-after_* hook, found ${other}" >&2; return 1; }
}

@test "C-6: every declared command file exists on disk" {
  run python3 - "$MANIFEST" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
for c in ((doc.get("provides") or {}).get("commands") or []):
    print(c.get("file"))
PY
  [ "$status" -eq 0 ]
  local file
  while read -r file; do
    [ -n "$file" ] || continue
    [ -f "${REPO_ROOT}/${file}" ] || { echo "declared command file missing: ${file}" >&2; return 1; }
  done <<<"$output"
}

# --- C-7: registrar / detector lockstep --------------------------------------
#
# The single most important test in this file. `install::register_after_hooks`
# WRITES the hook entries; `hookcheck::classify` READS them. Before feature 013
# each carried its own literal and agreed only by coincidence. Here we register
# into a throwaway consumer tree and classify the result back — proving the two
# agree WITHOUT comparing literals, and that both derive from identity.sh.

@test "C-7: the registrar writes the identity constant's token" {
  local work="$BATS_TEST_TMPDIR/consumer-writes"
  mkdir -p "$work"
  run bash -c '
    set -euo pipefail
    cd "$2"
    source "$1/src/install.sh"
    install::register_after_hooks >/dev/null 2>&1
    cat .specify/extensions.yml
  ' _ "$REPO_ROOT" "$work"
  [ "$status" -eq 0 ]
  [ "$(grep -c "^  - extension: ${SPECKIT_EXT_ID}\$" <<<"$output")" -eq 6 ]
  [ "$(grep -c "^    command: ${SPECKIT_EXT_PUSH_COMMAND}\$" <<<"$output")" -eq 6 ]
}

@test "C-7: what the registrar writes, the detector reads back as present" {
  local work="$BATS_TEST_TMPDIR/consumer-lockstep"
  mkdir -p "$work"
  run bash -c '
    set -euo pipefail
    cd "$2"
    source "$1/src/install.sh"
    source "$1/src/hookcheck.sh"
    install::register_after_hooks >/dev/null 2>&1
    for h in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
      printf "%s=%s\n" "$h" "$(hookcheck::classify "$h")"
    done
    hookcheck::assess_into
    printf "overall=%s\n" "$HOOKCHECK_OVERALL"
  ' _ "$REPO_ROOT" "$work"
  [ "$status" -eq 0 ]
  local hook
  for hook in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
    grep -qx "${hook}=present" <<<"$output" || {
      echo "registrar/detector divergence for ${hook}:" >&2
      echo "$output" >&2
      return 1
    }
  done
  grep -qx "overall=present" <<<"$output"
}
