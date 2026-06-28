#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/manifest_hooks.bats  (feature 011 — Phase 1, T001 / C-1)
#
# The committed extension.yml manifest is the CLI-registered source of truth for
# the automatic mirror (Principle VII). It MUST declare all six `after_*` hooks,
# each firing `speckit.jira.push` with `optional: false`, `enabled: true`, and
# NO `before_*` hook (the bridge never pre-empts a lifecycle step).
#
# Pure-filesystem; parses the real YAML (PyYAML) — no Jira, no curl-shim.
# Placeholder-only (Privacy IX): command names + neutral prose, no coordinate.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  MANIFEST="$REPO_ROOT/extension.yml"
}

# Emit "<hook>\t<command>\t<optional>\t<enabled>" for every provides.hooks entry.
_dump_hooks() {
  python3 - "$MANIFEST" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
hooks = (doc.get("provides") or {}).get("hooks") or {}
for name, entries in hooks.items():
    for e in (entries or []):
        print("\t".join([
            name,
            str(e.get("command")),
            str(e.get("optional")),
            str(e.get("enabled")),
        ]))
PY
}

@test "C-1: extension.yml declares all six after_* hooks → speckit.jira.push" {
  run _dump_hooks
  [ "$status" -eq 0 ]
  local hook
  for hook in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
    echo "$output" | grep -qE "^${hook}	speckit\.jira\.push	" || {
      echo "missing/incorrect hook entry for ${hook}:" >&2
      echo "$output" >&2
      return 1
    }
  done
}

@test "C-1: every after_* hook is optional: false (Principle VII — non-skippable)" {
  run _dump_hooks
  [ "$status" -eq 0 ]
  # No line may declare the hook command as optional: True.
  if echo "$output" | grep -qE '	speckit\.jira\.push	True	'; then
    echo "a hook is optional: true (must be false per Principle VII):" >&2
    echo "$output" >&2
    return 1
  fi
  # Every declared hook line is optional: False.
  while IFS=$'\t' read -r name cmd optional enabled; do
    [ -n "$name" ] || continue
    [ "$optional" = "False" ] || {
      echo "hook ${name} has optional=${optional} (expected False)" >&2
      return 1
    }
    [ "$enabled" = "True" ] || {
      echo "hook ${name} has enabled=${enabled} (expected True)" >&2
      return 1
    }
  done <<<"$output"
}

@test "C-1: exactly the six after_* hooks are declared — and NO before_* hook" {
  run _dump_hooks
  [ "$status" -eq 0 ]
  local count
  count="$(echo "$output" | grep -cE '^after_' || true)"
  [ "$count" -eq 6 ] || {
    echo "expected 6 after_* hook entries, found ${count}:" >&2
    echo "$output" >&2
    return 1
  }
  if echo "$output" | grep -qE '^before_'; then
    echo "a before_* hook is declared (the bridge must never pre-empt a step):" >&2
    echo "$output" >&2
    return 1
  fi
}

@test "C-1: extension.id stays jira" {
  run python3 - "$MANIFEST" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
print((doc.get("extension") or {}).get("id"))
PY
  [ "$status" -eq 0 ]
  [ "$output" = "jira" ]
}
