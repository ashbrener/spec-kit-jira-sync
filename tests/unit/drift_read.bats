#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/drift_read.bats — US3 sink↔engine drift-read contract.
#
# The reconcile ENGINE (src/reconcile.sh, COPIED VERBATIM from spec-kit-linear)
# computes backward-drift from a Linear-shaped issue object:
#   * reconcile::_tracker_phase_token reads `.labels.nodes[].name` (phase:*) and
#     `.state.type == "completed"` (→ merged).
#   * reconcile::compute_drift reads `.updatedAt` for the tracker recency key.
# The Jira SINK (src/jira_sink.sh) speaks Jira's NATIVE REST shape
# (`.fields.updated`, `.fields.status.statusCategory`, `.fields.labels[]`). US3
# makes jira_sink::_fetch_drift_issue_json RESHAPE the Jira read into the
# engine's contract so drift actually fires for Jira (without touching the
# engine — the planned shared-engine extraction must stay mechanical).
#
# These are offline contract units: curl is shimmed (no network, no real Jira
# coordinates — Principle IX). They assert (a) the reshaped object MATCHES the
# engine contract, and (b) feeding it to reconcile::compute_drift fires
# phase_drift=1 when the tracker phase is AHEAD of disk.
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"

  # bats functrace makes jira_rest's RETURN cleanup trap be inherited by the
  # shimmed curl and delete the response body before it is read (see
  # us1_fresh.bats). Disable it so shim-backed reads behave as in production.
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  FIXTURES="${REPO_ROOT}/tests/fixtures/jira_responses"

  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export DRY_RUN=0
  export JIRA_MAX_RETRIES=0

  # Source the engine (its tail guard skips main on source) — pulls in the sink
  # + config + git_helpers + compute_drift for the contract assertions.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate

  jira_shim::install
}

teardown() {
  jira_shim::uninstall
}

# Helper: a hermetic git repo with a spec dir committed at an explicit date so
# compute_drift's recency disk key is deterministic.
_init_repo_with_spec() {
  local rel="$1" iso="$2"
  export GIT_AUTHOR_NAME='Test Author'
  export GIT_AUTHOR_EMAIL='test@example.com'
  export GIT_COMMITTER_NAME='Test Author'
  export GIT_COMMITTER_EMAIL='test@example.com'
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init --initial-branch=main --quiet
  mkdir -p "$REPO/$rel"
  printf 'spec body\n' > "$REPO/$rel/spec.md"
  git -C "$REPO" add "$rel/spec.md"
  GIT_COMMITTER_DATE="$iso" GIT_AUTHOR_DATE="$iso" \
    git -C "$REPO" commit --quiet -m "spec $rel"
}

# -----------------------------------------------------------------------------
# (1) Reshape — _fetch_drift_issue_json emits the ENGINE contract shape.
# -----------------------------------------------------------------------------

@test "_fetch_drift_issue_json reshapes a Jira REST search into the engine contract" {
  jira_shim::set_response GET "*/search/jql*" "$FIXTURES/drift_search_phase_ahead.json" 200

  # Capture the reshaped object ONCE (a later `run` would clobber $output).
  local reshaped
  reshaped="$(_fetch_drift_issue_json 310)"
  [ -n "$reshaped" ]

  # The reshaped object MUST carry the engine's Linear-shaped keys, NOT Jira's
  # native fields.* — those would never line up with compute_drift.
  printf '%s' "$reshaped" | jq -e 'has("updatedAt") and has("labels") and has("state")'

  # updatedAt ← fields.updated (compute_drift's tracker recency key),
  # NORMALISED from Jira's `.000+0000` form to the engine's %cI ISO spelling
  # (`+00:00`, no fractional seconds) so git_helpers::iso_to_epoch parses it.
  run jq -r '.updatedAt' <<<"$reshaped"
  [ "$output" = "2026-05-26T09:31:00+00:00" ]

  # labels.nodes[].name ← each fields.labels[] string (so the engine's phase:*
  # filter can read the lifecycle phase US1 stamped on the Story).
  run jq -r '.labels.nodes | map(.name) | sort | join(",")' <<<"$reshaped"
  [ "$output" = "phase:implementing,speckit-spec:310" ]

  # state.type ← "open" for a non-done statusCategory.
  run jq -r '.state.type' <<<"$reshaped"
  [ "$output" = "open" ]

  # The Jira-native envelope MUST be gone (no `.fields`, no `.status`, no bare
  # `.updated`) — the engine only understands the Linear-shaped keys above.
  run jq -e 'has("fields") or has("status") or has("updated")' <<<"$reshaped"
  [ "$status" -ne 0 ]
}

@test "_fetch_drift_issue_json maps a done statusCategory to state.type=completed" {
  # A done-category status with NO phase label is the engine's `merged` signal
  # (_tracker_phase_token: no phase label + state.type==completed → merged).
  jira_shim::set_response GET "*/search/jql*" "$FIXTURES/drift_search_done_category.json" 200

  local reshaped
  reshaped="$(_fetch_drift_issue_json 320)"
  [ -n "$reshaped" ]

  run jq -r '.state.type' <<<"$reshaped"
  [ "$output" = "completed" ]

  # The engine reads this as the `merged` phase token (no phase:* label present).
  run reconcile::_tracker_phase_token "$reshaped"
  [ "$status" -eq 0 ]
  [ "$output" = "merged" ]
}

@test "_fetch_drift_issue_json returns rc 0 + empty for an absent spec Story" {
  jira_shim::set_response GET "*/search/jql*" "$FIXTURES/search_absent.json" 200

  run _fetch_drift_issue_json 999
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_fetch_drift_issue_json fails closed (rc 3) on an unreadable read" {
  # A 401 is the jira_rest UNREADABLE signal — the sink propagates rc 3 so the
  # engine fails closed rather than treating it as absent.
  jira_shim::set_response GET "*/search/jql*" "$FIXTURES/error_401.json" 401

  run _fetch_drift_issue_json 310
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# -----------------------------------------------------------------------------
# (2) End-to-end through the engine — reshaped output fires phase_drift=1.
# -----------------------------------------------------------------------------

@test "reshaped output fires phase_drift=1 when the tracker phase is AHEAD of disk" {
  # Disk at `planning`; tracker (Jira) at `phase:implementing` → tracker ahead.
  _init_repo_with_spec "specs/310-ahead" "2026-05-26T09:31:00+00:00"
  jira_shim::set_response GET "*/search/jql*" "$FIXTURES/drift_search_phase_ahead.json" 200

  local issue_json
  issue_json="$(_fetch_drift_issue_json 310)"
  [ -n "$issue_json" ]

  # Feed the reshaped object straight into the pure engine comparator.
  run bash -c "cd '$REPO' && source '$REPO_ROOT/src/reconcile.sh' && reconcile::compute_drift 310 'specs/310-ahead' '$issue_json' planning"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fired=1"* ]]
  [[ "$output" == *"phase_drift=1"* ]]
  [[ "$output" == *"signals=phase_ordering"* ]]
  # The tracker token the engine derived from labels.nodes[] is `implementing`.
  [[ "$output" == *"linear=implementing"* ]]
}

@test "reshaped output: equal phase (disk implementing) fires nothing" {
  # Disk already at `implementing` (== tracker) → no phase ordering drift, and
  # recency only corroborates a phase drift, so nothing fires.
  _init_repo_with_spec "specs/310-equal" "2026-05-26T09:31:00+00:00"
  jira_shim::set_response GET "*/search/jql*" "$FIXTURES/drift_search_phase_ahead.json" 200

  local issue_json
  issue_json="$(_fetch_drift_issue_json 310)"

  run bash -c "cd '$REPO' && source '$REPO_ROOT/src/reconcile.sh' && reconcile::compute_drift 310 'specs/310-equal' '$issue_json' implementing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fired=0"* ]]
  [[ "$output" == *"phase_drift=0"* ]]
}
