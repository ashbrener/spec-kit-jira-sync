#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/author_resolution.bats  (feature-007 T005 — FR-001/FR-009, R1/R2)
#
# The VENDOR-NEUTRAL author-resolution floor. Author resolution lives in the
# engine/parser half (parser.sh / git_helpers.sh / workstate.sh), carries NO
# Jira account/issue-type vocabulary, and emits a neutral `author {value,source}`
# onto the workstate item. Priority order (R1):
#   1. an explicit `Owner:` / `Author:` line in spec.md (case-insensitive),
#   2. else the FIRST git author to ADD the spec dir (git first-add),
#   3. else empty (unknown → no label, no assignee, NOT an error).
#
# PURE transform / local-git tests: no network, no live Jira, no PII.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/src/workstate.sh"   # sources parser.sh
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/src/git_helpers.sh"
}

# --- parser::spec_author (Owner:/Author: line) -------------------------------

@test "parser::spec_author: echoes an Owner: line value" {
  local md="${BATS_TEST_TMPDIR}/spec.md"
  printf '# Feature\n\nOwner: alice@example.com\n\n## Summary\n' >"$md"
  run parser::spec_author "$md"
  [ "$status" -eq 0 ]
  [ "$output" = "alice@example.com" ]
}

@test "parser::spec_author: echoes an Author: line value" {
  local md="${BATS_TEST_TMPDIR}/spec.md"
  printf '# Feature\n\nAuthor: Bob The Builder\n' >"$md"
  run parser::spec_author "$md"
  [ "$status" -eq 0 ]
  [ "$output" = "Bob The Builder" ]
}

@test "parser::spec_author: is case-insensitive on the key" {
  local md="${BATS_TEST_TMPDIR}/spec.md"
  printf '# Feature\n\nowner: carol@example.com\n' >"$md"
  run parser::spec_author "$md"
  [ "$status" -eq 0 ]
  [ "$output" = "carol@example.com" ]
}

@test "parser::spec_author: trims surrounding whitespace and bold markers" {
  local md="${BATS_TEST_TMPDIR}/spec.md"
  printf '# Feature\n\n**Owner**:   dave@example.com   \n' >"$md"
  run parser::spec_author "$md"
  [ "$status" -eq 0 ]
  [ "$output" = "dave@example.com" ]
}

@test "parser::spec_author: empty when no Owner:/Author: line" {
  local md="${BATS_TEST_TMPDIR}/spec.md"
  printf '# Feature\n\n## Summary\n\nNo author here.\n' >"$md"
  run parser::spec_author "$md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "parser::spec_author: empty on a missing file (no error)" {
  run parser::spec_author "${BATS_TEST_TMPDIR}/nope.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "parser::spec_author: the FIRST Owner:/Author: line wins" {
  local md="${BATS_TEST_TMPDIR}/spec.md"
  printf 'Owner: first@example.com\nAuthor: second@example.com\n' >"$md"
  run parser::spec_author "$md"
  [ "$status" -eq 0 ]
  [ "$output" = "first@example.com" ]
}

# --- git_helpers::spec_first_author (git first-add) --------------------------

# Build a throwaway git repo whose spec dir is added by a known first author and
# later edited by a different author; the first-add author must win.
_make_git_repo() {
  local root="$1"
  mkdir -p "$root"
  git -C "$root" init -q
  git -C "$root" config user.email "starter@example.com"
  git -C "$root" config user.name "Starter"
  mkdir -p "$root/specs/007-x"
  printf '# x\n' >"$root/specs/007-x/spec.md"
  git -C "$root" add -A
  git -C "$root" commit -q -m "add spec dir"
  # A later edit by a DIFFERENT author must NOT change the first-add result.
  git -C "$root" config user.email "editor@example.com"
  git -C "$root" config user.name "Editor"
  printf '# x\n\nmore\n' >"$root/specs/007-x/spec.md"
  git -C "$root" add -A
  git -C "$root" commit -q -m "edit spec"
}

@test "git_helpers::spec_first_author: returns the first-add author email" {
  local root="${BATS_TEST_TMPDIR}/repo"
  _make_git_repo "$root"
  run bash -c 'cd "$1"; source "$2"; git_helpers::spec_first_author "specs/007-x"' \
    _ "$root" "${REPO_ROOT}/src/git_helpers.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "starter@example.com" ]
}

@test "git_helpers::spec_first_author: empty when the dir has no git history" {
  local root="${BATS_TEST_TMPDIR}/repo2"
  mkdir -p "$root/specs/007-y"
  git -C "$root" init -q
  printf '# y\n' >"$root/specs/007-y/spec.md"   # NOT committed
  run bash -c 'cd "$1"; source "$2"; git_helpers::spec_first_author "specs/007-y"' \
    _ "$root" "${REPO_ROOT}/src/git_helpers.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "git_helpers::spec_first_author: empty (no error) when not a git repo" {
  local root="${BATS_TEST_TMPDIR}/plain"
  mkdir -p "$root/specs/007-z"
  printf '# z\n' >"$root/specs/007-z/spec.md"
  run bash -c 'cd "$1"; source "$2"; git_helpers::spec_first_author "specs/007-z"' \
    _ "$root" "${REPO_ROOT}/src/git_helpers.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- workstate::_author_json (Owner-first, else git, else empty) -------------

@test "_author_json: Owner: line resolves with source owner_line" {
  local dir="${BATS_TEST_TMPDIR}/specs/007-a"
  mkdir -p "$dir"
  printf '# A\n\nOwner: owner@example.com\n' >"$dir/spec.md"
  run workstate::_author_json "$dir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.value == "owner@example.com"'
  echo "$output" | jq -e '.source == "owner_line"'
}

@test "_author_json: falls back to git first-add with source git_first_add" {
  local root="${BATS_TEST_TMPDIR}/repo3"
  _make_git_repo "$root"
  run bash -c 'cd "$1"; source "$2"; workstate::_author_json "specs/007-x"' \
    _ "$root" "${REPO_ROOT}/src/workstate.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.value == "starter@example.com"'
  echo "$output" | jq -e '.source == "git_first_add"'
}

@test "_author_json: empty object when neither resolves (unknown, graceful)" {
  local dir="${BATS_TEST_TMPDIR}/specs/007-b"
  mkdir -p "$dir"
  printf '# B\n\n## Summary\n' >"$dir/spec.md"
  run workstate::_author_json "$dir"
  [ "$status" -eq 0 ]
  # No author resolves → emit an empty object (the item simply omits .author).
  echo "$output" | jq -e '. == {}'
}

@test "_author_json: Owner: overrides the git first-add author" {
  local root="${BATS_TEST_TMPDIR}/repo4"
  _make_git_repo "$root"
  printf '# x\n\nOwner: explicit@example.com\n' >"$root/specs/007-x/spec.md"
  run bash -c 'cd "$1"; source "$2"; workstate::_author_json "specs/007-x"' \
    _ "$root" "${REPO_ROOT}/src/workstate.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.value == "explicit@example.com"'
  echo "$output" | jq -e '.source == "owner_line"'
}
