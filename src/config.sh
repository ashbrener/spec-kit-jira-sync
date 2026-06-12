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
# Feature 002 — configurable artifact mapping (data-model § 1, contracts/
# mapping-config.md). All mapping/validation logic lives HERE in the config
# layer so the vendor-neutral engine half of reconcile.sh stays free of Jira /
# mapping knowledge (FR-018). The `mapping:` block is OPTIONAL and additive over
# the existing issue_types / labels / phase_status keys: absent ⇒ the alias
# layer (`mapping::synthesize_default`) emits today's DEFAULT so behavior is
# byte-for-byte unchanged (FR-001, FR-002).
# ---------------------------------------------------------------------------

# The four ordinal workstate levels the mapping projects (parent → child).
readonly -a CONFIG_MAPPING_LEVELS=(
    "repo"
    "spec"
    "phase"
    "task"
)

# The synthesized DEFAULT per-level mapping (data-model § 1). Each entry is
# "<artifact><TAB><relationship_to_parent>". When `mapping:` is absent — OR a
# level is unspecified in a partial block (Q4 per-level inheritance) — the alias
# layer fills the level from this table, reproducing the shipped 001 projection.
declare -gA CONFIG_MAPPING_DEFAULT=(
    [repo]=$'Epic\tnone'
    [spec]=$'Story\tparent'
    [phase]=$'Subtask\tparent'
    [task]=$'checklist\tchecklist'
)

# The new task-identity label prefix (Q9) the alias layer synthesizes when a
# pre-feature config omits it — the identity key for any level projecting to a
# standalone Task issue (FR-009).
readonly CONFIG_DEFAULT_TASK_PREFIX="speckit-task:"

# The relationship_to_parent vocabulary (data-model § 1 / mapping-config.md
# matrix). `checklist` and `none` are sentinels; `parent` / `Epic-link` are the
# allowed hierarchy links; the dependency-style links are present in the
# vocabulary but REJECTED as hierarchy links by the matrix.
readonly -a CONFIG_RELATIONSHIP_VOCAB=(
    "parent"
    "Epic-link"
    "none"
    "checklist"
    "Blocks"
    "Relates"
    "Implements"
)

# The relationship values REJECTED outright as a hierarchy link (Q2, FR-007):
# they carry cross-spec dependency semantics, not nesting. `Epic-link` is NOT
# here because it is conditionally allowed (only when the parent is an Epic).
readonly -a CONFIG_RELATIONSHIP_REJECT=(
    "Blocks"
    "Relates"
    "Implements"
)

# Tracks whether `mapping:` was explicitly present in the loaded file (vs.
# fully alias-synthesized). Exposed via `mapping::is_explicit`: the Phase 4/US2
# available-type probe + the initiative super-level read it to distinguish an
# operator-declared block from the aliased default; the resolve path treats
# both identically once `mapping::synthesize_default` has run.
declare -g CONFIG_MAPPING_PRESENT=0

# Set to 1 once the alias layer has run on the current load, so resolve/
# validate can guard against being called on an un-synthesized state.
declare -g CONFIG_MAPPING_SYNTHESIZED=0

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
    CONFIG_MAPPING_PRESENT=0
    CONFIG_MAPPING_SYNTHESIZED=0

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

# ===========================================================================
# Feature 007 — author-based attribution config accessors.
#
# The opt-in `attribution:` block governs the feature: {enabled, assignee,
# label, author_source, authors_file}. The whole block is OPTIONAL and additive;
# absent OR `enabled: false` ⇒ the feature is OFF (default), which the engine
# short-circuits to byte-identical-to-today behavior (US4/SC-004). These are
# pure boolean/string accessors over CONFIG_VALUES — no Jira knowledge, no
# network. The assignee/accountId/handle MECHANICS live in the sink, never here.
# ===========================================================================

# config::attribution_enabled
#   rc 0 (true) iff `attribution.enabled` is exactly "true"; rc 1 otherwise
#   (absent / false / any other value). The master gate.
config::attribution_enabled() {
    config::_require_loaded
    [[ "${CONFIG_VALUES[attribution.enabled]:-false}" == "true" ]]
}

# config::attribution_assignee
#   rc 0 (true) when the assignee track is on. Defaults to ON when the block is
#   enabled but `assignee` is unspecified (assignee:true is the documented
#   default). Independent of the label track.
config::attribution_assignee() {
    config::_require_loaded
    [[ "${CONFIG_VALUES[attribution.assignee]:-true}" == "true" ]]
}

# config::attribution_label
#   rc 0 (true) when the always-on author:<handle> label track is on. Defaults
#   to ON when enabled but unspecified.
config::attribution_label() {
    config::_require_loaded
    [[ "${CONFIG_VALUES[attribution.label]:-true}" == "true" ]]
}

# config::attribution_authors_file
#   Echo the configured path to the gitignored operator identity map, or the
#   canonical default when unspecified.
config::attribution_authors_file() {
    config::_require_loaded
    printf '%s\n' "${CONFIG_VALUES[attribution.authors_file]:-.specify/extensions/jira/jira-authors.local.yml}"
}

# ===========================================================================
# Feature 002 — configurable artifact mapping (mapping::* namespace).
#
# These functions extend config.sh with the optional `mapping:` block: parse +
# enum-validate (mapping::parse), alias-layer default synthesis + per-level
# inheritance (mapping::synthesize_default), per-level resolution
# (mapping::resolve_level), and the fail-closed config-load validation gate
# (mapping::validate, with the offline relationship matrix in
# mapping::validate_relationships). The LIVE available-issue-type probe is
# Phase 4/US2 — mapping::validate leaves a labelled hook for it but performs no
# network I/O here.
#
# Vendor-neutrality (FR-018): all of this is config-layer; the engine half of
# reconcile.sh never sees it.
# ===========================================================================

# mapping::_inline_to_keys <full_key> <inline-map-string>
# The shipped _parse_file stores an inline map (`{ artifact: "Epic",
# relationship_to_parent: "none" }`) as one raw string. The contract schema
# uses exactly that inline form for levels, so split it into the flattened
# child keys (e.g. `mapping.levels.repo.artifact`). Accepts the body between
# the braces; each comma-separated `child: value` pair becomes
# CONFIG_VALUES["<full_key>.<child>"]. Malformed pairs are a config error.
mapping::_inline_to_keys() {
    local full_key="$1"
    local body="$2"
    # Strip the surrounding braces.
    body="${body#"{"}"
    body="${body%"}"}"

    local IFS=','
    local pair
    for pair in ${body}; do
        # Skip empties from a trailing comma.
        if [[ -z "${pair//[[:space:]]/}" ]]; then
            continue
        fi
        if [[ "${pair}" != *:* ]]; then
            config::_die "${CONFIG_LOADED_PATH}: malformed inline map for ${full_key} (no key:value): ${pair}"
        fi
        local ckey="${pair%%:*}"
        local cval="${pair#*:}"
        ckey="$(config::_strip "${ckey}")"
        cval="$(config::_strip "${cval}")"
        CONFIG_VALUES["${full_key}.${ckey}"]="${cval}"
    done
}

# mapping::_enum_guard <dotted.key> <value> <allowed...>
# Halt (exit 2) when <value> is non-empty and not one of <allowed>. An empty
# value is accepted (the alias layer fills defaults). Used for the
# mapping-block enum fields.
mapping::_enum_guard() {
    local key="$1"; shift
    local value="$1"; shift
    if [[ -z "${value}" ]]; then
        return 0
    fi
    local candidate
    for candidate in "$@"; do
        if [[ "${value}" == "${candidate}" ]]; then
            return 0
        fi
    done
    config::_die "${CONFIG_LOADED_PATH}: mapping.${key}: invalid value '${value}' (allowed: $*)"
}

# mapping::parse
# Normalise any inline-map level entries into flattened child keys, record
# whether `mapping:` was present, enum-validate the mapping-block scalars
# (initiative.on_absent=degrade, initiative.source=spec_input,
# project_style∈{team-managed,classic}), then run the alias layer so every
# level + lever has a resolved value. Fail-closed (exit 2) on a malformed enum.
#
# MUST be called after config::load; resolve/validate depend on it.
mapping::parse() {
    config::_require_loaded

    # Detect presence + expand inline-map level entries. A level stored as a
    # raw `{...}` string is the contract's inline form — split it.
    local lvl
    for lvl in "${CONFIG_MAPPING_LEVELS[@]}"; do
        local lkey="mapping.levels.${lvl}"
        local lval="${CONFIG_VALUES[${lkey}]:-}"
        if [[ -n "${lval}" ]]; then
            CONFIG_MAPPING_PRESENT=1
            if [[ "${lval}" == \{*\} ]]; then
                mapping::_inline_to_keys "${lkey}" "${lval}"
                # The block-opener form would have stored children directly; the
                # inline raw-string entry is now redundant — drop it.
                unset 'CONFIG_VALUES[mapping.levels.'"${lvl}"']'
            fi
        fi
    done

    # Any mapping.* key at all means the block is present (covers an
    # initiative-only or status_rollup-only block with no `levels:`).
    local k
    for k in "${!CONFIG_VALUES[@]}"; do
        if [[ "${k}" == mapping.* ]]; then
            CONFIG_MAPPING_PRESENT=1
            break
        fi
    done

    # Enum-validate the mapping-block scalars (only when present; empty ⇒ the
    # alias layer fills the default).
    mapping::_enum_guard "initiative.on_absent" \
        "${CONFIG_VALUES[mapping.initiative.on_absent]:-}" "degrade"
    mapping::_enum_guard "initiative.source" \
        "${CONFIG_VALUES[mapping.initiative.source]:-}" "spec_input"
    mapping::_enum_guard "project_style" \
        "${CONFIG_VALUES[mapping.project_style]:-}" "team-managed" "classic"

    mapping::synthesize_default
}

# mapping::synthesize_default
# The alias layer (FR-002). Fill every mapping field the loaded config did NOT
# specify from the synthesized DEFAULT, per-level (Q4 inheritance — NOT
# all-or-nothing). When `mapping:` is wholly absent this reproduces today's
# default block; when partial, only the unspecified levels/levers inherit.
# Also synthesizes the new `labels.task_prefix` default (Q9) for any
# pre-feature config that lacks it. Idempotent.
mapping::synthesize_default() {
    config::_require_loaded

    # Per-level artifact + relationship_to_parent inheritance.
    local lvl
    for lvl in "${CONFIG_MAPPING_LEVELS[@]}"; do
        local def="${CONFIG_MAPPING_DEFAULT[${lvl}]}"
        local def_artifact="${def%%$'\t'*}"
        local def_rel="${def#*$'\t'}"

        local akey="mapping.levels.${lvl}.artifact"
        local rkey="mapping.levels.${lvl}.relationship_to_parent"
        if [[ -z "${CONFIG_VALUES[${akey}]:-}" ]]; then
            CONFIG_VALUES["${akey}"]="${def_artifact}"
        fi
        if [[ -z "${CONFIG_VALUES[${rkey}]:-}" ]]; then
            CONFIG_VALUES["${rkey}"]="${def_rel}"
        fi
    done

    # Initiative super-level levers (OFF by default, FR-013).
    : "${CONFIG_VALUES[mapping.initiative.enabled]:=false}"
    : "${CONFIG_VALUES[mapping.initiative.artifact]:=Initiative}"
    : "${CONFIG_VALUES[mapping.initiative.on_absent]:=degrade}"
    : "${CONFIG_VALUES[mapping.initiative.source]:=spec_input}"

    # Operator-declared project style (Q3) — defaults to team-managed.
    : "${CONFIG_VALUES[mapping.project_style]:=team-managed}"

    # Status rollup lever (OFF by default, Q11/FR-011).
    : "${CONFIG_VALUES[mapping.status_rollup.enabled]:=false}"

    # New task-identity label prefix (Q9). Synthesized when a pre-feature
    # config omits it; never overwrites an operator-supplied value.
    : "${CONFIG_VALUES[labels.task_prefix]:=${CONFIG_DEFAULT_TASK_PREFIX}}"

    CONFIG_MAPPING_SYNTHESIZED=1
}

# mapping::is_explicit
# Return 0 when the loaded config carried an explicit `mapping:` block, 1 when
# the block was wholly alias-synthesized from the existing keys. A read-only
# accessor for the Phase 4/US2 probe + the initiative super-level; the resolve
# path itself does not branch on this (both cases resolve identically).
mapping::is_explicit() {
    config::_require_loaded
    (( CONFIG_MAPPING_PRESENT == 1 ))
}

# mapping::resolve_level <level>
# Echo the resolved mapping for a workstate level (engine-sink-interface-002
# §mapping-driven projection) as:
#
#     <artifact><TAB><relationship_to_parent>[<TAB><on_absent>]
#
# The optional third field is present only when a per-level `on_absent`
# fallback was configured (Q10). Halts on an unknown level or an unsynthesized
# state.
mapping::resolve_level() {
    config::_require_loaded
    if (( $# != 1 )); then
        config::_die "mapping::resolve_level requires exactly one argument (level)"
    fi
    if (( CONFIG_MAPPING_SYNTHESIZED == 0 )); then
        config::_die "mapping not synthesized; call \`mapping::parse\` after config::load"
    fi

    local level="$1"
    local known=0 candidate
    for candidate in "${CONFIG_MAPPING_LEVELS[@]}"; do
        if [[ "${candidate}" == "${level}" ]]; then
            known=1
            break
        fi
    done
    if (( known == 0 )); then
        config::_die "unknown mapping level: ${level}
hint: valid levels are ${CONFIG_MAPPING_LEVELS[*]}"
    fi

    local artifact="${CONFIG_VALUES[mapping.levels.${level}.artifact]:-}"
    local rel="${CONFIG_VALUES[mapping.levels.${level}.relationship_to_parent]:-}"
    local on_absent="${CONFIG_VALUES[mapping.levels.${level}.on_absent]:-}"

    if [[ -n "${on_absent}" ]]; then
        printf '%s\t%s\t%s\n' "${artifact}" "${rel}" "${on_absent}"
    else
        printf '%s\t%s\n' "${artifact}" "${rel}"
    fi
}

# mapping::validate_relationships
# The OFFLINE relationship-validation matrix (Q2, FR-007, mapping-config.md §4).
# Resolves fully at config-load with no network round-trip because the
# Epic-link parent-is-Epic check reads the loaded levels (classic vs
# team-managed style is operator-declared, Q3). Accumulates every violation into
# the nameref array <problems_ref>; the caller decides the exit. Allowed
# hierarchy links: parent / Epic-link(only under an Epic parent) / none /
# checklist. Rejected: Blocks / Relates / Implements as ANY hierarchy link; an
# unknown vocabulary value; `checklist` artifact paired with a non-checklist
# relationship; Epic-link where the parent level's artifact is not Epic.
mapping::validate_relationships() {
    local -n _problems_ref="$1"
    local path="${CONFIG_LOADED_PATH}"

    # Parent of each level (parent → child ordinal: repo > spec > phase > task).
    local -A parent_of=(
        [spec]="repo"
        [phase]="spec"
        [task]="phase"
        [repo]=""
    )

    local lvl
    for lvl in "${CONFIG_MAPPING_LEVELS[@]}"; do
        local artifact="${CONFIG_VALUES[mapping.levels.${lvl}.artifact]:-}"
        local rel="${CONFIG_VALUES[mapping.levels.${lvl}.relationship_to_parent]:-}"

        # Vocabulary guard.
        local in_vocab=0 v
        for v in "${CONFIG_RELATIONSHIP_VOCAB[@]}"; do
            if [[ "${rel}" == "${v}" ]]; then
                in_vocab=1
                break
            fi
        done
        if (( in_vocab == 0 )); then
            _problems_ref+=("${path}: mapping.levels.${lvl}.relationship_to_parent: unknown relationship '${rel}'")
            continue
        fi

        # Dependency-style links are never legal hierarchy links.
        local rejected=0 r
        for r in "${CONFIG_RELATIONSHIP_REJECT[@]}"; do
            if [[ "${rel}" == "${r}" ]]; then
                _problems_ref+=("${path}: mapping.levels.${lvl}.relationship_to_parent: '${rel}' is a dependency link, not a hierarchy link")
                rejected=1
                break
            fi
        done
        if (( rejected == 1 )); then
            continue
        fi

        # checklist sentinel: artifact and relationship must agree.
        if [[ "${artifact}" == "checklist" && "${rel}" != "checklist" ]]; then
            _problems_ref+=("${path}: mapping.levels.${lvl}: artifact 'checklist' requires relationship_to_parent 'checklist' (got '${rel}')")
            continue
        fi
        if [[ "${rel}" == "checklist" && "${artifact}" != "checklist" ]]; then
            _problems_ref+=("${path}: mapping.levels.${lvl}: relationship 'checklist' requires artifact 'checklist' (got '${artifact}')")
            continue
        fi

        # Epic-link is legal ONLY when the parent level projects to an Epic.
        if [[ "${rel}" == "Epic-link" ]]; then
            local parent="${parent_of[${lvl}]}"
            local parent_artifact=""
            if [[ -n "${parent}" ]]; then
                parent_artifact="${CONFIG_VALUES[mapping.levels.${parent}.artifact]:-}"
            fi
            if [[ "${parent_artifact}" != "Epic" ]]; then
                _problems_ref+=("${path}: mapping.levels.${lvl}.relationship_to_parent: 'Epic-link' is legal only when the parent level projects to an Epic (parent '${parent:-<none>}' projects to '${parent_artifact:-<none>}')")
            fi
        fi
    done
}

# mapping::validate
# The single fail-closed config-load validation gate (FR-017, mapping-config.md
# §validation order). Runs the OFFLINE checks — required-id presence for
# configured artifacts, then the relationship matrix — accumulating EVERY
# problem before exiting 2 (so the operator sees them all). Any failure writes
# nothing for the run (the engine maps the config rc to exit 2).
#
# Order (mapping-config.md §validation order):
#   1. parse + alias (already done by mapping::parse — guarded here).
#   2. required-id: a level projecting to a standalone Task issue needs
#      issue_types.task; an enabled initiative needs issue_types.initiative.
#   3. relationship matrix (mapping::validate_relationships).
#   4. available-type probe — LIVE, Phase 4/US2. SEAM/HOOK only (see below); no
#      network here.
#
# `checklist` is a render sentinel, not an issue type, and is exempt from the
# required-id + (future) available-type checks.
mapping::validate() {
    config::_require_loaded
    if (( CONFIG_MAPPING_SYNTHESIZED == 0 )); then
        config::_die "mapping not synthesized; call \`mapping::parse\` after config::load"
    fi

    local -a problems=()
    local path="${CONFIG_LOADED_PATH}"

    # --- 2. Required-id presence for configured artifacts --------------------
    # A level projecting to a standalone "Task" issue requires issue_types.task
    # (FR-009 identity needs a real issue-type id). `checklist` projects no
    # issue and is exempt. Epic/Story/Subtask reuse the existing required ids
    # (already enforced by config::validate); a non-default artifact that maps
    # to "Task" is the new required-id surface for this phase.
    local lvl
    for lvl in "${CONFIG_MAPPING_LEVELS[@]}"; do
        local artifact="${CONFIG_VALUES[mapping.levels.${lvl}.artifact]:-}"
        case "${artifact}" in
            Task)
                if [[ -z "${CONFIG_VALUES[issue_types.task]:-}" ]]; then
                    problems+=("${path}: issue_types.task: missing (required: level '${lvl}' projects to a Task issue)")
                fi
                ;;
        esac
    done

    # An enabled initiative super-level needs issue_types.initiative ONLY when
    # the instance supports Initiative; absence is handled at write time by
    # on_absent: degrade (FR-013), NOT a config error. So no required-id check
    # here — the available-type probe (step 4, Phase 4/US2) routes initiative
    # absence to degrade.

    # --- 3. Relationship matrix (offline) ------------------------------------
    mapping::validate_relationships problems

    # --- 4. Available-issue-type probe (LIVE) — Phase 4/US2 SEAM -------------
    # Out of scope for Phase 2 (Foundational): the live issue-type metadata
    # probe (FR-005, Q10) and the absent-type policy (FR-006) are implemented in
    # Phase 4/US2 as `mapping::detect_available_types` +
    # `mapping::validate_available`, which will append their findings to
    # `problems` HERE, ordered after the relationship matrix, before the single
    # exit below. Leaving the hook explicit keeps the validation order
    # (parse → required-id → relationship → available-type) intact.

    if (( ${#problems[@]} > 0 )); then
        config::_warn "mapping validation failed for ${path}:"
        local problem
        for problem in "${problems[@]}"; do
            printf '  - %s\n' "${problem}" >&2
        done
        exit 2
    fi

    return 0
}

# ===========================================================================
# Feature 002 — Phase 4/US2: the LIVE available-issue-type probe + absent-type
# policy (FR-005, FR-006, Q10, mapping-config.md §available-type detection).
#
# These complete the §validation-order step 4. They are kept SEPARATE from
# mapping::validate (which stays offline so the foundational unit suites can run
# the matrix without a transport): the engine (reconcile.sh, T023) runs
# mapping::validate first (offline gate), then probes the project once via
# mapping::detect_available_types, then runs mapping::validate_available with the
# detected set — all BEFORE the write loop, all fail-closed (exit 2 / rc 3).
#
# Vendor-neutrality (FR-018): the probe lives in the config layer; the engine
# half of reconcile.sh only orchestrates the call order, it embeds no Jira /
# issue-type knowledge.
# ===========================================================================

# mapping::detect_available_types
# Probe the TARGET project's issue-type metadata and echo the available-type
# NAME set, one name per line (FR-005, Q10). The probe is a READ via
# src/jira_rest.sh (`jira_rest::get "project/<key>"`), which returns the project
# resource carrying `.issueTypes[].name`. A real unreadable read — transport /
# auth / permission (jira_rest rc 3/4/5) OR a 200 whose body has no parseable
# issue-type array — returns rc 3 (FAIL-CLOSED): we must NOT validate configured
# artifacts against an empty/partial set, which would let an absent type slip
# through (or reject a present one). The caller feeds the echoed set to
# mapping::validate_available.
#
# Depends on jira_rest.sh being sourced (the engine + the sink both source it;
# the unit suite sources it explicitly). project_key comes from the loaded,
# gitignored config (Principle V/IX) — never a hardcoded coordinate.
mapping::detect_available_types() {
    config::_require_loaded

    local project
    project="${CONFIG_VALUES[project_key]:-}"
    if [[ -z "${project}" ]]; then
        # No project to probe — unreadable (fail-closed). config::validate would
        # already have halted on this; guard defensively.
        return 3
    fi

    local raw rc=0
    if raw="$(jira_rest::get "project/${project}" 2>/dev/null)"; then
        rc=0
    else
        rc=$?
    fi
    if (( rc != 0 )); then
        # A real unreadable read (transport / auth / permission). Fail closed so
        # the engine never validates against an unknown set.
        return 3
    fi

    # Extract the available types as `<name>\t<id>` rows (FR-005). The id lets
    # mapping::validate_available match by the RESOLVED issue-type id actually
    # POSTed (issue_types.<artifact>), not the artifact ALIAS name — so a default
    # whose `issue_types.story` id points to a differently-NAMED live type (e.g.
    # a Kanban board where the spec slot is a "Task") validates correctly instead
    # of failing on the absent alias name (live-dogfood finding). A 200 whose
    # body carries no parseable `.issueTypes[].name` is ALSO unreadable — we
    # cannot prove the available set, so fail closed rather than treat it as empty.
    local rows
    if ! rows="$(printf '%s' "${raw}" | jq -e -r '
        (.issueTypes // []) | map(select(.name)) | .[] | "\(.name)\t\(.id // "")"
    ' 2>/dev/null)"; then
        return 3
    fi
    printf '%s\n' "${rows}"
    return 0
}

# mapping::_artifact_type_id <artifact>
# Resolve an artifact ALIAS name to its configured issue-type id (the same
# binding the sink projects through: Epic→issue_types.epic, Story→…story, etc.;
# any other name → issue_types.<lowercased>). NON-halting: echoes the empty
# string when the artifact is the `checklist` sentinel, empty, or has no
# issue_types binding (so validate_available can fall back to the name check).
mapping::_artifact_type_id() {
    local artifact="${1:-}" key
    case "${artifact}" in
        Epic)    key="epic" ;;
        Story)   key="story" ;;
        Subtask) key="subtask" ;;
        Task)    key="task" ;;
        ""|checklist) printf ''; return 0 ;;
        *) key="$(printf '%s' "${artifact}" | tr '[:upper:]' '[:lower:]')" ;;
    esac
    printf '%s' "${CONFIG_VALUES[issue_types.${key}]:-}"
}

# mapping::validate_available <available-type-name>...
# The absent-type policy (FR-006, Q10, mapping-config.md §available-type). Reject
# every configured `levels.<level>.artifact` (and `initiative.artifact` when the
# super-level is enabled) that does NOT appear in the supplied available-type set
# — UNLESS that level declares a per-level `on_absent: "<type>"` fallback whose
# value IS in the set, the only escape. An `on_absent` whose fallback is ITSELF
# absent STILL hard-errors. The `checklist` render sentinel is EXEMPT (it
# projects no issue type). Initiative absence is NOT a hard error — it routes to
# `on_absent: degrade` (FR-013) — so the enabled-initiative artifact is checked
# only as a soft note, never a halt, here.
#
# A single fail-closed gate: accumulates EVERY violation (so the operator sees
# them all), then exits 2 if any remain — writing nothing for the run (FR-017).
# The caller (reconcile.sh T023) supplies the set from
# mapping::detect_available_types.
mapping::validate_available() {
    config::_require_loaded
    if (( CONFIG_MAPPING_SYNTHESIZED == 0 )); then
        config::_die "mapping not synthesized; call \`mapping::parse\` after config::load"
    fi

    # Build membership lookups over the supplied available-type set. Each arg is
    # either a real probe row `<name>\t<id>` (preferred — enables id matching) or
    # a bare `<name>` (legacy callers / unit tests). `have_ids` is set when ANY
    # row carried an id, switching the per-level check to id-matching (the
    # correct comparison: the resolved issue-type id, not the alias name).
    local -A available=()        # by NAME
    local -A available_ids=()    # by ID
    local have_ids=0
    local t name id
    for t in "$@"; do
        [[ -n "${t}" ]] || continue
        if [[ "${t}" == *$'\t'* ]]; then
            name="${t%%$'\t'*}"
            id="${t#*$'\t'}"
            [[ -n "${name}" ]] && available["${name}"]=1
            if [[ -n "${id}" ]]; then
                available_ids["${id}"]=1
                have_ids=1
            fi
        else
            available["${t}"]=1
        fi
    done

    local -a problems=()
    local path="${CONFIG_LOADED_PATH}"
    # Track whether ANY on_absent substitution mutated the resolved mapping. A
    # substitution can change a level's artifact away from its declared type
    # (e.g. a parent level Epic → Task), which can INVALIDATE a child's
    # relationship that the OFFLINE matrix (mapping::validate, run earlier on the
    # PRE-substitution mapping) already passed — most notably an `Epic-link`
    # child whose parent no longer projects to an Epic (NF1). When a
    # substitution happens we MUST re-run the relationship matrix against the
    # POST-substitution mapping before the single fail-closed exit below.
    local substituted=0

    local lvl
    for lvl in "${CONFIG_MAPPING_LEVELS[@]}"; do
        local artifact="${CONFIG_VALUES[mapping.levels.${lvl}.artifact]:-}"
        # The checklist sentinel projects no issue type — exempt from the probe.
        if [[ -z "${artifact}" || "${artifact}" == "checklist" ]]; then
            continue
        fi
        # Available? When the probe supplied ids and the artifact has an
        # issue_types binding, match by the RESOLVED id (the type actually
        # POSTed) — so an alias name that differs from the live display name
        # (e.g. story→a "Task" id on Kanban) still validates. Otherwise fall back
        # to matching the alias name (legacy callers, or a purely-named operator
        # artifact with no issue_types binding).
        local rid
        rid="$(mapping::_artifact_type_id "${artifact}")"
        if (( have_ids == 1 )) && [[ -n "${rid}" ]]; then
            [[ -n "${available_ids[${rid}]:-}" ]] && continue
        else
            [[ -n "${available[${artifact}]:-}" ]] && continue
        fi
        # Absent. The ONLY escape is a per-level on_absent fallback whose value is
        # itself available (by the same id-or-name rule). A fallback that is also
        # absent still hard-errors.
        local fallback="${CONFIG_VALUES[mapping.levels.${lvl}.on_absent]:-}"
        if [[ -n "${fallback}" ]]; then
            local frid fok=0
            frid="$(mapping::_artifact_type_id "${fallback}")"
            if (( have_ids == 1 )) && [[ -n "${frid}" ]]; then
                [[ -n "${available_ids[${frid}]:-}" ]] && fok=1
            else
                [[ -n "${available[${fallback}]:-}" ]] && fok=1
            fi
            if (( fok == 1 )); then
                # RESCUE — and SUBSTITUTE: the gate honors the fallback here, but
                # the WRITE path resolves the artifact via mapping::resolve_level
                # (which reads mapping.levels.<lvl>.artifact). Without writing the
                # fallback back into the resolved mapping, the projection would
                # POST the ABSENT primary's issue-type id (F2/F5). Write the
                # fallback into the level's artifact so resolve_level / the sink
                # project the type the project actually offers (FR-006). Clear the
                # now-satisfied on_absent so resolve_level no longer advertises a
                # pending fallback for an already-substituted level.
                CONFIG_VALUES[mapping.levels.${lvl}.artifact]="${fallback}"
                CONFIG_VALUES[mapping.levels.${lvl}.on_absent]=""
                substituted=1
                continue
            fi
            problems+=("${path}: mapping.levels.${lvl}: artifact '${artifact}' is absent from the project and its on_absent fallback '${fallback}' is also absent (no available substitute)")
            continue
        fi
        problems+=("${path}: mapping.levels.${lvl}: artifact '${artifact}' is not an available issue type in project ${CONFIG_VALUES[project_key]:-<unknown>} (set an on_absent fallback to an available type, or pick a type the project offers)")
    done

    # NF1 — re-validate the relationship matrix against the POST-substitution
    # mapping. The offline matrix (mapping::validate) ran BEFORE the probe, on the
    # PRE-substitution artifacts; an on_absent substitution that moved a parent
    # level away from Epic could leave a child `Epic-link` invalid yet unrejected.
    # Re-running the matrix here closes that hole, fail-closed (exit 2, zero
    # writes), and only when a substitution actually occurred (so the default /
    # no-fallback path pays no cost and reports no duplicate matrix findings).
    if (( substituted == 1 )); then
        mapping::validate_relationships problems
    fi

    if (( ${#problems[@]} > 0 )); then
        config::_warn "available-type validation failed for ${path}:"
        local problem
        for problem in "${problems[@]}"; do
            printf '  - %s\n' "${problem}" >&2
        done
        exit 2
    fi

    return 0
}
