#!/usr/bin/env bash
# ORIGIN: copied unchanged from spec-kit-linear/src/parser.sh @ 7dbe6bd
# Shared engine/infra, pending extraction (PLAN.md §5/§11). Do not edit logic here.
# shellcheck shell=bash
#
# parser.sh — markdown parser for spec-kit artifacts.
#
# Public functions (all prefixed `parser::`):
#   parser::feature_number <spec_dir>
#   parser::short_name <spec_dir>
#   parser::lifecycle_phase <spec_dir> [pr_state]
#   parser::task_phases <tasks_md_path>
#   parser::tasks_in_phase <tasks_md_path> <phase_index>
#   parser::phase_estimate <tasks_md_path> <phase_index>
#   parser::spec_estimate <tasks_md_path>
#   parser::malformed_task_lines <tasks_md_path>
#   parser::clarify_sessions <spec_md_path>
#   parser::clarify_session_bullets <spec_md_path> <date>
#   parser::decision_records <research_md_path>
#
# Implements the filesystem-side parser invariants documented in
# specs/001-spec-kit-linear-bridge/data-model.md §2.3-2.4 and the
# phase-inference ladder in spec FR-012 / FR-013 / FR-014.
#
# Vocabulary follows constitution Principle VIII: canonical spec-kit
# terms only (`## Phase N: <Name>` for task groupings, lifecycle phase
# identifiers from data-model.md `workflow_state_uuids` keys).
#
# This file is a library: it does NOT enable `set -euo pipefail` on
# the calling shell. Each top-level entry-point script in `src/` is
# responsible for setting its own shell options before sourcing this
# module (Principle VIII Rule 1: observable failure surfaces stay at
# the entry point, not in every library).

# ---------------------------------------------------------------------------
# parser::feature_number <spec_dir>
#
# Extracts the leading 3-digit feature number from the spec directory's
# basename (e.g. `specs/001-foo/` → `001`). Trailing slash tolerated.
# Empty output (and non-zero exit) when the basename does not start
# with `NNN-`.
# ---------------------------------------------------------------------------
parser::feature_number() {
    local spec_dir="$1"
    local base
    base="$(basename "${spec_dir%/}")"
    if [[ "$base" =~ ^([0-9]{3})- ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# parser::short_name <spec_dir>
#
# Extracts the kebab-case slug after `NNN-` from the spec directory's
# basename (e.g. `001-spec-kit-linear-bridge` →
# `spec-kit-linear-bridge`). Empty output (and non-zero exit) when the
# basename does not follow the `NNN-<slug>` shape.
# ---------------------------------------------------------------------------
parser::short_name() {
    local spec_dir="$1"
    local base
    base="$(basename "${spec_dir%/}")"
    if [[ "$base" =~ ^[0-9]{3}-(.+)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# parser::_has_clarifications_section <spec_md_path>
#
# Returns 0 iff `spec.md` contains a literal `## Clarifications`
# heading followed (anywhere later in the file) by at least one
# `### Session YYYY-MM-DD` subheading.
# ---------------------------------------------------------------------------
parser::_has_clarifications_section() {
    local spec_md="$1"
    [[ -f "$spec_md" ]] || return 1
    awk '
        /^## Clarifications[[:space:]]*$/ { in_section = 1; next }
        /^## / && in_section { exit }
        in_section && /^### Session [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
            found = 1
            exit
        }
        END { exit (found ? 0 : 1) }
    ' "$spec_md"
}

# ---------------------------------------------------------------------------
# parser::_has_checked_tasks <tasks_md_path>
#
# Returns 0 iff at least one `- [x]` checked task line exists in
# `tasks.md`. Case-insensitive on the `x` per common markdown variants.
# ---------------------------------------------------------------------------
parser::_has_checked_tasks() {
    local tasks_md="$1"
    [[ -f "$tasks_md" ]] || return 1
    grep -Eiq '^- \[x\] ' "$tasks_md"
}

# ---------------------------------------------------------------------------
# parser::lifecycle_phase <spec_dir> [pr_state]
#
# Infers the spec's current lifecycle phase from filesystem artifacts
# per spec FR-012 + FR-013 + data-model.md §6.1. Walks the inference
# ladder bottom-up, returning the highest-precedence phase whose
# trigger artifacts are present. Output is one of the canonical
# `workflow_state_uuids` keys:
#
#   specifying | clarifying | planning | tasking | red_team |
#   implementing | analyzing | ready_to_merge | merged
#
# Optional second arg is a caller-supplied PR state hint
# (`open` | `ready` | `merged`) emitted by `git_helpers::pr_state`;
# the parser stays decoupled from `gh`/git and never shells out.
#
# `spec.md` absent / empty → exits non-zero (caller should skip and
# warn per spec edge case §1).
# ---------------------------------------------------------------------------
parser::lifecycle_phase() {
    local spec_dir="$1"
    local pr_state="${2:-}"

    local spec_md="${spec_dir%/}/spec.md"
    local plan_md="${spec_dir%/}/plan.md"
    local tasks_md="${spec_dir%/}/tasks.md"

    if [[ ! -s "$spec_md" ]]; then
        return 1
    fi

    # PR hints short-circuit to terminal states regardless of artifact
    # ladder (FR-013, FR-014: retroactive sync lands directly).
    case "$pr_state" in
        merged)
            printf 'merged\n'
            return 0
            ;;
        open|ready|ready_for_review)
            printf 'ready_to_merge\n'
            return 0
            ;;
    esac

    local has_red_team=0 has_analyze=0
    if compgen -G "${spec_dir%/}/red-team*.md" >/dev/null; then
        has_red_team=1
    fi
    if compgen -G "${spec_dir%/}/analyze*.md" >/dev/null; then
        has_analyze=1
    fi

    if [[ "$has_analyze" -eq 1 ]]; then
        printf 'analyzing\n'
        return 0
    fi

    if [[ -f "$tasks_md" ]] && parser::_has_checked_tasks "$tasks_md"; then
        printf 'implementing\n'
        return 0
    fi

    if [[ "$has_red_team" -eq 1 ]]; then
        printf 'red_team\n'
        return 0
    fi

    if [[ -f "$tasks_md" ]]; then
        printf 'tasking\n'
        return 0
    fi

    if [[ -f "$plan_md" ]]; then
        printf 'planning\n'
        return 0
    fi

    if parser::_has_clarifications_section "$spec_md"; then
        printf 'clarifying\n'
        return 0
    fi

    printf 'specifying\n'
}

# ---------------------------------------------------------------------------
# parser::task_phases <tasks_md_path>
#
# Emits one line per `## Phase N: <Name>` heading found in tasks.md,
# formatted `<N>\t<Name>`. Both `## Phase 1: Setup` and
# `## Phase 10: Polish` are accepted; the name is trimmed of leading
# and trailing whitespace. No output if the file is absent or has no
# matching headings (caller infers "no task phases yet").
# ---------------------------------------------------------------------------
parser::task_phases() {
    local tasks_md="$1"
    [[ -f "$tasks_md" ]] || return 0
    awk '
        /^## Phase [0-9]+:/ {
            line = $0
            # Strip the leading "## Phase " prefix.
            sub(/^## Phase /, "", line)
            # Index of ":" splits "<N>" from "<Name>".
            colon = index(line, ":")
            if (colon == 0) next
            idx = substr(line, 1, colon - 1)
            name = substr(line, colon + 1)
            sub(/^[[:space:]]+/, "", name)
            sub(/[[:space:]]+$/, "", name)
            printf "%s\t%s\n", idx, name
        }
    ' "$tasks_md"
}

# ---------------------------------------------------------------------------
# parser::tasks_in_phase <tasks_md_path> <phase_index>
#
# Emits one line per task belonging to phase `<phase_index>`, formatted
# `<TaskID>\t<checked|unchecked>\t<description>\t<estimate>`. Tasks are
# checklist items (`- [ ]` / `- [x]`) appearing between the matching
# `## Phase N:` heading and the next `## ` heading. Task ID is the
# first whitespace-separated token after the checkbox; description is
# the remainder of the line (any trailing whitespace trimmed).
#
# Estimate is extracted per FR-035 — the first `[<digits>]` token
# encountered in the leading run of bracketed markers (e.g. `[P]`,
# `[US1]`) immediately following the task code. If such a token
# exists, the digits inside it become the `<estimate>` column AND the
# token is removed from `<description>`. Non-digit bracketed markers
# (`[P]`, `[US1]`) are PRESERVED in the description so the operator's
# task list keeps its spec-kit-canonical annotations. If no
# `[<digits>]` token is found within the first 5 leading bracketed
# tokens, the `<estimate>` column is empty and the description is
# untouched.
#
# If a checklist line has no recognisable task ID token, the entire
# remainder becomes the description and the ID is empty.
# ---------------------------------------------------------------------------
parser::tasks_in_phase() {
    local tasks_md="$1"
    local phase_index="$2"
    [[ -f "$tasks_md" ]] || return 0
    awk -v want="$phase_index" '
        /^## Phase [0-9]+:/ {
            line = $0
            sub(/^## Phase /, "", line)
            colon = index(line, ":")
            if (colon == 0) { in_phase = 0; next }
            idx = substr(line, 1, colon - 1)
            in_phase = (idx == want) ? 1 : 0
            next
        }
        /^## / { in_phase = 0; next }
        in_phase && /^- \[[ xX]\][[:space:]]/ {
            # Checkbox character is line[4] (1-indexed): "- [X] ".
            box = substr($0, 4, 1)
            state = (tolower(box) == "x") ? "checked" : "unchecked"
            rest = substr($0, 7)
            sub(/^[[:space:]]+/, "", rest)
            sub(/[[:space:]]+$/, "", rest)
            id = ""
            desc = rest
            sp = index(rest, " ")
            tab_idx = index(rest, "\t")
            if (tab_idx > 0 && (sp == 0 || tab_idx < sp)) sp = tab_idx
            if (sp > 0) {
                id = substr(rest, 1, sp - 1)
                desc = substr(rest, sp + 1)
                sub(/^[[:space:]]+/, "", desc)
                sub(/[[:space:]]+$/, "", desc)
            }
            estimate = ""
            preserved = ""
            remainder = desc
            scanned = 0
            while (scanned < 5 && match(remainder, /^\[[^]]+\][[:space:]]*/)) {
                token = substr(remainder, RSTART, RLENGTH)
                inner = token
                sub(/^\[/, "", inner)
                sub(/\][[:space:]]*$/, "", inner)
                if (inner ~ /^[0-9]+$/) {
                    estimate = inner
                    remainder = substr(remainder, RLENGTH + 1)
                    desc = preserved remainder
                    break
                } else {
                    preserved = preserved token
                    remainder = substr(remainder, RLENGTH + 1)
                    scanned = scanned + 1
                }
            }
            printf "%s\t%s\t%s\t%s\n", id, state, desc, estimate
        }
    ' "$tasks_md"
}

# ---------------------------------------------------------------------------
# parser::phase_estimate <tasks_md_path> <phase_index>
#
# Emits the sum of `[N]` Fibonacci estimate markers across every task
# in the given task phase. Per FR-035, emits an EMPTY string (not "0")
# when NO task in the phase carries a marker — so the caller can
# distinguish "operator declined to estimate" from "estimated as zero
# points". Tasks without markers contribute nothing to the sum.
# ---------------------------------------------------------------------------
parser::phase_estimate() {
    local tasks_md="$1"
    local phase_index="$2"
    [[ -f "$tasks_md" ]] || return 0
    local id state desc est total=0 saw_any=0
    while IFS=$'\t' read -r id state desc est; do
        : "${id:-}${state:-}${desc:-}"
        if [[ -n "$est" ]]; then
            total=$(( total + est ))
            saw_any=1
        fi
    done < <(parser::tasks_in_phase "$tasks_md" "$phase_index")
    if (( saw_any == 1 )); then
        printf '%s\n' "$total"
    fi
}

# ---------------------------------------------------------------------------
# parser::spec_estimate <tasks_md_path>
#
# Emits the sum of `[N]` markers across every task in the entire
# tasks.md (rollup for the spec Issue per FR-035). Empty string when
# no task carries a marker.
# ---------------------------------------------------------------------------
parser::spec_estimate() {
    local tasks_md="$1"
    [[ -f "$tasks_md" ]] || return 0
    local phase_index phase_name total=0 saw_any=0 sub_total
    while IFS=$'\t' read -r phase_index phase_name; do
        : "${phase_name:-}"
        sub_total="$(parser::phase_estimate "$tasks_md" "$phase_index")"
        if [[ -n "$sub_total" ]]; then
            total=$(( total + sub_total ))
            saw_any=1
        fi
    done < <(parser::task_phases "$tasks_md")
    if (( saw_any == 1 )); then
        printf '%s\n' "$total"
    fi
}

# ---------------------------------------------------------------------------
# parser::malformed_task_lines <tasks_md_path>
#
# Emits one line per checklist task line (`- [ ]` / `- [x]`) that
# appears OUTSIDE any `## Phase N:` heading. Lines are emitted with
# their 1-indexed source line number first, then a tab, then the
# verbatim line — useful for warning messages per FR-024 and SC-007.
# Empty output when every task line lives under some `## Phase`.
# ---------------------------------------------------------------------------
parser::malformed_task_lines() {
    local tasks_md="$1"
    [[ -f "$tasks_md" ]] || return 0
    awk '
        /^## Phase [0-9]+:/ { in_phase = 1; next }
        /^## / { in_phase = 0; next }
        !in_phase && /^- \[[ xX]\][[:space:]]/ {
            printf "%d\t%s\n", NR, $0
        }
    ' "$tasks_md"
}

# ---------------------------------------------------------------------------
# parser::clarify_sessions <spec_md_path>
#
# Emits one line per `### Session YYYY-MM-DD` subheading found under
# the `## Clarifications` section of spec.md, formatted
# `<date>\t<bullet-count>`. Bullets are counted as `- ` prefixed lines
# between this session's heading and the next `### ` or `## ` heading
# (whichever comes first). FR-008 + FR-015 source-of-truth.
# ---------------------------------------------------------------------------
parser::clarify_sessions() {
    local spec_md="$1"
    [[ -f "$spec_md" ]] || return 0
    awk '
        function flush() {
            if (current_date != "") {
                printf "%s\t%d\n", current_date, bullet_count
            }
            current_date = ""
            bullet_count = 0
        }
        /^## Clarifications[[:space:]]*$/ { in_section = 1; next }
        /^## / {
            if (in_section) { flush(); in_section = 0 }
            next
        }
        in_section && /^### Session [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
            flush()
            # Extract the date token (chars 13..22 in "### Session YYYY-MM-DD").
            current_date = substr($0, 13, 10)
            bullet_count = 0
            next
        }
        in_section && current_date != "" && /^- / {
            bullet_count++
        }
        END { if (in_section) flush() }
    ' "$spec_md"
}

# ---------------------------------------------------------------------------
# parser::clarify_session_bullets <spec_md_path> <date>
#
# Emits the verbatim bullet lines (each starting with `- `) belonging
# to the `### Session <date>` subheading. Used by reconcile to build
# the body of the per-session comment posted on the spec Issue
# (FR-015). Empty output if the date heading is not found.
# ---------------------------------------------------------------------------
parser::clarify_session_bullets() {
    local spec_md="$1"
    local date="$2"
    [[ -f "$spec_md" ]] || return 0
    awk -v want="$date" '
        /^## Clarifications[[:space:]]*$/ { in_section = 1; next }
        /^## / { in_section = 0; in_session = 0; next }
        in_section && /^### Session [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
            this_date = substr($0, 13, 10)
            in_session = (this_date == want) ? 1 : 0
            next
        }
        in_section && /^### / { in_session = 0; next }
        in_section && in_session && /^- / { print }
    ' "$spec_md"
}

# ---------------------------------------------------------------------------
# parser::spec_author <spec_md_path>          (feature-007 — FR-001, R1)
#
# Echoes the value of the FIRST `Owner:` or `Author:` line in the spec's top
# matter (case-insensitive on the key), with a leading `**`/`__` bold marker
# stripped and surrounding whitespace trimmed. Empty output (exit 0) when no
# such line exists or the file is absent — the caller then falls back to the
# git first-add author (workstate::_author_json).
#
# Vendor-neutral: this is a pure markdown read of an explicit author line; it
# carries NO Jira account/issue-type vocabulary (the resolved value is a free
# string — an email or an explicit owner/author name).
# ---------------------------------------------------------------------------
parser::spec_author() {
    local spec_md="$1"
    [[ -f "$spec_md" ]] || return 0
    awk '
        # Match a leading optional bold marker, then Owner|Author, a colon, and
        # the value. Case-insensitive via tolower() on a normalized prefix.
        {
            line = $0
            # Strip a leading bold marker (** or __) so "**Owner**:" matches.
            sub(/^[[:space:]]*(\*\*|__)?/, "", line)
            key = line
            # Take the substring up to the first colon as the key candidate.
            ci = index(line, ":")
            if (ci == 0) next
            key = substr(line, 1, ci - 1)
            # Drop a trailing bold marker on the key ("Owner**").
            sub(/(\*\*|__)$/, "", key)
            sub(/[[:space:]]+$/, "", key)
            if (tolower(key) == "owner" || tolower(key) == "author") {
                value = substr(line, ci + 1)
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                if (value != "") { print value; exit }
            }
        }
    ' "$spec_md"
}

# ---------------------------------------------------------------------------
# parser::spec_title_line <spec_md_path>          (feature-009 — FR-001, C-1)
#
# Echoes the value of the FIRST `Title:` line in the spec's top matter
# (case-insensitive on the key), with a leading `**`/`__` bold marker stripped
# and surrounding whitespace trimmed. Empty output (exit 0) when no such line
# exists, the value is empty, or the file is absent — the caller then falls
# through to the next rung of the title ladder (concise H1 → Summary → kebab).
#
# Vendor-neutral: this MIRRORS parser::spec_author exactly (same front-matter
# shape, feature 007), only the matched key changes to `title`. It is a pure
# markdown read; it carries NO Jira vocabulary (the value is a free string).
# ---------------------------------------------------------------------------
parser::spec_title_line() {
    local spec_md="$1"
    [[ -f "$spec_md" ]] || return 0
    awk '
        # Match a leading optional bold marker, then Title, a colon, and the
        # value. Case-insensitive via tolower() on a normalized prefix.
        {
            line = $0
            # Strip a leading bold marker (** or __) so "**Title**:" matches.
            sub(/^[[:space:]]*(\*\*|__)?/, "", line)
            key = line
            # Take the substring up to the first colon as the key candidate.
            ci = index(line, ":")
            if (ci == 0) next
            key = substr(line, 1, ci - 1)
            # Drop a trailing bold marker on the key ("Title**").
            sub(/(\*\*|__)$/, "", key)
            sub(/[[:space:]]+$/, "", key)
            if (tolower(key) == "title") {
                value = substr(line, ci + 1)
                # Drop a leading bold marker when the colon sat INSIDE the bold
                # span ("**Title:**  Foo" => value "**  Foo" => "Foo").
                sub(/^(\*\*|__)/, "", value)
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                if (value != "") { print value; exit }
            }
        }
    ' "$spec_md"
}

# ---------------------------------------------------------------------------
# parser::decision_records <research_md_path>
#
# Tolerant extractor for a spec's decision records (ADRs) from its research.md
# (feature 005, FR-001/003/007 / research R1-R2). A decision block is a `##`/`###`
# heading whose body (until the next heading of equal/higher level) carries a
# Decision statement. Decision / Rationale / Alternatives are read by
# CASE-INSENSITIVE label in BOTH grammars:
#   * bold lead   — `**Decision.**` / `**Decision:**` (this repo's research.md)
#   * bullet/plain — `- Decision:` / `Decision:`       (spec-kit's stock template)
# Values are multi-line (everything up to the next label or the block end).
#
# Emits a JSON ARRAY (one object per block) on stdout, each
# `{id, title, status?, decision, rationale?, alternatives?, source}`:
#   id     — explicit heading id (`R<N>`/`D<N>`/`ADR-<N>`, case-insensitive)
#            else a stable slug of the title (lowercase, non-alnum->`-`, trimmed),
#            positionally disambiguated (`-2`,`-3`) on a duplicate slug.
#   title  — the heading text after the id token.
#   source — repo-relative back-reference `research.md#<id>` (no host/URL, R7).
# Absent sub-parts are OMITTED (not blanked). NEVER fails: an absent/malformed
# file or a file with no decision blocks yields `[]` (FR-007). Vendor-neutral —
# pure filesystem read, no Jira vocabulary.
# ---------------------------------------------------------------------------
parser::decision_records() {
    local research_md="$1"
    [[ -f "$research_md" ]] || { printf '[]'; return 0; }

    local objs
    objs="$(awk '
        function jesc(s,   r) {
            r = s
            gsub(/\\/, "\\\\", r)
            gsub(/"/, "\\\"", r)
            gsub(/\n/, "\\n", r)
            gsub(/\t/, "\\t", r)
            gsub(/\r/, "", r)
            return r
        }
        function rtrim(s) { sub(/[[:space:]]+$/, "", s); return s }
        function ltrim(s) { sub(/^[[:space:]]+/, "", s); return s }
        function trim(s) { return ltrim(rtrim(s)) }
        function add_val(line) {
            if (cur_label == "") return
            if (vals[cur_label] == "") vals[cur_label] = line
            else vals[cur_label] = vals[cur_label] "\n" line
        }
        # Try to read a Decision/Rationale/Alternatives label off a body line.
        # Returns the canonical label or ""; sets G_VALUE to the inline remainder.
        function read_label(line,   t, low, lab, rest) {
            t = line
            sub(/^[[:space:]]+/, "", t)
            # Optional list bullet — a real bullet is "-"/"+"/"*" followed by
            # whitespace; `**Bold**` has no space after the first `*`, so anchor
            # the space to avoid eating one `*` off a bold lead.
            sub(/^[-*+][[:space:]]+/, "", t)
            sub(/^[[:space:]]+/, "", t)
            sub(/^\*\*/, "", t)                            # bold lead open
            low = tolower(t)
            lab = ""
            if (low ~ /^decision[.:*]/)       lab = "decision"
            else if (low ~ /^rationale[.:*]/) lab = "rationale"
            else if (low ~ /^alternatives/)   lab = "alternatives"
            if (lab == "") return ""
            rest = t
            sub(/^[A-Za-z]+/, "", rest)        # drop the label word
            sub(/^[A-Za-z[:space:]]*/, "", rest) # drop trailing label words (e.g. " considered")
            sub(/^\*\*/, "", rest)             # bold close before terminator
            sub(/^[.:]/, "", rest)             # the . or : terminator
            sub(/^\*\*/, "", rest)             # bold close after terminator
            G_VALUE = trim(rest)
            return lab
        }
        function flush(   out) {
            if (in_block && ("decision" in vals) && trim(vals["decision"]) != "") {
                out = "{\"id\":\"" jesc(cur_id) "\""
                out = out ",\"title\":\"" jesc(cur_title) "\""
                if ("status" in vals && trim(vals["status"]) != "")
                    out = out ",\"status\":\"" jesc(trim(vals["status"])) "\""
                out = out ",\"decision\":\"" jesc(trim(vals["decision"])) "\""
                if ("rationale" in vals && trim(vals["rationale"]) != "")
                    out = out ",\"rationale\":\"" jesc(trim(vals["rationale"])) "\""
                if ("alternatives" in vals && trim(vals["alternatives"]) != "")
                    out = out ",\"alternatives\":\"" jesc(trim(vals["alternatives"])) "\""
                out = out ",\"__title_slug\":\"" jesc(cur_slug) "\""
                out = out ",\"__has_id\":" (cur_has_id ? "true" : "false")
                out = out "}"
                print out
            }
            in_block = 0
            delete vals
            cur_label = ""
        }
        # A heading at level 2 or 3 opens a new candidate block.
        /^###?[[:space:]]/ {
            flush()
            heading = $0
            sub(/^#+[[:space:]]*/, "", heading)
            heading = trim(heading)
            cur_has_id = 0
            cur_id = ""
            cur_title = heading
            if (match(heading, /^([Rr]|[Dd])[0-9]+/) \
                || match(heading, /^[Aa][Dd][Rr]-[0-9]+/)) {
                cur_id = substr(heading, 1, RLENGTH)
                cur_has_id = 1
                rest = substr(heading, RLENGTH + 1)
                sub(/^[[:space:]]*[-—–:][[:space:]]*/, "", rest)
                cur_title = trim(rest)
                if (cur_title == "") cur_title = cur_id
            }
            s = tolower(cur_title)
            gsub(/[^a-z0-9]+/, "-", s)
            sub(/^-+/, "", s); sub(/-+$/, "", s)
            cur_slug = s
            in_block = 1
            cur_label = ""
            next
        }
        # Any other heading (level 1, or 4+) closes the current block.
        /^#+[[:space:]]/ { flush(); next }
        in_block {
            lab = read_label($0)
            if (lab != "") {
                cur_label = lab
                vals[lab] = G_VALUE
                next
            }
            if ($0 ~ /^[[:space:]]*$/) { cur_label = ""; next }
            add_val($0)
            next
        }
        END { flush() }
    ' "$research_md")"

    [[ -n "$objs" ]] || { printf '[]'; return 0; }

    # Resolve id (explicit else slug), positionally disambiguate duplicate slugs
    # in document order, compose the source ref, drop the private __* helpers.
    printf '%s\n' "$objs" | jq -s '
        [ . as $all
          | range(0; length) as $i
          | $all[$i] as $rec
          | (if $rec.__has_id then $rec.id
             else
               ([ $all[0:$i][]
                  | select(.__has_id | not)
                  | select(.__title_slug == $rec.__title_slug) ] | length) as $prior
               | if $prior == 0 then $rec.__title_slug
                 else "\($rec.__title_slug)-\($prior + 1)" end
             end) as $id
          | { id: $id, title: $rec.title }
            + (if $rec.status then { status: $rec.status } else {} end)
            + { decision: $rec.decision }
            + (if $rec.rationale then { rationale: $rec.rationale } else {} end)
            + (if $rec.alternatives then { alternatives: $rec.alternatives } else {} end)
            + { source: "research.md#\($id)" }
        ]
    '
}
