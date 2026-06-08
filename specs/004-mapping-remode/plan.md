# Implementation Plan: Mapping Re-mode / Orphan Pruning

**Branch**: `004-mapping-remode` | **Date**: 2026-06-08 |
**Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/004-mapping-remode/spec.md`

## Summary

Add a guarded, opt-in **re-mode** operation that converges a board's bridge-owned
artifacts to the shape the *current* mapping projects — pruning the orphans a
prior mapping shape left behind and regenerating the new shape in one pass — so an
operator can flip mappings back and forth without the board accumulating stale
artifacts. The whole feature is gated on two safety properties: it removes **only**
bridge-owned artifacts (those carrying the `speckit-*` identity labels), and it
acts destructively **only** behind the explicit `--remode` flag (`--remode
--dry-run` previews with zero writes; no separate confirmation — Clarifications
2026-06-08).

**Technical approach** — built on the merged 003 foundation:

- **Orphan identification = a set diff over identity labels.** The *desired-shape
  set* `D` is the identity label `reconcile::compose_identity` already mints for
  every level the current mapping projects (003's neutral level loop). The
  *existing bridge-owned set* `E` is enumerated by walking the repo Epic's
  descendant tree and keeping only issues that carry a label matching a configured
  identity prefix. **Orphans `O = E \ D`** — bridge-owned issues the current
  mapping no longer projects. Operator issues carry no identity-prefix label, so
  they are *structurally* excluded from `E` and can never enter `O` (FR-002 /
  FR-015).
- **Re-mode = `prune(O)` then ordinary `reconcile(D)`.** Regeneration reuses the
  unchanged 003 projection path; re-mode adds only the prune step and the diff in
  front of it. After it, an ordinary reconcile is zero-churn (FR-006).
- **The engine/sink seam from 003 holds.** The orphan **diff** is vendor-neutral
  (it operates on identity labels and level names only) and lives in the engine;
  the **prune mechanic** (hard-delete vs archive) is Jira-specific and lives in
  the sink — so the neutrality gate (003 FR-012) stays green.
- **Fail-closed by construction:** all reads that build `E` complete *before* any
  destructive write; a single unreadable read aborts the re-mode with zero
  deletions (FR-005 / SC-006).

This feature introduces **controlled destruction**, a deliberate departure from
the non-destructive-mirror principle, and therefore **requires a scoped
constitutional amendment as a gating prerequisite** (see Constitution Check).

## Technical Context

**Language/Version**: Bash (bash 4.4+ — CI runs 4.4 + 5.2), `jq` for all JSON

**Primary Dependencies**: `jq`, `curl` (REST, shimmed in tests), the existing
`src/{reconcile,jira_sink,jira_rest,config,adf,workstate,summary}.sh`; the 003
neutral level loop (`reconcile::compose_identity` / `compose_payload` /
`ordered_levels` / `sync_level_artifact`)

**Storage**: none — filesystem specs in → Jira out; no engine-side state cache
(Principle II). The orphan set is computed fresh from live reads every run.

**Testing**: `bats` (unit + integration over the curl-shim), `shellcheck
--severity=style`, `yamllint -d relaxed`, `markdownlint-cli2`, the privacy guard
(`no-real-identifiers.bats`). The fail-safe-scoping property (US2) gets the
heaviest **adversarial** coverage — it is the sole load-bearing safety net.

**Target Platform**: developer/CI shell + the live Jira REST v3 (dogfood board)

**Project Type**: single-project CLI / reconcile engine

**Performance Goals**: re-mode latency dominated by Jira REST round-trips. Orphan
enumeration adds a bounded descendant-walk (one search per parent level); prune is
one DELETE (or one transition) per orphan. No new round-trips on the *ordinary*
reconcile beyond the FR-014 orphan-detection read.

**Constraints**: fail-safe scoping (never touch a non-bridge issue) is absolute;
destructive writes only under `--remode`; dry-run preview must be byte-faithful to
the real action (SC-003); fail-closed reads (SC-006); idempotent/zero-churn after
re-mode (SC-005); vendor-neutral engine path preserved (003 FR-012); Privacy IX.

**Scale/Scope**: arg parsing + a re-mode orchestrator + a neutral orphan-diff in
`reconcile.sh`; a prune primitive + descendant enumeration + a bridge-owned
predicate in `jira_sink.sh`; a `remode.destruction` config key; a constitutional
amendment (v1.1.0). No hosted backend, daemon, or database (unchanged).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | How / Justification |
|---|---|---|
| I. Filesystem source of truth / read-only mirror | ⚠️ **AMENDMENT REQUIRED** | The mirror gains a *destructive* op for the first time. Still one-way (no Jira→fs write-back); the source of truth is unchanged. But "only ever creates/updates, never removes" no longer holds under `--remode`. **Requires a scoped amendment** (below) before destructive code lands. |
| II. Reconcile, never event-push; zero-churn | ✅ preserved | Re-mode reads full state and converges; no event diffs, no fs-side cache. Post-re-mode ordinary reconcile is zero-churn (SC-005); a no-change re-mode writes nothing (FR-006). |
| III. Layered idempotency (D + E) | ✅ Layer D only | Re-mode is a Layer-D operation. Layer E (webhook) is untouched and never prunes. |
| IV. Write-authority follows fs (drift-aware) | ✅ honored + extended | Backward-drift on a to-be-pruned issue is surfaced before deletion (FR-010), reusing the existing drift check; `--on-drift=abort` skips it. Surface, don't block. |
| V. ID-based binding, per-repo config | ✅ unchanged | Prune targets resolved by issue key from live reads; the destruction model is a config key (ids, not names). |
| VI. Credentials at the edges | ✅ unchanged | Same Basic-auth path; no new secret surface. |
| VII. Memory-just-works / escape hatches | ✅ consistent | Re-mode is an explicit **recovery/experimentation** escape hatch, never auto-fired on a hook. The ordinary auto-sync path stays non-destructive. |
| VIII. Surface, don't enforce — observable failure | ✅ central | Every prune/regenerate/skip is reported (FR-008); partial failures are surfaced not swallowed (FR-009); the ordinary reconcile *warns* on detected orphans but never acts (FR-014). |
| IX. No real identifiers in the tracked tree | ✅ gated | All fixtures use placeholders; the privacy guard stays green (FR-012). |
| X. workstate is the internal contract | ✅ unchanged | Desired-shape `D` is computed from `workstate` via the existing projection; no parallel Jira-shaped model. |

**Gate result: CONDITIONAL PASS** — every principle is satisfiable *except*
Principle I, which this feature deliberately amends. Per Governance ("plans that
violate a principle MUST be revised or trigger an amendment before implementation
begins"), the amendment is a **gating prerequisite task** (T00x in Phase 2),
landing *before* any destructive code. See [research.md](./research.md) R9 for the
amendment text and the MINOR-vs-MAJOR rationale (recommended: **MINOR → v1.1.0**,
a new scoped constitutional constraint, not the removal/redefinition that would
force MAJOR).

## Project Structure

### Documentation (this feature)

```text
specs/004-mapping-remode/
├── plan.md              # This file
├── research.md          # Phase 0 — the 9 design decisions (R1–R9)
├── data-model.md        # Phase 1 — entities + the prune-plan state
├── quickstart.md        # Phase 1 — operator walkthrough (flip A→B→A)
├── contracts/
│   ├── remode-cli.md            # the --remode / --dry-run CLI contract
│   └── engine-sink-prune.md     # the neutral orphan-diff ↔ sink-prune seam
├── checklists/
│   └── requirements.md  # (from /speckit-specify)
└── tasks.md             # Phase 2 — /speckit-tasks (NOT created here)
```

### Source Code (repository root)

```text
src/
├── reconcile.sh     # + ARG_REMODE parsing; reconcile::remode orchestrator;
│                    #   reconcile::compute_orphans (NEUTRAL diff: E \ D over
│                    #   identity labels); FR-014 orphan-warning in the ordinary path
├── jira_sink.sh     # + prune_artifact (hard-delete | archive, per config);
│                    #   enumerate_bridge_descendants (parent-walk); a
│                    #   bridge-owned predicate (label matches an identity prefix)
└── config.sh        # + remode.destruction accessor (hard-delete | archive)

config-template.yml  # + remode: { destruction: hard-delete } documented default

tests/
├── unit/
│   ├── compute_orphans.bats          # E\D diff: empty, no-change, each transition
│   ├── bridge_owned_predicate.bats   # identity-prefix membership; operator excl.
│   ├── prune_artifact.bats           # hard-delete vs archive; fail surfaced
│   └── remode_args.bats              # --remode / --remode --dry-run parsing
├── integration/
│   ├── remode_us1_switch_modes.bats          # issue→checklist, type change, Initiative toggle
│   ├── remode_us2_failsafe_scoping.bats       # ADVERSARIAL: operator issues untouched
│   ├── remode_us3_guard_dryrun_fidelity.bats  # ordinary=0 destructive; dry-run==real set
│   ├── remode_us4_idempotent_flip.bats        # A→B→A; no-change re-mode = 0 writes
│   ├── remode_failclosed.bats                 # unreadable read → 0 deletions
│   └── reconcile_orphan_warning.bats          # FR-014 warn-not-prune in ordinary path
└── unit/no-real-identifiers.bats   # privacy guard (extended deny coverage if needed)

.specify/memory/constitution.md     # v1.0.0 → v1.1.0 (controlled-destruction carve-out)
```

**Structure Decision**: Single-project CLI engine (unchanged). The work splits on
the **003 engine/sink seam**: the orphan *diff* is vendor-neutral and lands in
`reconcile.sh` (so the neutrality gate keeps passing); the *prune mechanic* and
*descendant enumeration* are Jira-specific and land in `jira_sink.sh`. No new
top-level module — re-mode is an orchestration mode of the existing engine,
mirroring how 003 wired the level loop.

## Complexity Tracking

> Filled because the Constitution Check carries one deliberate violation.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Destructive op in a non-destructive-mirror project (Principle I departure) | The board cannot be cleaned of prior-shape orphans without removing bridge-owned issues; without it the experiment-with-mapping workflow accumulates permanent stale artifacts (the dogfood-proven gap) | A purely additive "relabel-as-stale" approach was considered, but it leaves the orphans on the board (clutter remains) and still mutates issues — it is destruction without the cleanliness payoff. Hard-delete is the clean default; archive is the preserve-the-human-layer option. Both stay strictly bridge-owned + opt-in + dry-run-previewable, which is exactly the scope of the amendment. |
