# spec-kit-jira-sync — agent context

A greenfield bridge that mirrors a spec-kit project's specs into **Jira**, the
twin of the shipped `spec-kit-linear`, consuming the neutral `workstate` format
internally. This repo is also the independent second consumer that proves
`workstate`.

## Non-negotiables

- **Privacy (Principle IX)**: NO real Jira coordinates/PII in any tracked file —
  no workspace/company/project names, person names, emails, sites, account ids,
  cloudIds/UUIDs, or tokens. Real values live ONLY in gitignored `.env`,
  `jira-config.yml`, and `tests/.private-deny`. The privacy guard
  (`tests/unit/no-real-identifiers.bats`) gates CI.
- **No AI-attribution trailers** in commit messages.
- **Tests are the gate**; run the exact CI locally before pushing.
- **Engine stays vendor-neutral**: Jira specifics live only in the sink + config
  (the engine is copied from spec-kit-linear, pending later extraction).

## Key references

- Governance: `.specify/memory/constitution.md` (v1.0.0)
- Build strategy / engine seam: `PLAN.md`
- Seed brief: `SEED-BRIEF.md`
- workstate schema: `~/Code/AI/workstate-schema/schema/workstate.schema.json`

## Commands

- Reconcile: `src/reconcile.sh --all [--dry-run] [--on-drift=abort]`
- Slash (write): `/speckit-jira-push` →
  `reconcile.sh [--all|--spec NNN] [--dry-run] [--on-drift=abort|proceed]`
- Slash (read-only preview): `/speckit-jira-status` → `reconcile.sh --dry-run`
- Tests: `bats --recursive tests/unit`
- Lint (CI parity): `shellcheck --severity=style src/*.sh`,
  `yamllint -d relaxed .github/workflows/ci.yml`,
  `npx markdownlint-cli2 "specs/**/*.md" "*.md"`

## Active feature

<!-- SPECKIT START -->
- **No feature currently active** — 001–004 all merged to main. The natural next
  step is the **engine extraction** (carve the now-vendor-neutral engine into a
  shared lib with spec-kit-linear), unblocked by 003's enforced neutrality gate;
  or sink-side Initiative-toggle type-awareness (the 004 T017 follow-up).
- **004-mapping-remode** — guarded, opt-in re-mode / orphan pruning: `--remode`
  prunes the bridge-owned orphans the current mapping no longer projects (orphans
  = E\D over `speckit-*` identity labels) and regenerates the new shape. Fail-safe
  scoping (never touch operator issues), `--remode --dry-run` preview, fail-closed
  reads, default hard-delete (archive optional). Introduced controlled destruction
  via constitution **v1.1.0** carve-out. Merged to main (PR #7); 417-test suite
  green. Known follow-up: sink-side Initiative-toggle type-awareness (T017).
  Plan: `specs/004-mapping-remode/plan.md`
- **003-engine-orchestration-unification** — behavior-preserving re-platforming:
  the 001-era orchestrators replaced by one neutral mapping-driven level loop,
  deleted, with an enforced vendor-neutral engine path (extraction prerequisite).
  Merged to main (PR #6); 365-test suite green.
  Plan: `specs/003-engine-orchestration-unification/plan.md`
- **002-configurable-mapping** — configurable artifact mapping (alias default,
  per-level mapping + available-type validation, 2-level checklist, status
  rollup, Initiative super-level, workstate-direct). Merged to main (PR #3),
  live-dogfood-proven. Plan: `specs/002-configurable-mapping/plan.md`
- **001-core-bridge** — parser→workstate→jira-sink reconcile (Layer D). Merged.
  Plan: `specs/001-core-bridge/plan.md`
<!-- SPECKIT END -->
