#!/usr/bin/env bash
# =============================================================================
# scripts/check.sh — local CI-parity runner.
#
# Mirrors the 4 jobs in .github/workflows/ci.yml (shellcheck, yamllint,
# markdownlint, bats) using the EXACT same commands and the same
# skip-when-absent behavior, so a developer can run the full gate locally
# before pushing.
#
# Behavior:
#   * Each check prints a clear header, then runs.
#   * A check is SKIPPED (not failed) when its inputs are absent OR its tool
#     is not installed — mirroring ci.yml's "exit 0 when nothing to lint"
#     posture and keeping the local runner forgiving of optional tooling.
#   * Real failures are aggregated; the script exits non-zero if ANY check
#     failed, after printing a final PASS/FAIL summary.
#
# Usage:  scripts/check.sh
# =============================================================================
set -euo pipefail

# Resolve the repo root from this script's location so the runner works
# regardless of the caller's working directory.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# ----- result tracking -------------------------------------------------------
# Parallel arrays of check name -> outcome ("PASS" | "FAIL" | "SKIP").
declare -a RESULT_NAMES=()
declare -a RESULT_STATES=()

record() {
  RESULT_NAMES+=("$1")
  RESULT_STATES+=("$2")
}

header() {
  printf '\n'
  printf '=== %s ===\n' "$1"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Check 1: shellcheck  (ci.yml job "shellcheck")
# Lints every *.sh under src/ and scripts/.
# ---------------------------------------------------------------------------
check_shellcheck() {
  header "shellcheck (--shell=bash --severity=style)"
  if ! have shellcheck; then
    echo "shellcheck not installed — skipping."
    record "shellcheck" "SKIP"
    return 0
  fi
  local files=() root f
  for root in src scripts; do
    if [[ -d "$root" ]]; then
      while IFS= read -r -d '' f; do files+=("$f"); done \
        < <(find "$root" -type f -name '*.sh' -print0)
    fi
  done
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No .sh files under src/ or scripts/ — skipping."
    record "shellcheck" "SKIP"
    return 0
  fi
  printf 'Linting %d file(s):\n' "${#files[@]}"
  printf '  %s\n' "${files[@]}"
  if shellcheck --shell=bash --severity=style "${files[@]}"; then
    record "shellcheck" "PASS"
  else
    record "shellcheck" "FAIL"
  fi
}

# ---------------------------------------------------------------------------
# Check 2: yamllint  (ci.yml job "yamllint")
# Lints the explicit YAML surface area that exists.
# ---------------------------------------------------------------------------
check_yamllint() {
  header "yamllint (-d relaxed)"
  if ! have yamllint; then
    echo "yamllint not installed — skipping."
    record "yamllint" "SKIP"
    return 0
  fi
  local targets=(
    extension.yml
    config-template.yml
    templates/github-action.yml
    .github/workflows/ci.yml
  )
  local existing=() f
  for f in "${targets[@]}"; do
    if [[ -f "$f" ]]; then existing+=("$f"); fi
  done
  if [[ ${#existing[@]} -eq 0 ]]; then
    echo "None of the target YAML files exist — skipping."
    record "yamllint" "SKIP"
    return 0
  fi
  printf 'Linting %d YAML file(s):\n' "${#existing[@]}"
  printf '  %s\n' "${existing[@]}"
  if yamllint -d relaxed "${existing[@]}"; then
    record "yamllint" "PASS"
  else
    record "yamllint" "FAIL"
  fi
}

# ---------------------------------------------------------------------------
# Check 3: markdownlint  (ci.yml job "markdownlint")
# Builds the glob list dynamically from present targets, then runs
# markdownlint-cli2 via npx. Rule config is auto-discovered from
# .markdownlint-cli2.jsonc at the repo root.
# ---------------------------------------------------------------------------
check_markdownlint() {
  header "markdownlint-cli2 (npx --yes)"
  if ! have npx; then
    echo "npx (Node.js) not installed — skipping."
    record "markdownlint" "SKIP"
    return 0
  fi
  local globs=()
  [[ -d commands ]] && globs+=("commands/*.md")
  [[ -f README.md ]] && globs+=("README.md")
  [[ -f CHANGELOG.md ]] && globs+=("CHANGELOG.md")
  [[ -f CONTRIBUTING.md ]] && globs+=("CONTRIBUTING.md")
  [[ -d specs ]] && globs+=("specs/**/*.md")
  if [[ ${#globs[@]} -eq 0 ]]; then
    echo "No markdown targets present — skipping."
    record "markdownlint" "SKIP"
    return 0
  fi
  printf 'Linting globs:\n'
  printf '  %s\n' "${globs[@]}"
  if npx --yes markdownlint-cli2 "${globs[@]}"; then
    record "markdownlint" "PASS"
  else
    record "markdownlint" "FAIL"
  fi
}

# ---------------------------------------------------------------------------
# Check 4: bats  (ci.yml job "bats")
# Runs the unit + integration suites that exist. The integration suite is
# included here for local parity (CI gates it behind RUN_INTEGRATION_TESTS).
# ---------------------------------------------------------------------------
check_bats() {
  header "bats (--recursive tests/unit tests/integration)"
  if ! have bats; then
    echo "bats not installed — skipping."
    record "bats" "SKIP"
    return 0
  fi
  local dirs=() d
  for d in tests/unit tests/integration; do
    if [[ -d "$d" ]]; then dirs+=("$d"); fi
  done
  if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "No tests/unit or tests/integration directories — skipping."
    record "bats" "SKIP"
    return 0
  fi
  printf 'Running suites:\n'
  printf '  %s\n' "${dirs[@]}"
  if bats --print-output-on-failure --recursive "${dirs[@]}"; then
    record "bats" "PASS"
  else
    record "bats" "FAIL"
  fi
}

# ----- run all checks --------------------------------------------------------
# Each check is wrapped so a non-zero return from the tool doesn't abort the
# whole runner under `set -e` — we want every check to run and aggregate.
check_shellcheck
check_yamllint
check_markdownlint
check_bats

# ----- summary ---------------------------------------------------------------
header "summary"
failed=0
for i in "${!RESULT_NAMES[@]}"; do
  printf '  %-14s %s\n' "${RESULT_NAMES[$i]}" "${RESULT_STATES[$i]}"
  if [[ "${RESULT_STATES[$i]}" == "FAIL" ]]; then
    failed=1
  fi
done

printf '\n'
if [[ "$failed" -ne 0 ]]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
exit 0
