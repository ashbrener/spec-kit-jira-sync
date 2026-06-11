# Contract: parser → workstate → sink ADR seam

Preserves the 003 engine/sink boundary: ADR **extraction + the neutral
`decisions[]` projection** live in the parser/engine (vendor-neutral); the **Jira
comment / marker / digest mechanics** live in the sink. The neutrality gate
(`engine_vendor_neutral.bats`) MUST stay green.

## Parser (neutral — `parser.sh`)

### `parser::decision_records <research_md_path>` → JSON array (rc 0)

- Echoes `[{id, title, status, decision, rationale, alternatives, source}]` — one
  per `research.md` decision block; `[]` when the file is absent or has no blocks.
- Tolerant of both label grammars (bold-lead + bullet/plain), case-insensitive,
  multi-line values (research R1). Stable id per R2. NEVER fails on a malformed/
  absent file — absence is `[]`, not an error (FR-007).
- Pure read of the filesystem; no Jira vocabulary.

## Workstate (neutral — `workstate.sh`)

### `workstate::_decisions_json <spec_dir>` → `decisions[]`

- Builds the item's `decisions[]` from `<spec_dir>/research.md` via the parser;
  wired into item assembly next to `_notes_json`. Validates against the workstate
  schema's new optional `decisions[]` floor field (Principle X).

## Sink (Jira-specific — `jira_sink.sh`)

### `sync_decision_records <issue_key> <item_json>` → rc 0 | 3

- For each `item.decisions[]` element: compute the marker `[speckit-adr:<spec>-<id>]`
  and the rendered ADR body (per `adr-comment-layout.md`).
- `query_existing_comment_body(issue_key, marker)`:
  - rc 3 (unreadable) → **fail closed** (return 3; the engine promotes exit 3).
  - ABSENT → create the comment.
  - PRESENT → compare the normalized body digest; **mismatch → update in place**,
    **match → skip** (zero churn).
- Honors `DRY_RUN` (no write) and the `DRY-0` placeholder (skip the probe — the
  issue isn't created yet; PR #9 guard).
- Tally each create/update/skip in the run summary (Principle VIII).

## Engine wrapper (neutral — `reconcile.sh`)

### `reconcile::sync_decision_records <issue_key> <item_json>`

- Thin wrapper that calls the sink (mirrors `reconcile::sync_clarify_comments`).
  Wired right AFTER the clarify-comment call at both call sites (`process_spec`,
  `process_workstate_item`), same rc-3-fail-closed / rc≠0-exit-1 handling.

## Invariants across the seam

- **I-1**: the engine/parser path carries no Jira issue-type/artifact/relationship
  vocabulary (neutrality gate). `decisions[]` is neutral; the marker/ADF/digest
  live only in the sink.
- **I-2 (FR-008)**: ADR markers (`speckit-adr:`) and clarify markers
  (`speckit-note:`) are disjoint — neither path reads or writes the other's comments.
- **I-3 (FR-004)**: with `decisions[]` unchanged on disk + already mirrored, the
  sink issues zero comment writes.
- **I-4 (FR-009)**: the sink's rendered body matches `adr-comment-layout.md` (the
  Linear-parity golden shape).
