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
# workstate::_notes_json <spec_dir>
#
# Builds the item's `notes[]` array (kind=comment annotations) from the spec's
# recorded clarification/decision sessions under `## Clarifications`. One note
# per `### Session YYYY-MM-DD` block: `{ body, timestamp_iso }` where body is the
# session heading + its verbatim bullet lines (Markdown) and timestamp_iso is the
# session date. These map to at-most-once Jira comments in the sink (US4 /
# FR-007). Echoes a JSON array (possibly `[]`). Built entirely with jq (no
# string splicing) so bullet text is always well-formed JSON.
# ---------------------------------------------------------------------------
workstate::_notes_json() {
    local spec_dir="${1%/}"
    local spec_md="${spec_dir}/spec.md"
    [[ -s "$spec_md" ]] || { printf '[]'; return 0; }

    local note_objs=()
    local session_date _bullet_count
    while IFS=$'\t' read -r session_date _bullet_count; do
        : "${_bullet_count:-}"
        [[ -n "$session_date" ]] || continue
        local bullets body note
        bullets="$(parser::clarify_session_bullets "$spec_md" "$session_date")"
        body="$(printf '### Session %s\n\n%s' "$session_date" "$bullets")"
        note="$(jq -n \
            --arg ts "${session_date}T00:00:00+00:00" \
            --arg body "$body" \
            '{ timestamp_iso: $ts, body: $body }')"
        note_objs+=("$note")
    done < <(parser::clarify_sessions "$spec_md")

    if (( ${#note_objs[@]} > 0 )); then
        printf '%s\n' "${note_objs[@]}" | jq -cs '.'
    else
        printf '[]'
    fi
}

# ---------------------------------------------------------------------------
# workstate::_decisions_json <spec_dir>
#
# Builds the spec's decision records (ADRs) from its `research.md` via
# parser::decision_records. One object per decision block:
#   { id, title, decision, rationale, alternatives, source }
# where `source` is `research.md#<id>` (the back-reference) and `alternatives`
# is the verbatim "Alternatives rejected" text (a string; empty when absent).
#
# This is a vendor-NEUTRAL floor extension (Principle X): it rides on the item's
# `extensions.decisions[]` (the schema's escape hatch for rich producers,
# `additionalProperties:true`), so it adds NO new top-level item field and the
# emitted document stays Draft-2020-12 schema-valid. The sink consumes it to
# mirror each ADR as an at-most-once spec-Issue comment.
#
# Echoes a JSON array (possibly `[]`). Empty when there is no research.md or no
# decision blocks. Built entirely with jq from the parser's NUL/US-framed stream
# (no string splicing) so multi-line values are always well-formed JSON.
# ---------------------------------------------------------------------------
workstate::_decisions_json() {
    local spec_dir="${1%/}"
    local research_md="${spec_dir}/research.md"
    [[ -s "$research_md" ]] || { printf '[]'; return 0; }

    # The parser emits NUL-terminated records, fields split by the ASCII Unit
    # Separator (U+001F): id US title US decision US rationale US alternatives.
    # Read the raw bytes with --raw-input --slurp, split on NUL, drop the
    # trailing empty chunk, then split each record on US into the named fields.
    local out
    out="$(parser::decision_records "$research_md" \
        | jq -R -s '
            [ split("\u0000")[]
              | select(length > 0)
              | split("\u001f")
              | {
                  id:           (.[0] // ""),
                  title:        (.[1] // ""),
                  decision:     (.[2] // ""),
                  rationale:    (.[3] // ""),
                  alternatives: (.[4] // ""),
                  source:       ("research.md#" + (.[0] // ""))
                }
            ]
        ' 2>/dev/null)" || out='[]'
    [[ -n "$out" ]] || out='[]'
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# workstate::_links_json <spec_dir>
#
# Builds the item's `links[]` array (typed non-containment relations) from the
# spec's cross-spec dependency declarations. Convention: a `## Dependencies`
# section in spec.md whose bullets name a rel + a target feature number, e.g.
#     - depends_on: 002
#     - blocks: 003-other-spec
# Each becomes `{ rel, target }` (target = the bare feature number / spec id).
# These map to Jira issue links in the sink (US4 / FR-007). Echoes a JSON array
# (possibly `[]`). Unknown rels pass through (the sink acts only on
# `depends_on`/`blocks`).
# ---------------------------------------------------------------------------
workstate::_links_json() {
    local spec_dir="${1%/}"
    local spec_md="${spec_dir}/spec.md"
    [[ -s "$spec_md" ]] || { printf '[]'; return 0; }

    local rows
    rows="$(awk '
        /^## Dependencies[[:space:]]*$/ { in_section = 1; next }
        /^## / { if (in_section) in_section = 0; next }
        in_section && /^-[[:space:]]+/ {
            line = $0
            sub(/^-[[:space:]]+/, "", line)
            ci = index(line, ":")
            if (ci == 0) next
            rel = substr(line, 1, ci - 1)
            target = substr(line, ci + 1)
            gsub(/[[:space:]]/, "", rel)
            sub(/^[[:space:]]+/, "", target)
            sub(/[[:space:]]+$/, "", target)
            if (rel != "" && target != "") {
                printf "%s\t%s\n", rel, target
            }
        }
    ' "$spec_md")"

    [[ -n "$rows" ]] || { printf '[]'; return 0; }

    printf '%s\n' "$rows" | jq -R -s '
        [ split("\n")[]
          | select(length > 0)
          | split("\t")
          | { rel: .[0], target: .[1] }
        ]
    '
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
# workstate::item_for_spec <spec_dir> [generated_iso_unused] [state_hint]
#
# Maps one spec directory (`specs/NNN-<short>/`) to a single workstate item
# (kind="spec") and prints it as JSON on stdout. Returns non-zero (and emits
# nothing) when spec.md is absent/empty — the caller should skip + warn.
#
# Item fields populated (floor subset, contracts/workstate.md):
#   id            "<NNN>-<short-name>"            (stable idempotency key)
#   title         spec.md heading
#   kind          "spec"
#   state         parser::lifecycle_phase token (or the caller's state_hint)
#   body          spec.md Summary section          (omitted when empty)
#   labels        ["speckit-spec:<NNN>"]
#   item_source   { path, last_commit_iso }
#   links         []   (cross-spec deps; floor placeholder for now)
#   notes         []   (clarify sessions; floor placeholder for now)
#   children      one per task phase (kind="task")
#
# The second arg is accepted for signature symmetry but unused at item level;
# `generated_iso` lives on the document's `source`, not per item.
#
# The OPTIONAL third arg is a pre-computed lifecycle-phase token (a neutral
# `workflow_state_uuids` key such as `merged`/`ready_to_merge`). When supplied
# it OVERRIDES the artifact-ladder inference for the item's `state`. The
# producer's filesystem ladder (parser::lifecycle_phase) cannot see git
# merge/PR state — that signal lives in the engine, which already resolves it
# once per spec via git_helpers::pr_state. Passing the engine's resolved token
# in keeps merge-detection vendor-neutral (it stays an engine/parser concern,
# never a Jira concern) while ensuring a spec read as `merged` actually carries
# `state: "merged"` so the sink's merged→Done transition fires. Empty / omitted
# → fall back to the artifact-ladder inference unchanged.
# ---------------------------------------------------------------------------
workstate::item_for_spec() {
    local spec_dir="${1%/}"
    # Second positional arg intentionally unused (document-level concern).
    local state_hint="${3:-}"

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
    local title state body label path last_commit_iso notes_json links_json decisions_json
    title="$(workstate::_spec_title "$spec_dir")"
    # Prefer the engine's pre-resolved lifecycle token (it folds in git
    # merge/PR state the filesystem ladder cannot see); otherwise infer from
    # artifacts on disk.
    if [[ -n "$state_hint" ]]; then
        state="$state_hint"
    else
        state="$(parser::lifecycle_phase "$spec_dir" || true)"
    fi
    [[ -n "$state" ]] || state="specifying"
    state="$(workstate::_normalize_phase "$state")"
    body="$(workstate::_spec_body "$spec_dir")"
    label="speckit-spec:${feature_number}"
    path="${spec_dir}/"
    last_commit_iso="$(workstate::_last_commit_iso "$spec_dir")"
    # Clarify/decision sessions → notes[]; cross-spec deps → links[] (US4).
    notes_json="$(workstate::_notes_json "$spec_dir")"
    [[ -n "$notes_json" ]] || notes_json='[]'
    links_json="$(workstate::_links_json "$spec_dir")"
    [[ -n "$links_json" ]] || links_json='[]'
    # research.md decision records (ADRs) → extensions.decisions[] (neutral floor
    # extension; the sink mirrors each as an at-most-once spec-Issue comment).
    decisions_json="$(workstate::_decisions_json "$spec_dir")"
    [[ -n "$decisions_json" ]] || decisions_json='[]'

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
        --argjson notes "$notes_json" \
        --argjson links "$links_json" \
        --argjson decisions "$decisions_json" \
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
            links: $links,
            notes: $notes,
            children: $children
        }
        + (if $body == "" then {} else { body: $body } end)
        + (if ($decisions | length) == 0 then {}
           else { extensions: { decisions: $decisions } } end)'
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

# ---------------------------------------------------------------------------
# workstate-direct input (feature-002 US5) — read + on-entry validation.
#
# The reconcile entrypoint accepts a `workstate` document directly via
# `--workstate <PATH | ->`, skipping the spec-kit parser so any producer can
# drive the sink (FR-015/FR-016, Principle X). The document is validated on
# entry, before any write; a malformed / schema-invalid / unpinned document is
# rejected fail-closed (rc 2, nothing written).
# ---------------------------------------------------------------------------

# workstate::read_document <PATH | ->
#   Echo the raw document content from a file PATH or, when the argument is `-`,
#   from standard input. rc 2 when a file path is missing/unreadable (input
#   error, no write). stdin is read verbatim (the caller validates the bytes).
workstate::read_document() {
    local src="${1:-}"
    if [[ "$src" == "-" ]]; then
        cat
        return 0
    fi
    if [[ -z "$src" || ! -r "$src" ]]; then
        printf 'spec-kit-jira-sync: --workstate file not found or unreadable: %q\n' "$src" >&2
        return 2
    fi
    cat -- "$src"
}

# workstate::validate_document <json>
#   Validate a workstate document on entry. Returns 0 when acceptable, 2 when
#   the document is malformed / schema-invalid / unpinned (fail-closed, no
#   write). Two tiers:
#     (1) ALWAYS-ON dependency-free floor (jq): valid JSON; `schema_version`
#         present AND equal to the pinned WORKSTATE_SCHEMA_VERSION; `source.repo`
#         present; `items` a non-empty array; every item carries the required
#         floor fields (id, title, kind, state). This rejects malformed,
#         unpinned, and structurally schema-invalid documents.
#     (2) BEST-EFFORT full Draft-2020-12 validation: when a jsonschema runner
#         (python3 + jsonschema) AND the published schema resolve (WORKSTATE_SCHEMA
#         or WORKSTATE_SCHEMA_REPO/schema/workstate.schema.json), run full schema
#         conformance and reject on failure. When unavailable, the floor stands
#         and a note is logged (no silent skip).
workstate::validate_document() {
    local doc="${1:-}"

    # (1) Valid JSON?
    if ! printf '%s' "$doc" | jq -e . >/dev/null 2>&1; then
        printf 'spec-kit-jira-sync: --workstate input is not valid JSON (rejected, no write)\n' >&2
        return 2
    fi

    # Pinned schema_version?
    local ver
    ver="$(printf '%s' "$doc" | jq -r '.schema_version // ""' 2>/dev/null || printf '')"
    if [[ "$ver" != "$WORKSTATE_SCHEMA_VERSION" ]]; then
        printf 'spec-kit-jira-sync: --workstate schema_version %q is not the supported %q (rejected, no write)\n' \
            "$ver" "$WORKSTATE_SCHEMA_VERSION" >&2
        return 2
    fi

    # Structural floor: source.repo + non-empty items[] each with id/title/kind/state.
    if ! printf '%s' "$doc" | jq -e '
        ((.source.repo // "") | length > 0)
        and ((.items // []) | type == "array")
        and ((.items | length) > 0)
        and (.items | all(.[];
              ((.id // "") | length > 0)
              and ((.title // "") | length > 0)
              and ((.kind // "") | length > 0)
              and ((.state // "") | length > 0)))
    ' >/dev/null 2>&1; then
        printf 'spec-kit-jira-sync: --workstate document fails the workstate structural floor (rejected, no write)\n' >&2
        return 2
    fi

    # (2) Best-effort full Draft-2020-12 validation when a runner + schema exist.
    local schema=""
    if [[ -n "${WORKSTATE_SCHEMA:-}" && -f "${WORKSTATE_SCHEMA}" ]]; then
        schema="${WORKSTATE_SCHEMA}"
    elif [[ -n "${WORKSTATE_SCHEMA_REPO:-}" && -f "${WORKSTATE_SCHEMA_REPO}/schema/workstate.schema.json" ]]; then
        schema="${WORKSTATE_SCHEMA_REPO}/schema/workstate.schema.json"
    fi
    if [[ -n "$schema" ]] && command -v python3 >/dev/null 2>&1 \
        && python3 -c 'import jsonschema' >/dev/null 2>&1; then
        # The validator script comes in on stdin via the heredoc, so the document
        # must be passed as a FILE arg (NOT piped to stdin — the heredoc owns it).
        local _docfile; _docfile="$(mktemp "${TMPDIR:-/tmp}/ws-doc.XXXXXX")"
        printf '%s' "$doc" >"$_docfile"
        local _vrc=0
        python3 - "$schema" "$_docfile" >/dev/null 2>&1 <<'PY' || _vrc=$?
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1]))
doc = json.load(open(sys.argv[2]))
jsonschema.Draft202012Validator.check_schema(schema)
jsonschema.Draft202012Validator(schema).validate(doc)
PY
        rm -f "$_docfile"
        if (( _vrc != 0 )); then
            printf 'spec-kit-jira-sync: --workstate document failed full schema validation (rejected, no write)\n' >&2
            return 2
        fi
    else
        workstate::_log_validation_degraded
    fi
    return 0
}

# Emit (once) a note that full schema validation was skipped — no silent cap.
workstate::_log_validation_degraded() {
    [[ -z "${_WORKSTATE_VALIDATION_DEGRADED_LOGGED:-}" ]] || return 0
    _WORKSTATE_VALIDATION_DEGRADED_LOGGED=1
    printf 'spec-kit-jira-sync: note — full workstate schema validation unavailable (no jsonschema runner / schema); applied the structural floor + version pin only\n' >&2
}
