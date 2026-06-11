#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/adf.bats
#
# Unit tests for src/adf.sh — the Markdown -> Atlassian Document Format (ADF)
# renderer. These are PURE transform tests: no network, no curl, no live Jira.
# They assert structural validity of the emitted ADF by inspecting node types,
# attrs and text with jq (the same way the sink will hand bodies to REST v3).
#
# Privacy (Principle IX): every fixture below uses placeholders only — example
# .test URLs, generic task labels — never real Jira coordinates or PII.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/src/adf.sh"
}

# --- adf::from_markdown ------------------------------------------------------

@test "from_markdown: empty input still yields a valid doc" {
  run adf::from_markdown ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.version == 1 and .type == "doc"'
  echo "$output" | jq -e '.content | length >= 1'
}

@test "from_markdown: heading + paragraph + bullet list produce valid ADF" {
  local md
  md=$'# Title\n\nAn intro paragraph.\n\n- alpha\n- beta'

  run adf::from_markdown "$md"
  [ "$status" -eq 0 ]

  # Top-level doc envelope.
  echo "$output" | jq -e '.version == 1 and .type == "doc"'

  # Block sequence: heading, paragraph, bulletList.
  echo "$output" | jq -e '[.content[].type] == ["heading","paragraph","bulletList"]'

  # Heading carries level 1 and the right text.
  echo "$output" | jq -e '.content[0].attrs.level == 1'
  echo "$output" | jq -e '.content[0].content[0].text == "Title"'

  # Paragraph text round-trips.
  echo "$output" | jq -e '.content[1].content[0].text == "An intro paragraph."'

  # Bullet list has two listItems, each wrapping a paragraph.
  echo "$output" | jq -e '.content[2].content | length == 2'
  echo "$output" | jq -e '[.content[2].content[].type] == ["listItem","listItem"]'
  echo "$output" | jq -e '.content[2].content[0].content[0].type == "paragraph"'
  echo "$output" | jq -e '.content[2].content[1].content[0].content[0].text == "beta"'
}

@test "from_markdown: heading levels map # ## ### to 1 2 3" {
  run adf::from_markdown $'# One\n## Two\n### Three'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.content[] | select(.type=="heading") | .attrs.level] == [1,2,3]'
}

@test "from_markdown: ordered list becomes an orderedList node" {
  run adf::from_markdown $'1. first\n2. second\n3. third'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.content[0].type == "orderedList"'
  echo "$output" | jq -e '.content[0].content | length == 3'
  echo "$output" | jq -e '.content[0].content[2].content[0].content[0].text == "third"'
}

@test "from_markdown: fenced code block keeps language and verbatim text" {
  run adf::from_markdown $'```bash\necho hi\necho bye\n```'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.content[0].type == "codeBlock"'
  echo "$output" | jq -e '.content[0].attrs.language == "bash"'
  echo "$output" | jq -e '.content[0].content[0].text == "echo hi\necho bye"'
}

@test "from_markdown: inline link splits into a text run with a link mark" {
  run adf::from_markdown 'See the [docs](https://example.test/guide) for more.'
  [ "$status" -eq 0 ]

  # The paragraph splits into: plain, linked, plain.
  echo "$output" | jq -e '[.content[0].content[].text] == ["See the ","docs"," for more."]'
  echo "$output" | jq -e '.content[0].content[1].marks[0].type == "link"'
  echo "$output" | jq -e '.content[0].content[1].marks[0].attrs.href == "https://example.test/guide"'
}

@test "from_markdown: text with JSON-hostile chars is safely escaped" {
  # Quotes/braces/tabs must survive as data, not break the JSON. A single
  # literal backslash is included via printf to avoid shell-quoting ambiguity.
  local payload
  payload="$(printf 'Edge "quotes" and {braces} and a back\\slash.')"

  run adf::from_markdown "$payload"
  [ "$status" -eq 0 ]
  # The output parses as JSON (jq -e on any block proves that) and the text
  # round-trips byte-for-byte, which is only possible if jq escaped it.
  echo "$output" | jq -e --arg expect "$payload" '.content[0].content[0].text == $expect'
}

# --- adf::task_list ----------------------------------------------------------

@test "task_list: checklist renders a taskList with DONE/TODO states" {
  local items='[{"text":"Write the spec","done":true},{"text":"Implement","done":false}]'

  run adf::task_list "$items"
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.type == "taskList"'
  echo "$output" | jq -e '[.content[].type] == ["taskItem","taskItem"]'
  echo "$output" | jq -e '[.content[].attrs.state] == ["DONE","TODO"]'
  echo "$output" | jq -e '.content[0].content[0].text == "Write the spec"'
  echo "$output" | jq -e '.content[1].content[0].text == "Implement"'

  # localIds are present and unique per item.
  echo "$output" | jq -e '[.content[].attrs.localId] | (length == 2) and (unique | length == 2)'
}

@test "task_list: empty array yields a paragraph placeholder (NOT a childless taskList — Jira 400)" {
  run adf::task_list '[]'
  [ "$status" -eq 0 ]
  # Bug-2 guard: a `taskList` with `content: []` is rejected by Jira with 400
  # INVALID_INPUT. An empty array must render a non-empty paragraph instead.
  echo "$output" | jq -e '.type == "paragraph" and (.content | length > 0)'
  echo "$output" | jq -e '.type != "taskList"'
}

@test "task_list: a taskItem with empty text still has non-empty content (no Jira 400)" {
  run adf::task_list '[{"text":"","done":false}]'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.type == "taskList"'
  # The single taskItem must carry non-empty content (a space fallback), never []
  echo "$output" | jq -e '.content[0].content | length > 0'
}

@test "task_list: missing 'done' defaults to TODO" {
  run adf::task_list '[{"text":"No flag"}]'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.content[0].attrs.state == "TODO"'
}

# --- adf::truncate -----------------------------------------------------------

@test "truncate: short text passes through unchanged" {
  run adf::truncate "a short body"
  [ "$status" -eq 0 ]
  [ "$output" = "a short body" ]
}

@test "truncate: long text is capped and annotated" {
  # 2000 'x' chars, default cap 1500.
  local long
  long="$(printf 'x%.0s' {1..2000})"

  run adf::truncate "$long"
  [ "$status" -eq 0 ]

  # Body cut to 1500 + the "…(truncated)" note (1 + 11 codepoints).
  local len
  len="$(printf '%s' "$output" | jq -Rrs 'rtrimstr("\n") | length')"
  [ "$len" -eq "$((1500 + 12))" ]

  # The annotation is present.
  [[ "$output" == *"…(truncated)" ]]
}

@test "truncate: explicit max controls the cap" {
  run adf::truncate "0123456789ABCDEF" 5
  [ "$status" -eq 0 ]
  [[ "$output" == "01234…(truncated)" ]]
}
