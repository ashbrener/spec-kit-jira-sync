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
- **009-title-source-ladder** (active) — make the issue title human-readable: a
  deterministic title-source ladder (NO LLM at reconcile — Principle II) replacing
  today's H1-or-kebab rule in `workstate::_spec_title`. First-match-wins: explicit
  `Title:` line → a concise within-cap `# Feature Specification:` H1 → first
  sentence of `## Summary` → kebab short-name. ~120-char word-boundary cap demotes
  a verbose pasted-Input H1 below the Summary so a wall never becomes the title.
  Backward-compatible (good-H1 specs byte-identical, no churn); vendor-neutral
  (reads spec.md, stays in the neutral layer — 003 gate green); Privacy IX. Fixes
  an operator-reported gap on both bridges (sk-linear port is a follow-up). Spec done.
  Plan: `specs/009-title-source-ladder/plan.md`
- **008-install-seed-ceremony** — the adoption on-ramp: `/speckit-jira-install`
  REST-resolves the binding (project key, issue-type ids, phase→status maps,
  story-points) and writes the gitignored jira-config.yml; `/speckit-jira-seed`
  validates labels + confirms the lifecycle mapping reachable. New
  `config::write_binding` (byte-stable, preserves operator blocks); fail-closed
  exit 2/3; Privacy IX; sink-side (003 untouched). Merged to main (PR #21).
  Plan: `specs/008-install-seed-ceremony/plan.md`
- **007-author-attribution** — two-track attribution: an account-independent
  `author:<handle>` LABEL always, plus a Jira ASSIGNEE only when the author maps
  to a real accountId (create-only, Linear FR-034 parity). Opt-in, default OFF =
  byte-identical. Merged to main (PR #13). Plan: `specs/007-author-attribution/plan.md`
- **006-consumer-privacy-guard** — consumer-side privacy guard: a fail-closed
  pre-write gate scanning the consumer's tracked tree for the operator's own
  resolved coordinates (exact, zero-FP) + Atlassian shapes, two-tier verdict
  (BLOCK = exact coords + `ATATT` + `.atlassian.net` → exit 4, zero writes; WARN =
  generic email/UUID/accountId → surface + proceed). Neutral `src/privacy_guard.sh`
  + `reconcile::privacy_gate` (in the 003 audit) + Jira shapes in the sink.
  Enforces Principle IX (no amendment). Merged to main (PR #18; #17 merged the
  spec only). Plan: `specs/006-consumer-privacy-guard/plan.md`
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
