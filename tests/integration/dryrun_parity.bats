#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/dryrun_parity.bats — the FR-016 / SC-007 dry-run gate (T044).
#
# Proves the PREVIEW guarantee end-to-end over the MOCKED Jira REST (curl-shim,
# decision D10): a `--dry-run` reconcile reports every write it WOULD make but
# performs NONE. Concretely, with DRY_RUN=1 the run MUST:
#
#   * fire ZERO mutating requests — no POST/PUT to /issue, /transitions,
#     /comment, or /issueLink reaches the transport (FR-016: "perform none");
#   * still READ — GET / JQL searches ARE allowed, because dry-run reads the
#     tracker to COMPUTE the plan it previews (SC-007: the preview's reported
#     actions match a subsequent live run, so it must read the same state);
#   * still REPORT the intended actions — the sink narrates each would-write to
#     stderr and the run summary tallies the planned creates — and exit 0.
#
# The fixture is 002-updates, chosen because it exercises ALL write paths in one
# pass: a per-repo Epic create, a Story create + status transition, a Subtask
# create per task phase, a cross-spec dependency (`depends_on: 001` ⇒ a
# /issueLink), and a clarify session (⇒ a /comment). Under dry-run, EVERY one of
# those must short-circuit before curl, so the recorded requests carry no
# mutation at all.
#
# Harness mirrors us1_fresh.bats / us2_idempotent.bats EXACTLY: the
# `set +o functrace` caveat, the curl-shim, the placeholder jira-config.sample,
# a deterministic offline run, and Principle-IX placeholder identifiers only.
# The one deliberate difference is DRY_RUN: the engine sources reconcile.sh with
# `declare -g DRY_RUN=0`, and the harness drives reconcile::process_spec directly
# (bypassing parse_args, which is what normally syncs DRY_RUN from --dry-run), so
# DRY_RUN=1 is (re)asserted AFTER the source — exactly the state the flag yields.
# =============================================================================

setup() {
  load "../helpers/jira-shim.bash"

  # See us1_fresh.bats: bats enables `set -o functrace`, which makes jira_rest's
  # RETURN cleanup trap be inherited by the shimmed curl and delete the response
  # body before _request reads it. Disable it so shim-backed reads behave as in
  # production (otherwise the plan-computing reads come back empty).
  set +o functrace

  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  # --- Edge env (placeholders only; Principle IX) ---------------------------
  export JIRA_BASE_URL="https://example.atlassian.net"
  export JIRA_EMAIL="operator@example.com"
  export JIRA_API_TOKEN="placeholder-token"
  export JIRA_MAX_RETRIES=0

  # --- Stage the 002-updates fixture under a specs/ root --------------------
  # 002-updates carries phases + a clarification + a `depends_on` dependency, so
  # one reconcile pass touches the Epic, Story, Subtask, comment, AND issue-link
  # write paths — the broadest possible dry-run surface.
  WORKDIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORKDIR/specs"
  cp -R "$REPO_ROOT/tests/fixtures/specs/002-updates" "$WORKDIR/specs/002-updates"

  # Pin recency via the env override so the fixture needs no commits.
  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  # --- Source the engine (guard skips main on source) -----------------------
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  # Load the placeholder config fixture.
  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate

  # --- Arm dry-run ----------------------------------------------------------
  # reconcile.sh sources with `declare -g DRY_RUN=0`; parse_args (which the
  # harness bypasses by calling process_spec directly) is what normally copies
  # ARG_DRY_RUN into DRY_RUN. Set both here so the sink + transport see the exact
  # state a `--dry-run` invocation produces.
  ARG_DRY_RUN=1
  DRY_RUN=1

  # --- Install the shim and register canned READ responses ------------------
  # Dry-run still READS to compute the plan; every read reports ABSENT (empty)
  # so the engine's plan is "would CREATE everything", the broadest preview. The
  # writes below are registered too so an UNEXPECTED mutation would still
  # "succeed" at the transport — the assertions then catch it as a recorded
  # request, rather than the run erroring on a missing rule and masking the leak.
  jira_shim::install

  # JQL searches (drift read, Epic lookup, Story lookup, per-phase Subtask
  # lookup, dependency-target resolve) → absent.
  jira_shim::set_response GET "*/search/jql*" search_absent.json 200
  # Transition list (resolve a status transition) — only consulted on a live
  # write, but registered so a stray resolve still reads cleanly.
  jira_shim::set_response GET "*/issue/*/transitions" transitions.json 200
  # Comment read for the clarify dedup probe → empty comment list (clean absent),
  # so the clarify path proceeds to its (dry-run, no-op) create.
  jira_shim::set_response GET "*/issue/*/comment" comment_list_empty.json 200
  # Catch-all issue GET (block-link issuelinks read, diff read) → absent shape.
  jira_shim::set_response GET "*/issue/*" search_absent.json 200

  # WRITES — registered so a leaked mutation "succeeds" and is RECORDED (caught
  # by the assertions) rather than erroring on a missing rule.
  jira_shim::set_response POST "*/rest/api/3/issue" issue_create_ok.json 201
  jira_shim::set_response POST "*/issue/*/transitions" issue_create_ok.json 204
  jira_shim::set_response POST "*/issue/*/comment" comment_create_ok.json 201
  jira_shim::set_response POST "*/issueLink" issue_create_ok.json 201
  jira_shim::set_response PUT "*/issue/*" issue_create_ok.json 204

  # Quiet per-mutation chatter; the summary still emits.
  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

# dryrun::mutating_count <requests>
#   Echo the number of recorded requests that are MUTATIONS — a POST/PUT whose
#   URL targets a write endpoint (/issue create, /transitions, /comment,
#   /issueLink, or an /issue/<key> field PUT). Reads (GET / JQL) never count.
dryrun::mutating_count() {
  local reqs="$1"
  # A request record is `METHOD <m>\nURL <u>\nBODY <b>\n---`. Pair each METHOD
  # line with the URL line that follows it, keep only POST/PUT to a write path.
  printf '%s\n' "$reqs" \
    | awk '
        /^METHOD / { m = $2; next }
        /^URL /    {
          u = $2
          # A bare /issue/<key> field PUT: ends in /issue/<segment> with no
          # further slash. Strip everything up to the last /issue/ then check the
          # tail has no slash (so /issue/<key> matches but /issue/<key>/comment
          # does not — those write paths are matched explicitly below).
          tail = u
          sub(/.*\/issue\//, "", tail)
          is_issue_key = (tail != u && tail !~ /\//)
          if ((m == "POST" || m == "PUT") &&
              (u ~ /\/rest\/api\/3\/issue$/ ||
               u ~ /\/transitions$/         ||
               u ~ /\/comment$/             ||
               u ~ /\/issueLink$/           ||
               is_issue_key)) {
            n++
          }
        }
        END { print n + 0 }
      '
}

# --- (a) ZERO MUTATIONS ------------------------------------------------------

@test "a --dry-run reconcile fires ZERO mutating requests" {
  cd "$WORKDIR"

  summary::start "dry-run parity"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]

  local reqs
  reqs="$(jira_shim::requests)"

  # No POST /issue creates (no Epic / Story / Subtask written).
  local creates
  creates="$(printf '%s\n' "$reqs" \
    | grep -c '^URL https://example.atlassian.net/rest/api/3/issue$' || true)"
  [ "$creates" -eq 0 ] || {
    echo "expected 0 POST /issue creates under dry-run, got $creates" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # No transition POSTs.
  local transitions
  transitions="$(printf '%s\n' "$reqs" \
    | grep -B2 '/transitions$' | grep -c '^METHOD POST$' || true)"
  [ "$transitions" -eq 0 ] || {
    echo "expected 0 transition POSTs under dry-run, got $transitions" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # No comment POSTs.
  local comments
  comments="$(printf '%s\n' "$reqs" \
    | grep -B2 '/comment$' | grep -c '^METHOD POST$' || true)"
  [ "$comments" -eq 0 ] || {
    echo "expected 0 comment POSTs under dry-run, got $comments" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # No issue-link POSTs.
  local links
  links="$(printf '%s\n' "$reqs" \
    | grep -B2 '/issueLink$' | grep -c '^METHOD POST$' || true)"
  [ "$links" -eq 0 ] || {
    echo "expected 0 /issueLink POSTs under dry-run, got $links" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # No field PUTs.
  local puts
  puts="$(printf '%s\n' "$reqs" | grep -c '^METHOD PUT$' || true)"
  [ "$puts" -eq 0 ] || {
    echo "expected 0 PUT updates under dry-run, got $puts" >&2
    printf '%s\n' "$reqs" >&2
    false
  }

  # Belt-and-braces: the method+URL-aware mutation count across ALL write paths
  # is exactly zero.
  local mutations
  mutations="$(dryrun::mutating_count "$reqs")"
  [ "$mutations" -eq 0 ] || {
    echo "expected 0 mutating requests under dry-run, got $mutations" >&2
    printf '%s\n' "$reqs" >&2
    false
  }
}

# --- (b) READS STILL FIRE (the plan is computed) -----------------------------

@test "a --dry-run reconcile STILL reads Jira to compute the plan" {
  cd "$WORKDIR"

  summary::start "dry-run parity"
  reconcile::process_spec "specs/002-updates"

  local reqs
  reqs="$(jira_shim::requests)"

  # At least one read fired — dry-run must read the tracker to build the preview.
  [[ "$reqs" == *'METHOD GET'* ]]

  # A JQL search fired (the drift / idempotency lookups that compute the plan).
  [[ "$reqs" == *'/search/jql'* ]]

  # Every recorded request is a read (GET). With nothing mirrored yet, no write
  # path has a reason to mutate, so the recorded traffic is reads only.
  local non_gets
  non_gets="$(printf '%s\n' "$reqs" \
    | grep -E '^METHOD ' | grep -cv '^METHOD GET$' || true)"
  [ "$non_gets" -eq 0 ] || {
    echo "expected reads only under dry-run, found $non_gets non-GET request(s)" >&2
    printf '%s\n' "$reqs" >&2
    false
  }
}

# --- (c) THE PLAN IS STILL REPORTED ------------------------------------------

@test "a --dry-run reconcile still REPORTS the intended actions and exits 0" {
  cd "$WORKDIR"

  summary::start "dry-run parity"
  run reconcile::process_spec "specs/002-updates"
  [ "$status" -eq 0 ]

  # The run narrates what it WOULD do: the sink emits a DRY-RUN intent line per
  # planned mutation (stderr). With an absent tracker the plan creates the Story
  # and at least one Subtask, so those intents must appear.
  [[ "$output" == *'DRY-RUN'* ]]
  [[ "$output" == *'mutate_issue_create'* ]]
}

@test "a --dry-run reconcile summary TALLIES the planned creates" {
  cd "$WORKDIR"

  summary::start "dry-run parity"
  reconcile::process_spec "specs/002-updates"

  # The preview is reported as planned work: the Story + its Subtask are tallied
  # as `created` (the disposition the engine records for a would-create), so the
  # summary the operator reads matches what a live run would perform (SC-007).
  run summary::count created
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ] || {
    echo "expected >=2 planned creates (Story + Subtask) reported, got $output" >&2
    false
  }

  # No errors on the dry-run preview path.
  run summary::count error
  [ "$output" -eq 0 ] || {
    echo "expected 0 errors under dry-run, got $output" >&2
    false
  }
}
