# Backlog — planned features (not yet specced)

Lightweight capture so ideas survive between sessions. Each becomes a full
spec-kit cycle (`/speckit-specify` …) when picked up. Privacy IX applies: no real
coordinates here.

## Feature 004 (proposed) — Mapping re-mode / orphan pruning

**Captured**: 2026-06-08 · **Sequenced after**: 003 (engine orchestration
unification) · **Status**: idea, not specced.

**Capability**: let an operator change the mapping config (e.g. `spec→Story` →
`spec→Epic`, or 3-level ↔ 2-level checklist) and run a guarded resync that
**prunes the bridge-owned artifacts the new mapping no longer wants and
regenerates the new shape** — so teams can experiment per-project and "see what
feels right" without the board accumulating orphans. The live dogfood proved the
gap: switching modes today leaves orphans (old 3-level Subtasks linger when you
move to a 2-level checklist; mixing configs stacks Subtasks alongside the
checklist). Today the bridge only adds/updates; it never **prunes**.

**Why after 003**: the unified, mapping-driven orchestration (003) is the clean
foundation — a re-mode becomes "compute the desired shape → prune bridge-owned
artifacts not in it → regenerate", driven through one code path rather than
bolted onto the divergent 001/002 paths.

**Framing insight (reframes the "backup?" question)**: Jira is a one-way,
**regenerable projection** of the source-of-truth specs. Bridge-owned *content*
needs no backup — it re-mirrors from the specs at will. The only non-regenerable
data is **human collaboration added directly on the issues** (comments, manual
links, attachments, hand-set statuses). So the destruction model hinges on
whether a team treats the issues as a collaboration surface or a throwaway
projection.

**Key decisions to pin in 004's clarify**:

- **Destruction model**: archive / supersede (preserve the human layer — likely
  default) · hard-delete (cleanest board; safe IF the issues are throwaway, given
  content regenerates) · relabel/detach-only (least destructive). Operator-
  selectable per project is plausible.
- **Scope of pruning**: ONLY bridge-owned artifacts (those carrying the
  `speckit-*` identity labels); NEVER operator-created issues. Fail-safe scoping
  is the crux.
- **Guard**: opt-in flag (e.g. `--remode` / `--prune`), **dry-run first**, and a
  confirmation — never the default reconcile (which stays non-destructive).
- **Idempotency**: after a re-mode, the new shape re-runs zero-churn.
- **Constitution**: this introduces controlled deletion/archival, a departure
  from the non-destructive-mirror principle — may need a constitution note or a
  scoped exception (bridge-owned + opt-in + dry-run).
