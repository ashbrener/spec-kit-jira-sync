#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/no-real-identifiers.bats
#
# Privacy guard. spec-kit-jira-sync is (or will become) a PUBLIC repo. NO real
# identifier may ever enter a tracked file: not a company / workspace name, a
# project key, a person's name or email, a Jira Cloud site, an account ID, a
# cloudId / UUID, and above all not a live Atlassian API token.
#
# DESIGN (so this guard never itself leaks what it forbids):
#   1. COMMITTED structural guards below contain ZERO real values — only the
#      *shapes* secrets take (e.g. the Atlassian API-token prefix). Safe to ship
#      in a public repo because they name nobody.
#   2. The operator's REAL literals live ONLY in a gitignored deny-list at
#      tests/.private-deny (one extended-regex per line; blank lines and '#'
#      comments ignored). The guard loads it when present and scans for each
#      entry. Because that file is gitignored, the real strings never reach git
#      — not even split across concatenations (the older fragmented approach
#      still put the real bytes in history; this does not). In CI (no deny-list)
#      the structural guards still run; the operator's pre-push local run is
#      where instance-specific leaks get caught before they can be committed.
#
# Bootstrap: copy tests/.private-deny.example -> tests/.private-deny and fill in
# your real coordinates. The resolved jira-config.yml and .env (which legitimately
# hold real values for local dogfooding) are gitignored, so `git ls-files` never
# sees them — only neutral placeholders ship.
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
DENY_LIST="${REPO_ROOT}/tests/.private-deny"

# Structural guards — SHAPES only, never real values. Each is fragmented across
# string concatenation so this committed file cannot self-match.
_structural_patterns() {
  printf '%s\n' \
    "ATA""TT[A-Za-z0-9_=-]{8,}"
  # ^ Atlassian Cloud API tokens (v3) begin with this prefix. Catches a
  #   committed token regardless of its value, without naming anyone.
}

# Operator's real literals, loaded from the gitignored deny-list if present.
# Blank lines and '#' comments are skipped. Absent (e.g. CI) -> no-op.
_private_patterns() {
  [ -f "$DENY_LIST" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$DENY_LIST" || true
}

@test "no real identifiers leak into the tracked tree (privacy guard)" {
  cd "$REPO_ROOT"
  local pattern hits all_hits=""
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # -I skips binaries; -E for the regex shapes; -i so case variants collapse.
    # `--` terminates options so a tracked path starting with '-' is never read
    # as a grep flag.
    hits="$(git ls-files -z | xargs -0 grep -nIiE -- "$pattern" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      all_hits+="--- pattern: ${pattern} ---"$'\n'"${hits}"$'\n'
    fi
  done < <(_structural_patterns; _private_patterns)

  if [ -n "$all_hits" ]; then
    printf 'Forbidden identifier(s) found in tracked files:\n%s\n' "$all_hits" >&2
    printf 'Real secrets/coordinates belong only in the gitignored .env /\n' >&2
    printf 'jira-config.yml — replace tracked occurrences with placeholders.\n' >&2
    return 1
  fi
}

@test "feature-002 fixtures are tracked (under the guard) and placeholder-only" {
  # The new-mode fixtures + the template mapping block must be UNDER the
  # git-ls-files scan above (so the guard actually covers them) and carry only
  # neutral placeholders (FR-019, Privacy IX).
  cd "$REPO_ROOT"
  local f
  for f in \
    config-template.yml \
    tests/fixtures/workstate/direct/placeholder.workstate.json \
    tests/fixtures/jira_responses/issuetype_meta/project_scrum.json \
    tests/fixtures/jira_responses/issuetype_meta/project_kanban.json; do
    git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || {
      echo "untracked (the privacy guard would not scan it): $f" >&2
      return 1
    }
  done
  # The committed mapping template + workstate-direct placeholder name only the
  # neutral project key / example repo (never a real coordinate).
  grep -q 'project_key: "PROJ"' config-template.yml
  grep -q 'mapping:' config-template.yml
  grep -q 'example-org/example-repo' \
    tests/fixtures/workstate/direct/placeholder.workstate.json
}

@test "feature-007 author map sample is tracked + placeholder-only (Privacy IX / FR-010)" {
  # The committed authors-map sample must be UNDER the git-ls-files scan (so the
  # privacy guard actually covers it) and carry only neutral placeholders — no
  # real email/account id, and a non-PII handle (never an email/local-part).
  cd "$REPO_ROOT"
  local sample=".specify/extensions/jira/jira-authors.local.yml.sample"
  git ls-files --error-unmatch -- "$sample" >/dev/null 2>&1 || {
    echo "untracked (the privacy guard would not scan it): $sample" >&2
    return 1
  }
  # The example emails are example.com (reserved, never real).
  grep -q 'dev-one@example.com' "$sample"
  grep -q 'handle: "dev-one"' "$sample"
  # A null-accountId placeholder demonstrates the label-only (non-Jira-user) case.
  grep -q 'accountId: null' "$sample"
  # The RESOLVED map (real PII) must be gitignored — never tracked.
  if git ls-files --error-unmatch -- \
      ".specify/extensions/jira/jira-authors.local.yml" >/dev/null 2>&1; then
    echo "the resolved authors map (real PII) is TRACKED — it must be gitignored" >&2
    return 1
  fi
}

@test "feature-007 attribution config block is committed placeholder-only" {
  cd "$REPO_ROOT"
  # The opt-in attribution: block ships in the committed template with the
  # gitignored authors_file path only — no real coordinate.
  grep -q 'attribution:' config-template.yml
  grep -q 'jira-authors.local.yml' config-template.yml
}

@test "feature-006 privacy guard source + fixtures do not self-match a BLOCK shape" {
  # The consumer-side guard's own source (src/privacy_guard.sh, the sink's
  # privacy providers) and its committed test fixtures must NOT contain a literal
  # that matches a BLOCK-tier Atlassian shape (the ATATT token prefix or a
  # non-example <name>.atlassian.net host). The shape literals are fragmented in
  # source (FR-009) and the test fixtures assemble any non-example host at
  # runtime; only the IANA-reserved example.atlassian.net documentation host is
  # an allowed literal (it is excluded from the BLOCK site shape). This is the
  # CI-side mirror of tests/unit/privacy_dogfood.bats.
  cd "$REPO_ROOT"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/jira_sink.sh"
  local site_re tok_re hits
  site_re="$(jira_sink::privacy_shapes | awk -F'\t' '$2=="site"{print $3}')"
  tok_re="$(jira_sink::privacy_shapes | awk -F'\t' '$2=="api-token"{print $3}')"
  hits="$(git ls-files -z | xargs -0 grep -lIiE -- "$site_re" 2>/dev/null || true)"
  hits+="$(git ls-files -z | xargs -0 grep -lIiE -- "$tok_re" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "BLOCK-tier shape self-match in a tracked file (FR-009 violation):" >&2
    printf '%s\n' "$hits" >&2
    return 1
  fi
}

@test "private deny-list, when present, actually contributes patterns" {
  # Guards against a silently-empty deny-list giving false confidence. Skips
  # cleanly in CI where the gitignored file is absent.
  [ -f "$DENY_LIST" ] || skip "no tests/.private-deny present (expected in CI)"
  run _private_patterns
  [ -n "$output" ] || {
    echo "tests/.private-deny exists but yields no patterns — fill it in." >&2
    return 1
  }
}
