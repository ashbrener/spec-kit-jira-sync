#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/checklist_subtree.bats  (feature-002 US3, T026)
#
# Unit tests for adf::render_checklist_subtree — the 2-level (checklist) mode
# renderer. It emits the in-body checklist SUB-TREE: a stable provenance marker
# paragraph followed by an ADF taskList whose items are KEYED BY THE WORKSTATE
# TASK ID (Q9), with byte-stable ordering so an unchanged re-render is
# byte-identical (the SC-004 / FR-008 zero-churn anchor for 2-level mode).
#
# Pure transform: no network, no curl. Placeholders only (Principle IX).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/src/adf.sh"
}

# A two-phase flattened task set with explicit, stable workstate task ids.
_tasks() {
  printf '%s' '[
    {"id":"1.0","text":"Write the spec","done":true},
    {"id":"1.1","text":"Implement the bridge","done":false},
    {"id":"2.0","text":"Polish","done":false}
  ]'
}

@test "render_checklist_subtree: emits a marker paragraph above a taskList" {
  run adf::render_checklist_subtree "$(_tasks)"
  [ "$status" -eq 0 ]

  # The sub-tree is an array of two top-level block nodes: a paragraph
  # (the provenance marker) THEN the taskList.
  echo "$output" | jq -e 'type == "array" and length == 2'
  echo "$output" | jq -e '.[0].type == "paragraph"'
  echo "$output" | jq -e '.[1].type == "taskList"'
}

@test "render_checklist_subtree: each item keyed by its workstate task id" {
  run adf::render_checklist_subtree "$(_tasks)"
  [ "$status" -eq 0 ]

  # Three taskItems, in input order.
  echo "$output" | jq -e '[.[1].content[].type] == ["taskItem","taskItem","taskItem"]'
  echo "$output" | jq -e '.[1].content[0].content[0].text == "Write the spec"'
  echo "$output" | jq -e '.[1].content[2].content[0].text == "Polish"'

  # localId of each item embeds its workstate task id (NOT a bare index) so a
  # reorder/rename re-keys by id rather than position.
  echo "$output" | jq -e '.[1].content[0].attrs.localId == "task-1.0"'
  echo "$output" | jq -e '.[1].content[1].attrs.localId == "task-1.1"'
  echo "$output" | jq -e '.[1].content[2].attrs.localId == "task-2.0"'

  # localIds are unique.
  echo "$output" | jq -e '[.[1].content[].attrs.localId] | (unique | length) == 3'
}

@test "render_checklist_subtree: DONE/TODO state follows each task's done flag" {
  run adf::render_checklist_subtree "$(_tasks)"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.[1].content[].attrs.state] == ["DONE","TODO","TODO"]'
}

@test "render_checklist_subtree: the marker line is stable and non-empty" {
  run adf::render_checklist_subtree "$(_tasks)"
  [ "$status" -eq 0 ]
  # A single stable marker text node; the same constant exposed for the diff.
  echo "$output" | jq -e '(.[0].content[0].text | length) > 0'
  echo "$output" | jq -e --arg m "$ADF_CHECKLIST_MARKER" '.[0].content[0].text == $m'
}

@test "render_checklist_subtree: re-render of identical tasks is byte-identical" {
  local a b
  a="$(adf::render_checklist_subtree "$(_tasks)")"
  b="$(adf::render_checklist_subtree "$(_tasks)")"
  [ "$a" = "$b" ]
}

@test "render_checklist_subtree: empty task set still yields marker + empty taskList" {
  run adf::render_checklist_subtree '[]'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].type == "paragraph"'
  echo "$output" | jq -e '.[1].type == "taskList" and (.[1].content | length == 0)'
}

@test "render_checklist_subtree: a completion toggle changes only the state attr" {
  local base toggled
  base="$(adf::render_checklist_subtree "$(_tasks)")"
  # Flip task 1.1 to done.
  toggled="$(adf::render_checklist_subtree '[
    {"id":"1.0","text":"Write the spec","done":true},
    {"id":"1.1","text":"Implement the bridge","done":true},
    {"id":"2.0","text":"Polish","done":false}
  ]')"
  [ "$base" != "$toggled" ]
  # Same localIds (no duplication / no re-key on a mere toggle).
  local ids_base ids_toggled
  ids_base="$(printf '%s' "$base" | jq -c '[.[1].content[].attrs.localId]')"
  ids_toggled="$(printf '%s' "$toggled" | jq -c '[.[1].content[].attrs.localId]')"
  [ "$ids_base" = "$ids_toggled" ]
}

@test "render_checklist_subtree: text with JSON-hostile chars is safely escaped" {
  run adf::render_checklist_subtree '[{"id":"1.0","text":"Edge \"quotes\" and {braces}","done":false}]'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[1].content[0].content[0].text == "Edge \"quotes\" and {braces}"'
}
