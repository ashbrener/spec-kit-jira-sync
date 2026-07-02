#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tests/helpers/hookcheck_fixtures.bash — sample .specify/extensions.yml
# variants for the 012 hook-health tests. Mirrors the block shape that
# install::_render_hook_block produces so detection is tested against the
# real on-disk grammar.
#
# Sourced by tests/unit/hookcheck*.bats. Each builder writes a complete
# extensions.yml to the given path.
#
# PRIVACY (Principle IX): placeholder-only — the extension id `jira`, the
# command `speckit.jira.push`, and fabricated prompts/descriptions. NO real
# Jira coordinate (no site, project key, accountId, email, or token).
# =============================================================================

# Emit one `jira` hook block (install's shape).
_hookcheck_fx_jira_block() {
    local hook="$1" enabled="${2:-true}"
    printf '  %s:\n' "$hook"
    printf '  - extension: jira\n'
    printf '    command: speckit.jira.push\n'
    printf '    enabled: %s\n' "$enabled"
    printf '    optional: false\n'
    printf '    prompt: Reconciling to Jira...\n'
    printf '    description: Reconcile after /%s so Jira stays in sync.\n' "${hook#after_}"
}

# Emit a git-only hook block (no jira entry → jira "absent" for this hook).
_hookcheck_fx_git_block() {
    local hook="$1" enabled="${2:-true}"
    printf '  %s:\n' "$hook"
    printf '  - extension: git\n'
    printf '    command: speckit.git.commit\n'
    printf '    enabled: %s\n' "$enabled"
    printf '    optional: true\n'
}

_hookcheck_fx_header() {
    printf 'installed:\n- jira\nsettings:\n  auto_execute_hooks: true\nhooks:\n'
}

# All six after_* hooks registered for jira (enabled).
hookcheck_fixtures::all_present() {
    local path="$1" h
    { _hookcheck_fx_header
      for h in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
          _hookcheck_fx_jira_block "$h" true
      done
    } >"$path"
}

# Three present, three absent (partial). Absent ones simply omitted.
hookcheck_fixtures::partial() {
    local path="$1"
    { _hookcheck_fx_header
      _hookcheck_fx_jira_block after_specify true
      _hookcheck_fx_jira_block after_clarify true
      _hookcheck_fx_jira_block after_plan    true
    } >"$path"
}

# No jira hooks at all (git-only blocks) → "none".
hookcheck_fixtures::none() {
    local path="$1" h
    { _hookcheck_fx_header
      for h in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
          _hookcheck_fx_git_block "$h" true
      done
    } >"$path"
}

# All present, but after_specify deliberately disabled → "present" overall
# (0 missing) with after_specify in the disabled list.
hookcheck_fixtures::one_disabled() {
    local path="$1" h
    { _hookcheck_fx_header
      _hookcheck_fx_jira_block after_specify false
      for h in after_clarify after_plan after_tasks after_implement after_analyze; do
          _hookcheck_fx_jira_block "$h" true
      done
    } >"$path"
}

# Mixed: a git sibling with enabled:false in the SAME block as an enabled
# jira entry — the git entry's false MUST NOT make jira read "disabled".
hookcheck_fixtures::git_sibling_disabled() {
    local path="$1" h
    { _hookcheck_fx_header
      printf '  after_specify:\n'
      printf '  - extension: git\n'
      printf '    command: speckit.git.commit\n'
      printf '    enabled: false\n'
      printf '  - extension: jira\n'
      printf '    command: speckit.jira.push\n'
      printf '    enabled: true\n'
      for h in after_clarify after_plan after_tasks after_implement after_analyze; do
          _hookcheck_fx_jira_block "$h" true
      done
    } >"$path"
}

# Malformed YAML-ish content (unparseable shape, but readable file).
hookcheck_fixtures::malformed() {
    local path="$1"
    printf '%s\n' ':::not yaml::: [unterminated' >"$path"
}
