# Implementation Plan: Author-Based Attribution

**Branch**: `007-author-attribution` | **Date**: 2026-06-11 |
**Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/007-author-attribution/spec.md`

## Summary

Make the board reflect **who authored each spec**, as a two-track attribution:

1. **Engine/parser (vendor-neutral) — author resolution.** Per spec, resolve one
   author: an explicit `Owner:`/`Author:` front-matter line in `spec.md` (parser),
   else the **git first-add** author of the spec dir (`git log --diff-filter=A
   --reverse --format='%ae' -- specs/NNN-*/ | head -1`), else *unknown*. Carry it
   on the workstate item as a neutral floor field `author: {value, source}` — no
   Jira vocabulary.
2. **Sink (Jira-specific) — assignee + label.** Load the gitignored operator map
   `jira-authors.local.yml` (`email → {accountId, handle}`; null accountId =
   label-only; `default_assignee`). On the spec-level **create**, set
   `fields.assignee.accountId` when the author resolves to a non-null accountId; on
   **update**, never send assignee (Linear FR-034 — preserves a manual
   reassignment). Always stamp `author:<handle>` (the explicit, non-PII map handle)
   with strip-stale-then-set idempotency (the `phase:*` label hygiene). Fail-soft
   on a bad accountId write (surface, don't abort). Surface author + source in the
   summary.

Opt-in via an `attribution:` config block; **default OFF = byte-for-byte
identical** to today. Privacy IX is a hard gate (the map + a `.sample` are
gitignored/placeholder; labels carry a handle, never an email/accountId).

## Technical Context

**Language/Version**: Bash (bash 4.4+ — CI runs 4.4 + 5.2), `jq` for JSON

**Primary Dependencies**: `jq`, `curl` (REST, shimmed in tests), `git` (the
first-add resolution); existing `src/{parser,git_helpers,workstate,jira_sink,
reconcile,config}.sh`; the workstate schema gains a neutral `author` floor field.

**Storage**: none (filesystem/git in → Jira out; idempotency via the issue's
assignee-on-create + the `author:*` label). The operator map is a gitignored
config file, never a runtime cache (Principle II).

**Testing**: `bats` (unit + integration over the curl-shim), `shellcheck
--severity=style`, `yamllint`, `markdownlint`, the **privacy guard**
(`no-real-identifiers.bats` — extended to the new `.sample` + fixtures), and the
**003 neutrality gate** (`engine_vendor_neutral.bats`).

**Target Platform**: developer/CI shell + live Jira REST v3 (dogfood board)

**Project Type**: single-project CLI / reconcile engine

**Performance Goals**: unchanged — author resolution is one `git log` per spec
(cheap, local); assignee rides the existing create payload; the label rides the
existing label set. No new round-trips on update.

**Constraints**: opt-in/backward-compatible (default OFF, US4 anchor); idempotent
(assignee create-only — never clobbers a manual reassignment, FR-003); fail-soft
on a bad write (FR-008); vendor-neutral engine (FR-009); Privacy IX (FR-010); no
mapping change, no constitutional amendment.

**Scale/Scope**: `parser.sh` (+`Owner:` line), `git_helpers.sh` (+first-add
author), `workstate.sh` (+neutral `author` floor on the item), `jira_sink.sh`
(+authors-map load, assignee-on-create, `author:<handle>` label), `reconcile.sh`
(thread author + the create-vs-update assignee gate + summary), `config.sh`
(+`attribution` accessors), `.gitignore` (+`jira-authors.local.yml`), a committed
`jira-authors.local.yml.sample`, the workstate schema (+`author` floor field).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | How |
|---|---|---|
| I. Filesystem source of truth / read-only mirror | ✅ unchanged | author derives from the fs/git; one-way to Jira; a manual reassignment is *not* overwritten (FR-003) — the bridge surfaces, doesn't enforce. |
| II. Reconcile, never event-push; zero-churn | ✅ preserved | assignee set on create only (no update churn); the `author:*` label is strip-then-set idempotent; off-by-default = byte-identical (SC-004). |
| III. Layered idempotency (D+E) | ✅ Layer D only | attribution is a Layer-D write; Layer E (status webhook) untouched. |
| IV. Write-authority follows fs (drift-aware) | ✅ unchanged | rides the per-spec reconcile; no new write-authority surface. |
| V. ID-based binding | ✅ honored | the accountId is an *id* from the operator map (never resolved by name — the GDPR finding); the map is the binding, gitignored. |
| VI. Credentials at the edges | ✅ unchanged | same Basic-auth path; the authors map is a gitignored operator file (like `.env`/`jira-config.yml`). |
| VII. Memory-just-works / escape hatches | ✅ additive | rides the existing reconcile; no new command; opt-in. |
| VIII. Surface, don't enforce — observable failure | ✅ central | author + source tallied in the summary (FR-001); a bad assignee write is surfaced, not fatal (FR-008); unresolved author is a graceful no-op (not an error). |
| IX. No real identifiers in the tracked tree | ✅ **hard gate** | the map (real emails/accountIds = PII) is **gitignored**; only a placeholder `.sample` is committed; labels carry a **non-PII handle**, never an email/accountId; `no-real-identifiers.bats` extended to cover them. |
| X. workstate is the internal contract | ✅ extended (in-grain) | author is carried as a neutral `author` floor field the parser produces and the sink consumes — not a Jira-shaped model; the email→accountId/handle resolution is the sink's job (the neutral item never holds a Jira id). |

**Architectural-Constraints check:** no change to the constitutional data-model
(repo→Project, spec→Issue, …). Assignee + a label are **attributes on the existing
spec issue**, not a new mapping. So this is **additive + opt-in — no amendment**
(unlike 004). The 003 engine/sink seam holds: author *resolution* (git/spec) is
neutral in the engine/parser; the *assignee/accountId/handle* mechanics are
sink-only.

**Gate result: PASS** — no violations; Complexity Tracking empty.

## Project Structure

### Documentation (this feature)

```text
specs/007-author-attribution/
├── plan.md              # This file
├── research.md          # Phase 0 — R1–R7 design decisions
├── data-model.md        # Phase 1 — Author / authors-map / label / assignee
├── quickstart.md        # Phase 1 — operator walkthrough (enable + map + push)
├── contracts/
│   ├── authors-map.md          # the gitignored jira-authors.local.yml shape + .sample
│   └── attribution-seam.md     # neutral author resolution ↔ sink assignee/label
├── checklists/requirements.md  # (from /speckit-specify)
└── tasks.md             # Phase 2 — /speckit-tasks (NOT created here)
```

### Source Code (repository root)

```text
src/
├── parser.sh        # + parser::spec_author (Owner:/Author: front-matter line)
├── git_helpers.sh   # + git first-add author of a spec dir (--diff-filter=A --reverse)
├── workstate.sh     # + neutral author {value,source} floor on the item
├── config.sh        # + attribution.* accessors (enabled/assignee/label/author_source/authors_file)
├── jira_sink.sh     # + authors-map load; assignee-on-create; author:<handle> label
│                    #   (strip-stale-then-set); fail-soft on a bad assignee write
└── reconcile.sh     # + thread author through; create-vs-update assignee gate; summary row

.gitignore                              # + .specify/extensions/jira/jira-authors.local.yml
.specify/extensions/jira/jira-authors.local.yml.sample   # committed, PLACEHOLDER ids only
config-template.yml                     # + documented opt-in attribution: block
~/Code/AI/workstate-schema/.../workstate.schema.json     # + author floor field (cross-repo)

tests/
├── unit/
│   ├── author_resolution.bats     # Owner: wins; git first-add fallback; neither → unknown
│   ├── authors_map.bats           # mapped→accountId+handle; null→label-only; missing handle→err
│   └── attribution_config.bats    # attribution.* accessors; default OFF
├── integration/
│   ├── attr_us1_assignee_label.bats   # enabled+mapped → assigned + author:<handle> on create
│   ├── attr_us2_nonuser_label.bats    # null accountId → unassigned but labelled; unknown → no-op
│   ├── attr_us3_idempotent.bats       # update sends NO assignee; manual reassign survives; label stable
│   └── attr_us4_off_byte_identical.bats  # default OFF → zero assignee, zero author label
└── unit/no-real-identifiers.bats   # privacy guard — covers the .sample + fixtures
```

**Structure Decision**: Single-project CLI engine (unchanged). Attribution splits
on the **003 seam**: neutral author resolution in `parser.sh`/`git_helpers.sh` →
the neutral `author` floor on the workstate item → the Jira assignee/label
mechanics in `jira_sink.sh`. The operator map is a gitignored config file (the
`.env`/`jira-config.yml` pattern), so no real PII enters the tree.

## Sequencing & dependencies

- **Cross-PR:** 007 touches `jira_sink.sh` + `reconcile.sh`, which **005 (#12,
  pending merge)** also touches — but *different functions* (005: ADR comment
  path; 007: assignee/author-label on the create/update path), so a git merge is
  likely clean. **Flag:** rebase 007 onto post-005 `main` before its PR merges to
  catch any incidental overlap.
- **Cross-repo:** the neutral `author` floor field is a `workstate-schema` change
  (additive-safe, like 005's `decisions[]`). The repo is local/remoteless here, so
  it's a local schema edit; the bridge's CI gate doesn't require it (validation is
  conditional), but add it for strict-validation correctness + Principle X.

## Complexity Tracking

> No Constitution violations — section intentionally empty.
