# Phase 0 Research: Issue-Title Source Ladder

A small, deterministic change to the **neutral title-derivation layer**
(`workstate.sh` + `parser.sh`). Grounded in the existing functions; the three
forks are pinned (ladder order; 120-char word-boundary cap, no ellipsis; no
number prefix). No LLM, no engine/sink change, no schema change.

## R1 — Where the title is derived today (the function to replace)

- **Finding**: `workstate::_spec_title <spec_dir>` (src/workstate.sh ~53–80) is the
  sole title source: first `#` heading → strip `Feature Specification:` label →
  else `parser::short_name` (kebab). Its output flows to `item.title` in
  `workstate::item_for_spec` (~418); the Jira sink maps `item.title` → the issue
  `summary` unchanged.
- **Decision**: rewrite `_spec_title` as the ladder; leave `item_for_spec` and the
  sink untouched. Vendor-neutral by construction (reads `spec.md`, not Jira).

## R2 — Reusable building blocks (don't reinvent)

- `workstate::_spec_body` (~89) already extracts the `## Summary` section (awk:
  capture between `^## Summary$` and the next `^##` heading, trim blank edges). **Reuse**
  it for the first-sentence rung.
- `parser::spec_author` (~450) reads an `Owner:`/`Author:` front-matter line
  (strips bold markers, splits on the first colon, case-insensitive key match,
  trims the value). **Mirror it exactly** for the new `Title:` line.
- `parser::short_name` (~kebab) returns the `NNN-<slug>` suffix — the unchanged
  last-resort rung.

## R3 — New functions (the ladder pieces)

- **Decision**:
  - `parser::spec_title_line <spec_md_path>` — clone of `parser::spec_author` with
    the key `title`. Returns the `Title:` value or empty. (Same path-arg shape.)
  - `workstate::_summary_first_sentence <spec_dir>` — pipe `_spec_body` output
    through: skip leading **non-prose** lines (`>` blockquote, `-`/`*`/`+` list,
    `!` image, ``` fence, `#` heading, `|` table, blank), take the first prose
    line, extract the **first sentence** (up to the first period-then-space, `.`-at-EOL, `?`, or `!`
    terminator; whole line if none), trim. Empty if no prose line exists.
  - `workstate::_cap_title <string>` — if `${#s} ≤ 120` echo verbatim; else cut to
    the longest prefix ≤120 ending on a **word boundary** (last space at/under 120),
    no ellipsis. Pure shell parameter ops — no locale/time/random (Principle II).
- **Rationale**: each piece is a small pure function, unit-testable in isolation;
  composing them keeps `_spec_title` a readable ladder.

## R4 — The ladder (first-match-wins) + backward-compat proof

- **Decision** — rewrite `workstate::_spec_title <spec_dir>`:
  1. `t=parser::spec_title_line(spec.md)` → non-empty ⇒ `_cap_title(t)`, return.
  2. `h1` = first `#` heading minus `Feature Specification:` label. Use ⇔ it is a
     **real concise name**: non-empty AND not the literal `[FEATURE NAME]`
     placeholder AND not byte-equal to `parser::short_name` AND `${#h1} ≤ 120`.
     If so ⇒ `_cap_title(h1)` (a no-op for ≤120), return.
  3. `s=_summary_first_sentence(spec_dir)` → non-empty ⇒ `_cap_title(s)`, return.
  4. `parser::short_name(spec_dir)` (kebab) — last resort.
- **Backward-compat (FR-004/SC-002)**: a clean within-cap H1 hits rung 2 and
  `_cap_title` is a no-op, so the output is **byte-identical to today** → zero
  churn on the majority of well-formed specs. Only the cases that today produced a
  bad title change: placeholder H1, kebab-equal H1, >120 verbose H1 (all demoted to
  Summary/`Title:`), and the no-H1 case (today already kebab, now Summary-first if
  present). Exactly the intended improvements.

## R5 — Length cap = 120, word boundary, no ellipsis (clarify b)

- **Decision**: cap at **120**; truncate at the last space ≤120 (never mid-word);
  no inserted ellipsis (the full text lives in the description body). Applied to the
  `Title:`, H1, and Summary rungs (not the kebab — slugs are short).
- **Rationale**: a readability bound, not a platform limit (Jira/Linear accept
  longer); deterministic and trivial to test.

## R6 — Surface the chosen rung (FR-008, minimal)

- **Decision**: keep the derivation a **pure producer** (no logging side effects in
  the library). FR-008 is satisfied minimally — the resolved title is already
  visible in the reconcile summary's created/updated rows. An optional one-line
  debug note ("title for NNN derived via <rung>") MAY be emitted by the caller, but
  is NOT a workstate field (no schema change). Don't over-engineer.
- **Rationale**: avoids a cross-repo `workstate` floor change for a nicety; keeps
  `_spec_title` side-effect-free and deterministic.

## R7 — Neutrality, privacy, sk-linear port

- **Neutrality (003)**: `workstate::*`/`parser::*` are the neutral producers (they
  carry the `# ORIGIN: copied from spec-kit-linear` shared header); the 003 audit
  targets `reconcile::*` functions, not these. The new functions read `spec.md` and
  contain no Jira vocabulary → the neutrality gate is unaffected.
- **Privacy (IX)**: test fixtures are small placeholder-only `spec.md` variants
  (no real names/coords); `no-real-identifiers.bats` covers them.
- **sk-linear**: the same title logic exists in the sibling; porting this ladder
  there is a **cross-repo follow-up** (design goal, not a dependency of this PR).

## R8 — Testing (pure filesystem, no curl-shim)

- **Decision**: bats unit tests over small `spec.md` fixtures (heredoc or
  `tests/fixtures/titles/`): clean-H1 (regression — byte-identical), placeholder-H1
  +Summary, verbose-H1 +Summary (→ Summary, capped, not the wall), `Title:`-line
  +verbose-H1 (→ Title), Summary-only, neither (→ kebab), a >120 Summary sentence
  (→ capped on word boundary, no mid-word, no ellipsis), and idempotency
  (same fixture twice → identical). No network/shim needed — it's pure parsing.

## Resolved decisions summary

| # | Decision |
|---|---|
| R1 | Rewrite `workstate::_spec_title`; leave `item_for_spec` + sink untouched |
| R2 | Reuse `_spec_body` (Summary), mirror `parser::spec_author` (Title:), keep `short_name` |
| R3 | New `parser::spec_title_line`, `_summary_first_sentence`, `_cap_title` (pure) |
| R4 | 4-rung ladder; clean within-cap H1 byte-identical (zero churn) |
| R5 | cap 120, word boundary, no ellipsis |
| R6 | derivation stays pure; FR-008 minimal (no schema change) |
| R7 | neutral layer (003 safe), placeholder fixtures (IX), sk-linear port = follow-up |
| R8 | pure-filesystem bats fixtures; ladder + cap + idempotency + regression |
