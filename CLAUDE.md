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
- **006-consumer-privacy-guard** (active) — extend the privacy guarantee from
  this repo to the CONSUMER repos: a fail-closed pre-write gate (every reconcile +
  install) that scans the consumer's whole tracked tree for the operator's own
  resolved coordinates (exact, zero-FP) + generic Atlassian shapes, asserts
  jira-config.yml/.env are gitignored, and hard-aborts (exit 4, zero writes) on a
  hit — naming file+shape-class without re-leaking. Neutral mechanism
  (`src/privacy_guard.sh` + `reconcile::privacy_gate`, in the 003 audit) + Jira
  shapes in the sink. Dep-free core; gitleaks/trufflehog recommended-not-bundled.
  Enforces Principle IX (no amendment). Spec+clarify+plan done.
  Plan: `specs/006-consumer-privacy-guard/plan.md`
- **007-author-attribution** — make the board reflect who authored each
  spec: a two-track attribution — an account-independent `author:<handle>` LABEL
  always (works for non-Jira-users), plus a Jira ASSIGNEE only when the author
  maps to a real accountId (create-only, never clobbered on update — Linear FR-034
  parity). Author = `Owner:` line else git first-add. Static gitignored
  email→accountId map (dynamic resolution is GDPR-impossible). Opt-in, default OFF
  = byte-identical. Additive (no amendment); Privacy IX + 003 neutrality gate are
  the hard gates. Spec+clarify+plan done. Plan: `specs/007-author-attribution/plan.md`
- **005-adr-mirroring** — ADR comment mirroring: each spec's `research.md`
  decision records (Decision/Rationale/Alternatives) mirrored as idempotent
  comments on the spec's Jira issue. Merged to main (PR #12); neutral
  `workstate.decisions[]` floor field. Plan: `specs/005-adr-mirroring/plan.md`
- **Engine extraction** (next-big) — carve the now-vendor-neutral engine into a
  shared lib with spec-kit-linear, unblocked by 003's neutrality gate.
- **004-mapping-remode** — guarded, opt-in re-mode / orphan pruning: `--remode`
  prunes the bridge-owned orphans the current mapping no longer projects and
  regenerates. Controlled destruction via constitution v1.1.0 carve-out. Merged
  to main (PR #7); 417-test suite green. Plan: `specs/004-mapping-remode/plan.md`
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
