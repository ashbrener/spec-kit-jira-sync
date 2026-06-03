#!/usr/bin/env bash
# shellcheck shell=bash
#
# src/config.sh — loader + validator for
# `.specify/extensions/jira/jira-config.yml`.
#
# Sourced by other bridge scripts. Never executed directly. Public API
# uses the `config::*` namespace per the project convention.
#
# Per Principle V (ID-based binding, per-repo config) every Jira
# identifier the bridge consumes — project key, issue-type ids, status
# ids, transition ids — is resolved once by the seed/install step and
# stored in this per-repo, GITIGNORED config. This module enforces that
# contract on every run BEFORE any downstream code talks to Jira: a
# missing/invalid binding is a PROJECT-LEVEL configuration error that
# halts the whole run (Principle VIII), distinct from a per-spec failure.
# The engine maps that distinct rc to process exit 2.
#
# Privacy (Principle IX): this module NEVER reads secrets. The Jira
# Basic-auth token + email live only in the gitignored `.env`
# (JIRA_BASE_URL / JIRA_EMAIL / JIRA_API_TOKEN), never in jira-config.yml
# and never here.
#
# Behaviour summary:
#   config::load [path]                       — parse + populate state
#       (default `.specify/extensions/jira/jira-config.yml`)
#   config::get <dotted.key>                  — echo a scalar
#       (e.g. `project_key`, `issue_types.story`)
#   config::get_status_transition <phase>     — echo the target Jira
#       status id for a lifecycle phase (from `phase_status`), plus the
#       optional explicit transition id (from `transitions`) when one is
#       configured, as `<status-id>[<TAB><transition-id>]`. This is the
#       single Jira-specific vendor lever the engine calls.
#   config::validate                          — confirm every required
#       key is present; on failure print precise missing-key diagnostics
#       to stderr and exit with the project-level config rc (2).
#
# YAML parsing strategy: the config file is shallow (top-level keys plus
# one nested block per group — `issue_types`, `phase_status`,
# `transitions`, `labels`), so we parse it with a small bash state machine
# (indent stack -> flattened "dotted" keys) rather than pulling in yq. yq
# is intentionally NOT a required dependency per `plan.md` Technical
# Context — keeping the dep surface to bash + curl + jq + git lets the
# bridge install cleanly on a stock macOS / Ubuntu operator workstation.
# This mirrors the proven spec-kit-linear `src/config.sh` parser, swapping
# the Linear fields (team/project/workflow-state UUIDs) for the Jira ones
# (project key, issue-type ids, phase->status map, label prefixes).
#
# NOTE: a sourced library MUST NOT mutate the caller's shell options (codex
# review P2). Shell-option ownership stays with entry points; functions here use
# explicit error handling (config::_die) rather than relying on `set -e`.

# ---------------------------------------------------------------------------
# Module-level state. All keys are flattened "dotted" paths under the
# top-level `jira:` block, with that prefix stripped (e.g. `project_key`,
# `issue_types.story`, `phase_status.implementing`). One associative
# array keeps the parser's output discoverable to every getter without
# re-reading the file.
# ---------------------------------------------------------------------------

declare -gA CONFIG_VALUES=()
declare -g CONFIG_LOADED_PATH=""

# Default resolved-config location (gitignored per Principle V/IX).
readonly CONFIG_DEFAULT_PATH=".specify/extensions/jira/jira-config.yml"

# The six lifecycle phases the engine drives, in ordinal order. Each maps
# to a target Jira status id under `phase_status` (data-model § 2/§ 3).
readonly -a CONFIG_LIFECYCLE_PHASES=(
    "specifying"
    "planning"
    "tasking"
    "implementing"
    "ready_to_merge"
    "merged"
)

# The three issue-type ids required to project workstate onto Jira
# (Epic per repo, Story per spec, Subtask per task phase).
readonly -a CONFIG_ISSUE_TYPES=(
    "epic"
    "story"
    "subtask"
)

# The four label prefixes the sink applies (data-model § 2). Names are
# config-supplied so an operator can re-prefix without code changes.
readonly -a CONFIG_LABEL_PREFIXES=(
    "spec_prefix"
    "repo_prefix"
    "phase_prefix"
    "lifecycle_prefix"
)

# ---------------------------------------------------------------------------
# Internal helpers.
# ---------------------------------------------------------------------------

# config::_die <message...>
# Print a structured, operator-actionable error to stderr and exit 2
# (the project-level config-error halt code; the engine maps the same
# distinct rc to process exit 2, per Principle VIII). All public-API
# fatal error paths funnel through here.
config::_die() {
    local message="$*"
    printf 'spec-kit-jira-sync: config: %s\n' "${message}" >&2
    exit 2
}

# config::_warn <message...>
# Non-fatal companion to `_die` — for cases where the caller wants the
# diagnostic but is responsible for the exit decision (e.g.
# `config::validate` accumulates every missing key before exiting).
config::_warn() {
    local message="$*"
    printf 'spec-kit-jira-sync: config: %s\n' "${message}" >&2
}

# config::_strip <raw>
# Trim leading + trailing whitespace and unwrap surrounding single or
# double quotes from a YAML scalar. Trailing `#` comments are stripped
# upstream in `_parse_file` before this is called.
config::_strip() {
    local value="${1-}"
    # leading whitespace
    value="${value#"${value%%[![:space:]]*}"}"
    # trailing whitespace
    value="${value%"${value##*[![:space:]]}"}"
    # surrounding double quotes
    if [[ "${value}" == \"*\" ]]; then
        value="${value#\"}"
        value="${value%\"}"
    # surrounding single quotes
    elif [[ "${value}" == \'*\' ]]; then
        value="${value#\'}"
        value="${value%\'}"
    fi
    printf '%s' "${value}"
}

# config::_parse_file <path>
# Populate CONFIG_VALUES from a shallow YAML file. The grammar we accept
# matches `config-template.yml` / data-model § 2:
#
#   key: value                      # scalar at the current indent level
#   key:                            # nested-block opener
#     child: value                  # child of the most recent opener
#   key: {}                         # explicit empty inline map (e.g.
#                                   #   `transitions: {}`)
#
# Keys are flattened to dotted paths; the leading `jira.` prefix produced
# by the top-level `jira:` block is stripped so getters address fields as
# `project_key`, `issue_types.story`, etc. That is the entire shape
# data-model § 2 ever produces, so we don't try to be a general-purpose
# YAML parser.
config::_parse_file() {
    local path="$1"
    local line raw_key raw_value
    local indent
    # Parallel arrays simulating a stack: stack[i] is the YAML key at
    # depth i; indents[i] is the column at which that key's CHILDREN
    # must sit. depth is the count of currently-open blocks.
    local -a stack=()
    local -a indents=()
    local depth=0
    local current_prefix=""

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Strip trailing CR (Windows-friendly).
        line="${line%$'\r'}"

        # Drop trailing comments. We're permissive: any `#` not inside a
        # balanced-quote run is treated as a comment. The config template
        # never embeds `#` inside scalar values, so the simple split below
        # is safe.
        if [[ "${line}" == *'#'* ]]; then
            local before_hash="${line%%#*}"
            local dq="${before_hash//[^\"]/}"
            local sq="${before_hash//[^\']/}"
            if (( ${#dq} % 2 == 0 )) && (( ${#sq} % 2 == 0 )); then
                line="${before_hash}"
            fi
        fi

        # Skip blank lines.
        if [[ -z "${line//[[:space:]]/}" ]]; then
            continue
        fi

        # Compute leading indent (spaces only; tabs are rejected to keep
        # the operator-edit path predictable).
        if [[ "${line}" == *$'\t'* ]]; then
            config::_die "${path}: tab character in indentation; use spaces only"
        fi
        local lstripped="${line#"${line%%[![:space:]]*}"}"
        indent=$(( ${#line} - ${#lstripped} ))

        # Pop the indent stack until the top frame's child-indent is
        # strictly less than the current line's indent (i.e. the current
        # line is a child of the surviving top frame, or a sibling of the
        # popped one).
        while (( depth > 0 )) && (( indents[depth-1] >= indent )); do
            depth=$(( depth - 1 ))
            unset 'stack[depth]'
            unset 'indents[depth]'
        done

        # Rebuild current_prefix from the surviving stack.
        current_prefix=""
        local d
        for (( d = 0; d < depth; d++ )); do
            if [[ -z "${current_prefix}" ]]; then
                current_prefix="${stack[d]}"
            else
                current_prefix="${current_prefix}.${stack[d]}"
            fi
        done

        # key:value or key:  (block opener)
        if [[ "${lstripped}" != *:* ]]; then
            config::_die "${path}: malformed line (no key:value separator): ${lstripped}"
        fi

        raw_key="${lstripped%%:*}"
        raw_value="${lstripped#*:}"
        raw_key="$(config::_strip "${raw_key}")"
        raw_value="$(config::_strip "${raw_value}")"

        local full_key
        if [[ -z "${current_prefix}" ]]; then
            full_key="${raw_key}"
        else
            full_key="${current_prefix}.${raw_key}"
        fi

        # An explicit inline empty map (`transitions: {}`) is a scalar-less
        # leaf, not a block opener — record nothing and move on so the
        # block isn't left dangling on the stack.
        if [[ "${raw_value}" == "{}" ]]; then
            continue
        fi

        if [[ -z "${raw_value}" ]]; then
            # Block opener — push onto the stack.
            stack[depth]="${raw_key}"
            indents[depth]="${indent}"
            depth=$(( depth + 1 ))
            current_prefix="${full_key}"
        else
            # Strip the leading `jira.` top-level prefix so getters address
            # fields directly (project_key, issue_types.story, ...).
            local store_key="${full_key#jira.}"
            CONFIG_VALUES["${store_key}"]="${raw_value}"
        fi
    done < "${path}"
}

# ---------------------------------------------------------------------------
# Public API.
# ---------------------------------------------------------------------------

# config::load [path]
# Parse the resolved jira-config.yml at [path] (default
# `.specify/extensions/jira/jira-config.yml`) and populate module state.
# A missing / unreadable / malformed binding is a PROJECT-LEVEL config
# error: it halts via `config::_die` (exit 2). NEVER reads secrets.
config::load() {
    if (( $# > 1 )); then
        config::_die "config::load accepts at most one argument (path to jira-config.yml)"
    fi

    local path="${1:-${CONFIG_DEFAULT_PATH}}"

    if [[ ! -e "${path}" ]]; then
        config::_die "file not found: ${path}
hint: copy config-template.yml to ${path} and run the Jira install/seed step to populate ids"
    fi

    if [[ ! -r "${path}" ]]; then
        config::_die "file not readable: ${path}"
    fi

    # Reset state so consecutive loads in the same process don't leak.
    CONFIG_VALUES=()
    CONFIG_LOADED_PATH="${path}"

    config::_parse_file "${path}"
}

# config::_require_loaded
# Internal guard for every getter. Refuses to operate on empty state.
config::_require_loaded() {
    if [[ -z "${CONFIG_LOADED_PATH}" ]]; then
        config::_die "no config loaded; call \`config::load [path]\` first"
    fi
}

# config::get <dotted.key>
# Echo a scalar by its flattened key (project_key, issue_types.story,
# labels.spec_prefix, phase_status.implementing, ...). Halts if the key
# is absent so callers can rely on a non-empty result.
config::get() {
    config::_require_loaded
    if (( $# != 1 )); then
        config::_die "config::get requires exactly one argument (dotted.key)"
    fi

    local key="$1"
    local value="${CONFIG_VALUES[${key}]:-}"
    if [[ -z "${value}" ]]; then
        config::_die "${CONFIG_LOADED_PATH}: ${key} is missing"
    fi
    printf '%s\n' "${value}"
}

# config::get_status_transition <phase_token>
# The single Jira-specific vendor lever the engine calls. Echo the target
# Jira status id for a lifecycle phase (from `phase_status`), followed —
# when an explicit transition id is configured for that phase under
# `transitions` — by a TAB and that transition id:
#
#     <status-id>\t<transition-id>   (explicit transition configured)
#     <status-id>                    (resolve transition dynamically)
#
# An absent `transitions.<phase>` is the common case (data-model § 2:
# `transitions: {}`); the sink then resolves the matching transition by
# target status at write time (research D6). Halts on an unknown phase or
# a missing status mapping (Principle VIII).
config::get_status_transition() {
    config::_require_loaded
    if (( $# != 1 )); then
        config::_die "config::get_status_transition requires exactly one argument (lifecycle phase)"
    fi

    local phase="$1"
    local known=0
    local candidate
    for candidate in "${CONFIG_LIFECYCLE_PHASES[@]}"; do
        if [[ "${candidate}" == "${phase}" ]]; then
            known=1
            break
        fi
    done

    if (( known == 0 )); then
        config::_die "unknown lifecycle phase: ${phase}
hint: valid phases are ${CONFIG_LIFECYCLE_PHASES[*]}"
    fi

    local status_id="${CONFIG_VALUES[phase_status.${phase}]:-}"
    if [[ -z "${status_id}" ]]; then
        config::_die "${CONFIG_LOADED_PATH}: phase_status.${phase} is missing
hint: re-run the Jira seed step to capture the lifecycle-phase -> status-id map"
    fi

    local transition_id="${CONFIG_VALUES[transitions.${phase}]:-}"
    if [[ -n "${transition_id}" ]]; then
        printf '%s\t%s\n' "${status_id}" "${transition_id}"
    else
        printf '%s\n' "${status_id}"
    fi
}

# config::validate
# Confirm every required key is present. Returns 0 on success; on
# failure, prints each missing key to stderr (prefixed with the source
# file path so the operator can jump straight to the offending line) and
# exits 2 (the project-level config-error halt, Principle VIII). Does NOT
# inspect secrets — the token lives in .env, never here.
#
# Required keys (data-model § 2):
#   project_key
#   issue_types.{epic,story,subtask}
#   phase_status.<each of 6 lifecycle phases>
#   labels.{spec_prefix,repo_prefix,phase_prefix,lifecycle_prefix}
config::validate() {
    config::_require_loaded

    local -a problems=()
    local path="${CONFIG_LOADED_PATH}"

    # project_key.
    if [[ -z "${CONFIG_VALUES[project_key]:-}" ]]; then
        problems+=("${path}: project_key: missing")
    fi

    # issue-type ids — all three required.
    local itype
    for itype in "${CONFIG_ISSUE_TYPES[@]}"; do
        local ikey="issue_types.${itype}"
        if [[ -z "${CONFIG_VALUES[${ikey}]:-}" ]]; then
            problems+=("${path}: ${ikey}: missing")
        fi
    done

    # phase_status map — all six lifecycle phases required.
    local phase
    for phase in "${CONFIG_LIFECYCLE_PHASES[@]}"; do
        local pkey="phase_status.${phase}"
        if [[ -z "${CONFIG_VALUES[${pkey}]:-}" ]]; then
            problems+=("${path}: ${pkey}: missing (run the Jira seed step)")
        fi
    done

    # label prefixes — all four required.
    local prefix
    for prefix in "${CONFIG_LABEL_PREFIXES[@]}"; do
        local lkey="labels.${prefix}"
        if [[ -z "${CONFIG_VALUES[${lkey}]:-}" ]]; then
            problems+=("${path}: ${lkey}: missing")
        fi
    done

    if (( ${#problems[@]} > 0 )); then
        config::_warn "validation failed for ${path}:"
        local problem
        for problem in "${problems[@]}"; do
            printf '  - %s\n' "${problem}" >&2
        done
        exit 2
    fi

    return 0
}
