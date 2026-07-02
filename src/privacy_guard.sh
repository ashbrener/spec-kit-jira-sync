# shellcheck shell=bash
# =============================================================================
# src/privacy_guard.sh — VENDOR-NEUTRAL consumer-tree privacy scan mechanism.
#
# This module is the generic, fail-closed scan MECHANISM for the consumer-side
# privacy guard (feature 006). It contains NO Jira/Atlassian vocabulary and no
# knowledge of any vendor's identifier shapes — those live exclusively behind
# caller-supplied callbacks (the sink's `*::privacy_*` providers). It is
# therefore extractable alongside the engine, exactly like the rest of the
# neutral reconcile path (the 003 engine/sink seam, FR-012).
#
# Responsibilities (mechanism only):
#   * privacy_guard::assert_git  — confirm the cwd is an enumerable git
#     work-tree (FR-010); rc passthrough.
#   * privacy_guard::scan SHAPES_FN KNOWN_FN IGNORE_FN — enumerate the tracked
#     tree, run the caller's shape regexes + known-value literals over it, assert
#     the caller's ignore-target paths are gitignored-and-untracked, print one
#     `severity<TAB>class<TAB>file` finding per hit, and return rc 1 IFF any
#     `block`-severity finding exists (a warn-only run returns rc 0).
#
# Hard invariants:
#   * READ-ONLY (FR-011): only `git ls-files`, `git ls-files --error-unmatch`,
#     `git check-ignore`, `git rev-parse`, and `grep` are run — never an edit,
#     stage, or commit of any consumer file.
#   * NO RE-LEAK (FR-007): grep is always `-l` (files-with-matches only), never
#     `-n` — the matched bytes are never captured or printed.
#   * BINARY-SAFE (FR-008): `grep -I` skips binary blobs.
#   * OPTION-SAFE: every grep / git invocation is `--`-terminated so a path
#     beginning with `-` is never read as a flag.
#
# Sourcing: this file defines functions only; it has no side effects at source
# time, so it is `set -euo pipefail`-safe to source from reconcile.sh and from
# the bats suites. It depends on nothing but `git` + `grep`.
# =============================================================================

# Idempotent include-guard (012) — safe to source twice (the consented
# self-heal sources install.sh, which re-sources shared libs).
[[ -n "${_PRIVACY_GUARD_SH_LOADED:-}" ]] && return 0
readonly _PRIVACY_GUARD_SH_LOADED=1

# -----------------------------------------------------------------------------
# privacy_guard::assert_git
#   rc 0 iff the cwd is inside a git work-tree (an enumerable tracked tree),
#   else rc 1. The caller treats rc≠0 as a hard fail (cannot enumerate ⇒ cannot
#   prove the tree clean ⇒ fail closed, FR-010). No vendor vocabulary.
# -----------------------------------------------------------------------------
privacy_guard::assert_git() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# privacy_guard::_grep_matches MODE PATTERN
#   Echo (one per line) the tracked files in which PATTERN matches, using MODE:
#     shapes → -lIiE (extended regex, case-insensitive, binary-skip)
#     known  → -lIFe (fixed string, binary-skip)
#   `git ls-files -z | xargs -0` enumerates the tracked tree NUL-safely so a
#   path with a space/newline is handled; `-l` (never `-n`) keeps the matched
#   bytes uncaptured (no re-leak); `--` terminates options. set -e-safe: a
#   no-match grep (rc 1) and an empty xargs are both swallowed.
# -----------------------------------------------------------------------------
privacy_guard::_grep_matches() {
    local mode="$1" pattern="$2"
    if [[ "$mode" == "shapes" ]]; then
        git ls-files -z | xargs -0 grep -lIiE -- "$pattern" 2>/dev/null || true
    else
        git ls-files -z | xargs -0 grep -lIF -- "$pattern" 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# privacy_guard::scan SHAPES_FN KNOWN_FN IGNORE_FN
#   The core neutral scan. Each callback, when invoked, prints zero or more
#   `severity<TAB>class<TAB>pattern` lines:
#     SHAPES_FN → `severity<TAB>class<TAB>extended-regex`   (shape pass)
#     KNOWN_FN  → `severity<TAB>class<TAB>literal`          (known-value pass)
#     IGNORE_FN → a path per line (a leading severity/class is tolerated but
#                 ignored — every ignore-target violation is a `block` finding)
#   Prints `severity<TAB>class<TAB>file` per finding to stdout. Returns rc 1 iff
#   ≥1 `block` finding, else rc 0 (a warn-only run returns 0). READ-ONLY.
# -----------------------------------------------------------------------------
privacy_guard::scan() {
    local shapes_fn="${1:?privacy_guard::scan requires a shapes callback}"
    local known_fn="${2:?privacy_guard::scan requires a known-values callback}"
    local ignore_fn="${3:?privacy_guard::scan requires an ignore-targets callback}"

    local blocked=0
    local severity class pattern path f

    # --- Shape pass + known-value pass over the tracked tree ------------------
    local mode provider
    for mode in shapes known; do
        if [[ "$mode" == "shapes" ]]; then provider="$shapes_fn"; else provider="$known_fn"; fi
        while IFS=$'\t' read -r severity class pattern; do
            [[ -n "$pattern" ]] || continue
            while IFS= read -r f; do
                [[ -n "$f" ]] || continue
                printf '%s\t%s\t%s\n' "$severity" "$class" "$f"
                [[ "$severity" == "block" ]] && blocked=1
            done < <(privacy_guard::_grep_matches "$mode" "$pattern")
        done < <("$provider")
    done

    # --- Ignore-target assertion (a violation is always a block) -------------
    # A `block` finding if the path is TRACKED (git ls-files --error-unmatch
    # rc 0) OR it EXISTS but is NOT gitignored (git check-ignore -q rc≠0). A
    # non-existent, untracked path is vacuously safe (no creds yet).
    while IFS=$'\t' read -r severity class path; do
        # Tolerate a bare-path line (the path lands in `severity`).
        if [[ -z "$path" && -n "$severity" && -z "$class" ]]; then
            path="$severity"
        fi
        [[ -n "$path" ]] || continue
        local violated=0
        if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
            violated=1
        elif [[ -e "$path" ]] && ! git check-ignore -q -- "$path"; then
            violated=1
        fi
        if (( violated == 1 )); then
            printf 'block\ttracked-config\t%s\n' "$path"
            blocked=1
        fi
    done < <("$ignore_fn")

    (( blocked == 0 ))
}
