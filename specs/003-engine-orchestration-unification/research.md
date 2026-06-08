# Research — Engine Orchestration Unification

Three decisions underpin this behavior-preserving re-platforming. The first was
pinned in `/speckit-clarify`; the other two are recorded here.

## Decision 1 — Absorb-then-delete the 001 orchestrators (not retain as adapters)

- **Decision**: Migrate the 001 orchestrators'
  (`ensure_repo_epic`/`sync_spec_issue`/`sync_task_phase_subissues`) behavior into
  the generic projection + a neutral payload composer, then **delete** them once
  unused. (Clarifications 2026-06-08.)
- **Rationale**: A retained adapter leaves a second, Jira-shaped code path that
  weakens FR-006 vendor-neutrality and gives the eventual lift two things to move.
  Deletion yields one projection path and the cleanest lift. The integration tests
  assert *observable writes* (not the function names), so they remain the oracle
  across the swap.
- **Alternatives**: (a) thin adapters over the generic projection — lower-risk but
  leaves dead-ish Jira-shaped shims; (b) keep both, switch by mode — most debt,
  least lift-ready. Both rejected in clarify.

## Decision 2 — Enforce the neutral surface via an enumerated function list

- **Decision**: The neutrality gate (FR-012) audits an **explicit, enumerated
  list** of engine-orchestration function names (recorded in
  `contracts/engine-sink-interface-003.md`), extracting each function's body and
  asserting it contains no Jira issue-type id, artifact-name literal, or
  relationship-vocabulary term.
- **Rationale**: An explicit list is unambiguous and self-documents the audited
  surface; the contract file is the single place to update when the surface
  changes, and the gate fails loudly if a forbidden token appears. Allowed neutral
  tokens (level names `repo`/`spec`/`phase`/`task`, config label prefixes) are
  whitelisted in the gate.
- **Alternatives**: (a) comment-marker delimiters (`# ENGINE-NEUTRAL …`) scanned
  by the gate — flexible but easy to mis-place / forget; (b) file-level split now
  (engine.sh) — rejected by clarify (no physical split in this feature). The
  enumerated list gives the enforcement without the physical move.

## Decision 3 — Equivalence is proven by the unchanged suite + T056 + live dogfood

- **Decision**: "Zero behavior change" is proven by (a) the full existing
  347-test suite passing with **zero test edits**, (b) a new full-stack
  non-default-shape idempotency test (T056), and (c) a live-dogfood zero-churn
  re-run in each mapping mode. Equivalence is defined as **identical observable
  writes** (request method + URL + payload + counts), NOT identical internal call
  order.
- **Rationale**: The suite already asserts request shapes/counts and zero-churn
  across all six modes; if it stays green untouched, the observable behavior is
  unchanged by definition. T056 closes the one gap (engine-driven non-default
  shape, full stack). The live dogfood is the real-world backstop the mock can't
  fully model (it caught 3 ADF bugs in 001 and 1 P1 in 002).
- **Alternatives**: assert exact REST call ordering — rejected; it over-constrains
  the refactor (the orchestration is allowed to reorder internal calls as long as
  the emitted writes match) and isn't what operators observe.
