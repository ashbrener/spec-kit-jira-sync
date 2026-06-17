# Contract: Issue-Title Source Ladder

The neutral title-derivation seam in `workstate.sh` + `parser.sh`. The Jira sink
is unchanged (it keeps mapping `item.title` → the issue `summary`). Pure
filesystem parsing — no network, no LLM, no schema change.

## 1. `parser::spec_title_line <spec_md_path>`

- **Mirror of** `parser::spec_author` with key `title`.
- **Behavior**: scan lines; strip a leading bold marker (`**`/`__`); split on the
  first `:`; if the (bold-stripped, trimmed) key lowercases to `title`, echo the
  trimmed value and exit; empty value or no match ⇒ no output (rc 0).
- **MUST**: read-only; no Jira vocabulary.

## 2. `workstate::_summary_first_sentence <spec_dir>`

- **Input**: pipes `workstate::_spec_body` (the trimmed `## Summary` block).
- **Behavior**: skip leading non-prose lines (blank, `>`, `-`/`*`/`+` list, `!`
  image, ``` fence, `#` heading, `|` table); on the first prose line, take the
  first sentence — up to the first period-then-space, `.`-at-end-of-line, `?`, or `!` terminator
  (inclusive of the terminator, then trimmed), or the whole line if no terminator;
  trim. No prose line ⇒ empty output (rc 0).
- **MUST**: deterministic; read-only.

## 3. `workstate::_cap_title <string>`

- **Behavior**: `${#s} ≤ 120` ⇒ echo `s` verbatim. Else echo the longest prefix
  whose length ≤120 that ends at a **word boundary** (truncate at the last space at
  or before index 120; if the first 120 chars contain no space, hard-cut at 120).
  **No ellipsis.**
- **MUST**: pure shell/awk string ops — no locale/time/random; same input ⇒ same
  output.

## 4. `workstate::_spec_title <spec_dir>` (rewritten — the ladder)

```text
spec_md = spec_dir/spec.md ; [[ -s spec_md ]] || return 0
1. t = parser::spec_title_line(spec_md)         ; [ -n t ] ⇒ echo _cap_title(t); return
2. h1 = first '#' heading, strip 'Feature Specification:' label
   use_h1 = h1 nonempty AND h1 != '[FEATURE NAME]' AND h1 != short_name AND len(h1) ≤ 120
                                                 ; use_h1 ⇒ echo _cap_title(h1); return
3. s = workstate::_summary_first_sentence(spec_dir) ; [ -n s ] ⇒ echo _cap_title(s); return
4. echo parser::short_name(spec_dir)            # kebab last resort (may be empty for a non-NNN dir)
```

- **Backward-compat**: rung 2 with a clean within-cap H1 ⇒ `_cap_title` is a no-op
  ⇒ **byte-identical to today** (FR-004).
- **MUST**: deterministic; vendor-neutral; no side effects.

## 5. Behavioral assertions (testable — pure-filesystem bats fixtures)

| ID | Fixture | Expected title |
|---|---|---|
| C-1 | clean `# Feature Specification: Clean Name` | `Clean Name` (byte-identical to pre-feature) |
| C-2 | H1 = `[FEATURE NAME]` placeholder + `## Summary: "Does X. More."` | `Does X.` (first Summary sentence) |
| C-3 | H1 = a >120-char wall + a `## Summary` | the Summary sentence, capped ≤120 on a word boundary — **not** the wall |
| C-4 | `Title: Crisp Override` + a verbose H1 | `Crisp Override` |
| C-5 | no usable H1, has `## Summary` | first Summary sentence (capped) |
| C-6 | no H1, no Summary, dir `009-foo-bar` | `foo-bar` (kebab last resort) |
| C-7 | H1 byte-equal to the kebab short-name + a Summary | the Summary sentence (H1 treated as weak) |
| C-8 | a `## Summary` whose first sentence is >120 chars | capped ≤120, ends on a word boundary, no mid-word cut, no ellipsis |
| C-9 | any fixture, derived twice | identical both times (deterministic, zero-churn) |
| C-10 | Summary opens with a blockquote/list/image then prose | the first **prose** sentence (markup skipped); none ⇒ kebab |
| C-11 | all new fixtures | placeholder-only — `no-real-identifiers.bats` + 006 guard green |
| C-12 | — | `engine_vendor_neutral.bats` green (derivation is in the neutral layer, no Jira vocab) |
