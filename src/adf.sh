#!/usr/bin/env bash
# =============================================================================
# src/adf.sh — Markdown -> Atlassian Document Format (ADF) JSON.
#
# Converts the bounded Markdown subset the vendor-neutral engine emits into ADF
# (Atlassian Document Format) JSON, the native body representation for Jira REST
# API v3 issue descriptions and comments (research D2). A separate helper renders
# a per-phase checklist as an ADF `taskList` of interactive checkboxes (D3).
#
# DESIGN: every byte of JSON is built with `jq` — this file NEVER concatenates
# strings into JSON. Markdown is parsed line-by-line in bash into a flat block
# list; jq assembles the ADF document and escapes all text. The supported subset
# matches what the engine emits:
#   - paragraphs
#   - ATX headings (#, ##, ### -> levels 1..3)
#   - bullet lists (-, *, +)
#   - ordered lists (1. 2. ...)
#   - fenced code blocks (``` ... ```), optional language
#   - inline links [text](url) within paragraph / list-item / heading text
#
# All functions are PURE transforms: no network, no curl, no global state. Source
# this file and call the adf::* functions; stdout is the ADF JSON (compact).
#
# Placeholders only — no real data appears here (Principle IX).
# =============================================================================

# ----------------------------------------------------------------------------
# adf::_inline <text>
#
# Emit a JSON array of ADF inline nodes for one line of text, splitting out
# Markdown links [label](url) into `text` nodes carrying a `link` mark and
# leaving the surrounding runs as plain `text` nodes. Empty input yields an empty
# array. Pure; reads its single argument, writes JSON to stdout.
# ----------------------------------------------------------------------------
adf::_inline() {
  local text="$1"

  if [[ -z "$text" ]]; then
    printf '[]'
    return 0
  fi

  # Split the line into alternating (plain, link-label, link-url) segments using
  # a bash ERE that peels off the first Markdown link each pass, accumulating each
  # piece as a JSON object so jq only has to assemble (and escape) — never parse —
  # the result. A single =~ match avoids bracket-glob pitfalls of ${var%%[*}.
  local -a parts=()
  local rest="$text"
  # Groups: 1=text before link, 2=label, 3=url, 4=remainder. ERE has no lazy
  # quantifier; [^][]* on group 1 keeps it from swallowing a later '['.
  local link_re='^([^][]*)\[([^][]+)\]\(([^)]+)\)(.*)$'
  while [[ "$rest" =~ $link_re ]]; do
    local before="${BASH_REMATCH[1]}"
    local label="${BASH_REMATCH[2]}"
    local url="${BASH_REMATCH[3]}"
    rest="${BASH_REMATCH[4]}"

    if [[ -n "$before" ]]; then
      parts+=("$(jq -cn --arg t "$before" '{type:"text",text:$t}')")
    fi
    parts+=("$(jq -cn --arg t "$label" --arg u "$url" \
      '{type:"text",text:$t,marks:[{type:"link",attrs:{href:$u}}]}')")
  done

  if [[ -n "$rest" ]]; then
    parts+=("$(jq -cn --arg t "$rest" '{type:"text",text:$t}')")
  fi

  if [[ ${#parts[@]} -eq 0 ]]; then
    printf '[]'
    return 0
  fi

  printf '%s\n' "${parts[@]}" | jq -cs '.'
}

# ----------------------------------------------------------------------------
# adf::_paragraph <text>  /  adf::_heading <level> <text>
#
# Single-block helpers returning one ADF node as compact JSON. Both delegate
# inline parsing to adf::_inline so links inside paragraphs and headings work.
# ----------------------------------------------------------------------------
adf::_paragraph() {
  local content
  content="$(adf::_inline "$1")"
  jq -cn --argjson c "$content" '{type:"paragraph",content:$c}'
}

adf::_heading() {
  local level="$1" content
  content="$(adf::_inline "$2")"
  jq -cn --argjson lvl "$level" --argjson c "$content" \
    '{type:"heading",attrs:{level:$lvl},content:$c}'
}

# ----------------------------------------------------------------------------
# adf::_list <type> <line0> <line1> ...
#
# Build a bulletList or orderedList node from already-stripped item texts.
# <type> is "bullet" or "ordered". Each item becomes a listItem wrapping a
# paragraph, so inline links inside items are preserved.
# ----------------------------------------------------------------------------
adf::_list() {
  local kind="$1"; shift
  local node_type
  if [[ "$kind" == "ordered" ]]; then
    node_type="orderedList"
  else
    node_type="bulletList"
  fi

  local -a items=()
  local line para
  for line in "$@"; do
    para="$(adf::_paragraph "$line")"
    items+=("$(jq -cn --argjson p "$para" '{type:"listItem",content:[$p]}')")
  done

  printf '%s\n' "${items[@]}" \
    | jq -cs --arg nt "$node_type" '{type:$nt,content:.}'
}

# ----------------------------------------------------------------------------
# adf::_code_block <language> <text>
#
# A codeBlock node. Empty language -> no attrs (plain code block). Text is passed
# verbatim through jq, so backticks/braces/quotes are escaped safely.
# ----------------------------------------------------------------------------
adf::_code_block() {
  local lang="$1" text="$2"
  if [[ -n "$lang" ]]; then
    jq -cn --arg l "$lang" --arg t "$text" \
      '{type:"codeBlock",attrs:{language:$l},content:[{type:"text",text:$t}]}'
  else
    jq -cn --arg t "$text" \
      '{type:"codeBlock",content:[{type:"text",text:$t}]}'
  fi
}

# ----------------------------------------------------------------------------
# adf::from_markdown <markdown>
#
# Convert the supported Markdown subset to a full ADF document:
#   { "version":1, "type":"doc", "content":[ ...block nodes... ] }
#
# Blocks are emitted as one compact JSON object per line on a pipe, then jq slurps
# them into the doc's content array. An empty / whitespace-only input still yields
# a valid doc with a single empty paragraph (ADF requires non-empty content for
# some surfaces; an empty paragraph is the safe minimum).
# ----------------------------------------------------------------------------
adf::from_markdown() {
  local md="$1"
  local -a blocks=()

  # Group accumulators for runs of consecutive list items.
  local -a bullet_buf=() ordered_buf=()
  # Code-fence state.
  local in_code=0 code_lang="" code_buf=""

  _flush_bullets() {
    if [[ ${#bullet_buf[@]} -gt 0 ]]; then
      blocks+=("$(adf::_list bullet "${bullet_buf[@]}")")
      bullet_buf=()
    fi
  }
  _flush_ordered() {
    if [[ ${#ordered_buf[@]} -gt 0 ]]; then
      blocks+=("$(adf::_list ordered "${ordered_buf[@]}")")
      ordered_buf=()
    fi
  }

  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    # --- fenced code block ---------------------------------------------------
    if [[ "$line" =~ ^[[:space:]]*\`\`\`(.*)$ ]]; then
      if [[ "$in_code" -eq 0 ]]; then
        _flush_bullets; _flush_ordered
        in_code=1
        code_lang="${BASH_REMATCH[1]}"
        code_lang="${code_lang#"${code_lang%%[![:space:]]*}"}"  # ltrim
        code_buf=""
      else
        # closing fence
        in_code=0
        blocks+=("$(adf::_code_block "$code_lang" "$code_buf")")
        code_lang=""; code_buf=""
      fi
      continue
    fi
    if [[ "$in_code" -eq 1 ]]; then
      if [[ -n "$code_buf" ]]; then
        code_buf+=$'\n'"$line"
      else
        code_buf="$line"
      fi
      continue
    fi

    # --- blank line: paragraph/list break -----------------------------------
    if [[ -z "${line//[[:space:]]/}" ]]; then
      _flush_bullets; _flush_ordered
      continue
    fi

    # --- heading -------------------------------------------------------------
    if [[ "$line" =~ ^(#{1,3})[[:space:]]+(.*)$ ]]; then
      _flush_bullets; _flush_ordered
      local hashes="${BASH_REMATCH[1]}"
      blocks+=("$(adf::_heading "${#hashes}" "${BASH_REMATCH[2]}")")
      continue
    fi

    # --- ordered list item ---------------------------------------------------
    if [[ "$line" =~ ^[[:space:]]*[0-9]+\.[[:space:]]+(.*)$ ]]; then
      _flush_bullets
      ordered_buf+=("${BASH_REMATCH[1]}")
      continue
    fi

    # --- bullet list item ----------------------------------------------------
    if [[ "$line" =~ ^[[:space:]]*[-*+][[:space:]]+(.*)$ ]]; then
      _flush_ordered
      bullet_buf+=("${BASH_REMATCH[1]}")
      continue
    fi

    # --- paragraph -----------------------------------------------------------
    _flush_bullets; _flush_ordered
    blocks+=("$(adf::_paragraph "$line")")
  done <<< "$md"

  # End-of-input flushes.
  if [[ "$in_code" -eq 1 ]]; then
    blocks+=("$(adf::_code_block "$code_lang" "$code_buf")")
  fi
  _flush_bullets; _flush_ordered

  unset -f _flush_bullets _flush_ordered

  if [[ ${#blocks[@]} -eq 0 ]]; then
    jq -cn '{version:1,type:"doc",content:[{type:"paragraph",content:[]}]}'
    return 0
  fi

  printf '%s\n' "${blocks[@]}" \
    | jq -cs '{version:1,type:"doc",content:.}'
}

# ----------------------------------------------------------------------------
# adf::task_list <json-array of {text,done}>
#
# Render a per-phase checklist as an ADF `taskList` (research D3): each entry
# becomes a `taskItem` whose `state` is "DONE" when done==true else "TODO", with
# the item text as its inline content. Each taskItem requires a unique localId.
#
# Input is a JSON array, e.g. '[{"text":"Write spec","done":true}, ...]'. The
# whole transform happens in jq; bash only passes the argument through.
# ----------------------------------------------------------------------------
adf::task_list() {
  local task_json="$1"
  : "${task_json:=[]}"

  jq -cn --argjson items "$task_json" '
    {
      type: "taskList",
      attrs: { localId: "tasklist-0" },
      content: (
        $items
        | to_entries
        | map(
            .key as $i
            | .value as $v
            | {
                type: "taskItem",
                attrs: {
                  localId: ("task-" + ($i | tostring)),
                  state: (if ($v.done == true) then "DONE" else "TODO" end)
                },
                content: (
                  if (($v.text // "") | length) > 0
                  then [ { type: "text", text: ($v.text | tostring) } ]
                  else []
                  end
                )
              }
          )
      )
    }
  '
}

# ----------------------------------------------------------------------------
# adf::truncate <text> [max]
#
# Cap long bodies before rendering: if <text> exceeds <max> characters (default
# 1500), cut to <max> and append a short "…(truncated)" note; otherwise return
# the text unchanged. Counting and slicing are done in jq for correct Unicode
# codepoint length. Output is plain text (feed it to adf::from_markdown next).
# ----------------------------------------------------------------------------
adf::truncate() {
  local text="$1"
  local max="${2:-1500}"

  jq -rn --arg t "$text" --argjson max "$max" '
    if ($t | length) > $max
    then ($t[0:$max] + "…(truncated)")
    else $t
    end
  '
}

# ----------------------------------------------------------------------------
# 2-level (checklist) mode — keyed sub-tree render (feature-002 US3, Q7/Q9).
#
# In 2-level mode the task phases/tasks collapse into a single in-body checklist
# carried by the SPEC issue's description, instead of becoming Subtask children.
# The bridge OWNS only this sub-tree; the prose above it is preserved across
# re-runs (the sink diffs only the sub-tree). To make that work the render is:
#   * KEYED by the workstate task id — each taskItem's localId derives from the
#     task id, NOT its position, so a reorder/rename re-keys by identity with no
#     duplication (Q7).
#   * BYTE-STABLE — an unchanged task set re-renders byte-identically, so the
#     sink's sub-tree compare yields `unchanged` ⇒ zero writes (FR-008, SC-004).
#   * PROVENANCE-MARKED — a single stable marker line renders above the taskList
#     (Q9) so the sink can locate the sub-tree inside a co-owned body without a
#     timestamp or other churn-inducing volatile content.
# ----------------------------------------------------------------------------

# The stable provenance marker line rendered above the checklist sub-tree. It is
# a fixed constant (NO timestamp / counter) so the round-trip stays byte-stable,
# and it is the delimiter the sink uses to isolate the sub-tree from the prose
# preamble. Exposed for the sink + tests; never localized or interpolated.
ADF_CHECKLIST_MARKER="Tasks — mirrored by spec-kit-jira-sync (edits above this line are preserved; this checklist is managed by the bridge)"

# ----------------------------------------------------------------------------
# adf::render_checklist_subtree <tasks-json>
#
# <tasks-json> is a JSON array of flattened tasks, each {id,text,done}, where
# `id` is the stable workstate task id (the caller composes it from the phase +
# task ordinal). Emits the checklist SUB-TREE as a JSON array of two ADF block
# nodes: [ <marker paragraph>, <taskList> ]. Each taskItem's localId is
# "task-<id>" (keyed by id); `state` is DONE when done==true else TODO. Built
# entirely in jq so text is escaped and key order is fixed (byte-stable).
# ----------------------------------------------------------------------------
adf::render_checklist_subtree() {
  local tasks_json="${1:-[]}"
  : "${tasks_json:=[]}"

  jq -cn --argjson items "$tasks_json" --arg marker "$ADF_CHECKLIST_MARKER" '
    [
      { type: "paragraph",
        content: [ { type: "text", text: $marker } ] },
      { type: "taskList",
        attrs: { localId: "speckit-checklist" },
        content: (
          $items
          | map(
              {
                type: "taskItem",
                attrs: {
                  localId: ("task-" + ((.id // "") | tostring)),
                  state: (if (.done == true) then "DONE" else "TODO" end)
                },
                content: (
                  if (((.text // "") | tostring | length) > 0)
                  then [ { type: "text", text: (.text | tostring) } ]
                  else []
                  end
                )
              }
            )
        )
      }
    ]
  '
}
