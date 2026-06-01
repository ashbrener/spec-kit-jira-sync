#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# src/reconcile.sh — the spec-kit ↔ Jira reconciler (Layer D), engine half.
#
# ORIGIN: vendor-neutral ENGINE adapted-from spec-kit-linear @ 7dbe6bd
#   (`git -C ~/Code/AI/speckit-linear rev-parse --short HEAD`).
#   The drift / disposition / lifecycle / CLI / description-composer engine is
#   COPIED VERBATIM from the sibling's src/reconcile.sh — the hardening
#   (idempotency, fail-closed reads, recency corroboration, disposition fork)
#   is preserved exactly, not rewritten. The Linear GraphQL WRITER half has
#   been REMOVED; its signatures now live behind the engine↔sink interface in
#   src/jira_sink.sh (contracts/engine-sink-interface.md), to be implemented
#   against Jira REST in US1. The single Jira-specific config lever the engine
#   calls is `config::get_status_transition` (the sibling's
#   `config::get_workflow_state_uuid`, renamed for Jira's transition semantics).
#
# This is the ENTRY-POINT script the reconcile command + every hook funnel
# into. It is NOT sourced as a library by production code; functions defined
# here are local to this process. The other src/*.sh modules are sourced below
# for their public APIs (`config::*`, `summary::*`, `git_helpers::*`,
# `parser::*`, `workstate::*`, and the sink). The bats unit suites DO source
# this file for its pure engine functions — the `[[ BASH_SOURCE == 0 ]]` guard
# at the tail means sourcing never runs main().
#
# -----------------------------------------------------------------------------
# Constitutional alignment
# -----------------------------------------------------------------------------
# Principle I (filesystem-is-truth) — this script never writes to disk
#   (other than tempfiles it cleans up); every spec.md/tasks.md edit
#   stays operator-owned.
# Principle II (reconcile, never event-push) — every invocation reads
#   full filesystem state and converges Jira; no diff cache, no
#   sidecar last_sync.json.
# Principle IV (drift-aware write authority) — ANY worktree may WRITE: the
#   invoking worktree's filesystem state is the write authority. Before each
#   write reconcile computes a backward-drift signal and, when the tracker
#   appears ahead, SURFACES a WARNING — it never refuses the write of its own
#   accord (warn, don't block).
# Principle VIII (observable failure) — every per-spec failure is
#   collected via summary::add and surfaced in the final summary::emit block.
#
# -----------------------------------------------------------------------------
# Exit codes
# -----------------------------------------------------------------------------
#   0 — every spec processed (possibly with non-fatal warnings)
#   1 — partial failure: some specs failed but others succeeded; or a
#       transport failure was aggregated as a warning
#   2 — project-level config error (missing/malformed jira-config.yml,
#       unseeded ids); halt without partial mutation
#   3 — transport failure across the board (config OK, but Jira
#       unreachable; nothing was written)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Module sourcing — strict order: config first (it validates ids and is
# depended on by the sink + reconcile body), then the rest. The
# `# shellcheck source=` directives let shellcheck statically follow the
# sourced API surface.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Note: SC1091 disabled per source directive because CI invokes shellcheck
# without --external-sources; the `source=` directives still document intent
# for IDE-side shellcheck integrations that DO follow external sources.
# shellcheck source=./config.sh disable=SC1091
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=./summary.sh disable=SC1091
source "${SCRIPT_DIR}/summary.sh"
# shellcheck source=./git_helpers.sh disable=SC1091
source "${SCRIPT_DIR}/git_helpers.sh"
# shellcheck source=./parser.sh disable=SC1091
source "${SCRIPT_DIR}/parser.sh"
# shellcheck source=./workstate.sh disable=SC1091
source "${SCRIPT_DIR}/workstate.sh"
# shellcheck source=./jira_sink.sh disable=SC1091
source "${SCRIPT_DIR}/jira_sink.sh"

# -----------------------------------------------------------------------------
# Module constants
# -----------------------------------------------------------------------------

# Default config path. Resolved relative to PWD (the consumer repo's
# root) rather than to the script, so the same script binary serves
# every consumer repo's invocation.
readonly RECONCILE_CONFIG_PATH_DEFAULT=".specify/extensions/jira/jira-config.yml"

# Cap on the verbatim Overview body before we truncate to the first
# paragraph (split on `\n\n`) + ellipsis.
readonly RECONCILE_OVERVIEW_MAX_CHARS=1500

# Header preface for task-phase sub-issue descriptions. The one-way semantics
# must be impossible to miss per spec. Backticks here delimit a markdown
# code-span, not a bash subshell.
# shellcheck disable=SC2016  # backticks are a markdown code-span, not bash
readonly RECONCILE_SUBISSUE_HEADER='> **Read-only mirror of `tasks.md` — ticks in Jira are overwritten on next reconcile.**'

# Diagrams-block "no GitHub remote" warning latch — one-shot pattern.
# Flipped on the first render_diagrams_block call that can't resolve a
# github.com base URL so the warning fires once per reconcile.
declare -g _RECONCILE_DIAGRAMS_WARNED=0

# Overview-block "spec.md has no ## Overview section" warning latch — one-shot.
declare -g _RECONCILE_OVERVIEW_WARNED=0

# Project Status accumulator. Each per-spec process_spec call appends one row
# (newline-separated): `<lifecycle_phase>\t<last_touched_epoch>`.
declare -g _RECONCILE_LIFECYCLE_ROWS=""

# Per-spec workstate-item cache. reconcile::sync_spec_issue builds the neutral
# workstate item once and stashes it here so reconcile::sync_task_phase_subissues
# reuses it without re-parsing the spec dir. Reset on each process_spec entry.
declare -g RECONCILE_WORKSTATE_ITEM=""

# -----------------------------------------------------------------------------
# CLI flags — populated by reconcile::parse_args.
# -----------------------------------------------------------------------------
declare -g ARG_SPEC=""          # NNN or empty
declare -g ARG_ALL=0            # 0|1
declare -g ARG_DRY_RUN=0        # 0|1
declare -g ARG_QUIET=0          # 0|1
declare -g ARG_RETROACTIVE=0    # 0|1 — DEPRECATED no-op alias. Writing from
                                #       any branch is the default, so this flag
                                #       now sets NO behavioral global; it only
                                #       triggers a single deprecation INFO row.

# Drift disposition override. Empty = unset = the proceed-and-warn default.
# Set to `abort` or `proceed` via --on-drift=<value>; any other value is a
# usage error at parse time. Has no observable effect when no backward-drift
# fires.
declare -g ARG_ON_DRIFT=""      # "" | abort | proceed

# Aggregate exit-code tracker. We start at 0 and monotonically promote
# to higher severities as failures accumulate.
declare -g RECONCILE_EXIT_CODE=0

# Honour the dry-run flag for the sink. DRY_RUN is the sink's contract name
# (engine-sink-interface.md "honor --dry-run"); ARG_DRY_RUN is the engine's
# parse-time flag. Kept in sync at parse time so the sink can read DRY_RUN.
declare -g DRY_RUN=0

# -----------------------------------------------------------------------------
# reconcile::usage
#   Print operator-facing usage to stderr.
# -----------------------------------------------------------------------------
reconcile::usage() {
    cat >&2 <<'EOF'
Usage: reconcile.sh [--spec NNN | --all] [--dry-run] [--on-drift=abort|proceed]
                    [--quiet] [--config PATH] [--help]

Reconcile filesystem spec state into Jira (Layer D). Idempotent.

Options:
  --spec NNN       Reconcile only the spec whose feature number matches NNN.
  --all            Reconcile every specs/NNN-feature/ in the repo. This is the
                   DEFAULT when neither --spec nor --all is given; the two are
                   mutually exclusive.
  --dry-run        Log every mutation that WOULD fire; issue none.
  --on-drift=V     Disposition for backward-drift (Jira ahead of disk) on a
                   non-interactive run. V is one of:
                     proceed  Overwrite Jira from disk and record a WARNING
                              (the default when --on-drift is omitted).
                     abort    Skip the drifted spec, leave Jira unchanged,
                              and record a WARNING + skip note.
                   Has no effect when no drift fires. An interactive (TTY) run
                   prompts proceed/abort instead. Any other value is an error.
  --retroactive    DEPRECATED no-op. Writing from any branch is now the
                   default — this flag is no longer needed. Passing it prints
                   one deprecation INFO row and otherwise changes nothing.
  --quiet          Suppress per-mutation log lines. Summary still emits.
  --config PATH    Override the path to jira-config.yml
                   (default: .specify/extensions/jira/jira-config.yml).
  --help           Show this help.

Exit codes (monotonic escalation: 0 < 1 < 3 < 2):
  0  Clean success — no warnings or errors.
  1  Completed with per-spec warnings (backward-drift surfaced, missing
     spec.md, or a skipped spec dir).
  2  Project-level config error (halt without partial mutation).
  3  A spec failed closed (Jira unreadable / retries exhausted); nothing
     written for it.
EOF
}

# -----------------------------------------------------------------------------
# reconcile::log
#   Emit a per-mutation log line to stderr. Suppressed by --quiet.
#   stdout is reserved for any future structured-output mode; per-step
#   chatter is stderr only (matches summary::emit convention).
# -----------------------------------------------------------------------------
reconcile::log() {
    if (( ARG_QUIET == 1 )); then
        return 0
    fi
    printf 'spec-kit-jira: %s\n' "$*" >&2
}

# -----------------------------------------------------------------------------
# reconcile::promote_exit <code>
#   Monotonically promote RECONCILE_EXIT_CODE. We use a fixed severity
#   order: 0 < 1 < 3 < 2 (config errors are the most severe — they
#   prove the operator MUST act). The first 2 wins and short-circuits
#   further promotion.
# -----------------------------------------------------------------------------
reconcile::promote_exit() {
    local incoming="$1"
    # 2 is terminal — never demote.
    if (( RECONCILE_EXIT_CODE == 2 )); then
        return 0
    fi
    case "$incoming" in
        2) RECONCILE_EXIT_CODE=2 ;;
        3) (( RECONCILE_EXIT_CODE < 3 )) && RECONCILE_EXIT_CODE=3 ;;
        1) (( RECONCILE_EXIT_CODE < 1 )) && RECONCILE_EXIT_CODE=1 ;;
        0) : ;;
        *) : ;;
    esac
    return 0
}

# =============================================================================
# Step 1 — Argument parsing.
# =============================================================================
reconcile::parse_args() {
    local config_path="${RECONCILE_CONFIG_PATH_DEFAULT}"
    while (( $# > 0 )); do
        case "$1" in
            --spec)
                if (( $# < 2 )); then
                    printf 'spec-kit-jira: --spec requires a feature number argument\n' >&2
                    reconcile::usage
                    exit 2
                fi
                ARG_SPEC="$2"
                shift 2
                ;;
            --spec=*)
                ARG_SPEC="${1#--spec=}"
                shift
                ;;
            --all)
                ARG_ALL=1
                shift
                ;;
            --dry-run)
                ARG_DRY_RUN=1
                shift
                ;;
            --quiet)
                ARG_QUIET=1
                shift
                ;;
            --on-drift)
                if (( $# < 2 )); then
                    printf 'spec-kit-jira: --on-drift requires a value (abort|proceed)\n' >&2
                    reconcile::usage
                    exit 2
                fi
                ARG_ON_DRIFT="$2"
                shift 2
                ;;
            --on-drift=*)
                ARG_ON_DRIFT="${1#--on-drift=}"
                shift
                ;;
            --retroactive)
                # DEPRECATED no-op alias. Writing from any branch is the
                # default, so this flag sets NO behavioral global. We mark it
                # seen here so main() can emit EXACTLY ONE deprecation INFO row
                # after summary::start.
                ARG_RETROACTIVE=1
                shift
                ;;
            --config)
                if (( $# < 2 )); then
                    printf 'spec-kit-jira: --config requires a path argument\n' >&2
                    reconcile::usage
                    exit 2
                fi
                config_path="$2"
                shift 2
                ;;
            --config=*)
                config_path="${1#--config=}"
                shift
                ;;
            -h|--help)
                reconcile::usage
                exit 0
                ;;
            *)
                printf 'spec-kit-jira: unknown argument: %s\n' "$1" >&2
                reconcile::usage
                exit 2
                ;;
        esac
    done

    # Validate --on-drift early: an unrecognised value is a usage error at
    # parse time. Empty = unset = proceed-and-warn default; only
    # `abort`/`proceed` are otherwise accepted.
    case "$ARG_ON_DRIFT" in
        ''|abort|proceed) : ;;
        *)
            printf 'spec-kit-jira: --on-drift value must be abort or proceed (got %q)\n' "$ARG_ON_DRIFT" >&2
            reconcile::usage
            exit 2
            ;;
    esac

    # Legacy --retroactive (deprecated no-op) with no explicit --spec still
    # implies --all, so a pasted v0.1.x command keeps its enumeration
    # behaviour. The flag itself changes nothing else; the one deprecation
    # INFO row is emitted by main() after summary::start.
    if (( ARG_RETROACTIVE == 1 )) && [[ -z "$ARG_SPEC" ]] && (( ARG_ALL == 0 )); then
        ARG_ALL=1
    fi

    # --all is the DEFAULT when no --spec is given (CLI contract, cli.md): the
    # simplest hook/operator invocation `reconcile.sh` reconciles every spec
    # (codex review P2). Only --spec + --all together is contradictory.
    if [[ -z "$ARG_SPEC" ]] && (( ARG_ALL == 0 )); then
        ARG_ALL=1
    fi
    if [[ -n "$ARG_SPEC" ]] && (( ARG_ALL == 1 )); then
        printf 'spec-kit-jira: --spec and --all are mutually exclusive\n' >&2
        reconcile::usage
        exit 2
    fi
    if [[ -n "$ARG_SPEC" && ! "$ARG_SPEC" =~ ^[0-9]+$ ]]; then
        printf 'spec-kit-jira: --spec value must be numeric (got %q)\n' "$ARG_SPEC" >&2
        exit 2
    fi

    # Keep the sink's DRY_RUN contract name in sync with the parsed flag.
    # Read by jira_sink.sh (sourced) — not unused.
    # shellcheck disable=SC2034
    DRY_RUN="$ARG_DRY_RUN"

    # Stash the resolved config path back on a module global so step 2
    # can pick it up without re-parsing.
    declare -g RECONCILE_CONFIG_PATH="$config_path"
}

# =============================================================================
# Step 2 — Config load + validate.
#   Halts with exit 2 on any failure (Principle VIII). The `config::*` API
#   already prints actionable diagnostics; we just funnel its exit code
#   through reconcile::promote_exit and surface the same warning via
#   summary::add.
# =============================================================================
reconcile::load_config() {
    local path="${RECONCILE_CONFIG_PATH}"
    if [[ ! -e "$path" ]]; then
        summary::add error "jira-config.yml not found at ${path}; run the Jira install/seed step"
        reconcile::promote_exit 2
        return 2
    fi
    # config::load populates the module-level associative arrays in THIS
    # process. If config::load exits 2, we inherit that exit (the script
    # terminates with code 2 via `set -e`, which is the right thing for a
    # project config failure).
    config::load "$path"
    config::validate
    reconcile::log "config loaded from ${path}"
}

# =============================================================================
# Step 3 — Spec enumeration.
#   Emits one spec directory path per line on stdout. Empty output (with
#   exit 0) is a valid "no specs to reconcile" outcome.
# =============================================================================
reconcile::enumerate_specs() {
    local specs_root="specs"
    if [[ ! -d "$specs_root" ]]; then
        return 0
    fi

    if [[ -n "$ARG_SPEC" ]]; then
        # Match any specs/NNN-* whose NNN prefix equals ARG_SPEC. We use
        # a glob and filter via the regex so leading-zero variations
        # ("3" vs "003") resolve to the same dir.
        local dir
        for dir in "${specs_root}"/*/; do
            [[ -d "$dir" ]] || continue
            local base
            base="$(basename "${dir%/}")"
            if [[ "$base" =~ ^([0-9]+)- ]]; then
                local num="${BASH_REMATCH[1]}"
                # Compare as integers so 003 == 3.
                if (( 10#$num == 10#$ARG_SPEC )); then
                    printf '%s\n' "${dir%/}"
                fi
            fi
        done
        return 0
    fi

    # --all: every NNN-* dir under specs/. Sorted by feature number
    # ascending so the per-spec loop output is deterministic.
    local dir
    for dir in "${specs_root}"/*/; do
        [[ -d "$dir" ]] || continue
        local base
        base="$(basename "${dir%/}")"
        if [[ "$base" =~ ^[0-9]+- ]]; then
            printf '%s\n' "${dir%/}"
        fi
    done | sort
}

# =============================================================================
# JSON-build helpers — bash strings into jq-safe JSON.
#
# These are thin wrappers around `jq -Rn '$x'` that handle the awkward
# quoting that bash heredocs and `printf` don't. We never hand-roll JSON
# in this file — every string crosses the jq boundary so embedded
# quotes/newlines/backslashes are escaped correctly.
# =============================================================================

# reconcile::json_string <raw>
#   Echo a JSON-encoded string literal for <raw>. Output includes the
#   surrounding quotes.
reconcile::json_string() {
    local raw="${1-}"
    jq -Rn --arg v "$raw" '$v'
}

# reconcile::json_array <items...>
#   Echo a JSON array of strings.
reconcile::json_array() {
    local item
    local -a pieces=()
    for item in "$@"; do
        pieces+=("$(reconcile::json_string "$item")")
    done
    if (( ${#pieces[@]} == 0 )); then
        printf '[]'
        return 0
    fi
    local IFS=','
    printf '[%s]' "${pieces[*]}"
}

# =============================================================================
# Memory block rendering.
#
# Produces the markdown fragment for the spec issue description's memory
# table. The composer concatenates it into the bridge-owned description body.
# =============================================================================
reconcile::render_memory_block() {
    local feature_number="$1"
    local short_name="$2"
    local lifecycle_phase="$3"
    local spec_dir="$4"
    local feature_branch="$5"

    local current_branch worktree_lines worktree_cell last_touched_cell source_cell

    current_branch="$(git_helpers::current_branch || true)"

    # Build a "; "-joined list of worktree paths that currently hold
    # the spec's feature branch. A single path is the common case;
    # we defensively handle multi-line input by joining with "; ".
    worktree_lines="$(git_helpers::worktree_for_branch "$feature_branch" || true)"
    if [[ -z "$worktree_lines" ]]; then
        worktree_cell="\`(no worktree currently on ${feature_branch})\`"
    else
        local joined
        joined="$(printf '%s' "$worktree_lines" | tr '\n' ';' | sed 's/;$//' | sed 's/;/; /g')"
        worktree_cell="\`${joined}\`"
    fi

    # Last-touched: `<timestamp> by <operator email>`. If we can't read the
    # disk mtime, label as "unknown". The operator email is best-effort —
    # config::get_operator_email is not part of the core config API, so the
    # call degrades gracefully (no email) when it is absent.
    local last_touched operator_email
    last_touched="$(git_helpers::last_touched "$spec_dir" || true)"
    if [[ -z "$last_touched" ]]; then
        last_touched="unknown"
    fi
    operator_email="$(config::get_operator_email 2>/dev/null || true)"
    if [[ -n "$operator_email" ]]; then
        last_touched_cell="${last_touched} by \`${operator_email}\`"
    else
        last_touched_cell="${last_touched}"
    fi

    # GitHub source URL — best-effort. We use `git remote get-url origin`
    # and rewrite the SSH form to https. If neither works we fall back to
    # a repo-relative path.
    local remote_url="" github_url=""
    if remote_url="$(git remote get-url origin 2>/dev/null)"; then
        if [[ "$remote_url" =~ ^git@([^:]+):(.+)\.git$ ]]; then
            remote_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        elif [[ "$remote_url" =~ ^ssh://git@([^/]+)/(.+)\.git$ ]]; then
            remote_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        elif [[ "$remote_url" =~ ^https?://(.+)\.git$ ]]; then
            remote_url="https://${BASH_REMATCH[1]}"
        fi
    fi
    if [[ -n "$remote_url" && -n "$current_branch" ]]; then
        github_url="${remote_url}/tree/${current_branch}/${spec_dir}"
    elif [[ -n "$remote_url" ]]; then
        github_url="${remote_url}/tree/HEAD/${spec_dir}"
    fi
    if [[ -n "$github_url" ]]; then
        source_cell="[GitHub →](${github_url})"
    else
        source_cell="\`(local: ${spec_dir})\`"
    fi

    # Canonical-right-now worktree pointer. Only present when MORE THAN ONE
    # worktree touches the spec dir; the single-worktree case omits the row.
    # Ranked by spec-dir commit time, never branch name or mtime — reuses
    # _drift_worktree_lines' canonical selection so the WARNING row and
    # memory block agree.
    local canonical_row=""
    local touching_raw
    touching_raw="$(git_helpers::worktrees_touching_spec "$feature_number" 2>/dev/null || true)"
    if [[ -n "$touching_raw" ]]; then
        local touching_count
        touching_count="$(printf '%s\n' "$touching_raw" | grep -c .)"
        if (( touching_count > 1 )); then
            local canon_line canon_path canon_branch
            canon_line="$(printf '%s\n' "$touching_raw" | sort -t$'\t' -k1,1nr -s | head -1)"
            canon_path="$(printf '%s' "$canon_line" | cut -f2)"
            canon_branch="$(printf '%s' "$canon_line" | cut -f3)"
            canonical_row=$'\n'"| **Canonical worktree** | \`${canon_path}\` (branch \`${canon_branch:-detached}\`) — most recent spec-dir commit |"
        fi
    fi

    # Title-case the lifecycle phase for human display.
    local phase_display
    case "$lifecycle_phase" in
        ready_to_merge) phase_display="Ready-to-merge" ;;
        red_team)       phase_display="Red-team" ;;
        *)              phase_display="$(printf '%s' "$lifecycle_phase" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')" ;;
    esac

    # Markdown table — fixed column order (Field / Value). The caller
    # (compose_issue_description) concatenates this block into the
    # bridge-owned description body. The canonical-worktree row is emitted
    # directly after Worktree(s) when present (multi-worktree case).
    cat <<EOF
| Field | Value |
|---|---|
| **Phase** | ${phase_display} |
| **Branch** | \`${feature_branch}\` |
| **Worktree(s)** | ${worktree_cell} |${canonical_row}
| **Last touched** | ${last_touched_cell} |
| **Source** | ${source_cell} |
| **Spec** | ${feature_number}-${short_name} |
EOF
}

# =============================================================================
# reconcile::_strip_last_reconciled_row <description>
#
# Echo the input description with any `| **Last reconciled by** | ... |`
# row removed. Co-binding helper: a timestamped row would otherwise mutate
# on every reconcile, breaking the zero-churn guarantee on a no-op sync.
# Stripping it from BOTH sides of the description diff lets the idempotency
# probe ask "did anything else change?".
# =============================================================================
reconcile::_strip_last_reconciled_row() {
    local body="$1"
    printf '%s' "$body" | sed '/^| \*\*Last reconciled by\*\* |.*|$/d'
}

# =============================================================================
# reconcile::_extract_overview <spec_md_path>
#
# Echo the body of spec.md's `## Overview` (or `# Overview` if H1) section,
# with leading and trailing blank lines trimmed. Returns empty output if no
# Overview section exists or the file is missing — graceful degradation.
# =============================================================================
reconcile::_extract_overview() {
    local spec_md="$1"
    [[ -f "$spec_md" ]] || return 0

    awk '
        BEGIN { in_section = 0; depth = 0 }
        /^#+[[:space:]]+/ {
            n = 0
            line = $0
            while (substr(line, n + 1, 1) == "#") { n++ }
            title = substr(line, n + 1)
            sub(/^[[:space:]]+/, "", title)
            sub(/[[:space:]]+$/, "", title)

            if (in_section == 0) {
                if ((n == 1 || n == 2) && title == "Overview") {
                    in_section = 1
                    depth = n
                    next
                }
            } else {
                if (n <= depth) {
                    exit
                }
            }
        }
        in_section { print }
    ' "$spec_md" | awk '
        BEGIN { started = 0 }
        {
            if (started == 0 && $0 ~ /^[[:space:]]*$/) { next }
            started = 1
            buf[NR] = $0
            last = NR
        }
        END {
            while (last > 0 && buf[last] ~ /^[[:space:]]*$/) { last-- }
            for (i = 1; i <= last; i++) {
                if (i in buf) { print buf[i] }
            }
        }
    '
}

# =============================================================================
# reconcile::_github_base_url
#
# Echo the consumer repo's https://github.com/<owner>/<repo> URL, or empty
# when `git remote get-url origin` isn't a GitHub URL.
# =============================================================================
reconcile::_github_base_url() {
    local remote_url="" base_url=""
    if remote_url="$(git remote get-url origin 2>/dev/null)"; then
        if [[ "$remote_url" =~ ^git@([^:]+):(.+)\.git$ ]]; then
            base_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        elif [[ "$remote_url" =~ ^ssh://git@([^/]+)/(.+)\.git$ ]]; then
            base_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        elif [[ "$remote_url" =~ ^https?://(.+)\.git$ ]]; then
            base_url="https://${BASH_REMATCH[1]}"
        elif [[ "$remote_url" =~ ^https?://github\.com/.+ ]]; then
            base_url="$remote_url"
        fi
    fi
    if [[ -n "$base_url" && "$base_url" == *github.com* ]]; then
        printf '%s' "$base_url"
    fi
}

# =============================================================================
# reconcile::render_overview_block <spec_dir>
#
# Build the markdown body for the spec issue's `## What this spec does`
# block. Sourced verbatim from spec.md's `## Overview` section. The caller
# concatenates this block into the bridge-owned description body.
#
# Empty Overview (spec.md has no `## Overview` heading) → echo nothing and
# surface a one-shot warned summary line per reconcile run.
# =============================================================================
reconcile::render_overview_block() {
    local spec_dir="$1"
    local spec_md="${spec_dir%/}/spec.md"

    local overview_body
    overview_body="$(reconcile::_extract_overview "$spec_md")"

    if [[ -z "$overview_body" ]]; then
        if (( _RECONCILE_OVERVIEW_WARNED == 0 )); then
            summary::add warned "overview block skipped: spec.md has no \`## Overview\` section (one or more specs)"
            _RECONCILE_OVERVIEW_WARNED=1
        fi
        return 0
    fi

    # Truncate to first paragraph + ellipsis when over cap.
    local body_chars=${#overview_body}
    if (( body_chars > RECONCILE_OVERVIEW_MAX_CHARS )); then
        local first_para
        first_para="$(printf '%s\n' "$overview_body" | awk '
            /^[[:space:]]*$/ { exit }
            { print }
        ')"
        overview_body="${first_para}"$'\n\n…'
    fi

    # Build the "Read full spec on GitHub →" link.
    local base_url current_branch link_line
    base_url="$(reconcile::_github_base_url)"
    current_branch="$(git_helpers::current_branch 2>/dev/null || true)"

    if [[ -n "$base_url" && -n "$current_branch" ]]; then
        link_line="[Read full spec on GitHub →](${base_url}/blob/${current_branch}/${spec_md})"
    elif [[ -n "$base_url" ]]; then
        link_line="[Read full spec on GitHub →](${base_url}/blob/HEAD/${spec_md})"
    else
        link_line="\`(local: ${spec_md})\`"
    fi

    cat <<EOF
## What this spec does

${overview_body}

${link_line}
EOF
}

# =============================================================================
# reconcile::render_diagrams_block
#
# Build the markdown body for the spec issue's `## Diagrams` block — four
# bullet pointers at the consumer repo's README anchors. If the consumer
# repo's remote isn't GitHub-shaped, the function echoes nothing and the
# caller treats that as "skip the diagrams block entirely".
# =============================================================================
reconcile::render_diagrams_block() {
    local remote_url="" base_url=""
    if remote_url="$(git remote get-url origin 2>/dev/null)"; then
        if [[ "$remote_url" =~ ^git@([^:]+):(.+)\.git$ ]]; then
            base_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        elif [[ "$remote_url" =~ ^ssh://git@([^/]+)/(.+)\.git$ ]]; then
            base_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        elif [[ "$remote_url" =~ ^https?://(.+)\.git$ ]]; then
            base_url="https://${BASH_REMATCH[1]}"
        elif [[ "$remote_url" =~ ^https?://github\.com/.+ ]]; then
            base_url="$remote_url"
        fi
    fi

    if [[ -z "$base_url" || "$base_url" != *github.com* ]]; then
        if (( _RECONCILE_DIAGRAMS_WARNED == 0 )); then
            summary::add warned "diagrams block skipped: \`git remote get-url origin\` did not resolve to a github.com URL"
            _RECONCILE_DIAGRAMS_WARNED=1
        fi
        return 0
    fi

    cat <<EOF
## Diagrams

Visual references in the repo's README:

- [How sync works](${base_url}#how-sync-works) — the everyday case / PR merge / escape hatches
- [Data model](${base_url}#data-model) — structural hierarchy + content mapping
- [Phase mapping](${base_url}#phase-mapping) — lifecycle state transitions
- [Write authority across worktrees](${base_url}#write-authority-across-worktrees) — read vs write rules
EOF
}

# =============================================================================
# reconcile::compose_issue_description <overview_block> <memory_block> [<diagrams_block>]
#
# Build the spec issue description from scratch in canonical order:
#   overview → memory → diagrams
#
# The bridge fully owns the description body: any prior content in the
# tracker is discarded on every reconcile. <overview_block> and
# <diagrams_block> may be empty (graceful degradation); the memory block is
# mandatory.
# =============================================================================
reconcile::compose_issue_description() {
    local overview_block="$1"
    local memory_block="$2"
    local diagrams_block="${3:-}"

    local result=""
    if [[ -n "$overview_block" ]]; then
        result+="${overview_block}"$'\n\n'
    fi
    result+="${memory_block}"
    if [[ -n "$diagrams_block" ]]; then
        result+=$'\n\n'"${diagrams_block}"
    fi

    # Trim trailing newlines for clean concatenation downstream.
    while [[ "$result" == *$'\n' ]]; do
        result="${result%$'\n'}"
    done

    printf '%s' "$result"
}

# =============================================================================
# reconcile::compose_subissue_checklist <feature_number> <phase_index> <tasks_md_path>
#
# Build the markdown body for a task-phase sub-issue. The read-only-mirror
# header from RECONCILE_SUBISSUE_HEADER is the first line; each task becomes
# a `- [ ]` / `- [x]` line.
# =============================================================================
reconcile::compose_subissue_checklist() {
    local feature_number="$1"
    local phase_index="$2"
    local tasks_md="$3"

    {
        printf '%s\n' "${RECONCILE_SUBISSUE_HEADER}"
        # shellcheck disable=SC2016  # backticks are a markdown code-span, not bash
        printf '> Source: `specs/%s-*/tasks.md` § Phase %s.\n' \
            "$feature_number" "$phase_index"
        printf '\n'
        local id state desc est box
        while IFS=$'\t' read -r id state desc est; do
            : "${est:-}"
            case "$state" in
                checked)   box="x" ;;
                unchecked) box=" " ;;
                *)         box=" " ;;
            esac
            if [[ -n "$id" ]]; then
                printf -- '- [%s] **%s** — %s\n' "$box" "$id" "$desc"
            else
                printf -- '- [%s] %s\n' "$box" "$desc"
            fi
        done < <(parser::tasks_in_phase "$tasks_md" "$phase_index")
    }
}

# =============================================================================
# reconcile::subissue_state_key <tasks_md> <phase_index>
#
# Returns one of {todo, in_progress, done} — Todo if zero tasks are checked,
# Done if every task is checked, In Progress otherwise. Empty phase (no tasks
# at all) defaults to Todo.
# =============================================================================
reconcile::subissue_state_key() {
    local tasks_md="$1"
    local phase_index="$2"
    local total=0 checked=0
    local id state desc est
    while IFS=$'\t' read -r id state desc est; do
        : "${id:-}${desc:-}${est:-}"
        total=$(( total + 1 ))
        if [[ "$state" == "checked" ]]; then
            checked=$(( checked + 1 ))
        fi
    done < <(parser::tasks_in_phase "$tasks_md" "$phase_index")
    if (( total == 0 )); then
        printf 'todo\n'
    elif (( checked == 0 )); then
        printf 'todo\n'
    elif (( checked >= total )); then
        printf 'done\n'
    else
        printf 'in_progress\n'
    fi
}

# =============================================================================
# Per-spec orchestration.
# =============================================================================

# reconcile::sync_spec_issue <feature_number> <short_name> <spec_dir> <phase> <branch>
#   Heart of the per-spec mutation path: build the neutral workstate item for
#   the spec and hand it to the sink to find-or-create/update the Story under
#   the per-repo Epic. Echoes the spec issue key for downstream sub-issue
#   reconcile. Returns non-zero on any sink failure.
#
#   US1/T023: the title/state/body/labels are now driven from
#   workstate::item_for_spec (the neutral internal contract) rather than
#   recomposing tracker-shaped state inline. The item is cached on a module
#   global so reconcile::sync_task_phase_subissues reuses it without re-parsing.
reconcile::sync_spec_issue() {
    local feature_number="$1"
    local short_name="$2"
    local spec_dir="$3"
    local lifecycle_phase="$4"
    local feature_branch="$5"
    : "${short_name:-}" "${lifecycle_phase:-}" "${feature_branch:-}"

    # Build the neutral workstate item once (title/state/body/labels/children).
    # The producer normalizes the lifecycle phase to the documented 6-phase
    # vocabulary the sink's config maps, so the sink never sees clarifying/
    # red_team/analyzing.
    local item_json
    if ! item_json="$(workstate::item_for_spec "$spec_dir")"; then
        return 1
    fi
    # Cache for the sub-issue pass (process_spec runs them back-to-back).
    declare -g RECONCILE_WORKSTATE_ITEM="$item_json"

    # Repo slug = basename of the repo root (the workstate source.repo
    # convention, workstate::document_for_repo). Best-effort: a non-git or
    # detached checkout degrades to the spec dir's grandparent basename.
    local repo_slug epic_id spec_issue_id
    repo_slug="$(git rev-parse --show-toplevel 2>/dev/null | xargs -r basename 2>/dev/null || true)"
    if [[ -z "$repo_slug" ]]; then
        repo_slug="$(basename "$(dirname "$(dirname "${spec_dir%/}")")" 2>/dev/null || true)"
    fi

    # ensure_repo_epic + sync_spec_issue own the find-or-create + transition.
    if ! epic_id="$(ensure_repo_epic "$repo_slug")"; then
        return 1
    fi

    if ! spec_issue_id="$(sync_spec_issue "$item_json" "$epic_id")"; then
        return 1
    fi
    printf '%s\n' "$spec_issue_id"
}

# reconcile::sync_task_phase_subissues <spec_issue_id> <feature_number> <spec_dir>
#   For each task phase (a workstate child), create one Subtask under the Story.
#   Returns the per-phase sub-issue ids as a JSON object keyed by phase index
#   for downstream blocking-relation reconcile.
#
#   US1/T023: the phase set + per-task checklist are driven from the cached
#   workstate item's children (kind="task") instead of re-parsing tasks.md.
reconcile::sync_task_phase_subissues() {
    local spec_issue_id="$1"
    local feature_number="$2"
    local spec_dir="$3"
    : "${feature_number:-}"

    # Reuse the item cached by reconcile::sync_spec_issue; rebuild only if the
    # cache is somehow empty (defensive — process_spec always runs them paired).
    local item_json="${RECONCILE_WORKSTATE_ITEM:-}"
    if [[ -z "$item_json" ]]; then
        item_json="$(workstate::item_for_spec "$spec_dir")" || return 1
    fi

    sync_task_phase_subissues "$spec_issue_id" "$item_json"
}

# reconcile::sync_inter_phase_blocks <phase_map> <spec_dir>
#   Wire blocking relations between task-phase sub-issues. We parse
#   `Phase N depends on Phase M` style hints from plan.md and tasks.md.
#   The sink owns the idempotent block-link reconcile.
reconcile::sync_inter_phase_blocks() {
    local phase_map="$1"
    local spec_dir="$2"

    # Read plan.md + tasks.md text and search for "Phase N depends on
    # Phase M" patterns. Case-insensitive, tolerant of em-dash and
    # colon separators. We emit one "<from>\t<to>" line per dep
    # (Phase M blocks Phase N → from=M, to=N).
    local deps
    deps="$({
        for f in "${spec_dir%/}/plan.md" "${spec_dir%/}/tasks.md"; do
            [[ -f "$f" ]] || continue
            grep -iE 'Phase[[:space:]]+[0-9]+[[:space:]]+depends[[:space:]]+on[[:space:]]+Phase[[:space:]]+[0-9]+' "$f" 2>/dev/null || true
        done
    } | awk '
        {
            match($0, /[Pp]hase[[:space:]]+[0-9]+[[:space:]]+depends[[:space:]]+on[[:space:]]+[Pp]hase[[:space:]]+[0-9]+/)
            if (RSTART == 0) next
            seg = substr($0, RSTART, RLENGTH)
            n = split(seg, parts, /[^0-9]+/)
            from = ""; to = ""
            for (i = 1; i <= n; i++) {
                if (parts[i] != "") {
                    if (to == "") { to = parts[i] }
                    else if (from == "") { from = parts[i] }
                }
            }
            if (from != "" && to != "") {
                printf "%s\t%s\n", from, to
            }
        }' | sort -u)"

    if [[ -z "$deps" ]]; then
        return 0
    fi

    # Hand the resolved dependency edges + phase→subissue map to the sink,
    # which owns the idempotent get-blocks → diff → link delta.
    sync_inter_phase_blocks "$phase_map" "$deps"
}

# reconcile::sync_clarify_comments <spec_issue_id> <spec_dir>
#   For every `### Session YYYY-MM-DD` block under ## Clarifications, post
#   (idempotently) one comment on the spec issue with the session's Q/A
#   bullets. Idempotency is via a leading marker; the sink owns the
#   at-most-once create.
reconcile::sync_clarify_comments() {
    local spec_issue_id="$1"
    local spec_dir="$2"

    sync_clarify_comments "$spec_issue_id" "$spec_dir"
}

# =============================================================================
# Drift machinery (PURE comparator + ladder).
#
# These functions are FOUNDATIONAL and side-effect-free: they read git +
# the already-fetched issue JSON and emit a verdict, but they DO NOT touch the
# sink write path. COPIED VERBATIM from the sibling — the hardening lives here.
# =============================================================================

# Drift recency clock-skew tolerance, in seconds. Overridable via the
# environment for testing / tuning; a few minutes absorbs laptop↔tracker
# clock skew without masking real edits.
declare -g RECONCILE_DRIFT_SKEW_TOLERANCE_SECONDS="${RECONCILE_DRIFT_SKEW_TOLERANCE_SECONDS:-120}"

# Sentinel ordinal returned for an unknown / uninferrable phase token. A
# distinct negative sentinel that the comparator special-cases to DISABLE the
# phase signal entirely (falling back to recency alone).
declare -gri RECONCILE_PHASE_ORDINAL_UNKNOWN=-1

# reconcile::_phase_ordinal <phase_token>
#   Map a lifecycle phase token to its strictly-ordered ordinal int on
#   stdout. The ladder is total over every token parser::lifecycle_phase can
#   emit:
#       clarifying=0 specifying=1 planning=2 tasking=3
#       implementing=4 ready_to_merge=5 merged=6
#   An unknown / empty token echoes the UNKNOWN sentinel (-1), which the
#   comparator reads as "phase signal unavailable — use recency alone". Pure.
reconcile::_phase_ordinal() {
    local token="${1:-}"
    case "$token" in
        clarifying)     printf '0\n' ;;
        specifying)     printf '1\n' ;;
        planning)       printf '2\n' ;;
        tasking)        printf '3\n' ;;
        implementing)   printf '4\n' ;;
        ready_to_merge) printf '5\n' ;;
        merged)         printf '6\n' ;;
        *)              printf '%s\n' "$RECONCILE_PHASE_ORDINAL_UNKNOWN" ;;
    esac
}

# reconcile::_tracker_phase_token <issue_json>
#   Derive the tracker-recorded lifecycle phase token from an already-fetched
#   spec-issue JSON object. Precedence:
#     1. A `phase:<token>` label present → that token (the primary source).
#     2. No phase label AND workflow state in a completed/merged category
#        (state.type == "completed") → `merged` (merged carries no phase
#        label).
#     3. Otherwise → empty (phase signal unavailable for this issue).
#   Reads ONLY fields already selected by the drift fetch
#   (labels.nodes[].name, state.type).
reconcile::_tracker_phase_token() {
    local issue_json="${1:-}"
    [[ -n "$issue_json" ]] || return 0

    # Guard against a non-object / empty-lookup response (absent issue).
    if ! printf '%s' "$issue_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
        return 0
    fi

    local label_token
    label_token="$(printf '%s' "$issue_json" \
        | jq -r '
            (.labels.nodes // [])
            | map(.name | select(startswith("phase:")))
            | (.[0] // "")
            | ltrimstr("phase:")
          ' 2>/dev/null || printf '')"
    if [[ -n "$label_token" ]]; then
        printf '%s\n' "$label_token"
        return 0
    fi

    # No phase label — a completed workflow state means merged.
    local state_type
    state_type="$(printf '%s' "$issue_json" \
        | jq -r '.state.type // "" | ascii_downcase' 2>/dev/null || printf '')"
    if [[ "$state_type" == "completed" ]]; then
        printf 'merged\n'
    fi
}

# reconcile::compute_drift <feature_number> <spec_dir> <issue_json> <disk_phase_token>
#
#   THE PURE BACKWARD-DRIFT COMPARATOR. Takes the disk-inferred phase token
#   (already computed by the caller via parser::lifecycle_phase — passed IN,
#   not recomputed), the spec dir (for the recency disk key), and the
#   already-fetched tracker spec-issue JSON, and emits a single-line verdict
#   on stdout that the disposition flow and the WARNING emitter both consume:
#
#       fired=<0|1> phase_drift=<0|1> recency_drift=<0|1> signals=<csv> \
#           disk=<tok> linear=<tok> [disk_iso=<iso> linear_iso=<iso> skew=<n>]
#
#   (The `linear=` verdict field name is kept verbatim from the copied engine
#   so the WARNING emitter + tests parse an identical line shape; it denotes
#   "the tracker side" generically.)
#
#   Rules:
#     * phase_drift = ordinal(tracker) > ordinal(disk), STRICTLY. Skipped
#       (treated false) when either ordinal is the UNKNOWN sentinel.
#     * recency_drift = phase_drift AND (tracker_epoch - disk_epoch) > SKEW.
#       Recency CORROBORATES a phase drift, never fires alone.
#     * fired = phase_drift (recency only sharpens it).
#     * signals = csv of {phase_ordering, recency} that fired ("" when none).
#     * Absent tracker issue (empty/`{}`/non-object JSON, first reconcile)
#       → nothing to be ahead of → fired=0.
#
#   PURE: reads git (spec_dir_last_commit) + the issue JSON; performs NO
#   write, NO summary::add, NO global mutation.
reconcile::compute_drift() {
    local feature_number="${1:-}"
    local spec_dir="${2:-}"
    local issue_json="${3:-}"
    local disk_phase_token="${4:-}"

    : "${feature_number:-}"  # accepted for scoping symmetry; unused locally

    # --- Tracker-side phase + recency, derived from the already-fetched JSON.
    local tracker_phase_token='' tracker_updated_iso='' tracker_epoch=''
    local issue_is_object=0
    if [[ -n "$issue_json" ]] \
        && printf '%s' "$issue_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
        issue_is_object=1
        tracker_phase_token="$(reconcile::_tracker_phase_token "$issue_json")"
        tracker_updated_iso="$(printf '%s' "$issue_json" \
            | jq -r '.updatedAt // ""' 2>/dev/null || printf '')"
        if [[ -n "$tracker_updated_iso" && "$tracker_updated_iso" != "null" ]]; then
            tracker_epoch="$(git_helpers::iso_to_epoch "$tracker_updated_iso")"
        fi
    fi

    # Absent tracker issue (first reconcile): nothing to be ahead of.
    if (( issue_is_object == 0 )); then
        printf 'fired=0 phase_drift=0 recency_drift=0 signals= disk=%s linear=\n' \
            "${disk_phase_token:-}"
        return 0
    fi

    # --- Disk-side recency key (git committer date, never mtime).
    local disk_iso='' disk_epoch=''
    disk_iso="$(git_helpers::spec_dir_last_commit "$spec_dir")"
    if [[ -n "$disk_iso" ]]; then
        disk_epoch="$(git_helpers::iso_to_epoch "$disk_iso")"
    fi

    # --- Phase-ordering signal -------------------------------------------
    local disk_ord tracker_ord phase_drift=0
    disk_ord="$(reconcile::_phase_ordinal "$disk_phase_token")"
    tracker_ord="$(reconcile::_phase_ordinal "$tracker_phase_token")"
    # Skip the phase signal when EITHER ordinal is unknown. With no phase
    # drift, nothing fires — recency only corroborates a phase drift.
    if (( disk_ord != RECONCILE_PHASE_ORDINAL_UNKNOWN )) \
        && (( tracker_ord != RECONCILE_PHASE_ORDINAL_UNKNOWN )) \
        && (( tracker_ord > disk_ord )); then
        phase_drift=1
    fi

    # --- Recency signal ---------------------------------------------------
    # Recency is a CORROBORATING signal, never a standalone trigger.
    #
    # The disk key is the spec dir's last GIT COMMIT time; the tracker key is
    # the issue's `updatedAt`. The bridge's OWN write bumps `updatedAt` to
    # "now", which is later than the last commit — so on every unchanged
    # re-run a naive recency check would fire spuriously and ratchet forever.
    # The fix: recency may only fire ALONGSIDE a phase-ordering drift.
    #
    # `skew` (seconds) is operator-tunable but must be a non-negative integer;
    # a malformed value would crash the `(( ))` under `set -e`, so fall back
    # to the 120s default rather than abort the reconcile.
    local recency_drift=0
    local skew="${RECONCILE_DRIFT_SKEW_TOLERANCE_SECONDS:-120}"
    if [[ ! "$skew" =~ ^[0-9]+$ ]]; then
        skew=120
    fi
    if (( phase_drift == 1 )) && [[ -n "$disk_epoch" && -n "$tracker_epoch" ]]; then
        if (( tracker_epoch - disk_epoch > skew )); then
            recency_drift=1
        fi
    fi

    # --- Combine ----------------------------------------------------------
    local fired=0 signals=''
    if (( phase_drift == 1 )); then
        signals="phase_ordering"
    fi
    if (( recency_drift == 1 )); then
        if [[ -n "$signals" ]]; then
            signals="${signals},recency"
        else
            signals="recency"
        fi
    fi
    if (( phase_drift == 1 || recency_drift == 1 )); then
        fired=1
    fi

    # --- Single-line verdict. Recency detail fields only when recency fired,
    #     so the WARNING emitter can append the detail line verbatim.
    if (( recency_drift == 1 )); then
        printf 'fired=%s phase_drift=%s recency_drift=%s signals=%s disk=%s linear=%s disk_iso=%s linear_iso=%s skew=%s\n' \
            "$fired" "$phase_drift" "$recency_drift" "$signals" \
            "${disk_phase_token:-}" "${tracker_phase_token:-}" \
            "${disk_iso:-}" "${tracker_updated_iso:-}" "$skew"
    else
        printf 'fired=%s phase_drift=%s recency_drift=%s signals=%s disk=%s linear=%s\n' \
            "$fired" "$phase_drift" "$recency_drift" "$signals" \
            "${disk_phase_token:-}" "${tracker_phase_token:-}"
    fi
}

# reconcile::_drift_verdict_field <verdict_line> <field>
#   Pull a single `key=value` field out of compute_drift's single-line
#   verdict. Echoes the value (empty when the field is absent). PURE.
reconcile::_drift_verdict_field() {
    local line="${1:-}" field="${2:-}"
    printf '%s\n' "$line" \
        | tr ' ' '\n' \
        | awk -F= -v k="$field" '$1 == k { print $2; exit }'
}

# reconcile::_emit_drift_warning <feature_number> <verdict_line>
#   The named backward-drift WARNING row. Emitted on EVERY drift regardless of
#   disposition (the audit trail — even a `proceed` write keeps the row).
#   Names: spec, disk phase, tracker phase, the signal(s) that fired. Appends
#   the recency detail line ONLY when the recency signal fired.
reconcile::_emit_drift_warning() {
    local feature_number="${1:-}" verdict="${2:-}"

    local disk linear signals
    disk="$(reconcile::_drift_verdict_field "$verdict" disk)"
    linear="$(reconcile::_drift_verdict_field "$verdict" linear)"
    signals="$(reconcile::_drift_verdict_field "$verdict" signals)"

    local row="spec ${feature_number} backward-drift: disk=${disk}  linear=${linear}  signals=${signals}"

    # Recency detail line — present only when the recency signal fired.
    if [[ "$(reconcile::_drift_verdict_field "$verdict" recency_drift)" == "1" ]]; then
        local disk_iso linear_iso skew
        disk_iso="$(reconcile::_drift_verdict_field "$verdict" disk_iso)"
        linear_iso="$(reconcile::_drift_verdict_field "$verdict" linear_iso)"
        skew="$(reconcile::_drift_verdict_field "$verdict" skew)"
        row+=$'\n'"         spec dir last commit ${disk_iso}  <  linear updatedAt ${linear_iso} (> ${skew}s)"
    fi

    # Multi-worktree canonical/touching lines. Collapses to nothing in the
    # single-worktree case.
    local worktree_lines
    worktree_lines="$(reconcile::_drift_worktree_lines "$feature_number")"
    if [[ -n "$worktree_lines" ]]; then
        row+=$'\n'"$worktree_lines"
    fi

    summary::add warned "$row"
}

# reconcile::_drift_worktree_lines <feature_number>
#   Render the canonical-worktree + touching-set lines of the drift WARNING
#   row from git_helpers::worktrees_touching_spec. The canonical worktree is
#   the MAX commit-epoch line (most recent spec-dir commit — never the branch
#   name or mtime); ties resolve to the first/invoking row. Echoes nothing
#   when ≤1 worktree touches the spec (single-worktree collapse). PURE-ish:
#   only reads the git worktree topology; mutates nothing.
reconcile::_drift_worktree_lines() {
    local feature_number="${1:-}"
    [[ -n "$feature_number" ]] || return 0

    local raw
    raw="$(git_helpers::worktrees_touching_spec "$feature_number" 2>/dev/null || true)"
    [[ -n "$raw" ]] || return 0

    # Count touching worktrees; collapse to nothing in the single case.
    local count
    count="$(printf '%s\n' "$raw" | grep -c .)"
    (( count > 1 )) || return 0

    # Canonical = MAX epoch (stable sort keeps the first row on an epoch
    # tie → the invoking worktree, which git_helpers emits first).
    local canonical_line canon_path canon_branch
    canonical_line="$(printf '%s\n' "$raw" | sort -t$'\t' -k1,1nr -s | head -1)"
    canon_path="$(printf '%s' "$canonical_line" | cut -f2)"
    canon_branch="$(printf '%s' "$canonical_line" | cut -f3)"

    local out
    out="         canonical worktree: ${canon_path} (branch ${canon_branch:-detached}) — most recent spec-dir commit"

    # Touching set: every worktree, "path (branch)", joined with ", ".
    local set_csv path branch
    while IFS=$'\t' read -r _ path branch; do
        [[ -n "$path" ]] || continue
        local entry="${path} (${branch:-detached})"
        if [[ -z "${set_csv:-}" ]]; then
            set_csv="$entry"
        else
            set_csv="${set_csv}, ${entry}"
        fi
    done <<< "$raw"
    out+=$'\n'"         touching worktrees: ${set_csv}"

    printf '%s\n' "$out"
}

# reconcile::_drift_prompt <feature_number>
#   The interactive backward-drift prompt. Reads the operator's proceed/abort
#   choice from the CONTROLLING TERMINAL (`/dev/tty`), NOT the inherited stdin
#   (the prompt MUST NOT consume the spec-enumeration stdin stream).
#   Re-prompts on invalid input; empty-enter is the safe default `abort`.
#   Echoes the resolved disposition (`proceed` | `abort`).
#
#   The tty source is overridable via `RECONCILE_DRIFT_TTY` so the bats
#   prompt-body tests can drive a here-string/file in place of a real
#   terminal. In production it is unset and the prompt reads `/dev/tty`.
reconcile::_drift_prompt() {
    local feature_number="${1:-}"
    local tty_src="${RECONCILE_DRIFT_TTY:-/dev/tty}"

    # Open the controlling terminal (or its test stand-in) ONCE on fd 3 so the
    # answer read never disturbs — or gets disturbed by — the inherited stdin.
    # The prompt copy goes to stderr so the disposition word on stdout stays
    # clean for command substitution. A tty that cannot be opened collapses to
    # the safe abort default (never hang, never silently proceed).
    if ! exec 3< "$tty_src" 2>/dev/null; then
        printf 'abort\n'
        return 0
    fi

    local ans
    while true; do
        printf 'spec %s — Jira appears ahead of this worktree. Overwrite Jira from disk? [p]roceed / [a]bort (default: abort): ' \
            "$feature_number" >&2

        # Read one line from fd 3. A failed read (EOF / closed tty) collapses
        # to the safe abort default.
        if ! read -r ans <&3; then
            exec 3<&-
            printf 'abort\n'
            return 0
        fi

        case "$ans" in
            p|P|proceed|PROCEED)
                exec 3<&-
                printf 'proceed\n'
                return 0
                ;;
            a|A|abort|ABORT|'')
                # Empty-enter = abort (the safe default).
                exec 3<&-
                printf 'abort\n'
                return 0
                ;;
            *)
                # Invalid input re-prompts — never crash, never silently pick.
                printf 'spec %s — please answer p (proceed) or a (abort).\n' \
                    "$feature_number" >&2
                ;;
        esac
    done
}

# reconcile::_drift_disposition <feature_number> <verdict_line>
#   THE DISPOSITION FORK — both arms of the warn-not-block state machine.
#   Echoes exactly one of:
#       proceed   — overwrite Jira from disk (write continues)
#       abort     — skip the spec, leave Jira unchanged
#
#   Only consulted when fired=1 (the caller writes silently on fired=0).
#
#   Resolution precedence:
#     1. An EXPLICIT `--on-drift` (ARG_ON_DRIFT=abort|proceed) is an operator
#        OVERRIDE and wins everywhere — even on a TTY it skips the prompt.
#     2. No explicit flag + interactive (`[[ -t 0 ]]`) → prompt the operator
#        proceed/abort via /dev/tty (empty=abort).
#     3. No explicit flag + non-interactive (`[[ ! -t 0 ]]`) →
#        proceed-and-warn default. MUST NOT hang.
#
#   The WARNING row has already been emitted by the caller before this is
#   consulted (the audit trail holds regardless of disposition).
reconcile::_drift_disposition() {
    local feature_number="${1:-}" verdict="${2:-}"
    : "${verdict:-}"  # reserved for richer disposition logic (multi-signal)

    # 1. Explicit --on-drift override — honoured in BOTH TTY arms, no prompt.
    case "${ARG_ON_DRIFT:-}" in
        abort)
            printf 'abort\n'
            return 0
            ;;
        proceed)
            printf 'proceed\n'
            return 0
            ;;
        *) : ;;  # unset → fall through to the TTY-gated default
    esac

    # 2. Interactive arm: prompt the operator. Gated on a real TTY so
    #    hooks/CI never reach the prompt (they take arm 3).
    if [[ -t 0 ]]; then
        reconcile::_drift_prompt "$feature_number"
        return 0
    fi

    # 3. Non-interactive arm: proceed-and-warn default. The WARNING row already
    #    recorded the drift for the CI audit trail.
    printf 'proceed\n'
}

# reconcile::pr_state_hint <pr_state_raw>
#   Normalise the raw output of git_helpers::pr_state into the lifecycle
#   hint token parser::lifecycle_phase expects: `merged`, `ready`, or the
#   empty string ("no signal — fall back to the artifact ladder").
#
#   git_helpers::pr_state emits one of two shapes:
#     * a rich JSON object (gh path) with the gh fields `state`
#       (OPEN|CLOSED|MERGED), `isDraft`, `mergedAt`, `url`; OR
#     * the bare word `merged` / `open` (git-only reachability fallback).
#
#   Merge is derived from `state == "MERGED"` (a non-null `mergedAt`
#   corroborates). An OPEN, non-draft PR maps to `ready` (→ ready_to_merge),
#   never `merged`.
reconcile::pr_state_hint() {
    local pr_state_raw="${1:-}"
    [[ -n "$pr_state_raw" ]] || return 0

    if printf '%s' "$pr_state_raw" | jq -e . >/dev/null 2>&1; then
        local pr_state pr_merged_at pr_draft
        pr_state="$(printf '%s' "$pr_state_raw" | jq -r '.state // "" | ascii_upcase')"
        pr_merged_at="$(printf '%s' "$pr_state_raw" | jq -r '.mergedAt // ""')"
        pr_draft="$(printf '%s' "$pr_state_raw" | jq -r '.isDraft // false')"
        if [[ "$pr_state" == "MERGED" || ( -n "$pr_merged_at" && "$pr_merged_at" != "null" ) ]]; then
            printf 'merged\n'
        elif [[ "$pr_state" == "OPEN" && "$pr_draft" == "false" ]]; then
            # Only an OPEN, non-draft PR signals "ready" — a closed-but-unmerged
            # (abandoned) PR must NOT advance the spec; fall back to artifact
            # inference (codex review P2).
            printf 'ready\n'
        fi
        return 0
    fi

    # git-only fallback path: the bare word `merged` is the only positive
    # signal; `open` (or anything else) leaves the hint empty so the
    # artifact ladder decides.
    if [[ "$pr_state_raw" == "merged" ]]; then
        printf 'merged\n'
    fi
}

# reconcile::process_spec <spec_dir>
#   Top-level per-spec orchestration. Returns 0 always — failures are
#   recorded via summary::add and promote RECONCILE_EXIT_CODE; we never
#   throw past this boundary so one bad spec can't bring down the --all sweep.
reconcile::process_spec() {
    local spec_dir="$1"

    local feature_number short_name spec_md
    if ! feature_number="$(parser::feature_number "$spec_dir")"; then
        summary::add warned "spec dir ${spec_dir}: basename does not match NNN-<slug>; skipping"
        return 0
    fi
    if ! short_name="$(parser::short_name "$spec_dir")"; then
        summary::add warned "spec dir ${spec_dir}: cannot extract short name; skipping"
        return 0
    fi

    spec_md="${spec_dir%/}/spec.md"
    if [[ ! -s "$spec_md" ]]; then
        summary::add warned "spec ${feature_number}: spec.md missing or empty; skipping"
        return 0
    fi

    # Feature branch is the canonical `<NNN>-<short-name>`.
    local feature_branch="${feature_number}-${short_name}"

    # --- Phase inference ----------------------------------------------
    # Hand the PR-state hint through to the parser so retroactive sync
    # lands directly on `merged` / `ready_to_merge` without simulating
    # intermediate transitions.
    local pr_state_raw lifecycle_phase
    pr_state_raw="$(git_helpers::pr_state "$feature_branch" 2>/dev/null || true)"

    local pr_state_hint
    pr_state_hint="$(reconcile::pr_state_hint "$pr_state_raw")"

    if ! lifecycle_phase="$(parser::lifecycle_phase "$spec_dir" "$pr_state_hint")"; then
        summary::add warned "spec ${feature_number}: cannot infer lifecycle phase; skipping"
        return 0
    fi

    reconcile::log "spec ${feature_number}: lifecycle=${lifecycle_phase} branch=${feature_branch}"

    # --- Backward-drift compute + disposition -------------------------
    # Read the tracker's current view (read-only) and compute the
    # backward-drift verdict. On fired=1, surface the WARNING row then resolve
    # the disposition. On fired=0 (forward / equal / no-drift) the write
    # proceeds SILENTLY — no prompt, no warning (the zero-false-positive path).
    local drift_issue_json drift_verdict drift_fired drift_disp drift_fetch_rc
    # Capture the fetch rc via if/else, NOT a bare `x=$(...); rc=$?`: under
    # `set -e` a bare assignment whose command substitution exits non-zero
    # aborts the whole reconcile BEFORE the `rc=$?` line runs — so an
    # unreadable tracker (rc 3) would crash the run instead of failing closed.
    if drift_issue_json="$(_fetch_drift_issue_json "$feature_number" 2>/dev/null)"; then
        drift_fetch_rc=0
    else
        drift_fetch_rc=$?
    fi
    # rc 3 = tracker was unreadable (transport / errors / malformed), which is
    # NOT the same as "issue absent". Drift stays advisory by default (fall
    # through, treat as absent, proceed), but an explicit --on-drift=abort must
    # fail closed: we cannot prove the tracker isn't ahead, so refuse the write
    # rather than risk clobbering it.
    # A non-zero rc from the drift read means the tracker was UNREADABLE
    # (transport / errors / malformed) — NOT "issue absent" (absence is rc 0 with
    # empty output). We cannot prove the tracker isn't ahead, so we MUST fail
    # closed unconditionally: record an error, promote exit 3, and skip this
    # spec's write regardless of --on-drift. Proceeding here would overwrite
    # state that was never read (FR-013 / Principle IV / jira-rest contract;
    # codex review P1). An unreadable read is an error, not advisory drift.
    if (( drift_fetch_rc != 0 )); then
        summary::add error "spec ${feature_number}: Jira unreadable (drift read rc ${drift_fetch_rc}) — skipped, no write (fail-closed; Jira unchanged)"
        reconcile::log "spec ${feature_number}: Jira unreadable (rc ${drift_fetch_rc}); failing closed, skipping write (Jira unchanged)"
        reconcile::promote_exit 3
        return 0
    fi
    drift_verdict="$(reconcile::compute_drift \
        "$feature_number" "$spec_dir" "${drift_issue_json:-}" "$lifecycle_phase")"
    drift_fired="$(reconcile::_drift_verdict_field "$drift_verdict" fired)"

    if [[ "$drift_fired" == "1" ]]; then
        # Emit the named WARNING row on EVERY drift, before any disposition
        # decision (the audit trail — even a proceed keeps it).
        reconcile::_emit_drift_warning "$feature_number" "$drift_verdict"

        # Disposition fork. Default = proceed-and-warn; the interactive +
        # non-interactive --on-drift arms layer on inside _drift_disposition.
        drift_disp="$(reconcile::_drift_disposition "$feature_number" "$drift_verdict")"
        if [[ "$drift_disp" == "abort" ]]; then
            # Operator/flag chose to skip — leave Jira unchanged.
            summary::add skipped "spec ${feature_number} skipped by operator (backward-drift abort) — Jira unchanged"
            reconcile::log "spec ${feature_number}: drift disposition=abort; skipping write (Jira unchanged)"
            return 0
        fi
        reconcile::log "spec ${feature_number}: drift fired (${drift_verdict}); disposition=${drift_disp} — proceeding with write"
    fi

    # Surface any malformed tasks.md lines.
    local malformed
    if malformed="$(parser::malformed_task_lines "${spec_dir%/}/tasks.md" 2>/dev/null)" \
        && [[ -n "$malformed" ]]; then
        local line_count
        line_count="$(printf '%s\n' "$malformed" | wc -l | awk '{print $1}')"
        summary::add warned "spec ${feature_number}: ${line_count} task line(s) outside any ## Phase header"
    fi

    # --- Spec issue find-or-create/update -----------------------------
    local spec_issue_id
    if ! spec_issue_id="$(reconcile::sync_spec_issue \
        "$feature_number" "$short_name" "$spec_dir" \
        "$lifecycle_phase" "$feature_branch")"; then
        summary::add error "spec ${feature_number}: sync_spec_issue failed"
        return 0
    fi
    if [[ -z "$spec_issue_id" || "$spec_issue_id" == "null" ]]; then
        summary::add error "spec ${feature_number}: no issue id resolved"
        return 0
    fi
    # Record the Story create/update for the run summary (Principle VIII). On a
    # fresh reconcile this is a create; idempotent diff/update is US2.
    summary::add created "spec ${feature_number}: Story ${spec_issue_id}"

    # --- Task-phase sub-issues ----------------------------------------
    local phase_map
    if ! phase_map="$(reconcile::sync_task_phase_subissues \
        "$spec_issue_id" "$feature_number" "$spec_dir")"; then
        summary::add error "spec ${feature_number}: sync_task_phase_subissues failed"
        # Continue to comments — sub-issue failures don't block the rest.
    elif [[ -n "${phase_map:-}" && "$phase_map" != "{}" ]]; then
        # One created row per phase Subtask, so the summary's created counter
        # reflects Story + Subtasks (the observable fresh-mirror result).
        local _subtask_count
        _subtask_count="$(printf '%s' "$phase_map" | jq -r 'length' 2>/dev/null || printf '0')"
        local _i
        for (( _i = 0; _i < _subtask_count; _i++ )); do
            summary::add created "spec ${feature_number}: Subtask"
        done
    fi

    # --- Inter-phase blocking relations -------------------------------
    if [[ -n "${phase_map:-}" && "$phase_map" != "{}" ]]; then
        reconcile::sync_inter_phase_blocks "$phase_map" "$spec_dir" || true
    fi

    # --- Clarify session comments -------------------------------------
    reconcile::sync_clarify_comments "$spec_issue_id" "$spec_dir" || true

    # --- Record lifecycle for the Project Status aggregate ------------
    # A drift `abort` returns before this point, so an operator-skipped spec
    # does not influence Project Status decisions.
    reconcile::_record_lifecycle "$lifecycle_phase" "$spec_dir"

    reconcile::log "spec ${feature_number}: reconcile complete"
    return 0
}

# =============================================================================
# Project Status sync — lifecycle aggregation.
#
# After every per-spec reconcile lands, aggregate the lifecycle phases
# observed across the touched specs and (where the sink supports it) flip the
# project/board status enum to match:
#
#   * Any spec in a `started`-type lifecycle phase → state=`started`.
#   * ALL specs in `merged` → state=`completed`.
#   * ALL specs in `merged` AND every spec's mtime older than
#     `sync.idle_window_days` (default 30) → state=`paused`.
#   * Otherwise the project's existing state is left untouched.
# =============================================================================

# reconcile::_idle_window_days
#   Echo the configured sync.idle_window_days as an integer. Falls back
#   to the documented default of 30 when the key is absent or malformed.
reconcile::_idle_window_days() {
    local raw="${CONFIG_VALUES[sync.idle_window_days]:-}"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$raw"
    else
        printf '30\n'
    fi
}

# reconcile::_lifecycle_is_started <phase>
#   Return 0 if <phase> is one of the `started`-type lifecycle phases.
#   specifying is intentionally treated as NOT started so a brand-new repo
#   with one freshly-minted spec doesn't accidentally promote the project
#   past planned (matches the "only flip on positive signal" rule).
reconcile::_lifecycle_is_started() {
    case "$1" in
        clarifying|planning|tasking|red_team|implementing|analyzing|ready_to_merge)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# reconcile::_record_lifecycle <phase> <spec_dir>
#   Append one row to _RECONCILE_LIFECYCLE_ROWS for the project-status
#   decision. Captures (phase, last-touched-epoch). Tolerant of unreadable
#   mtimes — epoch is "0" in that case which means "treat as recently
#   touched" (safer default than "ancient").
reconcile::_record_lifecycle() {
    local phase="$1"
    local spec_dir="$2"
    local epoch=""
    if epoch="$(stat -c %Y "$spec_dir" 2>/dev/null)"; then
        :
    elif epoch="$(stat -f %m "$spec_dir" 2>/dev/null)"; then
        :
    else
        epoch="0"
    fi
    if [[ -z "$epoch" || ! "$epoch" =~ ^[0-9]+$ ]]; then
        epoch="0"
    fi
    if [[ -z "$_RECONCILE_LIFECYCLE_ROWS" ]]; then
        _RECONCILE_LIFECYCLE_ROWS="${phase}"$'\t'"${epoch}"
    else
        _RECONCILE_LIFECYCLE_ROWS="${_RECONCILE_LIFECYCLE_ROWS}"$'\n'"${phase}"$'\t'"${epoch}"
    fi
}

# reconcile::_desired_project_state
#   Echo one of `started`, `completed`, `paused`, or empty (leave alone)
#   based on the aggregated lifecycle rows. Implements the priority order:
#   any started → started; all merged + idle → paused; all merged →
#   completed; nothing else flips.
reconcile::_desired_project_state() {
    if [[ -z "$_RECONCILE_LIFECYCLE_ROWS" ]]; then
        printf ''
        return 0
    fi

    local idle_days idle_window_secs now
    idle_days="$(reconcile::_idle_window_days)"
    idle_window_secs=$(( idle_days * 86400 ))
    now="$(date +%s 2>/dev/null || printf '0')"

    local any_started=0 all_merged=1 all_idle=1
    local row phase epoch
    while IFS=$'\t' read -r phase epoch; do
        [[ -n "$phase" ]] || continue
        if reconcile::_lifecycle_is_started "$phase"; then
            any_started=1
        fi
        if [[ "$phase" != "merged" ]]; then
            all_merged=0
        fi
        # Idle = mtime older than the window. Epoch 0 (couldn't read stat) is
        # treated as "recent" so we don't accidentally auto-pause a repo whose
        # filesystem we can't probe.
        if (( epoch == 0 )) || (( idle_window_secs <= 0 )) \
            || (( (now - epoch) < idle_window_secs )); then
            all_idle=0
        fi
        row=""  # silence shellcheck unused-var on the loop var
        : "${row}"
    done <<< "$_RECONCILE_LIFECYCLE_ROWS"

    if (( any_started == 1 )); then
        printf 'started\n'
    elif (( all_merged == 1 )) && (( all_idle == 1 )); then
        printf 'paused\n'
    elif (( all_merged == 1 )); then
        printf 'completed\n'
    else
        # No positive signal — leave the project's existing state alone.
        printf ''
    fi
}

# =============================================================================
# Main.
# =============================================================================
reconcile::main() {
    reconcile::parse_args "$@"

    local title
    title="spec-kit-jira reconcile"
    if [[ -n "$ARG_SPEC" ]]; then
        title="${title} — spec ${ARG_SPEC}"
    elif (( ARG_ALL == 1 )); then
        title="${title} — all specs"
    fi
    if (( ARG_DRY_RUN == 1 )); then
        title="${title} (dry-run)"
    fi
    summary::start "$title"

    # --retroactive is a deprecated no-op alias. Emit EXACTLY ONE INFO row per
    # invocation. It lands here, just after summary::start, so it survives the
    # buffer reset that summary::start performs and renders as the
    # top-of-summary INFO line.
    if (( ARG_RETROACTIVE == 1 )); then
        summary::add info "--retroactive is deprecated and now the default — writing from any branch needs no flag (use --all to enumerate)"
    fi

    # Step 2 — config load. Exits 2 via config::*'s own halt on failure.
    reconcile::load_config

    # Step 3 — spec enumeration.
    local -a spec_dirs=()
    local dir
    while IFS= read -r dir; do
        [[ -n "$dir" ]] && spec_dirs+=("$dir")
    done < <(reconcile::enumerate_specs)

    if (( ${#spec_dirs[@]} == 0 )); then
        if [[ -n "$ARG_SPEC" ]]; then
            summary::add warned "no spec directory matched --spec ${ARG_SPEC}"
            reconcile::promote_exit 1
        else
            reconcile::log "no specs/NNN-* directories found"
        fi
    fi

    # Step 4 — per-spec loop.
    local spec_dir
    for spec_dir in "${spec_dirs[@]}"; do
        reconcile::process_spec "$spec_dir"
    done

    # Step 5 — summary emission (Principle VIII).
    summary::emit

    # Step 6 — final exit code (CLI contract, cli.md): 0 clean · 1 per-spec
    # warnings (drift surfaced, missing spec.md, skipped dirs) · 3 a spec failed
    # closed · 2 config error. promote_exit is monotonic, so an earlier 3 (a
    # fail-closed spec) is never lowered here. A warning-only run MUST exit 1 so
    # hooks can tell it apart from a clean run (codex review P2).
    if summary::has_errors; then
        reconcile::promote_exit 1
    elif (( $(summary::count warned) > 0 || $(summary::count skipped) > 0 )); then
        reconcile::promote_exit 1
    fi

    exit "$RECONCILE_EXIT_CODE"
}

# Allow this script to be sourced for testing without executing main.
# When sourced, BASH_SOURCE[0] != $0; when executed, they match.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    reconcile::main "$@"
fi
