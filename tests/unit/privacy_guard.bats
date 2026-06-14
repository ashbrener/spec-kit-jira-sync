#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/privacy_guard.bats  (feature-006 Foundational, T006-T011)
#
# The VENDOR-NEUTRAL scan mechanism (src/privacy_guard.sh). Driven here with
# STUB callbacks (no Jira vocabulary) so the mechanism is proven independently
# of the Atlassian shapes. All fixtures are fabricated placeholders that cannot
# self-match a real forbidden pattern (Privacy IX).
#
#   * assert_git: non-git ⇒ rc≠0; git work-tree ⇒ rc 0 (C-6 unit half).
#   * scan: block regex/literal ⇒ finding + rc 1; warn-only ⇒ finding + rc 0;
#     clean ⇒ no output + rc 0; ignore-target tracked/unignored ⇒ rc 1.
#   * no-re-leak: the matched bytes never appear in the output (C-5/VR-3).
#   * read-only: the tree is byte-identical after a finding run (C-9/VR-5).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/privacy_guard.sh"

  WORK="$(mktemp -d "${BATS_TEST_TMPDIR}/pg.XXXXXX")"
}

teardown() {
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}

# A throwaway git repo with one identity so commits succeed.
_init_repo() {
  cd "$WORK"
  git init -q .
  git config user.email "test@example.com"
  git config user.name "Test"
}

# ---- Stub providers (no vendor vocabulary) ---------------------------------
# A block regex matching a fabricated marker, a warn regex matching another.
_stub_shapes() {
  printf '%s\t%s\t%s\n' block fake-block 'BLOCKMARK[0-9]{3}'
  printf '%s\t%s\t%s\n' warn fake-warn  'WARNMARK[0-9]{3}'
}
# A block literal — a fabricated "secret".
_stub_known() {
  printf '%s\t%s\t%s\n' block fake-known 'SEKRET-9f3a-LITERAL'
}
_stub_known_empty() { :; }
_stub_ignore_none() { :; }

# =============================================================================
# T006 — privacy_guard::assert_git
# =============================================================================

@test "assert_git: non-git temp dir ⇒ rc≠0 (C-6 unit half)" {
  cd "$WORK"   # mktemp dir is not a git repo
  run privacy_guard::assert_git
  [ "$status" -ne 0 ]
}

@test "assert_git: a git work-tree ⇒ rc 0" {
  _init_repo
  run privacy_guard::assert_git
  [ "$status" -eq 0 ]
}

# =============================================================================
# T008 — privacy_guard::scan core (shapes + known-value)
# =============================================================================

@test "scan: tracked file matching the block REGEX ⇒ block finding + rc 1" {
  _init_repo
  printf 'hello BLOCKMARK123 world\n' >tracked.txt
  git add tracked.txt
  run privacy_guard::scan _stub_shapes _stub_known_empty _stub_ignore_none
  [ "$status" -eq 1 ]
  [[ "$output" == *"block	fake-block	tracked.txt"* ]]
}

@test "scan: tracked file matching ONLY the warn REGEX ⇒ warn finding + rc 0" {
  _init_repo
  printf 'hello WARNMARK456 world\n' >tracked.txt
  git add tracked.txt
  run privacy_guard::scan _stub_shapes _stub_known_empty _stub_ignore_none
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn	fake-warn	tracked.txt"* ]]
  [[ "$output" != *"block	"* ]]
}

@test "scan: tracked file containing the block LITERAL ⇒ finding + rc 1" {
  _init_repo
  printf 'leak: SEKRET-9f3a-LITERAL here\n' >tracked.txt
  git add tracked.txt
  run privacy_guard::scan _stub_shapes _stub_known _stub_ignore_none
  [ "$status" -eq 1 ]
  [[ "$output" == *"block	fake-known	tracked.txt"* ]]
}

@test "scan: placeholder-clean repo ⇒ no output + rc 0" {
  _init_repo
  printf 'nothing to see here\n' >tracked.txt
  git add tracked.txt
  run privacy_guard::scan _stub_shapes _stub_known _stub_ignore_none
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scan: untracked file is NOT scanned (only the tracked tree)" {
  _init_repo
  printf 'placeholder\n' >tracked.txt
  git add tracked.txt
  printf 'BLOCKMARK999\n' >untracked.txt   # never git add-ed
  run privacy_guard::scan _stub_shapes _stub_known_empty _stub_ignore_none
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =============================================================================
# T009 — ignore-target assertion
# =============================================================================

_stub_ignore_one() { printf '%s\n' ".env"; }

@test "scan: ignore-target that is TRACKED ⇒ block violation + rc 1" {
  _init_repo
  printf 'X=1\n' >.env
  git add .env   # tracked — a violation
  run privacy_guard::scan _stub_shapes _stub_known_empty _stub_ignore_one
  [ "$status" -eq 1 ]
  [[ "$output" == *"block	tracked-config	.env"* ]]
}

@test "scan: ignore-target that EXISTS but is NOT gitignored ⇒ violation + rc 1" {
  _init_repo
  printf 'seed\n' >seed.txt && git add seed.txt   # a tracked tree exists
  printf 'X=1\n' >.env   # present, untracked, but NOT ignored
  run privacy_guard::scan _stub_shapes _stub_known_empty _stub_ignore_one
  [ "$status" -eq 1 ]
  [[ "$output" == *"block	tracked-config	.env"* ]]
}

@test "scan: ignore-target gitignored-and-untracked ⇒ no violation" {
  _init_repo
  printf '.env\n' >.gitignore && git add .gitignore
  printf 'X=1\n' >.env   # present but ignored, untracked
  run privacy_guard::scan _stub_shapes _stub_known_empty _stub_ignore_one
  [ "$status" -eq 0 ]
  [[ "$output" != *"tracked-config"* ]]
}

@test "scan: ignore-target that does not exist ⇒ vacuously safe (no violation)" {
  _init_repo
  printf 'seed\n' >seed.txt && git add seed.txt
  # no .env present at all
  run privacy_guard::scan _stub_shapes _stub_known_empty _stub_ignore_one
  [ "$status" -eq 0 ]
  [[ "$output" != *"tracked-config"* ]]
}

# =============================================================================
# T010 — no re-leak (VR-3 / C-5)
# =============================================================================

@test "scan: a known-value match names the class+file but NOT the matched bytes" {
  _init_repo
  printf 'leak: SEKRET-9f3a-LITERAL here\n' >tracked.txt
  git add tracked.txt
  run privacy_guard::scan _stub_shapes _stub_known _stub_ignore_none
  [ "$status" -eq 1 ]
  [[ "$output" == *"fake-known"* ]]
  [[ "$output" == *"tracked.txt"* ]]
  # The matched secret bytes must NOT appear in the output.
  [[ "$output" != *"SEKRET-9f3a-LITERAL"* ]]
}

# =============================================================================
# T011 — read-only (VR-5 / C-9)
# =============================================================================

@test "scan: the consumer tree is byte-identical after a finding run" {
  _init_repo
  printf 'leak: SEKRET-9f3a-LITERAL and BLOCKMARK123\n' >tracked.txt
  git add tracked.txt
  git commit -q -m seed
  local before_status before_sum
  before_status="$(git status --porcelain)"
  before_sum="$(find . -type f -not -path './.git/*' -exec cksum {} \; | sort)"
  run privacy_guard::scan _stub_shapes _stub_known _stub_ignore_one
  [ "$status" -eq 1 ]
  local after_status after_sum
  after_status="$(git status --porcelain)"
  after_sum="$(find . -type f -not -path './.git/*' -exec cksum {} \; | sort)"
  [ "$before_status" = "$after_status" ]
  [ "$before_sum" = "$after_sum" ]
}
