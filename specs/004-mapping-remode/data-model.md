# Phase 1 Data Model: Mapping Re-mode / Orphan Pruning

This feature adds **no new persisted state** (Principle II — no fs-side cache; the
orphan set is computed fresh from live reads every run). The "entities" below are
the in-memory sets and the transient prune-plan the re-mode computes during one
invocation. All identity is carried by Jira labels and issue keys — there is no new
schema or sidecar file.

## Entities

### Bridge-owned artifact

A Jira issue the bridge created and manages.

- **Identity**: at least one label whose value begins with a configured identity
  prefix (`repo_prefix` | `spec_prefix` | `phase_prefix` | `task_prefix`). This is
  the **bridge-owned predicate** (research R3) — the sole ownership test.
- **Fields used**: `key`, `labels`, `parent`, `status`, `updated`, `summary`.
- **Invariant (FR-002)**: if the predicate is false, the issue is the operator's
  and is excluded from every set below. Ownership that cannot be proven defaults to
  *operator-owned* (fail-safe).

### Desired-shape set `D`

The identity labels the **current** mapping projects an issue for.

- **Derivation**: `reconcile::compose_identity(level, item, slug[, idx])` over
  every spec × every issue-projecting level of the current mapping (research R1).
- **Excludes** the checklist/task sentinel level (renders into a parent body — no
  issue identity).
- **Includes** the repo identity (and the Initiative identity when the super-level
  is enabled).

### Existing bridge-owned set `E`

The bridge-owned issues currently on the board for this repo.

- **Derivation**: descendant walk from the repo Epic (Initiative when enabled) →
  spec issues → phase issues, each filtered through the bridge-owned predicate
  (research R2/R3).
- **Keyed by**: the issue's identity label (the predicate-matching value), with the
  Jira `key` carried for the prune action.

### Orphan

A bridge-owned artifact the current mapping no longer projects.

- **Definition**: `O = E \ D` by identity label (research R1).
- **Lifecycle**: detected (read) → reported (plan) → pruned (hard-delete | archive)
  → absent on the next enumeration. A prune failure leaves it in `E`, so the next
  re-mode re-detects and retries it (FR-009, resumable).

### Re-mode prune-plan (transient)

The computed plan for one `--remode` invocation. Never persisted.

| Field | Meaning |
|---|---|
| `prune[]` | `O` — `{key, identity_label, drift_warned}` per orphan |
| `regenerate[]` | `D \ E` (creates) ∪ `D ∩ E` (converges) — the new shape |
| `keep[]` | `D ∩ E` already-correct artifacts (zero-churn) |
| `aborted` | true iff a fail-closed read tripped (research R6) — then no pruning |
| `destruction` | `hard-delete` or `archive` (from `remode.destruction`) |

### Destruction model (config)

`remode.destruction` ∈ { `hard-delete` (default), `archive` }.

- **hard-delete**: `DELETE /issue/{key}`. Human layer lost; operator warned on
  drift (FR-010).
- **archive**: transition to a configured archived status **id** + strip identity
  labels (so the issue leaves `E` permanently). Requires the archive status id in
  config; absent ⇒ hard-error with remediation (research R5, Principle V/VIII).

## State transitions (an issue's fate under re-mode)

```text
                      current mapping projects its identity?
                                 │
                ┌────────────────┴─────────────────┐
              yes (∈ D)                          no (∉ D)
                │                                   │
        in E? ──┴── not in E              bridge-owned predicate?
        │            │                       │            │
     converge      create               yes (orphan)   no (operator)
   (zero-churn)   (new shape)               │              │
                                    destruction model    UNTOUCHED
                                     │            │      (FR-002, never
                                hard-delete    archive    read-modified)
                                  (DELETE)   (transition +
                                              strip labels)
```

## Validation rules

- **VR-1 (FR-002/SC-002)**: only issues satisfying the bridge-owned predicate may
  enter `prune[]`. Adversarially tested: operator issues under the same parent,
  with lookalike summaries, must never appear in `prune[]`.
- **VR-2 (FR-005/SC-006)**: `aborted ⇒ |prune executed| = 0`. A single unreadable
  read sets `aborted` before any destructive write.
- **VR-3 (SC-003)**: the `prune[]`/`regenerate[]` reported under `--remode
  --dry-run` equals the set acted on under `--remode` (same computation, gated
  tail).
- **VR-4 (FR-006/SC-005)**: when `D == E` (no shape change), `prune[]` and the
  create portion of `regenerate[]` are empty and the run writes nothing.
- **VR-5 (FR-008)**: every `prune`, `regenerate`, and `keep` is counted in the
  summary; no removal is silent.
