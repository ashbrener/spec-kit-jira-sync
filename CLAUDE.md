# spec-kit-jira — agent context

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
- Tests: `bats --recursive tests/unit`
- Lint (CI parity): `shellcheck --severity=style src/*.sh`,
  `yamllint -d relaxed .github/workflows/ci.yml`,
  `npx markdownlint-cli2 "specs/**/*.md" "*.md"`

## Active feature

<!-- SPECKIT START -->
- **001-core-bridge** — parser→workstate→jira-sink reconcile (Layer D).
  Plan: `specs/001-core-bridge/plan.md`
<!-- SPECKIT END -->
