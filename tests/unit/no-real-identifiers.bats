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

@test "feature-008 install/seed surface is committed placeholder-only (Privacy IX / C-10)" {
  # The install/seed command bodies + scripts are committed to a PUBLIC repo and
  # must carry only neutral placeholders — no real site/key/id/email. The only
  # allowed *.atlassian.net literal is the IANA-reserved example documentation
  # host (excluded from the BLOCK site shape).
  cd "$REPO_ROOT"
  local f
  for f in \
    commands/jira-install.md commands/jira-seed.md \
    .claude/commands/speckit-jira-install.md .claude/commands/speckit-jira-seed.md \
    src/install.sh src/seed.sh; do
    git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || {
      echo "untracked (the privacy guard would not scan it): $f" >&2
      return 1
    }
  done
  # No non-example .atlassian.net host literal in any committed 008 file.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/jira_sink.sh"
  local site_re hits
  site_re="$(jira_sink::privacy_shapes | awk -F'\t' '$2=="site"{print $3}')"
  hits="$(grep -lIiE -- "$site_re" \
            commands/jira-install.md commands/jira-seed.md \
            .claude/commands/speckit-jira-install.md \
            .claude/commands/speckit-jira-seed.md \
            src/install.sh src/seed.sh 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "a non-example .atlassian.net host leaked into a committed 008 file:" >&2
    printf '%s\n' "$hits" >&2
    return 1
  fi
}

@test "feature-008 install writes ONLY to the gitignored binding path (C-10)" {
  # After a (shimmed) install, the written jira-config.yml must be gitignored —
  # so a public repo never leaks the operator's resolved coordinates. We assert
  # the DEFAULT binding path is git-ignored and never tracked.
  cd "$REPO_ROOT"
  local binding=".specify/extensions/jira/jira-config.yml"
  # The path is declared in .gitignore.
  git check-ignore -q -- "$binding" || {
    echo "the resolved binding path is NOT gitignored: $binding" >&2
    return 1
  }
  # And it is not tracked.
  if git ls-files --error-unmatch -- "$binding" >/dev/null 2>&1; then
    echo "the resolved binding (real coordinates) is TRACKED — it must be gitignored" >&2
    return 1
  fi
}

@test "feature-009 title-ladder fixtures are inline + placeholder-only (Privacy IX / C-11)" {
  # The title-ladder tests use INLINE heredoc spec.md fixtures (no tracked
  # fixture files), so the privacy assertion is on the test source itself: it
  # must be UNDER the git-ls-files scan and carry only neutral placeholder text
  # (e.g. "Clean Name", "Does X. More.", example dirs like 009-foo-bar) — no
  # real name/email/coordinate. The generic structural + deny-list scan above
  # already covers it; here we pin tracked-ness + the absence of any '@' email
  # literal (placeholders never embed an email) so a regression is caught.
  cd "$REPO_ROOT"
  local src="tests/unit/title_ladder.bats"
  git ls-files --error-unmatch -- "$src" >/dev/null 2>&1 || {
    echo "untracked (the privacy guard would not scan it): $src" >&2
    return 1
  }
  # No real Atlassian/email coordinate: the ladder reads only spec.md prose and
  # the fixtures are neutral text — there is no email literal in the source.
  if grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$src"; then
    echo "an email literal leaked into the title-ladder test fixtures" >&2
    grep -nE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$src" >&2
    return 1
  fi
}

@test "feature-010 cascade/parser fixtures are tracked + placeholder-only (Privacy IX / C-12)" {
  # The cascade tests + new issue-status fixtures + the phase-parser tests must be
  # UNDER the git-ls-files scan and carry only neutral placeholders: the project
  # key PROJ, the reserved example.atlassian.net host (or none), fabricated issue
  # keys/ids, and neutral phase names (e.g. "Phase A — Foundations"). No real
  # site/key/id/email/name.
  cd "$REPO_ROOT"
  local f
  for f in \
    tests/unit/cascade_phases.bats \
    tests/unit/phase_parser.bats \
    tests/fixtures/jira_responses/issue_status_todo.json \
    tests/fixtures/jira_responses/issue_status_done.json; do
    git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || {
      echo "untracked (the privacy guard would not scan it): $f" >&2
      return 1
    }
  done
  # No non-example .atlassian.net host literal in the new fixtures.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/jira_sink.sh"
  local site_re hits
  site_re="$(jira_sink::privacy_shapes | awk -F'\t' '$2=="site"{print $3}')"
  hits="$(grep -lIiE -- "$site_re" \
            tests/fixtures/jira_responses/issue_status_todo.json \
            tests/fixtures/jira_responses/issue_status_done.json 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "a non-example .atlassian.net host leaked into a feature-010 fixture:" >&2
    printf '%s\n' "$hits" >&2
    return 1
  fi
  # The parser test fixtures embed no email literal (placeholders only).
  if grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' tests/unit/phase_parser.bats; then
    echo "an email literal leaked into the phase-parser test fixtures" >&2
    return 1
  fi
}

@test "feature-011 hook surface is committed placeholder-only (Privacy IX / C-9)" {
  # The automatic-mirror surface — the extension.yml provides.hooks block, the
  # install registrar in src/install.sh, and any tracked .specify/extensions.yml
  # fixture — is committed to a PUBLIC repo and must carry only neutral
  # placeholders: command names + neutral prose, no real site/key/id/email. The
  # dogfood ${SPECKIT_JIRA_DOGFOOD_SAFE:-false} literal is a shell expansion, NOT
  # a coordinate.
  cd "$REPO_ROOT"
  # extension.yml + the new registrar test must be UNDER the git-ls-files scan.
  local f
  for f in extension.yml tests/unit/hook_registration.bats tests/unit/manifest_hooks.bats; do
    git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || {
      echo "untracked (the privacy guard would not scan it): $f" >&2
      return 1
    }
  done
  # No non-example .atlassian.net host literal in the hook surface.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/jira_sink.sh"
  local site_re tok_re hits
  site_re="$(jira_sink::privacy_shapes | awk -F'\t' '$2=="site"{print $3}')"
  tok_re="$(jira_sink::privacy_shapes | awk -F'\t' '$2=="api-token"{print $3}')"
  hits="$(grep -lIiE -- "$site_re" \
            extension.yml src/install.sh \
            tests/unit/hook_registration.bats tests/unit/manifest_hooks.bats 2>/dev/null || true)"
  hits+="$(grep -lIiE -- "$tok_re" \
            extension.yml src/install.sh \
            tests/unit/hook_registration.bats tests/unit/manifest_hooks.bats 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "a BLOCK-tier Atlassian shape leaked into the feature-011 hook surface:" >&2
    printf '%s\n' "$hits" >&2
    return 1
  fi
  # Any tracked .specify/extensions.yml fixture must be placeholder-only too
  # (there are none today — the registrar tests seed inline — but guard for the
  # future so a committed fixture cannot smuggle a coordinate).
  local ext_fixtures
  ext_fixtures="$(git ls-files -- 'tests/fixtures/**/extensions.yml' '**/.specify/extensions.yml' 2>/dev/null || true)"
  if [ -n "$ext_fixtures" ]; then
    hits="$(printf '%s\n' "$ext_fixtures" | xargs grep -lIiE -- "$site_re" 2>/dev/null || true)"
    hits+="$(printf '%s\n' "$ext_fixtures" | xargs grep -lIiE -- "$tok_re" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      echo "a tracked extensions.yml fixture leaked a BLOCK-tier shape:" >&2
      printf '%s\n' "$hits" >&2
      return 1
    fi
  fi
}

@test "feature-012 hookcheck surface + fixtures are committed placeholder-only (Privacy IX / C-9)" {
  # The hook-self-heal surface — src/hookcheck.sh, the fixtures helper, and the
  # new bats suites — is committed to a PUBLIC repo and must carry only neutral
  # placeholders: the extension id `jira`, command names, and fabricated
  # prompts. No real site/key/id/email/name/token.
  cd "$REPO_ROOT"
  local f
  for f in \
    src/hookcheck.sh \
    tests/helpers/hookcheck_fixtures.bash \
    tests/unit/hookcheck.bats \
    tests/unit/hookcheck_selfheal.bats \
    tests/unit/reconcile_hookcheck.bats \
    tests/unit/include_guards.bats; do
    git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || {
      echo "untracked (the privacy guard would not scan it): $f" >&2
      return 1
    }
  done
  # No BLOCK-tier Atlassian shape (non-example .atlassian.net host or ATATT
  # token) in any committed 012 file.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/jira_sink.sh"
  local site_re tok_re hits
  site_re="$(jira_sink::privacy_shapes | awk -F'\t' '$2=="site"{print $3}')"
  tok_re="$(jira_sink::privacy_shapes | awk -F'\t' '$2=="api-token"{print $3}')"
  hits="$(grep -lIiE -- "$site_re" \
            src/hookcheck.sh tests/helpers/hookcheck_fixtures.bash \
            tests/unit/hookcheck.bats tests/unit/hookcheck_selfheal.bats \
            tests/unit/reconcile_hookcheck.bats tests/unit/include_guards.bats 2>/dev/null || true)"
  hits+="$(grep -lIiE -- "$tok_re" \
            src/hookcheck.sh tests/helpers/hookcheck_fixtures.bash \
            tests/unit/hookcheck.bats tests/unit/hookcheck_selfheal.bats \
            tests/unit/reconcile_hookcheck.bats tests/unit/include_guards.bats 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "a BLOCK-tier Atlassian shape leaked into the feature-012 surface:" >&2
    printf '%s\n' "$hits" >&2
    return 1
  fi
  # No email literal in the fixtures helper or module (placeholders only).
  if grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
       src/hookcheck.sh tests/helpers/hookcheck_fixtures.bash; then
    echo "an email literal leaked into the feature-012 hookcheck surface" >&2
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
