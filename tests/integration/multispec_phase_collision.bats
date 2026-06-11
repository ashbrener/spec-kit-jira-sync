#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/multispec_phase_collision.bats
#
# Regression for the multi-spec phase-Subtask identity collision (the bug:
# fix/multispec-phase-collision-and-empty-tasklist).
#
# The phase identity label is `task-phase:N` — a phase NUMBER, unique only
# WITHIN a spec. The feature-003 unified sync_level_artifact matched it with a
# label+project JQL (`labels = task-phase:1 AND project = PROJ`) for EVERY
# level, so across a multi-spec repo every spec's "Phase 1" matched the SAME
# Subtask: specs 2..N would UPDATE spec 1's Subtask instead of creating their
# own. The fix scopes the phase find to its parent
# (`parent = <story> AND labels = task-phase:N`).
#
# This drives a TWO-spec repo (002-alpha + 003-beta), each carrying an identical
# `## Phase 1` header, over the curl-shim and asserts:
#   * the phase find is PARENT-SCOPED (the JQL carries `parent = "<story>"`);
#   * with both phases absent under their OWN parent, TWO Subtask CREATE POSTs
#     fire with DISTINCT parents (each parented to its own spec's Story) — NOT
#     one create + one update;
#   * a second run, with each phase now found under its correct parent, is
#     idempotent for the phase level (0 creates, 0 PUTs).
#
# Offline + deterministic — no real Jira coordinates (Principle IX).
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

  WORKDIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORKDIR/specs"
  cp -R "$REPO_ROOT/tests/fixtures/specs/multispec-a/002-alpha" "$WORKDIR/specs/002-alpha"
  cp -R "$REPO_ROOT/tests/fixtures/specs/multispec-a/003-beta"  "$WORKDIR/specs/003-beta"

  export WORKSTATE_LAST_COMMIT_ISO="2026-05-31T00:00:00+00:00"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/reconcile.sh"

  config::load "$REPO_ROOT/tests/fixtures/config/jira-config.sample.yml"
  config::validate

  MS_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$MS_FIXTURES"

  # The two specs' Story keys (their phase Subtasks parent to these).
  MS_STORY_A="PROJ-201"   # 002-alpha
  MS_STORY_B="PROJ-301"   # 003-beta

  # Repo-Epic search → reuse the existing Epic (PROJ-100) for both specs.
  jq -n '{startAt:0,maxResults:50,total:1,issues:[
       {id:"10100",key:"PROJ-100",fields:{
         summary:"Specs — repo",labels:["speckit-repo:repo"],
         status:{id:"10000",name:"To Do"},updated:"2026-05-31T00:00:00.000+0000"
       }}]}' >"$MS_FIXTURES/epic_search.json"

  # Per-spec Story search + GET (matching desired → empty diff so the run is
  # zero-churn at the Story level; we are exercising the PHASE level).
  _ms_story_fixtures 002 "$MS_STORY_A" "$WORKDIR/specs/002-alpha"
  _ms_story_fixtures 003 "$MS_STORY_B" "$WORKDIR/specs/003-beta"

  # Phase-1 Subtask GETs for the idempotent (second) run — desired body matches.
  _ms_sub_get "$WORKDIR/specs/002-alpha" "SUB-A" "$MS_STORY_A" >"$MS_FIXTURES/subA_get.json"
  _ms_sub_get "$WORKDIR/specs/003-beta"  "SUB-B" "$MS_STORY_B" >"$MS_FIXTURES/subB_get.json"

  # Phase-1 Subtask searches keyed by PARENT — proves the find is parent-scoped.
  _ms_sub_search "SUB-A" "001 — Setup placeholder" "$MS_STORY_A" >"$MS_FIXTURES/subA_search.json"
  _ms_sub_search "SUB-B" "001 — Setup placeholder" "$MS_STORY_B" >"$MS_FIXTURES/subB_search.json"

  # An ABSENT search (total 0) — the fresh-phase create path.
  cp "$REPO_ROOT/tests/fixtures/jira_responses/search_absent.json" "$MS_FIXTURES/absent.json"

  jira_shim::install
  ARG_QUIET=1
}

teardown() {
  jira_shim::uninstall
}

# _ms_story_fixtures <num> <key> <spec_dir>
#   Write the per-spec Story search + GET fixtures (matching desired → no diff).
_ms_story_fixtures() {
  local num="$1" key="$2" spec_dir="$3"
  local item title state body story_summary story_desc story_labels status_id
  item="$(workstate::item_for_spec "$spec_dir")"
  title="$(printf '%s' "$item" | jq -r '.title // ""')"
  state="$(printf '%s' "$item" | jq -r '.state // ""')"
  body="$(printf '%s' "$item" | jq -r '.body // ""')"
  story_summary="${num} — ${title}"
  story_desc="$(adf::from_markdown "$body")"
  story_labels="$(printf '%s' "$item" | jq -c \
    --arg spec "speckit-spec:${num}" --arg phase "phase:${state}" \
    '([$spec, $phase] + (.labels // [])) | unique')"
  status_id="$(config::get_status_transition "$state" | cut -f1)"

  jq -n --arg key "$key" --arg summary "$story_summary" \
    --argjson labels "$story_labels" --arg status "$status_id" \
    '{startAt:0,maxResults:50,total:1,issues:[
       {id:("10"+$key|ltrimstr("PROJ-")),key:$key,fields:{
         summary:$summary,labels:$labels,
         status:{id:$status,name:"Mapped"},updated:"2026-05-31T00:00:00.000+0000"
       }}]}' >"$MS_FIXTURES/story_${num}_search.json"

  jq -n --arg key "$key" --arg summary "$story_summary" \
    --argjson desc "$story_desc" --argjson labels "$story_labels" \
    --arg status "$status_id" --arg epic "PROJ-100" \
    '{id:("10"+$key|ltrimstr("PROJ-")),key:$key,fields:{
       summary:$summary,description:$desc,labels:$labels,
       status:{id:$status,name:"Mapped"},parent:{key:$epic}
     }}' >"$MS_FIXTURES/story_${num}_get.json"
}

# _ms_sub_search <key> <summary> <parent_key>  → a parent-scoped search hit.
_ms_sub_search() {
  local key="$1" summary="$2" parent="$3"
  jq -n --arg key "$key" --arg summary "$summary" --arg parent "$parent" \
    '{startAt:0,maxResults:50,total:1,issues:[
       {id:("9"+($key|ltrimstr("SUB-"))),key:$key,fields:{
         summary:$summary,labels:["task-phase:1"],parent:{key:$parent}
       }}]}'
}

# _ms_sub_get <spec_dir> <key> <parent_key>  → the full Subtask, desired body.
_ms_sub_get() {
  local spec_dir="$1" key="$2" parent="$3"
  local item child child_title tasks_json sub_desc
  item="$(workstate::item_for_spec "$spec_dir")"
  child="$(printf '%s' "$item" | jq -c '.children[0]')"
  child_title="$(printf '%s' "$child" | jq -r '.title // ""')"
  tasks_json="$(printf '%s' "$child" | jq -c '(.extensions.tasks) // []')"
  sub_desc="$(jq -cn --argjson tl "$(adf::task_list "$tasks_json")" \
    '{version:1,type:"doc",content:[$tl]}')"
  jq -n --arg key "$key" --arg summary "$child_title" \
    --argjson desc "$sub_desc" --arg parent "$parent" \
    '{key:$key,fields:{
       summary:$summary,description:$desc,labels:["task-phase:1"],parent:{key:$parent}
     }}'
}

# ms::register_common — Epic/Story reads + writes shared by both runs.
ms::register_common() {
  jira_shim::set_response GET "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/transitions.json" 200
  jira_shim::set_response GET "*speckit-repo%3A*" "$MS_FIXTURES/epic_search.json" 200
  # Per-spec Story search by spec label (precede the generic story GET).
  jira_shim::set_response GET "*speckit-spec%3A002*" "$MS_FIXTURES/story_002_search.json" 200
  jira_shim::set_response GET "*speckit-spec%3A003*" "$MS_FIXTURES/story_003_search.json" 200
  jira_shim::set_response GET "*/issue/PROJ-201*" "$MS_FIXTURES/story_002_get.json" 200
  jira_shim::set_response GET "*/issue/PROJ-301*" "$MS_FIXTURES/story_003_get.json" 200
  jira_shim::set_response GET "*/issue/SUB-A*" "$MS_FIXTURES/subA_get.json" 200
  jira_shim::set_response GET "*/issue/SUB-B*" "$MS_FIXTURES/subB_get.json" 200
  jira_shim::set_response POST "*/rest/api/3/issue" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 201
  jira_shim::set_response PUT "*/issue/*" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
  jira_shim::set_response POST "*/issue/*/transitions" "$REPO_ROOT/tests/fixtures/jira_responses/issue_create_ok.json" 204
}

@test "two specs sharing 'Phase 1' mirror to DISTINCT Subtasks (parent-scoped find)" {
  cd "$WORKDIR"
  ms::register_common
  # Both phases ABSENT under their own parent → both must CREATE their own.
  # The phase search is parent-scoped, so it carries the parent key in the JQL;
  # match each spec's parent to an ABSENT result.
  jira_shim::set_response GET "*PROJ-201*task-phase%3A1*" "$MS_FIXTURES/absent.json" 200
  jira_shim::set_response GET "*PROJ-301*task-phase%3A1*" "$MS_FIXTURES/absent.json" 200
  # parent precedes labels in the JQL, but glob ordering is registration-order;
  # also register the parent-only glob as a safety net (still ABSENT).
  jira_shim::set_response GET "*parent*PROJ-201*" "$MS_FIXTURES/absent.json" 200
  jira_shim::set_response GET "*parent*PROJ-301*" "$MS_FIXTURES/absent.json" 200

  run reconcile::process_spec "specs/002-alpha"
  [ "$status" -eq 0 ] || { echo "002 rc=$status"; printf '%s\n' "$output"; false; }
  run reconcile::process_spec "specs/003-beta"
  [ "$status" -eq 0 ] || { echo "003 rc=$status"; printf '%s\n' "$output"; false; }

  local reqs
  reqs="$(jira_shim::requests)"

  # (1) The phase find is PARENT-SCOPED — the search URL carries `parent = "…"`.
  #     %22 = ", %3D = =, %20 = space; the JQL encodes to `parent%20%3D%20%22`.
  printf '%s\n' "$reqs" | grep -q 'parent%20%3D%20%22PROJ-201%22' \
    || { echo "no parent-scoped phase search for PROJ-201"; printf '%s\n' "$reqs"; false; }
  printf '%s\n' "$reqs" | grep -q 'parent%20%3D%20%22PROJ-301%22' \
    || { echo "no parent-scoped phase search for PROJ-301"; printf '%s\n' "$reqs"; false; }

  # (2) TWO Subtask CREATE POSTs (issuetype 10003) — one per spec — with DISTINCT
  #     parents. Collect the parent key from each Subtask-create body.
  local sub_parents
  sub_parents="$(printf '%s\n' "$reqs" \
    | grep '^BODY ' \
    | grep '"10003"' \
    | sed -E 's/^BODY //' \
    | jq -r '.fields.parent.key' 2>/dev/null | sort -u)"
  [ "$(printf '%s\n' "$sub_parents" | grep -c .)" -eq 2 ] \
    || { echo "expected 2 distinct Subtask parents, got:"; printf '%s\n' "$sub_parents"; printf '%s\n' "$reqs"; false; }
  printf '%s\n' "$sub_parents" | grep -qx 'PROJ-201'
  printf '%s\n' "$sub_parents" | grep -qx 'PROJ-301'

  # (3) Exactly two Subtask creates — NOT one create + one update (the bug).
  local sub_creates
  sub_creates="$(printf '%s\n' "$reqs" | grep '^BODY ' | grep -c '"10003"')"
  [ "$sub_creates" -eq 2 ] \
    || { echo "expected exactly 2 Subtask creates, got $sub_creates"; printf '%s\n' "$reqs"; false; }
}

@test "second run is idempotent for the phase level (0 creates, 0 PUTs)" {
  cd "$WORKDIR"
  ms::register_common
  # Each phase now EXISTS under its OWN parent (parent-scoped find hits it).
  jira_shim::set_response GET "*PROJ-201*task-phase%3A1*" "$MS_FIXTURES/subA_search.json" 200
  jira_shim::set_response GET "*PROJ-301*task-phase%3A1*" "$MS_FIXTURES/subB_search.json" 200
  jira_shim::set_response GET "*parent*PROJ-201*" "$MS_FIXTURES/subA_search.json" 200
  jira_shim::set_response GET "*parent*PROJ-301*" "$MS_FIXTURES/subB_search.json" 200

  run reconcile::process_spec "specs/002-alpha"
  [ "$status" -eq 0 ] || { echo "002 re-run rc=$status"; printf '%s\n' "$output"; false; }
  run reconcile::process_spec "specs/003-beta"
  [ "$status" -eq 0 ] || { echo "003 re-run rc=$status"; printf '%s\n' "$output"; false; }

  local reqs
  reqs="$(jira_shim::requests)"

  # The parent-scoped phase find located each spec's own Subtask (fix engaged).
  printf '%s\n' "$reqs" | grep -q 'parent%20%3D%20%22PROJ-201%22'
  printf '%s\n' "$reqs" | grep -q 'parent%20%3D%20%22PROJ-301%22'

  # No Subtask CREATE (issuetype 10003) on the idempotent run.
  local sub_creates
  sub_creates="$(printf '%s\n' "$reqs" | grep '^BODY ' | grep -c '"10003"' || true)"
  [ "$sub_creates" -eq 0 ] \
    || { echo "expected 0 Subtask creates on re-run, got $sub_creates"; printf '%s\n' "$reqs"; false; }

  # No PUT to either Subtask (zero-churn for the phase level). URL is on its own
  # log line, so scan the URL lines for an /issue/SUB-* PUT target.
  local put_subtasks
  put_subtasks="$(printf '%s\n' "$reqs" \
    | awk '/^METHOD PUT/{m=1;next} /^URL /{ if(m && $0 ~ /\/issue\/SUB-/) print; m=0 }')"
  [ -z "$put_subtasks" ] \
    || { echo "unexpected PUT to a Subtask on the idempotent run:"; printf '%s\n' "$put_subtasks"; false; }
}
