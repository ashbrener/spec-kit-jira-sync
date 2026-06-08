# Contract — engine ↔ sink interface, feature-003 unification

This **supersedes the orchestration half** of the 001/002 engine↔sink interface:
the engine stops calling the bespoke 001 orchestrators and instead drives the
generic projection through a neutral level loop. Read/write/projection primitive
signatures from 001/002 are otherwise unchanged. Behavior is byte-for-byte
preserved (FR-002).

## 1. The neutral level loop (engine side)

`reconcile::process_spec` and `reconcile::process_workstate_item` iterate the
ordered levels and drive the projection. No Jira knowledge enters this path.

| Helper (engine) | Returns | Notes |
|---|---|---|
| `ordered_levels()` | level names parent→child | `initiative?`,`repo`,`spec`,`phase`,`task`; the only level vocabulary |
| `compose_identity(level, item)` | identity label | from config label prefixes only (neutral) |
| `compose_payload(level, item)` | `{summary,body,labels,state?}` | from workstate + config labels only (neutral; see data-model rules) |
| `parent_projected_id(level)` | parent issue id or `""` | the projected id of `parent_of(level)` |

Loop (per spec/item): for each level → `compose_identity` + `compose_payload` +
`parent_projected_id` → `sync_level_artifact(level, identity, parent, payload)` →
`link_to_parent(...)` (per the 002 contract; no-op for `none`/`checklist`) →
record disposition. Cross-spec links + clarify comments + rollup + initiative run
exactly as today, keyed by neutral inputs.

## 2. `sync_level_artifact` — extended responsibilities (sink side)

The 002 `sync_level_artifact(level, identity_label, parent_id, input_json)` is
**extended** to absorb what the deleted 001 orchestrators did beyond bare
create/update — all behind the sink seam, emitting identical requests:

- **Status transition**: when `input_json.state` is present and the level maps to
  a status, apply the transition via the existing `config::get_status_transition`
  / `transition_issue` levers — only when the current status differs (zero-churn).
  Reproduces `sync_spec_issue`'s status behavior incl. the merged-not-Done fix.
- **2-level checklist**: when the level's child resolves to the `checklist`
  sentinel, compose the in-body checklist via the shipped `sync_body_checklist`
  (preserving prose, byte-stable sub-tree). Reproduces the US3 path.
- **Repo / spec / phase specifics**: the exact summary/label/body strings come in
  via `input_json` (composed neutrally by the engine), so the sink emits the same
  create/update payloads as `ensure_repo_epic` / `sync_spec_issue` /
  `sync_task_phase_subissues` did.

The 001 orchestrators (`ensure_repo_epic`, `sync_spec_issue`,
`sync_task_phase_subissues`) are **deleted** once nothing calls them.

## 3. Enumerated vendor-neutral surface (the audited list)

The neutrality gate (FR-012) audits exactly these engine-orchestration functions;
this list is the contract — update it here when the surface changes:

```text
reconcile::process_spec
reconcile::process_workstate_item
reconcile::ordered_levels
reconcile::compose_identity
reconcile::compose_payload
reconcile::parent_projected_id
reconcile::rollup_phases
reconcile::rollup_repo_epic
reconcile::sync_initiative
```

**Forbidden** in these bodies: a configured Jira issue-type id; a Jira
artifact-name literal used as a value (`Epic`/`Story`/`Subtask`/`Task`/
`Initiative`); a relationship-vocabulary term (`Epic-link`; `parent`/`checklist`
used as a Jira relationship value). **Allowed** (neutral): the level names
`repo`/`spec`/`phase`/`task`/`initiative`; config label-prefix keys; workstate
field names; disposition tokens.

## 4. Contract tests

- **Equivalence (SC-001)**: the full existing 347-test unit + integration suite
  passes UNCHANGED against the re-platformed orchestration (no test edited for a
  behavior difference; only additive tests).
- **Neutrality gate (FR-012 / SC-003)** — `tests/unit/engine_vendor_neutral.bats`:
  extracts each enumerated function body and asserts zero forbidden tokens; FAILS
  CI if a Jira id / artifact name / relationship term leaks into the engine path.
- **T056 full-stack non-default shape (SC-004)** —
  `tests/integration/us_fullstack_nondefault_zerochurn.bats`: a configured
  non-default label set + parent relationship, mirrored through the wired engine,
  then re-run → 0 created / 0 updated / 0 parent-write across every parent-bearing
  level.
- **Default equivalence (SC-005)**: the default (no-mapping) projection is
  byte-identical to the 001 baseline (existing us1 suite, unchanged).
