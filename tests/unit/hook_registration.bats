#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/hook_registration.bats  (feature 011 — Phase 2/3, C-2..C-8)
#
# The install-side hook registrar (`install::register_after_hooks` + helpers) is
# the GUARANTEED auto-mirror mechanism (FR-002): it idempotently writes/repairs
# the six `after_*` hooks in the consumer's `.specify/extensions.yml`, honouring
# an operator `enabled: false`, never duplicating, never disturbing other
# extensions' entries, and never corrupting a malformed file.
#
# Pure-FILESYSTEM — no curl-shim, no Jira. The registrar reads the manifest's
# command name + writes YAML; it never touches the vendor-neutral reconcile
# engine (003 neutral). Placeholder-only (Privacy IX): the dogfood `condition`
# literal `${SPECKIT_JIRA_DOGFOOD_SAFE:-false}` is a shell expansion, not a
# coordinate.
#
# C-7 drives BOTH dogfood branches by toggling the NON-HALTING dogfood detector
# (the halting install::guard_source_target is NOT what gates the condition —
# it would exit(2) before the registrar ever runs; the registrar uses a separate
# return-0/1 detector, overridable via INSTALL_DOGFOOD_OVERRIDE for the test).
# =============================================================================

setup() {
  set +o functrace
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/install.sh"

  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER"
  cd "$CONSUMER"
  # The registrar writes the relative INSTALL_EXTENSIONS_YML; cwd is the consumer.
  EXT_YML="$CONSUMER/.specify/extensions.yml"
}

# A pre-seeded extensions.yml with a hooks: section and a known shape.
_seed_extensions_yml() {
  mkdir -p "$CONSUMER/.specify"
  cat >"$EXT_YML"
}

@test "C-2: registrar on an absent file ⇒ creates it with auto_execute_hooks + six jira hooks" {
  [ ! -f "$EXT_YML" ]
  run install::register_after_hooks
  [ "$status" -eq 0 ]
  [ -f "$EXT_YML" ]

  grep -qE '^installed:' "$EXT_YML"
  grep -qE '^- jira' "$EXT_YML"
  grep -qE '^settings:' "$EXT_YML"
  grep -qE '^[[:space:]]+auto_execute_hooks:[[:space:]]+true' "$EXT_YML"
  grep -qE '^hooks:' "$EXT_YML"

  local hook
  for hook in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
    grep -qE "^  ${hook}:" "$EXT_YML" || {
      echo "missing hook section ${hook}" >&2; cat "$EXT_YML" >&2; return 1
    }
  done
  # All six carry an `extension: jira` entry with the push command + optional:false.
  [ "$(grep -cE '^  - extension: jira$' "$EXT_YML")" -eq 6 ]
  [ "$(grep -cE '^    command: speckit\.jira\.push$' "$EXT_YML")" -eq 6 ]
  [ "$(grep -cE '^    optional: false$' "$EXT_YML")" -eq 6 ]
}

@test "C-3: re-running the registrar ⇒ byte-identical extensions.yml (idempotent, no churn)" {
  install::register_after_hooks
  cp "$EXT_YML" "$BATS_TEST_TMPDIR/first.yml"
  install::register_after_hooks
  cmp "$BATS_TEST_TMPDIR/first.yml" "$EXT_YML" || {
    echo "second run diverged:" >&2
    diff "$BATS_TEST_TMPDIR/first.yml" "$EXT_YML" >&2 || true
    return 1
  }
}

@test "C-4: a hook pre-set enabled: false is preserved (never re-enabled) across re-run" {
  _seed_extensions_yml <<'YAML'
installed:
- jira
settings:
  auto_execute_hooks: true
hooks:
  after_specify:
  - extension: jira
    command: speckit.jira.push
    enabled: false
    optional: false
    prompt: Reconciling spec.md to Jira...
    description: pre-existing
    condition: null
YAML
  run install::register_after_hooks
  [ "$status" -eq 0 ]
  # The operator-disabled after_specify entry stays disabled.
  grep -qE '^    enabled: false$' "$EXT_YML"
  # And the others were registered (enabled: true).
  [ "$(grep -cE '^  - extension: jira$' "$EXT_YML")" -eq 6 ]
  # after_specify is still present exactly once (no duplicate).
  [ "$(grep -cE '^  after_specify:' "$EXT_YML")" -eq 1 ]
  # The single disabled entry was not flipped to true (one enabled:false remains).
  [ "$(grep -cE '^    enabled: false$' "$EXT_YML")" -eq 1 ]
}

@test "C-5: a pre-existing speckit-git entry under after_specify is untouched; jira added alongside" {
  _seed_extensions_yml <<'YAML'
installed:
- speckit-git
settings:
  auto_execute_hooks: true
hooks:
  after_specify:
  - extension: speckit-git
    command: speckit.git.commit
    enabled: true
    optional: true
YAML
  run install::register_after_hooks
  [ "$status" -eq 0 ]
  # The speckit-git entry is intact.
  grep -qE '^  - extension: speckit-git$' "$EXT_YML"
  grep -qE '^    command: speckit\.git\.commit$' "$EXT_YML"
  # A jira entry is added under after_specify alongside it.
  grep -qE '^  - extension: jira$' "$EXT_YML"
  # after_specify still appears once; both extensions live under it.
  [ "$(grep -cE '^  after_specify:' "$EXT_YML")" -eq 1 ]
  # The speckit-git command appears exactly once (not duplicated/churned).
  [ "$(grep -cE '^    command: speckit\.git\.commit$' "$EXT_YML")" -eq 1 ]
}

@test "C-6: a malformed/unreadable extensions.yml ⇒ informational message, no corruption, no halt" {
  # Unreadable: the file exists but cannot be read (chmod 000). The registrar
  # must surface an informational message and return WITHOUT corrupting it.
  _seed_extensions_yml <<'YAML'
installed:
- jira
hooks:
  after_specify:
  - extension: jira
YAML
  local before_sum
  before_sum="$(cksum "$EXT_YML")"
  chmod 000 "$EXT_YML"

  run install::register_after_hooks
  # Never a hard halt of the host (non-zero exit would fail the install ceremony
  # — the registrar degrades).
  [ "$status" -eq 0 ]

  chmod 644 "$EXT_YML"
  # Bytes unchanged — no partial write, no corruption.
  [ "$(cksum "$EXT_YML")" = "$before_sum" ]
  # An informational message was surfaced (stderr).
  echo "$output" | grep -qiE 'extensions\.yml|could not|verify'
}

@test "C-7: dogfood target ⇒ condition is the SAFE gate; normal target ⇒ condition: null" {
  # Dogfood ON (the non-halting detector returns 0): the rendered block carries
  # the literal ${SPECKIT_JIRA_DOGFOOD_SAFE:-false} condition.
  INSTALL_DOGFOOD_OVERRIDE=1 install::register_after_hooks
  grep -qE '^    condition: "\$\{SPECKIT_JIRA_DOGFOOD_SAFE:-false\}"$' "$EXT_YML" || {
    echo "dogfood condition gate not rendered:" >&2; cat "$EXT_YML" >&2; return 1
  }
  # No bare `condition: null` under a dogfood install.
  ! grep -qE '^    condition: null$' "$EXT_YML"

  # Fresh consumer, dogfood OFF: condition: null, no SAFE gate.
  rm -rf "$CONSUMER/.specify"
  INSTALL_DOGFOOD_OVERRIDE=0 install::register_after_hooks
  grep -qE '^    condition: null$' "$EXT_YML"
  ! grep -qE 'SPECKIT_JIRA_DOGFOOD_SAFE' "$EXT_YML"
}

# --------------------------------------------------------------------------
# C-8 — the hardened push one-liner runs reconcile WITH and WITHOUT .env
# (a missing .env must not break the &&-chain so an auto-fired hook degrades
# to reconcile's clean exit rather than a hard error). Extracts the literal
# bash one-liner from commands/jira-push.md and runs it against a stub repo
# whose src/reconcile.sh records that it ran.
# --------------------------------------------------------------------------

# Pull the fenced bash run-line out of a command .md (the `bash src/reconcile.sh`
# line). Substitutes the <FLAGS> placeholder with --all.
_extract_runline() {
  local md="$1"
  grep -E 'bash src/reconcile\.sh' "$md" | head -n1 | sed 's/<FLAGS>/--all/'
}

_make_stub_repo() {
  local root="$1"
  mkdir -p "$root/src"
  git -C "$root" init -q
  cat >"$root/src/reconcile.sh" <<'SH'
#!/usr/bin/env bash
echo "reconcile-ran" >"$(git rev-parse --show-toplevel)/RECONCILE_RAN"
exit 0
SH
  chmod +x "$root/src/reconcile.sh"
}

@test "C-8: push one-liner runs reconcile WITH .env present" {
  local repo="$BATS_TEST_TMPDIR/withenv"
  _make_stub_repo "$repo"
  printf 'JIRA_BASE_URL=https://example.atlassian.net\n' >"$repo/.env"
  local runline
  runline="$(_extract_runline "$REPO_ROOT/commands/jira-push.md")"
  [ -n "$runline" ]
  ( cd "$repo" && bash -c "$runline" )
  [ -f "$repo/RECONCILE_RAN" ]
}

@test "C-8: push one-liner runs reconcile WITHOUT .env (no hard-fail on missing .env)" {
  local repo="$BATS_TEST_TMPDIR/noenv"
  _make_stub_repo "$repo"
  [ ! -f "$repo/.env" ]
  local runline
  runline="$(_extract_runline "$REPO_ROOT/commands/jira-push.md")"
  [ -n "$runline" ]
  ( cd "$repo" && bash -c "$runline" )
  [ -f "$repo/RECONCILE_RAN" ]
}
