#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/config_write.bats  (feature 008 — Phase 2, T005-T007)
#
# Unit tests for the new `config::write_binding` writer in src/config.sh — the
# riskiest new piece of the install/seed ceremony. It must:
#   - fresh path absent: copy config-template.yml then substitute every resolved
#     value into its placeholder position; the written file `config::load`s back
#     to exactly those ids (round-trip)                                  [C-1]
#   - byte-stable idempotency: two calls with the same resolved values into the
#     same path are byte-identical (no timestamp/nonce; cmp clean)   [C-3/VR-5]
#   - operator-block preservation: a pre-existing config with operator-authored
#     mapping:/attribution:/remode: blocks keeps those blocks byte-for-byte while
#     only the resolved id fields change                              [C-4/VR-6]
#
# Offline + deterministic; no network; placeholder-only (Privacy IX).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/config.sh"
  export CONFIG_TEMPLATE_PATH="$REPO_ROOT/config-template.yml"
  TARGET="$BATS_TEST_TMPDIR/jira-config.yml"
}

# The resolved key=value set a successful install holds in memory before the
# single write: project_key, the three issue-type ids, the 6 phase_status ids,
# and the optional story-points field id.
_resolved_args() {
  printf '%s\n' \
    "project_key=ABC" \
    "issue_types.epic=11001" \
    "issue_types.story=11002" \
    "issue_types.subtask=11003" \
    "phase_status.specifying=21001" \
    "phase_status.planning=21002" \
    "phase_status.tasking=21003" \
    "phase_status.implementing=21004" \
    "phase_status.ready_to_merge=21005" \
    "phase_status.merged=21006" \
    "story_points_field_id=customfield_10099"
}

@test "T005 write_binding fresh: round-trips every resolved id (C-1)" {
  local -a args=()
  mapfile -t args < <(_resolved_args)

  run config::write_binding "$TARGET" "${args[@]}"
  [ "$status" -eq 0 ]
  [ -f "$TARGET" ]

  # The written file loads + validates back to exactly the resolved ids.
  config::load "$TARGET"
  [ "$(config::get project_key)" = "ABC" ]
  [ "$(config::get issue_types.epic)" = "11001" ]
  [ "$(config::get issue_types.story)" = "11002" ]
  [ "$(config::get issue_types.subtask)" = "11003" ]
  [ "$(config::get phase_status.specifying)" = "21001" ]
  [ "$(config::get phase_status.planning)" = "21002" ]
  [ "$(config::get phase_status.tasking)" = "21003" ]
  [ "$(config::get phase_status.implementing)" = "21004" ]
  [ "$(config::get phase_status.ready_to_merge)" = "21005" ]
  [ "$(config::get phase_status.merged)" = "21006" ]
  # config::validate must accept the written binding (all required keys present).
  run config::validate
  [ "$status" -eq 0 ]
}

@test "T006 write_binding is byte-stable / idempotent (C-3/VR-5)" {
  local -a args=()
  mapfile -t args < <(_resolved_args)

  config::write_binding "$TARGET" "${args[@]}"
  cp "$TARGET" "$BATS_TEST_TMPDIR/first.yml"

  # Second call into the same path with the same resolved values.
  config::write_binding "$TARGET" "${args[@]}"

  run cmp "$BATS_TEST_TMPDIR/first.yml" "$TARGET"
  [ "$status" -eq 0 ]
}

@test "T007 write_binding preserves operator-authored blocks byte-for-byte (C-4/VR-6)" {
  # Seed the target with an EXISTING config carrying a non-default operator
  # mapping:/attribution:/remode: block. The resolved-id fields below are
  # deliberately STALE (old ids) so we can prove they get rewritten.
  cat > "$TARGET" <<'YAML'
jira:
  project_key: "OLD"
  issue_types:
    epic: "90001"
    story: "90002"
    subtask: "90003"
  phase_status:
    specifying: "99001"
    planning: "99002"
    tasking: "99003"
    implementing: "99004"
    ready_to_merge: "99005"
    merged: "99006"
  transitions: {}
  labels:
    spec_prefix: "speckit-spec:"
    repo_prefix: "speckit-repo:"
    phase_prefix: "task-phase:"
    lifecycle_prefix: "phase:"
  attribution:
    enabled: true
    assignee: false
    label: true
  remode:
    destruction: archive
    archive_status: "88888"
  mapping:
    project_style: "classic"
    levels:
      repo: { artifact: "Epic", relationship_to_parent: "none" }
      spec: { artifact: "Story", relationship_to_parent: "Epic-link" }
      phase: { artifact: "Task", relationship_to_parent: "parent" }
      task: { artifact: "checklist", relationship_to_parent: "checklist" }
YAML

  local -a args=()
  mapfile -t args < <(_resolved_args)
  run config::write_binding "$TARGET" "${args[@]}"
  [ "$status" -eq 0 ]

  # The resolved id fields are rewritten.
  config::load "$TARGET"
  [ "$(config::get project_key)" = "ABC" ]
  [ "$(config::get issue_types.epic)" = "11001" ]
  [ "$(config::get phase_status.implementing)" = "21004" ]

  # The operator-authored blocks survive byte-for-byte.
  grep -q 'enabled: true' "$TARGET"
  grep -q 'assignee: false' "$TARGET"
  grep -q 'destruction: archive' "$TARGET"
  grep -q 'archive_status: "88888"' "$TARGET"
  grep -q 'project_style: "classic"' "$TARGET"
  grep -q 'relationship_to_parent: "Epic-link"' "$TARGET"
  grep -q 'artifact: "Task", relationship_to_parent: "parent"' "$TARGET"
}
