#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/engine_vendor_neutral.bats  (feature-003 US2, T012 — FR-012/SC-003)
#
# The ENFORCED neutrality gate: the engine orchestration path must carry NO Jira
# knowledge — no issue-type id resolution, no artifact-name literal used as a
# value, no relationship vocabulary. All of that lives behind the sink + config.
# This test statically audits the enumerated engine-orchestration functions (per
# contracts/engine-sink-interface-003.md §3) and FAILS CI if a forbidden token
# leaks into the engine path, so lift-readiness cannot silently regress.
#
# What is allowed (neutral): the level names repo/spec/phase/task; config label-
# prefix keys; workstate field names; calls to sink/config functions by name;
# and user-facing strings in `summary::add` / `*::_log` / `reconcile::log` lines
# (those legitimately say "Story"/"Subtask" for humans — they don't select a
# Jira type). Comments are documentation, not behavior, and are also stripped.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  ENGINE="$REPO_ROOT/src/reconcile.sh"
}

# The audited surface (the contract's enumerated list + the per-spec wrappers +
# the neutral repo-epic resolver — every engine function that drives projection).
_audited_functions() {
  printf '%s\n' \
    reconcile::process_spec \
    reconcile::process_workstate_item \
    reconcile::sync_spec_issue \
    reconcile::sync_task_phase_subissues \
    reconcile::ordered_levels \
    reconcile::compose_identity \
    reconcile::compose_payload \
    reconcile::parent_projected_id \
    reconcile::_repo_epic_key \
    reconcile::rollup_phases \
    reconcile::cascade_phases \
    reconcile::rollup_repo_epic \
    reconcile::sync_initiative \
    reconcile::compute_orphans \
    reconcile::remode \
    reconcile::warn_orphans \
    reconcile::privacy_gate
}

# Extract a top-level function's BODY (between `name() {` and the col-0 `}`),
# then strip comment lines and the human-facing summary/log lines.
_audited_body() {
  local fn="$1"
  awk -v fn="${fn}() {" '
    $0 == fn { inside=1; next }
    inside && /^}/ { inside=0 }
    inside { print }
  ' "$ENGINE" \
    | grep -vE '^[[:space:]]*#' \
    | grep -vE 'summary::add|::_log|reconcile::log'
}

@test "every audited engine function exists" {
  local fn
  while read -r fn; do
    grep -qE "^${fn}\(\) \{" "$ENGINE" || {
      echo "audited function not found in the engine: $fn" >&2; false; }
  done < <(_audited_functions)
}

@test "no engine function resolves a Jira issue type (issue_types / *_issue_type_id)" {
  local fn body
  while read -r fn; do
    body="$(_audited_body "$fn")"
    if printf '%s' "$body" | grep -qE 'issue_types|_artifact_issue_type_id|_level_issue_type_id'; then
      echo "VENDOR LEAK in ${fn}: resolves a Jira issue-type id" >&2
      printf '%s\n' "$body" | grep -nE 'issue_types|_artifact_issue_type_id|_level_issue_type_id' >&2
      false
    fi
  done < <(_audited_functions)
}

@test "no engine function uses a Jira artifact-name literal as a value" {
  # Capitalized artifact names (Epic/Story/Subtask/Task/Initiative) as VALUES —
  # the level vocabulary the engine may use is the lowercase repo/spec/phase/task.
  local fn body
  while read -r fn; do
    body="$(_audited_body "$fn")"
    if printf '%s' "$body" | grep -qE '\b(Epic|Story|Subtask|Initiative)\b|\bTask\b'; then
      echo "VENDOR LEAK in ${fn}: an artifact-name literal appears in behavior" >&2
      printf '%s\n' "$body" | grep -nE '\b(Epic|Story|Subtask|Initiative)\b|\bTask\b' >&2
      false
    fi
  done < <(_audited_functions)
}

@test "no engine function uses Jira relationship vocabulary as a value" {
  # The relationship vocabulary (Epic-link, Epic Link) lives behind the sink.
  local fn body
  while read -r fn; do
    body="$(_audited_body "$fn")"
    if printf '%s' "$body" | grep -qE 'Epic-link|Epic Link'; then
      echo "VENDOR LEAK in ${fn}: relationship vocabulary in the engine" >&2
      printf '%s\n' "$body" | grep -nE 'Epic-link|Epic Link' >&2
      false
    fi
  done < <(_audited_functions)
}
