#!/usr/bin/env bash
# shellcheck shell=bash
#
# workstate.sh — turn parsed spec-kit specs into schema-valid `workstate` JSON.
#
# The `workstate` format (workstate-schema/schema/workstate.schema.json,
# Draft 2020-12) is the bridge's neutral internal contract: this producer
# emits it, the Jira sink consumes ONLY it (Principle X / FR-003, FR-020).
#
# This module SOURCES src/parser.sh (the spec-kit reader) and maps every spec
# directory under `specs/NNN-*/` to one `workstate` item (kind="spec"), with
# one child per task phase (kind="task") carrying the per-task checklist under
# `children[].extensions.tasks` — a floor-safe extension sinks ignore if they
# do not understand it.
#
# Public functions (all prefixed `workstate::`):
#   workstate::item_for_spec <spec_dir> [generated_iso_unused]
#   workstate::document_for_repo <specs_root> [repo_slug] [generated_iso]
#
# ALL JSON is built with jq (never string-concatenated) so quoting,
# escaping and structure are always well-formed.
#
# TIME: this module NEVER calls `date` (the harness blocks it). The document's
# `source.generated_iso` is supplied by the caller (argument or
# WORKSTATE_GENERATED_ISO env), defaulting to the empty string. Per-item
# `last_commit_iso` is the git committer date of the spec dir, overridable via
# the WORKSTATE_LAST_COMMIT_ISO env (so fixture-driven tests need no commits).
#
# This file is a library: it does NOT enable `set -euo pipefail` on the
# calling shell (Principle VIII Rule 1). Entry-point scripts own their own
# shell options before sourcing this module.

# Resolve this module's own directory so we can source siblings regardless of
# the caller's CWD (agent worktrees reset CWD between calls).
_WORKSTATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=src/parser.sh disable=SC1091
. "${_WORKSTATE_DIR}/parser.sh"

# Schema version this producer targets (data-model.md §1).
WORKSTATE_SCHEMA_VERSION="${WORKSTATE_SCHEMA_VERSION:-0.1.0}"

# ---------------------------------------------------------------------------
# workstate::_spec_title <spec_dir>
#
# Echoes the spec's human title from the first `# ` heading in spec.md,
# stripping a leading `Feature Specification:` label if present (spec-kit's
# canonical heading shape). Falls back to the short_name when spec.md has no
# heading. Empty spec.md → empty output (caller treats as skip).
# ---------------------------------------------------------------------------
workstate::_spec_title() {
    local spec_dir="${1%/}"
    local spec_md="${spec_dir}/spec.md"
    [[ -s "$spec_md" ]] || return 0
    local title
    title="$(awk '
        /^# / {
            line = $0
            sub(/^# /, "", line)
            sub(/^[Ff]eature [Ss]pecification:[[:space:]]*/, "", line)
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
            exit
        }
    ' "$spec_md")"
    if [[ -z "$title" ]]; then
        title="$(parser::short_name "$spec_dir" || true)"
    fi
    printf '%s\n' "$title"
}

# ---------------------------------------------------------------------------
# workstate::_spec_body <spec_dir>
#
# Echoes the spec body for the issue description: the contents of the
# `## Summary` section of spec.md (up to the next `## ` heading), trimmed.
# Empty output when no Summary section exists — `body` is optional on the
# floor, so the item simply omits it.
# ---------------------------------------------------------------------------
workstate::_spec_body() {
    local spec_dir="${1%/}"
    local spec_md="${spec_dir}/spec.md"
    [[ -s "$spec_md" ]] || return 0
    awk '
        /^## Summary[[:space:]]*$/ { in_section = 1; next }
        /^## / { if (in_section) exit }
        in_section { print }
    ' "$spec_md" | awk '
        # Trim leading/trailing blank lines from the captured block.
        { lines[NR] = $0 }
        END {
            start = 1; end = NR
            while (start <= end && lines[start] ~ /^[[:space:]]*$/) start++
            while (end >= start && lines[end] ~ /^[[:space:]]*$/) end--
            for (i = start; i <= end; i++) print lines[i]
        }
    '
}

# ---------------------------------------------------------------------------
# workstate::_last_commit_iso <spec_dir>
#
# Echoes the ISO-8601 committer date of the most recent commit touching the
# spec dir (the drift/recency key — git-backed, never mtime). Overridable via
# WORKSTATE_LAST_COMMIT_ISO so fixture-driven tests need no committed spec
# dirs. Empty output when neither is available (field is optional).
# ---------------------------------------------------------------------------
workstate::_last_commit_iso() {
    local spec_dir="${1%/}"
    if [[ -n "${WORKSTATE_LAST_COMMIT_ISO:-}" ]]; then
        printf '%s\n' "$WORKSTATE_LAST_COMMIT_ISO"
        return 0
    fi
    local iso
    # The pathspec is relative to the -C working dir, so scope to that dir
    # itself ('.'), not "$spec_dir" again: a repo-relative path would otherwise
    # resolve under itself, match no commits, and drop the recency signal
    # (codex review P2).
    iso="$(git -C "$spec_dir" log -1 --format=%cI -- . 2>/dev/null || true)"
    if [[ -n "$iso" ]]; then
        printf '%s\n' "$iso"
    fi
}

# ---------------------------------------------------------------------------
# workstate::_normalize_phase <parser_phase>
#
# parser::lifecycle_phase emits a richer internal vocabulary (clarifying,
# red_team, analyzing) than the documented 6-phase lifecycle the sink's config
# maps (data-model §3). Collapse the intermediate states onto a supported phase
# before emission, or a spec mid-clarify/red-team/analyze would emit a state
# config rejects with an unknown-phase error (codex review P1). The producer
# owns its emitted vocabulary; here it chooses the documented six.
# ---------------------------------------------------------------------------
workstate::_normalize_phase() {
    case "$1" in
        clarifying)          printf 'specifying\n' ;;
        red_team|analyzing)  printf 'implementing\n' ;;
        specifying|planning|tasking|implementing|ready_to_merge|merged)
                             printf '%s\n' "$1" ;;
        *)                   printf '%s\n' "$1" ;;  # unknown: pass through; sink surfaces it
    esac
}

# ---------------------------------------------------------------------------
# workstate::_phase_state <phase_index> <tasks_md>
#
# Derives a child (task-phase) lifecycle token from its checkbox state:
#   - every task checked      → "done"
#   - some but not all checked → "in_progress"
#   - none checked            → "todo"
#   - phase with zero tasks    → "todo"
# A free-string state token, per the floor (sinks map it).
# ---------------------------------------------------------------------------
workstate::_phase_state() {
    local phase_index="$1"
    local tasks_md="$2"
    local id state desc est total=0 checked=0
    while IFS=$'\t' read -r id state desc est; do
        : "${id:-}${desc:-}${est:-}"
        total=$(( total + 1 ))
        [[ "$state" == "checked" ]] && checked=$(( checked + 1 ))
    done < <(parser::tasks_in_phase "$tasks_md" "$phase_index")

    if (( total == 0 )); then
        printf 'todo\n'
    elif (( checked == total )); then
        printf 'done\n'
    elif (( checked > 0 )); then
        printf 'in_progress\n'
    else
        printf 'todo\n'
    fi
}

# ---------------------------------------------------------------------------
# workstate::_phase_child <feature_number> <phase_index> <phase_name> <tasks_md>
#
# Emits the JSON object for one task-phase child (kind="task") on stdout:
#   { id, title:"Phase N — <name>", kind:"task", state,
#     extensions: { tasks: [ { text, done } ] } }
# The per-task checklist is built with jq from a NUL/tab-delimited stream so
# task text is never string-spliced into JSON.
# ---------------------------------------------------------------------------
workstate::_phase_child() {
    local feature_number="$1"
    local phase_index="$2"
    local phase_name="$3"
    local tasks_md="$4"

    local child_id="${feature_number}-phase-${phase_index}"
    local child_title="Phase ${phase_index} — ${phase_name}"
    local child_state
    child_state="$(workstate::_phase_state "$phase_index" "$tasks_md")"

    # Build the tasks[] array: one row per task as {text, done}. Feed jq a
    # tab-delimited record stream split into raw strings; map "checked" → true.
    local tasks_json
    tasks_json="$(
        parser::tasks_in_phase "$tasks_md" "$phase_index" \
        | jq -R -s '
            [ split("\n")[]
              | select(length > 0)
              | split("\t")
              | { text: (.[2] // ""), done: (.[1] == "checked") }
            ]
        '
    )"
    # Guard: empty phase yields an empty array, not null.
    [[ -n "$tasks_json" ]] || tasks_json='[]'

    jq -n \
        --arg id "$child_id" \
        --arg title "$child_title" \
        --arg state "$child_state" \
        --argjson tasks "$tasks_json" \
        '{
            id: $id,
            title: $title,
            kind: "task",
            state: $state,
            extensions: { tasks: $tasks }
        }'
}

# ---------------------------------------------------------------------------
# workstate::item_for_spec <spec_dir> [generated_iso_unused]
#
# Maps one spec directory (`specs/NNN-<short>/`) to a single workstate item
# (kind="spec") and prints it as JSON on stdout. Returns non-zero (and emits
# nothing) when spec.md is absent/empty — the caller should skip + warn.
#
# Item fields populated (floor subset, contracts/workstate.md):
#   id            "<NNN>-<short-name>"            (stable idempotency key)
#   title         spec.md heading
#   kind          "spec"
#   state         parser::lifecycle_phase token
#   body          spec.md Summary section          (omitted when empty)
#   labels        ["speckit-spec:<NNN>"]
#   item_source   { path, last_commit_iso }
#   links         []   (cross-spec deps; floor placeholder for now)
#   notes         []   (clarify sessions; floor placeholder for now)
#   children      one per task phase (kind="task")
#
# The second arg is accepted for signature symmetry but unused at item level;
# `generated_iso` lives on the document's `source`, not per item.
# ---------------------------------------------------------------------------
workstate::item_for_spec() {
    local spec_dir="${1%/}"
    # Second positional arg intentionally unused (document-level concern).

    local spec_md="${spec_dir}/spec.md"
    local tasks_md="${spec_dir}/tasks.md"

    if [[ ! -s "$spec_md" ]]; then
        return 1
    fi

    local feature_number short_name
    feature_number="$(parser::feature_number "$spec_dir" || true)"
    short_name="$(parser::short_name "$spec_dir" || true)"
    if [[ -z "$feature_number" || -z "$short_name" ]]; then
        return 1
    fi

    local item_id="${feature_number}-${short_name}"
    local title state body label path last_commit_iso
    title="$(workstate::_spec_title "$spec_dir")"
    state="$(parser::lifecycle_phase "$spec_dir" || true)"
    [[ -n "$state" ]] || state="specifying"
    state="$(workstate::_normalize_phase "$state")"
    body="$(workstate::_spec_body "$spec_dir")"
    label="speckit-spec:${feature_number}"
    path="${spec_dir}/"
    last_commit_iso="$(workstate::_last_commit_iso "$spec_dir")"

    # Build the children[] array from the task phases (may be empty).
    local children_json='[]'
    if [[ -f "$tasks_md" ]]; then
        local phase_objs=()
        local phase_index phase_name child
        while IFS=$'\t' read -r phase_index phase_name; do
            [[ -n "$phase_index" ]] || continue
            child="$(workstate::_phase_child \
                "$feature_number" "$phase_index" "$phase_name" "$tasks_md")"
            phase_objs+=("$child")
        done < <(parser::task_phases "$tasks_md")

        if (( ${#phase_objs[@]} > 0 )); then
            children_json="$(printf '%s\n' "${phase_objs[@]}" | jq -s '.')"
        fi
    fi

    # Assemble the item. `body` is added only when non-empty (floor: optional).
    jq -n \
        --arg id "$item_id" \
        --arg title "$title" \
        --arg state "$state" \
        --arg body "$body" \
        --arg label "$label" \
        --arg path "$path" \
        --arg last_commit_iso "$last_commit_iso" \
        --argjson children "$children_json" \
        '{
            id: $id,
            title: $title,
            kind: "spec",
            state: $state,
            labels: [ $label ],
            item_source: (
                { path: $path }
                + (if $last_commit_iso == "" then {}
                   else { last_commit_iso: $last_commit_iso } end)
            ),
            links: [],
            notes: [],
            children: $children
        }
        + (if $body == "" then {} else { body: $body } end)'
}

# ---------------------------------------------------------------------------
# workstate::document_for_repo <specs_root> [repo_slug] [generated_iso]
#
# Builds a complete, schema-valid `workstate` document for every spec under
# <specs_root>/NNN-*/ and prints it as JSON on stdout.
#
#   schema_version  WORKSTATE_SCHEMA_VERSION
#   source          { system:"spec-kit", repo:<slug>, generated_iso }
#   items[]         one per spec dir (kind="spec"), in numeric dir order
#
# <repo_slug> defaults to the basename of <specs_root>'s parent (the repo
# checkout dir). <generated_iso> defaults to WORKSTATE_GENERATED_ISO then "".
# Spec dirs whose spec.md is absent/empty are skipped silently (the item
# producer returns non-zero).
# ---------------------------------------------------------------------------
workstate::document_for_repo() {
    local specs_root="${1%/}"
    local repo_slug="${2:-}"
    local generated_iso="${3:-${WORKSTATE_GENERATED_ISO:-}}"

    if [[ -z "$repo_slug" ]]; then
        repo_slug="$(basename "$(dirname "$specs_root")")"
    fi

    local item_objs=()
    local spec_dir item
    # Iterate spec dirs in lexical (== numeric, zero-padded) order.
    for spec_dir in "${specs_root}"/[0-9][0-9][0-9]-*/; do
        [[ -d "$spec_dir" ]] || continue
        if item="$(workstate::item_for_spec "$spec_dir")"; then
            item_objs+=("$item")
        fi
    done

    local items_json='[]'
    if (( ${#item_objs[@]} > 0 )); then
        items_json="$(printf '%s\n' "${item_objs[@]}" | jq -s '.')"
    fi

    jq -n \
        --arg schema_version "$WORKSTATE_SCHEMA_VERSION" \
        --arg repo "$repo_slug" \
        --arg generated_iso "$generated_iso" \
        --argjson items "$items_json" \
        '{
            schema_version: $schema_version,
            source: {
                system: "spec-kit",
                repo: $repo,
                generated_iso: $generated_iso
            },
            items: $items
        }'
}
