#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/phase_parser.bats  (feature-010 US2 — FR-005/006/007, C-8/C-9)
#
# Phase-header parser broadening. `parser::task_phases` must:
#   * keep `## Phase N: Name` (numeric + colon) BYTE-IDENTICAL — the regression
#     anchor locked BEFORE the broadening (C-9 / SC-005 / FR-007), and
#   * additionally recognize a single-letter index AND non-colon separators
#     (em-dash / en-dash / hyphen) — `## Phase A — Name`, `## Phase 1 — Name`
#     (C-8 / FR-005), while `## Phaser:` must NOT match (boundary).
#
# Pure filesystem — no network, no Jira coordinates (Principle IX). Fixtures are
# inline heredocs with neutral placeholder phase names.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/parser.sh"
}

# Write tasks.md content into a fresh spec dir named 010-<slug> (so any helper
# that derives parser::short_name resolves). Echoes the tasks.md path.
_make_tasks() {
  local slug="$1"
  local dir="$BATS_TEST_TMPDIR/010-${slug}"
  mkdir -p "$dir"
  cat >"$dir/tasks.md"
  printf '%s\n' "$dir/tasks.md"
}

# -----------------------------------------------------------------------------
# C-9 (regression anchor) — locked FIRST, must pass against the CURRENT parser.
# -----------------------------------------------------------------------------
@test "task_phases: numeric-colon headers are byte-identical (C-9 anchor)" {
  local tm
  tm="$(_make_tasks numeric-colon <<'EOF'
# Tasks

## Phase 1: Setup

- [ ] T001 do a thing

## Phase 10: Polish

- [ ] T002 polish it
EOF
)"
  run parser::task_phases "$tm"
  [ "$status" -eq 0 ]
  # The pre-feature oracle: `<idx>\t<name>` per header, numerics intact.
  local expected
  expected="$(printf '1\tSetup\n10\tPolish')"
  [ "$output" = "$expected" ]
}

@test "task_phases: a name with internal punctuation/spacing is preserved (anchor)" {
  local tm
  tm="$(_make_tasks anchor-name <<'EOF'
## Phase 2: Cascade — the neutral pass
EOF
)"
  run parser::task_phases "$tm"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '2\tCascade — the neutral pass')" ]
}

# -----------------------------------------------------------------------------
# C-8 — letter index + non-colon separators (fails until T005).
# -----------------------------------------------------------------------------
@test "task_phases: letter index with em-dash is detected (C-8)" {
  local tm
  tm="$(_make_tasks letter-emdash <<'EOF'
## Phase A — Foundations

- [ ] T001 lay the foundations
EOF
)"
  run parser::task_phases "$tm"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'A\tFoundations')" ]
}

@test "task_phases: numeric index with em-dash, no colon, is detected (C-8)" {
  local tm
  tm="$(_make_tasks numeric-emdash <<'EOF'
## Phase 1 — Setup
EOF
)"
  run parser::task_phases "$tm"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '1\tSetup')" ]
}

@test "task_phases: hyphen and en-dash separators are detected (C-8)" {
  local tm
  tm="$(_make_tasks dash-variants <<'EOF'
## Phase 3 - Hyphen Name

## Phase 4 – En Dash Name
EOF
)"
  run parser::task_phases "$tm"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '3\tHyphen Name\n4\tEn Dash Name')" ]
}

@test "task_phases: '## Phaser:' does NOT match (word boundary, C-8)" {
  local tm
  tm="$(_make_tasks phaser <<'EOF'
## Phaser: not a phase

## Phasecontrol blah
EOF
)"
  run parser::task_phases "$tm"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "task_phases: mixed numeric-colon + letter-emdash file (both detected, C-8)" {
  local tm
  tm="$(_make_tasks mixed <<'EOF'
## Phase 1: Setup

- [ ] T001 setup

## Phase A — Foundations

- [ ] T002 foundations
EOF
)"
  run parser::task_phases "$tm"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '1\tSetup\nA\tFoundations')" ]
}

# -----------------------------------------------------------------------------
# tasks_in_phase + malformed (unphased) scan must agree with the broadened
# header recognition so letter/dash phases attach their tasks (FR-005/006).
# -----------------------------------------------------------------------------
@test "tasks_in_phase: a letter-indexed phase attaches its tasks (C-8/C-10)" {
  local tm
  tm="$(_make_tasks letter-tasks <<'EOF'
## Phase A — Foundations

- [ ] T001 first task
- [x] T002 second task
EOF
)"
  run parser::tasks_in_phase "$tm" "A"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q $'T001\tunchecked\tfirst task'
  printf '%s\n' "$output" | grep -q $'T002\tchecked\tsecond task'
}

@test "malformed_task_lines: tasks under a letter/dash phase are NOT flagged unphased (C-8)" {
  local tm
  tm="$(_make_tasks letter-unphased <<'EOF'
## Phase A — Foundations

- [ ] T001 belongs to phase A
EOF
)"
  run parser::malformed_task_lines "$tm"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
