#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/jira_sink_privacy.bats  (feature-006 US1/US2, T014/T015/T023)
#
# The Jira-AWARE privacy providers the neutral scan consumes:
#   * jira_sink::privacy_shapes        — five tiered shape regexes
#   * jira_sink::privacy_known_values  — the operator's exact resolved literals
#   * jira_sink::privacy_ignore_targets— the must-be-gitignored consumer paths
#
# Every fixture here is a fabricated placeholder shaped so neither this test nor
# the source self-matches a real coordinate (Privacy IX). The `<name>.atlassian
# .net` host and the fabricated UUIDs are reserved/non-real.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # The providers depend only on jira_sink.sh (env + a small jq/awk parse);
  # config need not be loaded for the shape/known-value/ignore providers.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/jira_sink.sh"
}

# A small grep helper: does CANDIDATE match the regex on row CLASS of the shapes
# output? Uses grep -E exactly as the scan mechanism does.
_shape_regex_for() {
  local class="$1"
  jira_sink::privacy_shapes | awk -F'\t' -v c="$class" '$2==c {print $3}'
}
_matches() {  # _matches <regex> <candidate>
  printf '%s' "$2" | grep -qiE -- "$1"
}

# A fabricated NON-example BLOCK site host, assembled at runtime so the literal
# `<name>.atlassian.net` never sits in this committed file (it would self-match
# the dogfood scan, C-11). The reserved `example.atlassian.net` host is the only
# `.atlassian.net` literal allowed in the tracked tree.
_block_host() {  # _block_host <leading-label>
  printf '%s.atlas''sian.net' "$1"
}

# =============================================================================
# T014 — jira_sink::privacy_shapes (five tiered shapes)
# =============================================================================

@test "privacy_shapes: prints exactly five severity<TAB>class<TAB>regex rows" {
  run jira_sink::privacy_shapes
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '	')" -eq 5 ]
}

@test "privacy_shapes: api-token + site are BLOCK; email/cloudId/accountId are WARN" {
  local out
  out="$(jira_sink::privacy_shapes)"
  [ "$(printf '%s' "$out" | awk -F'\t' '$2=="api-token"{print $1}')" = "block" ]
  [ "$(printf '%s' "$out" | awk -F'\t' '$2=="site"{print $1}')" = "block" ]
  [ "$(printf '%s' "$out" | awk -F'\t' '$2=="email"{print $1}')" = "warn" ]
  [ "$(printf '%s' "$out" | awk -F'\t' '$2=="cloudId-uuid"{print $1}')" = "warn" ]
  [ "$(printf '%s' "$out" | awk -F'\t' '$2=="accountId"{print $1}')" = "warn" ]
}

@test "privacy_shapes: api-token regex matches the token prefix, not a control" {
  local re
  re="$(_shape_regex_for api-token)"
  # A fabricated token-shaped string (prefix + filler). Assembled at RUNTIME so
  # this test file itself never ships a token-prefixed literal.
  local tok="ATA""TT""abcd1234EFGH5678ijkl"
  _matches "$re" "$tok"
  ! _matches "$re" "an ordinary sentence with no token"
}

@test "privacy_shapes: site regex matches <name>.atlassian.net, not a control" {
  local re
  re="$(_shape_regex_for site)"
  _matches "$re" "$(_block_host myco)"
  _matches "$re" "https://$(_block_host tenant-x)/rest"
  # The IANA-reserved documentation host is intentionally NOT a BLOCK.
  ! _matches "$re" "example.atlas""sian.net"
  ! _matches "$re" "example.com"
  ! _matches "$re" "atlassian-docs.example.org"
}

@test "privacy_shapes: email regex matches a generic address, not a bare word" {
  local re
  re="$(_shape_regex_for email)"
  _matches "$re" "someone@example.com"
  ! _matches "$re" "notanemail"
}

@test "privacy_shapes: cloudId-uuid regex matches a UUID, not a short hex" {
  local re
  re="$(_shape_regex_for cloudId-uuid)"
  _matches "$re" "11111111-2222-3333-4444-555555555555"
  ! _matches "$re" "1234abcd"
}

@test "privacy_shapes: accountId regex matches 24-hex and NNNNNN:UUID, not 8-hex" {
  local re
  re="$(_shape_regex_for accountId)"
  _matches "$re" "0123456789abcdef01234567"
  _matches "$re" "123456:11111111-2222-3333-4444-555555555555"
  ! _matches "$re" "deadbeef"
}

# =============================================================================
# T015 — jira_sink::privacy_known_values (always BLOCK; absent ⇒ no line)
# =============================================================================

@test "privacy_known_values: with EMAIL/BASE_URL/TOKEN exported ⇒ three block rows" {
  # The base-URL host is assembled at runtime so no `<name>.atlassian.net`
  # literal sits in this committed file (dogfood, C-11).
  local host; host="$(_block_host tenant-x)"
  JIRA_EMAIL="fabricated.user@example.com" \
  JIRA_BASE_URL="https://${host}/" \
  JIRA_API_TOKEN="FAKE-TOKEN-PLACEHOLDER-0001" \
    run jira_sink::privacy_known_values
  [ "$status" -eq 0 ]
  [[ "$output" == *"block	email	fabricated.user@example.com"* ]]
  # scheme stripped + trailing slash removed.
  [[ "$output" == *"block	site	${host}"* ]]
  [[ "$output" == *"block	api-token	FAKE-TOKEN-PLACEHOLDER-0001"* ]]
}

@test "privacy_known_values: NONE present ⇒ zero lines (degrades to no-op)" {
  JIRA_EMAIL="" JIRA_BASE_URL="" JIRA_API_TOKEN="" \
    run jira_sink::privacy_known_values
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "privacy_known_values: an authors map with an accountId ⇒ a block accountId row" {
  local map="${BATS_TEST_TMPDIR}/jira-authors.local.yml"
  cat >"$map" <<'YAML'
schema_version: 1
authors:
  dev-one@example.com:
    accountId: "0123456789abcdef01234567"
    handle: "dev-one"
  dev-two@example.com:
    accountId: null
    handle: "dev-two"
default_assignee: null
YAML
  JIRA_EMAIL="" JIRA_BASE_URL="" JIRA_API_TOKEN="" \
  PRIVACY_AUTHORS_FILE="$map" \
    run jira_sink::privacy_known_values
  [ "$status" -eq 0 ]
  [[ "$output" == *"block	accountId	0123456789abcdef01234567"* ]]
  # The null-accountId author contributes no row.
  [ "$(printf '%s\n' "$output" | grep -c 'accountId')" -eq 1 ]
}

# =============================================================================
# T023 — jira_sink::privacy_ignore_targets (the must-be-ignored paths)
# =============================================================================

@test "privacy_ignore_targets: prints config path, .env, and the authors map" {
  RECONCILE_CONFIG_PATH=".specify/extensions/jira/jira-config.yml" \
    run jira_sink::privacy_ignore_targets
  [ "$status" -eq 0 ]
  [[ "$output" == *".specify/extensions/jira/jira-config.yml"* ]]
  [[ "$output" == *".env"* ]]
  [[ "$output" == *".specify/extensions/jira/jira-authors.local.yml"* ]]
}

@test "privacy_ignore_targets: honours an overridden --config path" {
  RECONCILE_CONFIG_PATH="custom/dir/my-jira.yml" \
    run jira_sink::privacy_ignore_targets
  [ "$status" -eq 0 ]
  [[ "$output" == *"custom/dir/my-jira.yml"* ]]
}
