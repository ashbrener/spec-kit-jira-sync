# Contract — engine ↔ sink interface, feature-002 additions

This **extends** the 001 `engine-sink-interface.md` — it does not restate it. The
001 read/write/orchestrator signatures are unchanged; feature-002 adds the
sink-side contracts that drive mapping-configured projection, the 2-level
checklist render, status rollup, and the Initiative super-level (FR-003–FR-013,
FR-018). All mapping/Jira logic lives in the sink + config; the vendor-neutral
engine stays free of mapping knowledge.

## Engine boundary (unchanged except the input source)

The engine half of `reconcile.sh` is **unchanged** except that its entrypoint
accepts the `--workstate <file|->` input source (see `workstate-input.md`). It
calls the same orchestrators; the sink resolves the configured mapping behind
those calls. No mapping, relationship, or issue-type knowledge enters the engine
(FR-018).

## Mapping-driven projection (per-level artifact + relationship)

The sink resolves each `workstate` level to its configured artifact and links it
with the configured relationship (validated already at config-load per
`mapping-config.md`).

| Function | Returns | Notes |
|----------|---------|-------|
| `mapping::resolve_level <level>` | `{artifact, relationship_to_parent, on_absent?}` | reads the loaded `mapping:` block (or alias default) |
| `sync_level_artifact <level> <identity_label> <parent_id> <input_json>` | `{id,key}` (issue) or empty (`checklist` sentinel) | create/update the configured artifact under `parent_id` using `relationship_to_parent`; idempotent match by `identity_label` |
| `link_to_parent <child_id> <parent_id> <relationship>` | ok | applies `parent` / `Epic-link`; no-op for `none`/`checklist` |

- A level projecting to a standalone `Task` issue matches/updates by its
  task-identity label (`task_prefix`, Q9) so re-runs update rather than re-create
  (FR-009).
- `checklist`-sentinel levels create **no** child issue; they render into the
  parent body (below).

## 2-level checklist render — keyed sub-tree byte-diff (Q7)

| Function | Returns | Notes |
|----------|---------|-------|
| `render_checklist_subtree <tasks_json>` | ADF taskList fragment | each item **keyed by its `workstate` task id**; stable byte ordering |
| `diff_checklist_subtree <issue_id> <rendered_subtree>` | `changed` \| `unchanged` | byte-compares **only** the checklist sub-tree, not the full body |
| `sync_body_checklist <issue_id> <rendered_subtree>` | ok; **skip write when `unchanged`** | writes the body only when the sub-tree changed (FR-008) |

- A re-run against unchanged tasks re-renders **byte-identical** ADF ⇒
  `unchanged` ⇒ zero writes (US3 scenarios 2, SC-004).
- Reorder / completion-toggle / rename are handled by re-rendering keyed items;
  no item is duplicated and unrelated description edits do **not** trigger a
  rewrite (US3 scenario 3).
- A single stable provenance marker line renders above the checklist sub-tree
  (Q9) without perturbing the byte-stable compare.

## Status rollup — transition only on changed completion (Q11)

Off by default; reuses the 001 `transition_issue` / `config::get_status_transition`
levers — no new status surface.

| Function | Returns | Notes |
|----------|---------|-------|
| `rollup::compute_completion <level_id>` | `complete` \| `partial` | phase: all tasks checked; repo/top: all specs done |
| `rollup::transition_if_changed <issue_id> <computed> <prior>` | `transitioned` \| `noop` | transitions **only** when `computed` ≠ `prior` (forward and backward) |

- All tasks in a phase complete ⇒ that phase's issue → done status; all specs
  complete ⇒ the repo's top issue → done status (FR-011).
- A re-run against **unchanged** completion fires **no transition** (`noop`)
  (FR-012, US4 scenario 3, SC-004).
- With rollup off, only the spec-level status is set — exactly today's behavior
  (US4 scenario 4).

## Initiative super-level + graceful degradation (Q5)

| Function | Returns | Notes |
|----------|---------|-------|
| `initiative::probe_available` | `present` \| `absent` | issue-type metadata probe for the `Initiative` type |
| `ensure_initiative <narrative> <repo_slug>` | `{id,key}` | create/update the Initiative when `present`; narrative only from the explicit `spec_input` source |
| `initiative::degrade_onto_epic <epic_id> <narrative> <repo_slug>` | ok | when `absent`: fold the narrative onto the Epic behind a **stable marker** and carry repo grouping via the existing `repo_prefix` label |

- Degradation **never hard-fails** because the instance lacks Initiative
  (FR-013, SC-007).
- Degradation is **idempotent**: re-runs in the degraded state are zero-churn,
  and a later upgrade to an Initiative-capable instance re-homes the narrative
  without churn.
- `spec→Story` remains the backward-drift anchor; the super-level is **not** a
  new drift surface (FR-010).
- The narrative is populated only from the explicit source, never inferred
  (FR-014). In `--workstate` mode `spec_input` is gracefully absent
  (see `workstate-input.md`).

## Contract tests

Each function gets a bats unit test against the curl-shim: correct request shape,
idempotent no-op on unchanged input, and rc 3 propagation on an unreadable
response. Plus:

- 3-level projection creates Epic/Story/Task with the configured relationships.
- 2-level mode renders the keyed checklist sub-tree; a re-run is zero churn
  (byte-identical sub-tree, no body write).
- Rollup on: phase-complete → phase issue done, all-specs-done → top issue done;
  a re-run on unchanged completion fires no transition.
- Initiative on + present ⇒ Initiative created; on + absent ⇒ degrades onto the
  Epic + repo label with no hard fail, idempotently.
