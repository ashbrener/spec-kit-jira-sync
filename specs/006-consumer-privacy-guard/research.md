# Phase 0 Research: Consumer-Side Privacy Guard

All four spec forks are already pinned in the spec's Clarifications (lifecycle =
pre-write gate on every reconcile + at install; scope = whole tracked tree;
fail-closed = hard abort; build = bespoke dep-free core, scanners recommended-not-
bundled). This file records the *implementation* decisions those clarifications
imply, grounded in the existing `tests/unit/no-real-identifiers.bats` pattern and
the reconcile/sink seam.

## R1 — Gate placement (the single pre-write chokepoint)

- **Decision**: Insert one neutral gate in `reconcile::main()` **immediately after
  `reconcile::load_config` and before the write dispatch** (the `remode` /
  `run_workstate` / per-spec loop fork at `src/reconcile.sh:2851+`). Every write
  path funnels through that point, so one call covers all of them (FR-005).
- **Rationale**: Reconcile is the only write path (Principle I/II). Gating after
  config-load means the known-value pass can read the resolved coordinates the
  bridge just loaded; gating before the fork guarantees **zero Jira writes** on a
  leak (SC-001) without threading a check into each sync function.
- **Alternatives considered**: a per-spec check (rejected — runs N times, can
  half-write before tripping); a separate top-level wrapper script (rejected —
  bypassable, and the slash commands already call `reconcile.sh`).

## R2 — Vendor-neutral mechanism vs Jira shapes (the engine/sink seam)

- **Decision**: Split into a **neutral mechanism** and a **Jira provider**:
  - `src/privacy_guard.sh` (**NEW, vendor-neutral**): the scanner mechanism —
    enumerate the consumer's tracked tree (`git ls-files -z`), match a set of
    caller-supplied patterns + fixed known-values, skip binaries, assert a set of
    caller-supplied paths are gitignored-and-untracked, and return a structured
    fail-closed verdict. Contains **no** Jira/Atlassian vocabulary — it could be
    extracted alongside the engine.
  - `jira_sink.sh` (**Jira-specific providers**): `jira_sink::privacy_shapes`
    (the five Atlassian shape regexes), `jira_sink::privacy_known_values` (the
    operator's own resolved literals), and `jira_sink::privacy_ignore_targets`
    (the consumer paths that must be gitignored). These are the only
    vendor-aware pieces.
  - `reconcile::privacy_gate` (**neutral orchestrator** in `reconcile.sh`): asks
    the sink for shapes/known-values/ignore-targets, calls
    `privacy_guard::scan`, and on a hit does `summary::add error` +
    `reconcile::promote_exit 4` + returns non-zero (skipping the write fork).
- **Rationale**: FR-012 + the constitutional engine/sink seam (Architectural
  Constraints). The 003 neutrality gate (`engine_vendor_neutral.bats`) audits an
  enumerated list of `reconcile::*` functions for vendor tokens;
  `reconcile::privacy_gate` is **added to that audited list** and stays clean
  (it names no Atlassian term — the shapes come from the sink as opaque data).
- **Alternatives considered**: putting the shape regexes directly in
  `reconcile.sh` (rejected — breaks the neutrality gate); a standalone bats-only
  guard like the existing one (rejected — that guards *this* repo in CI; the
  consumer guard must run inline in the operator's reconcile, FR-001/FR-005).

## R3 — Two-pass detection, reusing the proven guard pattern

- **Decision**: Two passes over `git ls-files -z | xargs -0 grep ... --`:
  1. **Known-value pass** (`grep -F`, fixed strings): the operator's *exact*
     resolved coordinates — `JIRA_EMAIL`, the `JIRA_BASE_URL` host,
     `JIRA_API_TOKEN` (from the environment the slash command exports), and the
     `accountId`s in the gitignored `jira-authors.local.yml`. Zero false
     positives — only the bridge knows these (FR-002 pass 1).
  2. **Shape pass** (`grep -IiE`): the five generic Atlassian shapes (FR-002
     pass 2), the defensive net for values the bridge doesn't hold.
- **Reused mechanics** (from `no-real-identifiers.bats`): `git ls-files -z` for
  NUL-safe enumeration, `-I` to skip binaries (FR-008), `--` to terminate options
  so a path starting with `-` is never read as a flag, and **self-non-matching
  fixtures** — every pattern this feature commits is fragmented across string
  concatenation so the committed source cannot self-match (FR-009, Principle IX).
- **Rationale**: Proven, dep-free (`git` + `grep` only — FR-014), and already the
  CI guard's design, so the two guards agree on the same tree (the dogfooding
  edge case).
- **Note on the known-value pass availability**: the sink does not load `.env`;
  the slash commands export `JIRA_*` before invoking reconcile. When those vars
  are present the known-value pass runs; when absent (env not exported) it is a
  no-op and only the always-on shape pass runs. Documented, not silently skipped.

## R4 — The five Atlassian shape definitions, TIERED (Jira-specific, in the sink)

- **Decision (revised 2026-06-14, analyze C1)**: the shapes carry a **severity
  tier** so the fail-closed action is reserved for high-precision signals. Each
  regex is fragmented in source so it never self-matches (FR-009):
  - **BLOCK tier** (fail-closed — vendor-unique, near-zero false positive):
    - **API token**: the Atlassian Cloud token prefix `ATA`+`TT…` (reuse the CI
      guard's `_structural_patterns` definition).
    - **site host**: `[A-Za-z0-9][A-Za-z0-9-]*\.atlas`+`sian\.net`.
  - **WARN tier** (surface-and-proceed — broad, high false-positive):
    - **email**: `[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}`.
    - **cloudId / UUID**: `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`.
    - **accountId**: `[0-9a-f]{24}` and the `NNNNNN:UUID` form.
- **Rationale**: A live scan (analyze C1) showed the broad shapes hit 10+ of this
  repo's own tracked files (reserved `example.com` emails, fixture UUIDs, accountId
  placeholders) and would hit ordinary consumer content (a contributor email, a
  lockfile UUID, a 24-hex hash). Under a hard block that is a false-positive
  lockout — the failure mode that gets guards disabled (Principle VIII). Tiering
  (precision-blocks, recall-warns) is the industry norm (GitHub push-protection,
  gitleaks/trufflehog verified-vs-unverified) and keeps the **known-value pass**
  (exact, always BLOCK) as the precise guarantee for the operator's *own* email/
  token/site/accountId. Shapes live in `jira_sink.sh`, supplied to the neutral
  scanner as opaque `severity<TAB>class<TAB>pattern` strings.
- **Known limitation (documented, not a silent gap)**: a value split across lines
  / concatenation defeats a line-based scan (spec Edge Cases). The known-value
  pass still catches the operator's own split-free literals; recommending
  gitleaks/trufflehog (R8) covers more.

## R5 — Exit code: a dedicated `4` for a privacy leak

- **Decision**: Add **exit `4` = consumer-tree privacy leak (fail-closed, zero
  writes)** to the reconcile exit-code contract, distinct from `2` (config error)
  and `3` (Jira unreachable). Make `4` **terminal** in `reconcile::promote_exit`
  (never demoted), like `2`.
- **Rationale**: Principle VIII — name the failure class. A leak and a broken
  config are both "halt, zero writes," but the *remediation* differs sharply
  (scrub a secret vs fix ids), and `/speckit-jira-status` + CI need to tell them
  apart. The gate trips before the write fork, so `4` simply short-circuits the
  run.
- **Alternatives considered**: reuse `2` (rejected — conflates two very different
  remediations under one code, weakening the actionable message FR-006). Touch
  points: the `reconcile.sh` header table, `usage()`, and the cli contract — all
  additive, no existing code changes meaning.

## R6 — gitignore assertion (FR-004)

- **Decision**: For each ignore-target the sink names (the resolved
  `.specify/extensions/jira/jira-config.yml`, `.env`, and the
  `jira-authors.local.yml`), assert it is **not tracked**
  (`git ls-files --error-unmatch <path>` returns non-zero) **and**, when it
  exists, **is ignored** (`git check-ignore -q <path>` returns 0). Tracked, or
  present-but-not-ignored ⇒ fail closed and name the path.
- **Rationale**: "Tracked" is the unrecoverable case (already in history);
  "present but not ignored" is one `git add .` from it. A path that simply does
  not exist (no creds yet) is vacuously safe — nothing to leak.

## R7 — Non-git / unenumerable target (FR-010)

- **Decision**: If `git rev-parse --is-inside-work-tree` fails (no enumerable
  tracked tree), the guard **fails closed** (exit `4`) rather than skip.
- **Rationale**: The guard cannot prove the tree is clean, so it must not let a
  write proceed — symmetric with the constitution's fail-closed-reads precedent
  (Principle I carve-out / IV). Surfaced with a clear "not a git repo — cannot
  verify; refusing to write" message.

## R8 — gitleaks / trufflehog: recommended, never required

- **Decision**: Document gitleaks/trufflehog in the install/README as a
  complementary broader net. The guard MAY invoke one **best-effort if already on
  `PATH`** as an *advisory* (its findings are surfaced, but its absence is never
  an error and its presence never replaces the core known-value+shape guarantee).
  trufflehog live-verification stays **off** (it would hit Jira's API).
- **Rationale**: FR-014 + clarify (d). The forbidden set is mostly low-entropy
  PII these scanners miss or false-positive on; the bridge's known-value pass is
  the precise guarantee no generic scanner can offer. Keeping them optional
  preserves the bash/jq/curl minimal footprint.

## R9 — Dry-run interaction

- **Decision**: The gate runs on **every** reconcile, **including `--dry-run`**,
  and fails closed in both modes.
- **Rationale**: The tree's safety is independent of whether *this* run writes. A
  `--dry-run` (the `/speckit-jira-status` preview) that "passed" over a leaking
  tree would give false confidence; failing closed there doubles as the optional
  on-demand exposure the clarify allows (Principle VII). A dry-run that trips the
  guard writes nothing anyway and exits `4` with the same actionable report.

## R10 — Reporting without re-leak (FR-007)

- **Decision**: The scanner collects **files-with-matches only** (`grep -lIE` /
  `grep -lF`), never `grep -n`/the matched line. The report names the **file**
  and the **shape-class label** (`email` / `api-token` / `cloudId-uuid` /
  `accountId` / `site`, or `known-value:<class>`) plus the copy-paste remediation
  — it **never** prints the matched bytes (SC-004, FR-007).
- **Rationale**: `grep -n` would echo the offending line (the secret itself) into
  the operator's terminal/CI log — a re-leak. `-l` returns only the path, so the
  report is leak-free by construction.

## Resolved decisions summary

| # | Decision |
|---|---|
| R1 | One neutral gate in `reconcile::main` after `load_config`, before the write fork |
| R2 | `src/privacy_guard.sh` (neutral) + `jira_sink::privacy_*` providers + `reconcile::privacy_gate` (audited-neutral) |
| R3 | Two passes (`grep -F` known-values, `grep -IiE` shapes) reusing the CI guard's mechanics |
| R4 | Five Atlassian shapes live in the sink, fragmented so they never self-match |
| R5 | New terminal exit `4` = consumer-tree privacy leak |
| R6 | Assert config/.env/authors-map are untracked + ignored |
| R7 | Non-git target ⇒ fail closed |
| R8 | gitleaks/trufflehog recommended + best-effort-if-on-PATH, never required |
| R9 | Gate runs in dry-run too, fails closed (doubles as the on-demand exposure) |
| R10 | Report files + shape-class only (`grep -l`), never the matched bytes |
