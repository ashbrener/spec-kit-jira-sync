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
- **003-engine-orchestration-unification** (active) — behavior-preserving
  re-platforming: replace the 001-era orchestrators with one neutral
  mapping-driven level loop, delete them, and enforce a vendor-neutral engine path
  (the extraction prerequisite). Spec+plan done; 347-test suite is the equivalence
  oracle. Plan: `specs/003-engine-orchestration-unification/plan.md`
- **002-configurable-mapping** — configurable artifact mapping (alias default,
  per-level mapping + available-type validation, 2-level checklist, status
  rollup, Initiative super-level, workstate-direct). Merged to main (PR #3),
  live-dogfood-proven. Plan: `specs/002-configurable-mapping/plan.md`
- **004-mapping-remode** — guarded re-mode / orphan pruning (specced+clarified,
  on its own branch; impl after 003). Plan: pending.
- **001-core-bridge** — parser→workstate→jira-sink reconcile (Layer D). Merged.
  Plan: `specs/001-core-bridge/plan.md`
<!-- SPECKIT END -->
