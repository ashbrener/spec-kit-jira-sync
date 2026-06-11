# Implementation Plan: ADR / Decision-Record Mirroring

**Branch**: `005-adr-mirroring` | **Date**: 2026-06-11 |
**Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/005-adr-mirroring/spec.md`

## Summary

Mirror each spec's **decision records** (the `Decision / Rationale / Alternatives`
blocks in its `research.md`) as **idempotent comments on that spec's Jira issue**,
reusing the existing clarify-session comment machinery. The user-visible shape is
parity-locked to the Linear sibling (008). The work is a near-clone of the
clarify-comment path along a **parallel, isolated channel** so the existing
clarify behavior (and its tests) is untouched:

1. **`parser::decision_records <research.md>`** — tolerant extraction of decision
   blocks (both the bold-lead `**Decision.**` and the stock `- Decision:` forms),
   deriving a stable id (explicit `D<N>`/`R<N>` heading id, else a title slug with
   positional disambiguation).
2. **A neutral `workstate` `decisions[]` floor field** — the parser PRODUCES it,
   the Jira sink CONSUMES it (Principle X). This is the **only** Jira-sibling delta
   vs Linear (which reads `research.md` directly): the Jira bridge's internal
   contract is `workstate`, so ADRs must be expressible there.
3. **`sync_decision_records <issue_key> <item>`** (sink) — one comment per ADR with
   a stable hidden marker `[speckit-adr:<spec>-<id>]`; **update-in-place** when a
   normalized digest of the rendered body changes (FR-005); fail-closed read;
   DRY_RUN + `DRY-0` placeholder-guard aware — exactly like `sync_clarify_comments`.
4. **Engine wrapper `reconcile::sync_decision_records`** wired right after
   `reconcile::sync_clarify_comments` at both call sites (`process_spec`,
   `process_workstate_item`), with identical rc-3-fail-closed handling.

**Parity oracle:** the ADR comment's user-visible shape (fields, ordering, source
back-reference, one-comment-per-decision placement) must match Linear 008
(FR-009 / SC-005).

## Technical Context

**Language/Version**: Bash (bash 4.4+ — CI runs 4.4 + 5.2), `jq` for all JSON

**Primary Dependencies**: `jq`, `curl` (REST, shimmed in tests); the existing
`src/{parser,workstate,jira_sink,reconcile,adf,config}.sh`; the workstate schema
(`~/Code/AI/workstate-schema/schema/workstate.schema.json`) gains a `decisions[]`
floor field.

**Storage**: none (filesystem `research.md` in → Jira comments out; no engine-side
state — Principle II; idempotency is carried by the hidden comment marker).

**Testing**: `bats` (unit + integration over the curl-shim), `shellcheck
--severity=style`, `yamllint -d relaxed`, `markdownlint-cli2`, the privacy guard
(`no-real-identifiers.bats`), and the **003 neutrality gate**
(`engine_vendor_neutral.bats`) which must stay green.

**Target Platform**: developer/CI shell + the live Jira REST v3 (dogfood board)

**Project Type**: single-project CLI / reconcile engine

**Performance Goals**: unchanged — one extra read per spec issue (the ADR-comment
existence probe, paginated like the clarify probe) and at most one comment write
per changed/new ADR. Zero-churn on an unchanged corpus.

**Constraints**: idempotent / fail-closed / drift-aware (FR-004/FR-010);
vendor-neutral engine (FR-011 — the neutrality gate); user-visible parity with
Linear 008 (FR-009); Privacy IX; NO mapping change, NO constitutional amendment.

**Scale/Scope**: `parser.sh` (+`decision_records`), `workstate.sh` (+`decisions[]`),
`jira_sink.sh` (+`sync_decision_records` + an ADR ADF/body renderer + the
content-digest compare), `reconcile.sh` (+wrapper + 2 call sites), the workstate
schema (+`decisions[]`), config-template (a documented note only). No new CLI
surface, no new command.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | How |
|---|---|---|
| I. Filesystem source of truth / read-only mirror | ✅ unchanged | `research.md` → Jira comments, one way; a manually edited/deleted ADR comment is re-asserted from disk (manual edits not a control surface). Non-destructive (additive comments). |
| II. Reconcile, never event-push; zero-churn | ✅ preserved | Re-runs read the existing ADR comments and skip unchanged ones (FR-004/SC-002); no fs-side cache; identity is the hidden marker. |
| III. Layered idempotency (D+E) | ✅ Layer D only | ADR mirroring is a Layer-D comment write; Layer E (status webhook) is untouched. |
| IV. Write-authority follows fs (drift-aware) | ✅ unchanged | Rides the same per-spec reconcile; no new write-authority surface. |
| V. ID-based binding | ✅ unchanged | No new ids; the marker is a content-derived label, not a Jira coordinate. |
| VI. Credentials at the edges | ✅ unchanged | Same Basic-auth path. |
| VII. Memory-just-works | ✅ additive | Fires on the existing `after_*` reconcile path; no new command (FR-012). |
| VIII. Surface, don't enforce — observable failure | ✅ central | No `research.md`/no decisions ⇒ graceful no-op, no error (FR-007/SC-004); an unreadable comment read fails closed (FR-010); every create/update/skip is tallied. |
| IX. No real identifiers in the tracked tree | ✅ gated | Fixtures use placeholder coordinates; the source back-ref is a repo-relative `research.md#<id>` (no host/URL); privacy guard stays green (FR-013). |
| X. workstate is the internal contract | ✅ **extended (in-grain)** | ADRs are carried as a neutral `decisions[]` floor field — the parser produces schema-valid `workstate`, the sink consumes only it (FR-011). This is the prescribed way to express a new artifact (Principle X: evolve the floor, don't side-channel), not a violation. |

**Architectural-Constraints check:** the constitutional data-model already maps
*"non-task artifacts → spec-Issue comments."* An ADR is a non-task artifact →
spec-issue comment. So this is **in-grain**: **no mapping change, no amendment**
(unlike 004's controlled-destruction carve-out). The 003 engine/sink seam holds —
the neutral `decisions[]` projection stays in the parser/engine; the comment +
marker + digest mechanics live in the sink.

**Gate result: PASS** — no violations; Complexity Tracking left empty.

## Project Structure

### Documentation (this feature)

```text
specs/005-adr-mirroring/
├── plan.md              # This file
├── research.md          # Phase 0 — design decisions (R1–R8)
├── data-model.md        # Phase 1 — the ADR record + decisions[] + marker
├── quickstart.md        # Phase 1 — operator walkthrough
├── contracts/
│   ├── adr-comment-layout.md     # the parity-locked user-visible ADR shape (vs 008)
│   └── parser-sink-adr.md        # parser::decision_records ↔ sink sync_decision_records
├── checklists/requirements.md    # (from /speckit-specify)
└── tasks.md             # Phase 2 — /speckit-tasks (NOT created here)
```

### Source Code (repository root)

```text
src/
├── parser.sh        # + parser::decision_records (tolerant research.md extraction)
├── workstate.sh     # + workstate::_decisions_json → item.decisions[] (neutral floor)
├── jira_sink.sh     # + sync_decision_records (one comment/ADR, [speckit-adr:…]
│                    #   marker, update-in-place on body-digest change), + an ADR
│                    #   body renderer; reuses query_existing_comment_body + the
│                    #   comment create/update + a digest helper
└── reconcile.sh     # + reconcile::sync_decision_records wrapper; wire after the
                     #   clarify-comment call in process_spec + process_workstate_item

~/Code/AI/workstate-schema/schema/workstate.schema.json   # + decisions[] floor field
config-template.yml  # documented note only (no new required key)

tests/
├── unit/
│   ├── parser_decision_records.bats   # both grammars, ids, multi-line, no-file, no-blocks
│   ├── workstate_decisions.bats       # item.decisions[] shape; empty when absent
│   └── adr_comment_render.bats        # ADR body layout (parity fields/order) + digest
├── integration/
│   ├── adr_us1_mirror.bats            # 2 ADRs → 2 comments; coexist w/ clarify; no-research no-op
│   ├── adr_us2_idempotent.bats        # re-run 0 churn; edit → 1 update; add → 1 create; fail-closed
│   └── adr_parity.bats                # SC-005 shape parity check (golden ADR body)
└── unit/no-real-identifiers.bats      # privacy guard (placeholders only)
```

**Structure Decision**: Single-project CLI engine (unchanged). The ADR path is a
**parallel clone** of the clarify-comment path along the same pipeline
(`parser → workstate → sink`), kept isolated from `notes[]` so existing
clarify-comment counts/behavior and their tests are untouched. The 003 engine/sink
seam is preserved: neutral extraction + `decisions[]` in parser/engine, Jira
comment/marker/digest mechanics in the sink.

## Sequencing (cross-PR)

⚠️ A separate bug-fix PR — **multi-spec phase-Subtask collision + empty-`taskList`
400** — is in flight and touches `src/jira_sink.sh` and `src/reconcile.sh`. 005's
implementation also touches those files. **005 implementation MUST land after that
fix merges** (rebase 005 onto the post-fix `main`) to avoid conflicts. The 005
spec/plan/tasks (docs) have no such conflict and proceed now.

## Complexity Tracking

> No Constitution violations — section intentionally empty.
