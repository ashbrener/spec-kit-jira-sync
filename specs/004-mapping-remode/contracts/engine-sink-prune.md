# Contract: Engine orphan-diff ↔ Sink prune seam

Preserves the 003 engine/sink boundary: the **diff is vendor-neutral** (engine);
the **prune mechanic and descendant reads are Jira-specific** (sink). The
neutrality gate (`tests/unit/engine_vendor_neutral.bats`, 003 FR-012) MUST stay
green — the engine functions below carry no Jira issue-type / artifact-name /
relationship tokens.

## Engine side (neutral — `reconcile.sh`)

### `reconcile::compute_orphans <repo_slug> <item_json...>` → orphan identities

- **Input**: the repo slug and the workstate items (the same the projection sees).
- **Computes**: `D` via `reconcile::compose_identity` over the current mapping's
  issue-projecting levels; obtains `E` by calling the sink enumerator; returns
  `O = E \ D` as a list of `{key, identity_label, level}`.
- **Neutral**: operates only on level names (`repo`/`spec`/`phase`/`task`) and
  identity-label strings. No Jira type/relationship vocabulary.

### `reconcile::remode <scope>` → orchestration

- Drives: read-phase (build `E`, `D`, `O`) → plan/report → (dry-run stop) →
  prune loop (delegates the *mechanic* to the sink) → regenerate via the unchanged
  003 projection.
- **Fail-closed**: if the sink enumerator returns rc 3 (unreadable), abort with
  zero prune calls (FR-005).

## Sink side (Jira-specific — `jira_sink.sh`)

### `jira_sink::enumerate_bridge_descendants <root_key>` → bridge-owned issues (rc 0/3)

- Walks `parent = "<key>"` from the root (Initiative/Epic) down through spec and
  phase levels (reusing the existing `parent = …` JQL pattern).
- Filters candidates through `jira_sink::is_bridge_owned` (R3 predicate).
- **rc 3** on any unreadable search (fail-closed); the engine treats rc 3 as abort.
- **Returns** `{key, labels, parent, updated, status}` per bridge-owned issue.

### `jira_sink::is_bridge_owned <labels_json>` → 0/1

- True iff any label begins with a configured identity prefix
  (`repo_prefix|spec_prefix|phase_prefix|task_prefix`). `lifecycle_prefix` excluded.
- Pure/client-side — no read.

### `jira_sink::prune_artifact <key>` → 0/non-zero

- Dispatches on `config::get remode.destruction` (default `hard-delete`):
  - `hard-delete` → `DELETE /rest/api/3/issue/{key}`.
  - `archive` → transition to the configured archive status id + strip identity
    labels (issue leaves `E`); hard-error (rc 2) if no archive status id is set.
- **Honors `ARG_DRY_RUN`**: logs the intended prune, issues no write (the engine
  also gates the call, but the sink double-checks — defense in depth).
- A failed prune returns non-zero; the engine surfaces it (FR-009) and continues.

## Invariants across the seam

- **I-1**: `prune_artifact` is **only ever** called with a key that came from
  `enumerate_bridge_descendants` (i.e. already passed `is_bridge_owned`). The
  engine never synthesizes a key to prune. (FR-002 — the structural guarantee.)
- **I-2**: No `prune_artifact` call happens before `enumerate_bridge_descendants`
  has returned rc 0 for the entire tree (fail-closed read gate, FR-005).
- **I-3**: Under `--dry-run`, `prune_artifact` issues zero network writes.
- **I-4**: The engine functions stay free of Jira vocabulary (neutrality gate).
