#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us3_drift.bats — the US3 backward-drift gate (end-to-end).
#
# Proves the drift comparator actually FIRES against Jira over the MOCKED REST
# (curl-shim, decision D10). The reconcile ENGINE (src/reconcile.sh, copied
# verbatim from spec-kit-linear) computes drift from a Linear-shaped issue; the
# Jira SINK's jira_sink::_fetch_drift_issue_json (US3) reshapes Jira's native
# REST response into that contract so the pipeline
#   _fetch_drift_issue_json → compute_drift → _drift_disposition → WARNING rows
# in reconcile::process_spec computes real drift for Jira.
#
# The disk sample (001-sample) infers lifecycle phase `implementing` (ordinal 4).
# A tracker Story labeled `phase:ready_to_merge` (ordinal 5) is therefore AHEAD
# of disk — backward-drift. Cases:
#
#   (a) PHASE-AHEAD — the tracker phase is later than disk. The default
#       (proceed) disposition emits a named backward-drift WARNING and STILL
#       writes (warn, don't block — Principle IV).
#   (b) RECENCY — recency only fires ALONGSIDE a phase-ordering drift (the
#       bridge's own write bumps `updated`, so recency never stands alone). The
#       fixture keeps the phase drift AND sets the tracker `updated` far enough
#       past the disk commit (> RECONCILE_DRIFT_SKEW_TOLERANCE_SECONDS, 120s)
#       that recency corroborates → signals=phase_ordering,recency.
#   (c) --on-drift=abort — NO write, Jira unchanged, a WARNING + a skip row.
#
# Offline + deterministic; no real Jira coordinates (Principle IX).
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"

  # See us1_fresh.bats: bats functrace makes jira_rest's RETURN cleanup trap be
  # inherited by the shimmed curl and delete the response body before it is
  # read. Disable it so shim-backed reads behave as in production.
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0

  # Deterministic git identity for the committed spec dir (recency disk key).
  export GIT_AUTHOR_NAME='Test Author'
  export GIT_AUTHOR_EMAIL='test@example.com'
  export GIT_COMMITTER_NAME='Test Author'
  export GIT_COMMITTER_EMAIL='test@example.com'
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  # A real git repo: compute_drift's recency disk key is the spec dir's last
  # GIT COMMIT (git_helpers::spec_dir_last_commit), NOT mtime — so the spec dir
  # must be committed at an explicit date.
  WORKDIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORKDIR/specs"
  cp -R "$REPO_ROOT/tests/fixtures/specs/001-sample" "$WORKDIR/specs/001-sample"
  git -C "$WORKDIR" init --initial-branch=main --quiet
  git -C "$WORKDIR" add -A
  # Disk spec committed at 09:31:00 — the recency baseline the tracker is
  # compared against.
  GIT_COMMITTER_DATE="2026-05-26T09:31:00+00:00" \
  GIT_AUTHOR_DATE="2026-05-26T09:31:00+00:00" \
    git -C "$WORKDIR" commit --quiet -m "seed 001-sample"

  # Keep the workstate recency env pinned so the item composition is stable.
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-26T09:31:00+00:00"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate

  jira_shim::install

  # --- Synthesize the AHEAD tracker search responses ------------------------
  # The disk sample is `implementing` (ord 4); the tracker Story is labeled
  # `phase:ready_to_merge` (ord 5) → AHEAD. Two variants: phase-only (tracker
  # `updated` within skew of the disk commit) and recency (tracker `updated`
  # far past the disk commit so recency corroborates the phase drift).
  US3_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$US3_FIXTURES"

  # PHASE-AHEAD: tracker updated +60s (< 120s skew) → phase signal only.
  _us3_story_search "ready_to_merge" "2026-05-26T09:32:00.000+0000" \
    >"$US3_FIXTURES/drift_phase_ahead.json"
  # RECENCY: tracker updated +600s (> 120s skew) → phase + recency.
  _us3_story_search "ready_to_merge" "2026-05-26T09:41:00.000+0000" \
    >"$US3_FIXTURES/drift_recency.json"

  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

# _us3_story_search <phase-token> <updated-iso>
#   Emit a Jira /search/jql REST response (NATIVE shape) for a spec-001 Story at
#   the given lifecycle phase + updated timestamp. The sink's US3 reshape maps
#   fields.labels[]/fields.status/fields.updated into the engine contract.
_us3_story_search() {
  local phase="$1" updated="$2"
  jq -n \
    --arg phase "phase:${phase}" \
    --arg updated "$updated" \
    '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10101",key:"PROJ-101",
        self:"https://example.atlassian.net/rest/api/3/issue/10101",
        fields:{
          summary:"001 — Sample spec",
          issuetype:{id:"10002",name:"Story",subtask:false},
          status:{id:"20005",name:"Ready",
                  statusCategory:{id:4,key:"indeterminate",name:"In Progress"}},
          labels:["speckit-spec:001",$phase],
          updated:$updated,
          parent:{key:"PROJ-100"}
        }}]}'
}

# us3::register_writes_ok
#   Register the repo-Epic search + write endpoints so a proceeding reconcile's
#   writes "succeed" at the transport level. The test asserts on WHETHER writes
#   fired, not on a transport error. The spec-Story /search/jql glob is
#   registered by each test to the AHEAD fixture under exercise.
us3::register_writes_ok() {
  # The repo-Epic search (encoded speckit-repo: label) — reuse an existing Epic
  # so no Epic create fires. Registered before the generic Story search.
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{
         summary:"Specs — repo",labels:["speckit-repo:repo"],
         status:{id:"10000",name:"To Do"},updated:"2026-05-26T09:31:00.000+0000"
       }}]}' >"$US3_FIXTURES/epic_search.json"
  jira_shim::set_response GET "*speckit-repo%3A*" "$US3_FIXTURES/epic_search.json" 200

  # Per-phase Subtask searches → absent so the Subtask path creates (the test
  # only asserts on the Story-level write + the drift WARNING).
  jira_shim::set_response GET "*task-phase%3A*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/search_absent.json" 200

  # Transition list (resolve a transition to the target status).
  jira_shim::set_response GET "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200

  # The full-issue GET (diff read for the PRESENT Story path). Reuse the same
  # AHEAD labels so the only owed write is the status transition.
  jq -n '{id:"10101",key:"PROJ-101",fields:{
       summary:"001 — Sample spec",
       labels:["speckit-spec:001","phase:ready_to_merge"],
       status:{id:"99999",name:"Stale"},
       parent:{key:"PROJ-100"}
     }}' >"$US3_FIXTURES/story_get.json"
  jira_shim::set_response GET "*/issue/PROJ-101*" "$US3_FIXTURES/story_get.json" 200

  # Writes succeed at the transport level.
  jira_shim::set_response POST "*/rest/api/3/issue" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" \
    "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
}

# us3::count_writes — number of recorded mutating requests (POST/PUT).
us3::count_writes() {
  jira_shim::requests | grep -cE '^METHOD (POST|PUT)$' || true
}

# --- (a) PHASE-AHEAD ---------------------------------------------------------

@test "phase-ahead tracker fires a named backward-drift WARNING (default proceed)" {
  cd "$WORKDIR"
  # The spec-Story search resolves to the AHEAD (ready_to_merge) tracker.
  jira_shim::set_response GET "*/search/jql*" "$US3_FIXTURES/drift_phase_ahead.json" 200
  us3::register_writes_ok

  # process_spec mutates summary state via module globals; a `run` subshell
  # would discard those add()s. Call it bare (it returns 0 always) and capture
  # the emitted summary in the CURRENT shell.
  summary::start "us3 phase-ahead"
  reconcile::process_spec "specs/001-sample"

  local emitted
  emitted="$(summary::emit 2>&1)"

  # The named backward-drift WARNING names spec, disk + tracker phase, signal.
  [[ "$emitted" == *"spec 001 backward-drift"* ]]
  [[ "$emitted" == *"disk=implementing"* ]]
  [[ "$emitted" == *"linear=ready_to_merge"* ]]
  [[ "$emitted" == *"signals=phase_ordering"* ]]
  # Phase-only: recency did NOT corroborate (tracker updated within skew).
  [[ "$emitted" != *"phase_ordering,recency"* ]]
}

@test "phase-ahead default proceed STILL writes (warn, don't block)" {
  cd "$WORKDIR"
  jira_shim::set_response GET "*/search/jql*" "$US3_FIXTURES/drift_phase_ahead.json" 200
  us3::register_writes_ok

  summary::start "us3 phase-ahead write"
  run reconcile::process_spec "specs/001-sample"
  [ "$status" -eq 0 ]
  # (count_writes reads the shim request log, not summary state, so a `run`
  # subshell around process_spec is fine here — the writes were still recorded.)

  # The drift is advisory by default: the write proceeds (≥1 mutating request).
  local writes
  writes="$(us3::count_writes)"
  [ "$writes" -ge 1 ] || {
    echo "expected ≥1 write on proceed, got $writes" >&2
    jira_shim::requests >&2
    false
  }
}

# --- (b) RECENCY (alongside a phase-ordering drift) --------------------------

@test "recency corroborates a phase drift → signals=phase_ordering,recency" {
  cd "$WORKDIR"
  # Tracker `updated` is +600s past the disk commit (> 120s skew) AND the phase
  # is ahead → recency fires ALONGSIDE the phase drift (never alone).
  jira_shim::set_response GET "*/search/jql*" "$US3_FIXTURES/drift_recency.json" 200
  us3::register_writes_ok

  summary::start "us3 recency"
  reconcile::process_spec "specs/001-sample"

  local emitted
  emitted="$(summary::emit 2>&1)"
  [[ "$emitted" == *"spec 001 backward-drift"* ]]
  [[ "$emitted" == *"signals=phase_ordering,recency"* ]]
  # The recency detail line names the disk commit < tracker updatedAt (> skew).
  [[ "$emitted" == *"spec dir last commit"* ]]
  [[ "$emitted" == *"linear updatedAt"* ]]
}

# --- (c) --on-drift=abort ----------------------------------------------------

@test "--on-drift=abort skips the write, leaves Jira unchanged, records a skip" {
  cd "$WORKDIR"
  jira_shim::set_response GET "*/search/jql*" "$US3_FIXTURES/drift_phase_ahead.json" 200
  us3::register_writes_ok

  # The operator override = abort (honoured non-interactively).
  ARG_ON_DRIFT="abort"

  summary::start "us3 abort"
  reconcile::process_spec "specs/001-sample"

  # NO mutating request reached Jira — it is left unchanged.
  local writes
  writes="$(us3::count_writes)"
  [ "$writes" -eq 0 ] || {
    echo "expected 0 writes on abort, got $writes" >&2
    jira_shim::requests >&2
    false
  }

  # The WARNING row AND a skip note are both recorded (the audit trail holds
  # regardless of disposition).
  local emitted
  emitted="$(summary::emit 2>&1)"
  [[ "$emitted" == *"spec 001 backward-drift"* ]]
  [[ "$emitted" == *"backward-drift abort"* ]]

  run summary::count skipped
  [ "$output" -ge 1 ]
}
