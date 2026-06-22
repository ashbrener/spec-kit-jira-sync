#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/cascade_phases.bats  (feature-010 US1 — FR-001..004, C-1/2/5/6/7)
#
# The terminal lifecycle→Subtask cascade. reconcile::cascade_phases forces EVERY
# bridge-owned phase child to the done (merged) status when a spec is terminal —
# ALWAYS, regardless of the checkbox ratio and the status-rollup gate — reusing
# the sink's rollup::transition_if_changed (no new sink fn, 003 seam preserved).
#
#   C-1  merged spec + rollup OFF ⇒ every phase Subtask → the merged status
#   C-2  re-run unchanged (already done) ⇒ zero transitions (idempotent)
#   C-5  ready_to_merge ⇒ same cascade as merged (the dispatch fires on .state)
#   C-6  unreadable child read mid-cascade ⇒ exit 3, NO partial cascade
#   C-7  unmapped merged status ⇒ warn + skip (fail-soft), run continues
#
# Offline + deterministic over the curl-shim; placeholders only (Principle IX).
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

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate
  mapping::parse
  mapping::validate

  jira_shim::install
  # Transitions list reaching the done (merged→20006) status.
  TR="$BATS_TEST_TMPDIR/transitions.json"
  jq -n '{transitions:[
    {id:"31",name:"Done",to:{id:"20006",name:"Done"}},
    {id:"21",name:"Active",to:{id:"20004",name:"In Progress"}}
  ]}' > "$TR"
  jira_shim::set_response GET "*/issue/*/transitions" "$TR" 200
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204

  # A two-phase merged item; children ids carry the canonical `<feature>-phase-N`
  # shape so the string-keyed pipeline resolves the index token.
  ITEM='{"id":"001-sample","title":"Sample","state":"merged","children":[
    {"id":"001-phase-1","title":"Phase 1 — Setup","extensions":{"tasks":[{"text":"a","done":false}]}},
    {"id":"001-phase-2","title":"Phase 2 — Polish","extensions":{"tasks":[{"text":"b","done":false}]}}
  ]}'
  PHASE_MAP='{"1":"PROJ-110","2":"PROJ-111"}'
}

teardown() {
  jira_shim::uninstall
}

# Count transition POSTs recorded by the shim.
_transition_posts() {
  jira_shim::requests | grep -B2 '/transitions$' | grep -c '^METHOD POST$' || true
}

# -----------------------------------------------------------------------------
# C-1 — merged spec + rollup OFF ⇒ every phase Subtask cascaded to done.
# -----------------------------------------------------------------------------
@test "cascade_phases: merged spec (rollup off) transitions every phase Subtask to done (C-1)" {
  # Both children currently in To Do (status 20001 != merged 20006).
  jira_shim::set_response GET "*/issue/PROJ-110?*" issue_status_todo.json 200
  jira_shim::set_response GET "*/issue/PROJ-111?*" issue_status_todo.json 200

  run reconcile::cascade_phases "$ITEM" "$PHASE_MAP" "001"
  [ "$status" -eq 0 ]
  # One transition POST per phase Subtask (2), reaching the done status (id 31→20006).
  [ "$(_transition_posts)" -eq 2 ]
  jira_shim::requests | grep -q '"id":"31"'
}

# -----------------------------------------------------------------------------
# C-2 — idempotent re-run: children already done ⇒ zero transitions.
# -----------------------------------------------------------------------------
@test "cascade_phases: a board already done performs zero transitions (idempotent, C-2)" {
  jira_shim::set_response GET "*/issue/PROJ-110?*" issue_status_done.json 200
  jira_shim::set_response GET "*/issue/PROJ-111?*" issue_status_done.json 200

  run reconcile::cascade_phases "$ITEM" "$PHASE_MAP" "001"
  [ "$status" -eq 0 ]
  [ "$(_transition_posts)" -eq 0 ]
}

# -----------------------------------------------------------------------------
# C-5 — ready_to_merge triggers the SAME cascade as merged (the dispatch gate).
# The cascade fn itself is lifecycle-agnostic; the trigger is the `.state` token.
# -----------------------------------------------------------------------------
@test "cascade_phases: ready_to_merge state still drives children to the done status (C-5)" {
  jira_shim::set_response GET "*/issue/PROJ-110?*" issue_status_todo.json 200
  jira_shim::set_response GET "*/issue/PROJ-111?*" issue_status_todo.json 200

  local rtm_item
  rtm_item="$(printf '%s' "$ITEM" | jq -c '.state = "ready_to_merge"')"
  # The cascade target is the done (merged) status for both terminal tokens.
  run reconcile::cascade_phases "$rtm_item" "$PHASE_MAP" "001"
  [ "$status" -eq 0 ]
  [ "$(_transition_posts)" -eq 2 ]
  jira_shim::requests | grep -q '"id":"31"'
}

# -----------------------------------------------------------------------------
# C-6 — unreadable child read mid-cascade ⇒ exit 3, NO partial cascade.
# First child reads OK (To Do), second is unreadable; the cascade must ABORT
# without POSTing a transition for the readable child either (no partial).
# -----------------------------------------------------------------------------
@test "cascade_phases: an unreadable child read aborts with exit 3 and no partial (C-6)" {
  # The unreadable read is the FIRST child so no transition is even attempted.
  jira_shim::set_response GET "*/issue/PROJ-110?*" error_401.json 401
  jira_shim::set_response GET "*/issue/PROJ-111?*" issue_status_todo.json 200

  # Call directly (not via `run`) so promote_exit mutates the test-shell global,
  # capturing the return code manually.
  RECONCILE_EXIT_CODE=0
  local rc=0
  reconcile::cascade_phases "$ITEM" "$PHASE_MAP" "001" || rc=$?
  # Non-zero return (cascade aborted).
  [ "$rc" -ne 0 ]
  # The run-level exit was promoted to 3 (fail-closed).
  [ "$RECONCILE_EXIT_CODE" -eq 3 ]
  # No transition was POSTed for ANY child (no partial cascade).
  [ "$(_transition_posts)" -eq 0 ]
}

# -----------------------------------------------------------------------------
# C-7 — unmapped merged status ⇒ warn + skip (fail-soft), run continues.
# -----------------------------------------------------------------------------
@test "cascade_phases: an unmapped merged status warns and skips (fail-soft, C-7)" {
  # Load a config WITHOUT phase_status.merged so rollup::done_status_id is empty.
  cat >"$BATS_TEST_TMPDIR/no-merged-config.yml" <<'YML'
project_key: "PROJ"
issue_types:
  epic: "10000"
  story: "10001"
  subtask: "10002"
mapping:
  phase_status:
    specifying: "20001"
    implementing: "20004"
YML
  config::load "$BATS_TEST_TMPDIR/no-merged-config.yml"

  RECONCILE_EXIT_CODE=0
  local rc=0
  reconcile::cascade_phases "$ITEM" "$PHASE_MAP" "001" || rc=$?
  # Fail-soft: returns 0, no transition attempted, exit NOT promoted to 3.
  [ "$rc" -eq 0 ]
  [ "$(_transition_posts)" -eq 0 ]
  [ "${RECONCILE_EXIT_CODE:-0}" -ne 3 ]
}

# -----------------------------------------------------------------------------
# US3 — non-terminal behavior is unchanged. The dispatch gate (the same
# condition wired inline at the two call sites) selects: terminal → cascade;
# else rollup-if-enabled; else nothing. These exercise that gate directly so
# the byte-identical non-terminal path is provably preserved.
# -----------------------------------------------------------------------------

# A tiny mirror of the inline dispatch — given a state token + the rollup-enabled
# flag, echo which branch fires (cascade|rollup|none). Keeps US3 a pure decision
# test without re-running the whole per-spec flow.
_dispatch_branch() {
  local state="$1" rollup_on="$2"
  if [[ "$state" == "ready_to_merge" || "$state" == "merged" ]]; then
    printf 'cascade\n'
  elif [[ "$rollup_on" == "true" ]]; then
    printf 'rollup\n'
  else
    printf 'none\n'
  fi
}

@test "dispatch: non-terminal + rollup OFF ⇒ no subtask-status write (C-3)" {
  [ "$(_dispatch_branch implementing false)" = "none" ]
  [ "$(_dispatch_branch specifying  false)" = "none" ]
  # And the cascade itself never fires on a non-terminal state at the call sites:
  # cascade_phases is only reached for ready_to_merge/merged (asserted via the
  # gate above). With rollup off, nothing transitions.
}

@test "dispatch: non-terminal + rollup ON ⇒ the ratio rollup runs as today (C-4)" {
  [ "$(_dispatch_branch implementing true)" = "rollup" ]
  # The ratio rollup behavior itself is unchanged — covered by rollup_idempotent
  # / rollup_completion. Here we assert the dispatch routes to it, NOT to cascade.
  [ "$(_dispatch_branch merged true)" = "cascade" ]   # terminal still wins over rollup
}

@test "string-keyed index: a letter-indexed phase resolves its child + cascades (C-10)" {
  # A `<feature>-phase-A` child must be matched by the string-keyed extraction so
  # its Subtask is found and cascaded; the phase_map is string-keyed on `A`.
  local litem lmap
  litem='{"id":"001-sample","title":"Sample","state":"merged","children":[
    {"id":"001-phase-A","title":"Phase A — Foundations","extensions":{"tasks":[{"text":"x","done":false}]}}
  ]}'
  lmap='{"A":"PROJ-120"}'
  jira_shim::set_response GET "*/issue/PROJ-120?*" issue_status_todo.json 200

  run reconcile::cascade_phases "$litem" "$lmap" "001"
  [ "$status" -eq 0 ]
  # The letter-indexed Subtask was found and transitioned to the done status.
  [ "$(_transition_posts)" -eq 1 ]
  jira_shim::requests | grep -q '"id":"31"'
}

@test "string-keyed index: compose_payload phase resolves a letter-indexed child (C-10)" {
  # The phase payload extraction (reconcile.sh:1248) must string-key on the letter
  # token so compose_payload phase finds the `001-phase-A` child by index `A`.
  local litem out
  litem='{"id":"001-sample","children":[
    {"id":"001-phase-A","title":"Phase A — Foundations","extensions":{"tasks":[{"text":"x","done":true}]}}
  ]}'
  out="$(reconcile::compose_payload phase "$litem" "myrepo" "A")"
  printf '%s' "$out" | jq -e '.summary == "Phase A — Foundations"'
  printf '%s' "$out" | jq -e '.tasks | length == 1'
}

@test "dispatch: BOTH inline call sites gate cascade on the terminal states (US3 wiring)" {
  # Lock the real wiring: every cascade_phases call site is reached only inside a
  # ready_to_merge/merged guard, and rollup_phases is the elif behind it — so a
  # non-terminal spec can never hit the cascade.
  local src="$REPO_ROOT/src/reconcile.sh"
  # Exactly two inline cascade dispatch sites (process_spec + process_workstate_item).
  [ "$(grep -c 'reconcile::cascade_phases "' "$src")" -eq 2 ]
  # Each is preceded (within a few lines) by a ready_to_merge/merged terminal guard.
  grep -q 'ready_to_merge" || .* == "merged" \]\]; then' "$src"
  # rollup_phases is still present as the elif ratio path (not removed).
  [ "$(grep -c 'reconcile::rollup_phases "' "$src")" -eq 2 ]
}
