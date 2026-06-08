#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/checklist_diff.bats  (feature-002 US3, T027)
#
# Unit tests for the 2-level checklist SUB-TREE diff/write in src/jira_sink.sh:
#   - diff_checklist_subtree byte-compares ONLY the checklist sub-tree (the
#     marker paragraph + taskList), NOT the full body — so an unrelated prose
#     edit above the marker does not read as a change (Q7, FR-008);
#   - sync_body_checklist SKIPS the write when the sub-tree is unchanged
#     (zero churn), and when it DOES write it PRESERVES the prose preamble and
#     swaps only the sub-tree (no duplicate checklist).
#
# Offline + deterministic over the curl-shim (decision D10); no network, no real
# Jira coordinates (Privacy IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  # 2-level config: phase + task both collapse to the in-body checklist.
  CONF="${BATS_TEST_TMPDIR}/jira-config.yml"
  cat > "$CONF" <<'YAML'
jira:
  project_key: "PROJ"
  issue_types:
    epic: "10001"
    story: "10002"
    subtask: "10003"
  phase_status:
    specifying: "20001"
    planning: "20002"
    tasking: "20003"
    implementing: "20004"
    ready_to_merge: "20005"
    merged: "20006"
  transitions: {}
  labels:
    spec_prefix: "speckit-spec:"
    repo_prefix: "speckit-repo:"
    phase_prefix: "task-phase:"
    lifecycle_prefix: "phase:"
    task_prefix: "speckit-task:"
  mapping:
    levels:
      repo:  { artifact: "Epic",  relationship_to_parent: "none" }
      spec:  { artifact: "Story", relationship_to_parent: "parent" }
      phase: { artifact: "checklist", relationship_to_parent: "checklist" }
      task:  { artifact: "checklist", relationship_to_parent: "checklist" }
YAML
  config::load "$CONF"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::install

  TASKS='[
    {"id":"1.0","text":"Write the spec","done":true},
    {"id":"1.1","text":"Implement","done":false}
  ]'
  SUBTREE="$(adf::render_checklist_subtree "$TASKS")"
}

teardown() {
  jira_shim::uninstall
}

# Write a fixture issue whose description is a doc of <prose-content> + <subtree>.
# Args: <dest-file> <subtree-json>   (prose is a fixed single paragraph)
_issue_with_subtree() {
  local dest="$1" subtree="$2"
  jq -n --argjson st "$subtree" '
    {
      key: "PROJ-101",
      fields: {
        summary: "001 — Example",
        description: {
          version: 1, type: "doc",
          content: ([ {type:"paragraph",content:[{type:"text",text:"Spec prose here."}]} ] + $st)
        },
        labels: ["speckit-spec:001"],
        status: { id: "20004" },
        parent: { key: "PROJ-100" }
      }
    }' > "$dest"
}

# An issue whose description is prose ONLY (no checklist yet — the fresh case).
_issue_prose_only() {
  local dest="$1"
  jq -n '
    {
      key: "PROJ-101",
      fields: {
        summary: "001 — Example",
        description: {
          version: 1, type: "doc",
          content: [ {type:"paragraph",content:[{type:"text",text:"Spec prose here."}]} ]
        },
        labels: ["speckit-spec:001"],
        status: { id: "20004" },
        parent: { key: "PROJ-100" }
      }
    }' > "$dest"
}

# --- diff_checklist_subtree --------------------------------------------------

@test "diff_checklist_subtree: identical sub-tree reads as unchanged" {
  local fx="${BATS_TEST_TMPDIR}/cur_same.json"
  _issue_with_subtree "$fx" "$SUBTREE"
  jira_shim::set_response GET "*/issue/PROJ-101*" "$fx" 200

  run diff_checklist_subtree "PROJ-101" "$SUBTREE"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
}

@test "diff_checklist_subtree: a toggled task reads as changed" {
  local fx="${BATS_TEST_TMPDIR}/cur_toggle.json"
  # Current has 1.1 DONE; desired SUBTREE has 1.1 TODO.
  local cur_sub
  cur_sub="$(adf::render_checklist_subtree '[
    {"id":"1.0","text":"Write the spec","done":true},
    {"id":"1.1","text":"Implement","done":true}
  ]')"
  _issue_with_subtree "$fx" "$cur_sub"
  jira_shim::set_response GET "*/issue/PROJ-101*" "$fx" 200

  run diff_checklist_subtree "PROJ-101" "$SUBTREE"
  [ "$status" -eq 0 ]
  [ "$output" = "changed" ]
}

@test "diff_checklist_subtree: an edit to the prose ABOVE the marker is NOT a change" {
  # Same sub-tree, but the prose preamble is edited (a human edit in Jira).
  local fx="${BATS_TEST_TMPDIR}/cur_prose.json"
  jq -n --argjson st "$SUBTREE" '
    {
      key: "PROJ-101",
      fields: {
        description: {
          version: 1, type: "doc",
          content: ([ {type:"paragraph",content:[{type:"text",text:"A HUMAN EDITED this prose."}]} ] + $st)
        }
      }
    }' > "$fx"
  jira_shim::set_response GET "*/issue/PROJ-101*" "$fx" 200

  run diff_checklist_subtree "PROJ-101" "$SUBTREE"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
}

@test "diff_checklist_subtree: no marker yet (fresh) reads as changed" {
  local fx="${BATS_TEST_TMPDIR}/cur_fresh.json"
  _issue_prose_only "$fx"
  jira_shim::set_response GET "*/issue/PROJ-101*" "$fx" 200

  run diff_checklist_subtree "PROJ-101" "$SUBTREE"
  [ "$status" -eq 0 ]
  [ "$output" = "changed" ]
}

@test "diff_checklist_subtree: an unreadable read fails closed (rc 3)" {
  jira_shim::set_response GET "*/issue/PROJ-101*" error_401.json 401
  run diff_checklist_subtree "PROJ-101" "$SUBTREE"
  [ "$status" -eq 3 ]
}

# --- sync_body_checklist -----------------------------------------------------

@test "sync_body_checklist: unchanged sub-tree performs ZERO writes" {
  local fx="${BATS_TEST_TMPDIR}/cur_same.json"
  _issue_with_subtree "$fx" "$SUBTREE"
  jira_shim::set_response GET "*/issue/PROJ-101*" "$fx" 200

  # Call directly (NOT via `run`) so the disposition global propagates.
  local rc=0
  sync_body_checklist "PROJ-101" "$SUBTREE" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$JIRA_SINK_CHECKLIST_DISPOSITION" = "skipped" ]

  # No PUT was issued.
  local puts
  puts="$(jira_shim::requests | grep -c '^METHOD PUT' || true)"
  [ "$puts" -eq 0 ]
}

@test "sync_body_checklist: a changed sub-tree writes, preserving the prose preamble" {
  local fx="${BATS_TEST_TMPDIR}/cur_toggle.json"
  local cur_sub
  cur_sub="$(adf::render_checklist_subtree '[
    {"id":"1.0","text":"Write the spec","done":true},
    {"id":"1.1","text":"Implement","done":true}
  ]')"
  _issue_with_subtree "$fx" "$cur_sub"
  jira_shim::set_response GET "*/issue/PROJ-101*" "$fx" 200
  jira_shim::set_response PUT "*/rest/api/3/issue/PROJ-101*" issue_create_ok.json 204

  local rc=0
  sync_body_checklist "PROJ-101" "$SUBTREE" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$JIRA_SINK_CHECKLIST_DISPOSITION" = "updated" ]

  # Exactly one PUT, and its body preserves the prose preamble AND carries the
  # new sub-tree (the desired SUBTREE has 1.1 as TODO), with NO duplicate marker.
  local body
  body="$(jira_shim::requests | sed -n 's/^BODY //p' | tail -1)"
  printf '%s' "$body" | jq -e '.fields.description.content[0].content[0].text == "Spec prose here."'
  # The marker appears exactly once (no duplicated checklist).
  local markers
  markers="$(printf '%s' "$body" | jq --arg m "$ADF_CHECKLIST_MARKER" \
    '[.fields.description.content[] | select(.type=="paragraph") | select(([.content[]?.text]|join(""))==$m)] | length')"
  [ "$markers" -eq 1 ]
  # The written sub-tree equals the desired sub-tree (1.1 back to TODO).
  printf '%s' "$body" | jq -e '
    ([.fields.description.content[] | select(.type=="taskList")][0].content[1].attrs.state) == "TODO"'
}

@test "sync_body_checklist: fresh issue (no marker) appends the checklist once" {
  local fx="${BATS_TEST_TMPDIR}/cur_fresh.json"
  _issue_prose_only "$fx"
  jira_shim::set_response GET "*/issue/PROJ-101*" "$fx" 200
  jira_shim::set_response PUT "*/rest/api/3/issue/PROJ-101*" issue_create_ok.json 204

  local rc=0
  sync_body_checklist "PROJ-101" "$SUBTREE" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$JIRA_SINK_CHECKLIST_DISPOSITION" = "updated" ]

  local body
  body="$(jira_shim::requests | sed -n 's/^BODY //p' | tail -1)"
  # Prose preserved, exactly one marker, the taskList present.
  printf '%s' "$body" | jq -e '.fields.description.content[0].content[0].text == "Spec prose here."'
  printf '%s' "$body" | jq -e '[.fields.description.content[] | select(.type=="taskList")] | length == 1'
}

@test "sync_body_checklist: an unreadable read fails closed (rc 3, no write)" {
  jira_shim::set_response GET "*/issue/PROJ-101*" error_401.json 401
  run sync_body_checklist "PROJ-101" "$SUBTREE"
  [ "$status" -eq 3 ]
}
