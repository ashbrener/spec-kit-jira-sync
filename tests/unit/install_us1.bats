#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/install_us1.bats  (feature 008 — US1, T015-T017 + R1)
#
# End-to-end install over the curl-shim (offline): install::main resolves the
# binding and writes a complete gitignored jira-config.yml, after which
# reconcile.sh --dry-run runs WITHOUT an exit-2 config halt (SC-001/C-1). Plus:
#   - T016/C-11: story-points field absent ⇒ install still succeeds (exit 0),
#     records it as absent, writes a complete binding.
#   - T017/C-3: a second install against the same shimmed project yields a
#     BYTE-IDENTICAL jira-config.yml (idempotent).
#   - R1: a NON-INTERACTIVE install with an UNMAPPABLE phase ⇒ exit 2, names the
#     phase, and writes ZERO bytes (the resolve-stage no-partial-write proof).
#
# Placeholder-only (Privacy IX): PROJ, example.atlassian.net, fabricated ids.
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export JIRA_MAX_RETRIES=0
  export DRY_RUN=0
  export CONFIG_TEMPLATE_PATH="$REPO_ROOT/config-template.yml"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/install.sh"

  # Run install from a CONSUMER tree (never the bridge's own checkout), so the
  # source≠target guard passes. The written binding lives under it.
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER/specs"
  cd "$CONSUMER"
  TARGET="$CONSUMER/jira-config.yml"

  jira_shim::install

  PROJ_FX="$BATS_TEST_TMPDIR/proj.json"
  STAT_FX="$BATS_TEST_TMPDIR/stat.json"
  FLD_FX="$BATS_TEST_TMPDIR/fld.json"
  jq -n '{key:"PROJ",issueTypes:[
    {name:"Epic",id:"12001"},{name:"Story",id:"12002"},{name:"Subtask",id:"12003"}
  ]}' >"$PROJ_FX"
  jq -n '[ { "id":"10000","name":"Story","statuses":[
      {"id":"31001","name":"To Do","statusCategory":{"key":"new"}},
      {"id":"31002","name":"In Progress","statusCategory":{"key":"indeterminate"}},
      {"id":"31003","name":"Done","statusCategory":{"key":"done"}}
  ]} ]' >"$STAT_FX"
  jq -n '[ {id:"customfield_10016",name:"Story Points",schema:{custom:"x:float"}} ]' >"$FLD_FX"
}

teardown() {
  jira_shim::uninstall
}

_register_full_project() {
  jira_shim::set_response GET "*/myself*" "myself_ok.json" 200
  jira_shim::set_response GET "*/project/PROJ/statuses*" "$STAT_FX" 200
  jira_shim::set_response GET "*/project/PROJ*" "$PROJ_FX" 200
  jira_shim::set_response GET "*/field*" "$FLD_FX" 200
}

@test "T015 install::main writes a complete binding; reconcile --dry-run is not exit-2 (C-1)" {
  _register_full_project

  run install::main --project PROJ --non-interactive --no-seed --config "$TARGET"
  [ "$status" -eq 0 ]
  [ -f "$TARGET" ]

  # The written binding is complete + valid.
  config::load "$TARGET"
  run config::validate
  [ "$status" -eq 0 ]
  [ "$(config::get project_key)" = "PROJ" ]
  [ "$(config::get issue_types.story)" = "12002" ]
  [ "$(config::get phase_status.merged)" = "31003" ]

  # reconcile --dry-run against the written binding does not halt with the
  # exit-2 missing/invalid-config error. The reconcile config gate IS exactly
  # config::validate + the available-type validation (mapping::validate_available
  # over the shimmed project probe); proving both pass proves there is no exit-2
  # config halt — without an external `bash reconcile.sh` that would bypass the
  # in-process curl-shim and hit a real, unreachable Jira.
  mapping::parse
  mapping::validate
  local -a probe_rows=()
  mapfile -t probe_rows < <(mapping::detect_available_types)
  run mapping::validate_available "${probe_rows[@]}"
  [ "$status" -eq 0 ]
}

@test "T016 story-points absent ⇒ install still succeeds (C-11)" {
  jira_shim::set_response GET "*/myself*" "myself_ok.json" 200
  jira_shim::set_response GET "*/project/PROJ/statuses*" "$STAT_FX" 200
  jira_shim::set_response GET "*/project/PROJ*" "$PROJ_FX" 200
  # field response with NO story-points field.
  local nofld="$BATS_TEST_TMPDIR/nofld.json"
  jq -n '[ {id:"summary",name:"Summary"} ]' >"$nofld"
  jira_shim::set_response GET "*/field*" "$nofld" 200

  run install::main --project PROJ --non-interactive --no-seed --config "$TARGET"
  [ "$status" -eq 0 ]
  [ -f "$TARGET" ]
  # A complete binding minus the optional field.
  config::load "$TARGET"
  run config::validate
  [ "$status" -eq 0 ]
  # No story-points line was written.
  ! grep -q 'story_points_field_id' "$TARGET"
}

@test "T017 a second install is byte-identical (C-3 e2e)" {
  _register_full_project

  install::main --project PROJ --non-interactive --no-seed --config "$TARGET"
  cp "$TARGET" "$BATS_TEST_TMPDIR/first.yml"

  jira_shim::reset
  _register_full_project
  install::main --project PROJ --non-interactive --no-seed --config "$TARGET"

  run cmp "$BATS_TEST_TMPDIR/first.yml" "$TARGET"
  [ "$status" -eq 0 ]
}

@test "R1 non-interactive install, unmappable phase ⇒ exit 2, names it, zero bytes (no-partial-write)" {
  # A statuses set with NO 'done'-category status: ready_to_merge + merged have
  # no default and (non-interactively) no --phase-status override ⇒ unmappable.
  local stat_nodone="$BATS_TEST_TMPDIR/stat_nodone.json"
  jq -n '[ { "id":"10000","name":"Story","statuses":[
      {"id":"31001","name":"To Do","statusCategory":{"key":"new"}},
      {"id":"31002","name":"In Progress","statusCategory":{"key":"indeterminate"}}
  ]} ]' >"$stat_nodone"
  jira_shim::set_response GET "*/myself*" "myself_ok.json" 200
  jira_shim::set_response GET "*/project/PROJ/statuses*" "$stat_nodone" 200
  jira_shim::set_response GET "*/project/PROJ*" "$PROJ_FX" 200
  jira_shim::set_response GET "*/field*" "$FLD_FX" 200

  run install::main --project PROJ --non-interactive --no-seed --config "$TARGET"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ready_to_merge"* ]] || [[ "$output" == *"merged"* ]]
  # Zero bytes written — the resolve stage failed before the single write.
  [ ! -e "$TARGET" ]
}
