# Contract — `--workstate` direct input (Q8)

The reconcile entrypoint can be fed a `workstate` document directly, skipping the
spec-kit parser, so any non-spec-kit producer can drive the sink (FR-015, FR-016,
Principle X / §5). This contract governs the flag on `reconcile.sh`, the schema
pin + on-entry validation, the graceful absence of `spec_input`, and the
projection-equivalence guarantee. The vendor-neutral engine is unchanged except
that it accepts this input source.

## Invocation

```text
reconcile.sh --workstate <PATH | -> [--dry-run] [--on-drift=proceed|abort]
             [--quiet] [--config PATH]
```

| Flag | Meaning |
|------|---------|
| `--workstate PATH` | Read the `workstate` document from a file path. |
| `--workstate -` | Read the `workstate` document from standard input (stdin). |

- `--workstate` is **mutually exclusive** with `--spec`/`--all`: when present, no
  `specs/` tree is read. Supplying both is a config error (exit 2).
- All other reconcile flags (`--dry-run`, `--on-drift`, `--quiet`, `--config`)
  retain their 001 meaning.

## Schema pin + on-entry validation

- The accepted document is validated against the **pinned `workstate` schema
  version** (`schema_version` must match the version 001 consumes; Draft 2020-12)
  **on entry, before any write** (FR-016).
- A **malformed or unsupported** document (bad JSON, schema-invalid, or an
  unpinned `schema_version`) is rejected **fail-closed**: nothing is written, no
  partial mirror (US5 scenario 3, Principle VIII).
- File and stdin (`-`) inputs are validated identically; the only difference is
  the read source.

## `spec_input` gracefully absent

The `spec_input` narrative source (the Initiative super-level's `spec.md`
`Input:` line) is the one spec-kit coupling (§5). In workstate-direct mode no
originating `spec.md` exists, so:

- `spec_input` is treated as **gracefully absent**, not an error.
- When the Initiative super-level is on and `source: "spec_input"` resolves to
  nothing, the narrative is simply **unavailable** for that run (no Initiative
  narrative populated); the run still succeeds (FR-014 — narrative never
  inferred or fabricated).

## Projection equivalence

The projection from a `workstate` document MUST equal the projection of the
equivalent `specs/`-tree run over the same content (FR-015, SC-005): same
artifacts, same identity labels, same relationships, same idempotent re-run
behavior. File input and stdin input MUST produce identical projections
(US5 scenarios 1–2).

## Exit codes (consistent with 001 `cli.md`)

| Code | Meaning |
|------|---------|
| 0 | Success; the supplied `workstate` mirrored (or nothing to do). |
| 1 | Completed with per-item warnings. |
| 3 | Jira unreadable / fail-closed read (exhausted retries). |
| 2 | Config or input error — bad flag combo, or a malformed/unsupported `workstate` document (no write). |

Higher code wins when multiple occur (monotonic escalation, per 001).

## Contract tests

- A valid `workstate` file mirrors identically to the equivalent `specs/`-tree
  run (projection equivalence).
- The same document piped on stdin (`--workstate -`) mirrors identically to the
  file case.
- A malformed/unsupported document is rejected on entry with exit 2 and zero
  writes.
- `--workstate` with the Initiative super-level on and no `spec_input` succeeds
  with the narrative gracefully absent (no hard failure).
- `--workstate` combined with `--spec`/`--all` is a config error (exit 2).
