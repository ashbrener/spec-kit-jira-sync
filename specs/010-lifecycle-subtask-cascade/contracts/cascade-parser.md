# Contract: Lifecycle→Subtask Cascade + Phase-Parser Broadening

The neutral cascade decision (`reconcile.sh`) + the reused sink transition
(`jira_sink.sh`), and the parser broadening (`parser.sh`). 003 seam preserved.

## 1. Parser (neutral — `src/parser.sh`)

### Broadened phase-header recognition (3 sites: `:204`, `:249`, `:365`)

- **Match**: a `## Phase` prefix + index `[0-9A-Za-z]+` + a boundary (separator/space/EOL),
  so `## Phaser:` does not match.
- **Index**: the leading `[0-9A-Za-z]+` (string token — numeric or single letter).
- **Name**: the remainder with the separator stripped via
  `sub(/^[^A-Za-z0-9]+/, "", name)` (locale-stable; removes spaces + `:`/`-`/en-dash/
  em-dash bytes without embedding a multibyte char in the regex), then trailing-trim.
- **Output**: `parser::task_phases` emits `<idx>\t<name>` (unchanged shape).
- **Backward-compat**: `## Phase N: Name` ⇒ `<N>\t<Name>` byte-identical (C-5).

## 2. Cascade (neutral decision — `src/reconcile.sh`)

### `reconcile::cascade_phases <item_json> <phase_map_json> <feature_number>`

- For each `<phase_index>\t<subtask_key>` in `phase_map`: read the Subtask's current
  status (`query_issue_full`); unreadable ⇒ `summary::add error` + `promote_exit 3`
  + **abort the cascade for this spec** (no partial). Else `prior = (current ==
  rollup::done_status_id ? complete : partial)`; `rollup::transition_if_changed key
  "complete" prior`:
  - `noop` ⇒ no write (already done — idempotent);
  - `transitioned` ⇒ `summary::add updated "spec N: phase <idx> Subtask cascaded to done (merged)"`;
  - rc 1 (transport) ⇒ `summary::add error` + `promote_exit 1`.
- If `rollup::done_status_id` is empty (unmapped) ⇒ `summary::add warn "spec N:
  merged status unmapped — phase Subtasks not cascaded"` and return (fail-soft).
- **MUST**: carry no Jira vocabulary (the transition lives in the sink); reuse the
  existing `query_issue_full` + `rollup::transition_if_changed`.

### Phase-status dispatch (replaces the guarded `rollup_phases` calls at `:2316`, `:2455`)

```text
if lifecycle_phase == "ready_to_merge" || lifecycle_phase == "merged":
    reconcile::cascade_phases  <item> <phase_map> <feature_number>     # ALWAYS
elif reconcile::status_rollup_enabled:
    reconcile::rollup_phases   <item> <phase_map> <feature_number>     # today's ratio path
# else: no subtask-status write (today's default)
```

## 3. Sink (Jira — `src/jira_sink.sh`) — REUSED UNCHANGED

`rollup::transition_if_changed` (`:1134`) already: `complete` → the `merged` status
via `config::get_status_transition`; `noop` when `computed==prior`; rc 1 on transport
failure. `rollup::done_status_id` (`:1122`) = the merged status. No sink change.

## 4. Index-pipeline string-keying (`src/reconcile.sh`)

The four `[match("[0-9]+$")?][0].string` extractions (`:1237, :1248, :1309, :2656`)
MUST key on the actual phase-index token (numeric **or** letter) so letter-indexed
phases join their tasks + Subtask. Generalize `[0-9]+$` → the index token
(`[0-9A-Za-z]+$` or the exact identity-label suffix).

## 5. Behavioral assertions (testable)

| ID | Assertion |
|---|---|
| C-1 | merged spec + `status_rollup` OFF ⇒ every phase Subtask transitioned to the merged status (curl-shim) |
| C-2 | merged spec re-run unchanged ⇒ zero subtask transitions (idempotent) |
| C-3 | non-terminal spec, rollup OFF ⇒ no subtask-status write (byte-identical to today) |
| C-4 | non-terminal spec, rollup ON ⇒ ratio behavior unchanged from today |
| C-5 | `ready_to_merge` spec ⇒ same cascade as merged |
| C-6 | unreadable subtask read mid-cascade ⇒ exit 3, no partial cascade |
| C-7 | unmapped merged status ⇒ warn + skip (fail-soft), run continues |
| C-8 | `## Phase A — Name` / `## Phase 1 — Name` ⇒ phase detected (idx token + name); Subtask created |
| C-9 | `## Phase N: Name` ⇒ byte-identical parse to pre-feature (idx, name, label, title) |
| C-10 | letter-indexed phase ⇒ tasks attach + Subtask matches (string-keyed index) |
| C-11 | `engine_vendor_neutral.bats` green — cascade decision in reconcile has no Jira vocab |
| C-12 | `no-real-identifiers.bats` green — placeholder-only fixtures |
