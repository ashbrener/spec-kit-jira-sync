# Contract: author resolution ↔ assignee/label seam

Preserves the 003 engine/sink boundary. Author **resolution** is vendor-neutral
(engine/parser → the neutral `author` floor field); the **assignee/accountId/label**
mechanics are Jira-specific (sink). The neutrality gate stays green.

## Engine / parser (neutral)

### `parser::spec_author <spec_md>` → `<value>` | empty

- Echoes the value of a `^(Owner|Author):\s*(.+)$` line (case-insensitive) from the
  spec's top matter, else empty. Pure read; no Jira vocabulary.

### `git_helpers::spec_first_author <spec_dir>` → `<email>` | empty

- `git log --diff-filter=A --reverse --format='%ae' -- <spec_dir>/ | head -1`.
  Empty when no git history / not a repo. Neutral.

### `workstate::_author_json <spec_dir>` → `{value, source}` | `{}`

- Resolves per R1 (Owner line first, else git first-add, else empty); wired into
  `item_for_spec` as `item.author`. Neutral floor field — email/owner + a `source`
  enum, never an accountId.

## Sink (Jira-specific — `jira_sink.sh`)

### `jira_sink::_load_authors <path>` → in-memory map (rc 0)

- Reads the gitignored `jira-authors.local.yml`; returns `email → {accountId,
  handle}` + `default_assignee`. Absent file ⇒ empty map (attribution then yields
  no label/assignee for any author — surfaced).

### attribution applied in the spec-level sync

- Inputs: `item.author.{value,source}` + the loaded map + the `attribution.*`
  config + whether this is a CREATE or an UPDATE.
- **Label (always, when `attribution.label`):** desired labels gain
  `author:<handle>` (`map[value].handle`); the existing label diff strips stale
  `author:*` and sets the current (idempotent). A known author with no `handle` ⇒
  config error surfaced (no label).
- **Assignee (when `attribution.assignee`):** on **CREATE** only, if
  `map[value].accountId` is non-null, the create payload gains
  `fields.assignee.accountId`. On **UPDATE**, assignee is never included. A
  rejected assignee write ⇒ fail-soft (surface + still apply the label).
- **Summary:** one row per spec naming the resolved author + source + the outcome
  (assigned / label-only / unknown).

## Engine wiring (`reconcile.sh`)

- Thread `item.author` through the spec-level call; pass the CREATE-vs-UPDATE
  signal (already known from the disposition) so the sink gates assignee correctly;
  surface the attribution outcome in the run summary.

## Invariants

- **I-1 (neutrality):** the engine/parser path (author resolution + the `author`
  floor) carries no Jira issue-type/account/relationship vocabulary; the map +
  accountId + label-handle live only in the sink. `engine_vendor_neutral.bats`
  stays green.
- **I-2 (create-only assignee):** assignee is emitted only in a CREATE payload
  (FR-003) — provable from the recorded request bodies.
- **I-3 (off = identical):** `attribution.enabled` false/absent ⇒ neither path
  runs; payloads are byte-identical to pre-007 (SC-004).
- **I-4 (Privacy IX):** no real email/accountId reaches a tracked file or a label.
