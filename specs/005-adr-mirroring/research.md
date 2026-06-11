# Phase 0 Research: ADR / Decision-Record Mirroring

The five user-facing forks are pinned in the spec's Clarifications (2 from Linear
008 + 3 Jira-specific defaults). This document resolves the *implementation*
decisions, reusing the existing clarify-comment path as the template. Each is
Decision / Rationale / Alternatives.

---

## R1 — Source + parser: `parser::decision_records <research.md>`, tolerant

**Decision.** Parse `<spec_dir>/research.md`. A decision block is a `##`/`###`
heading; its body (until the next heading of equal/higher level) is scanned for
**Decision / Rationale / Alternatives** by *case-insensitive label*, tolerating
BOTH forms: a **bold lead** (`**Decision.**`, `**Decision:**` — this repo's
research.md) and a **bullet/plain label** (`- Decision:`, `Decision:` — spec-kit's
stock template). Values may be multi-line (everything up to the next label or the
block end). Emit one record per block with `{id, title, status, decision,
rationale, alternatives, source}`.

**Rationale.** Mirrors how `parser::clarify_sessions` already reads `spec.md`
sections — a tolerant, label-driven scan is robust to the two real-world grammars
without a brittle fixed template. `research.md` is the native, structured ADR
home spec-kit already produces (clarified: no `docs/adr/`).

**Alternatives.** A single strict grammar (reject the other form) — brittle,
breaks on either this repo's or the stock format. Rejected. Scraping `plan.md`
decision tables — out of scope; `research.md` is the canonical source.

---

## R2 — Stable id: heading-id else title-slug, positionally disambiguated

**Decision.** The decision key is the explicit heading id when the heading carries
one (`D<N>`/`R<N>`/`ADR-<N>`, matched case-insensitively), else a stable slug of
the decision's title/first line (lowercase, non-alphanumerics → `-`, trimmed). If
two un-headed blocks slugify identically, append a deterministic positional suffix
(`-2`, `-3`) in document order.

**Rationale.** The id is the idempotency anchor (R4); it must be deterministic and
survive content edits + reordering (FR-003). Heading ids are the operator's
explicit handle; the slug fallback keeps un-headed blocks mirrorable rather than
dropped; positional disambiguation prevents one block silently overwriting
another (spec edge case).

**Alternatives.** Content-hash id — changes when the decision text is edited, so a
revised ADR would orphan its old comment + post a new one (violates FR-005).
Rejected. Document-position-only id — reordering would re-key everything. Rejected.

---

## R3 — Neutral `workstate.decisions[]` floor field (the Jira-sibling delta)

**Decision.** Add a vendor-neutral `decisions[]` array to the workstate item:
`[{id, title, status, decision, rationale, alternatives, source}]`. The parser
(via `workstate::_decisions_json`) PRODUCES it; the Jira sink CONSUMES only it.
Add the field to the committed workstate schema as an optional floor field.

**Rationale.** The Jira bridge's internal contract is `workstate` (Principle X) —
the sink reads only `workstate`, never the filesystem. So ADRs must be expressible
there; a private side-channel would violate Principle X. This is the *one*
structural difference from Linear 008 (which reads `research.md` directly and needs
no schema change); the user-visible shape stays identical (FR-009). The field is
neutral (no Jira vocabulary), so the 003 neutrality gate is unaffected and the
Linear twin could adopt the same floor field later.

**Alternatives.** Overload the existing `notes[]` (clarify) array — would perturb
clarify-comment counts + their tests, and conflate two artifact kinds. Rejected
(keep a parallel, isolated channel). A Jira-shaped internal model — forbidden by
Principle X. Rejected.

---

## R4 — Idempotent comment: `[speckit-adr:<spec>-<id>]` marker, find-by-key

**Decision.** `sync_decision_records <issue_key> <item>` mirrors each ADR as one
comment carrying a hidden marker `[speckit-adr:<spec_num>-<id>]`. Reuse
`query_existing_comment_body(issue_key, marker)` (the clarify path's paginated
probe): marker PRESENT → the comment exists (go to R5 for update-vs-skip); ABSENT
→ create. The marker is keyed by identity (spec + decision id), NOT by content.

**Rationale.** Identical to the proven clarify-comment at-most-once mechanism, but
keyed by *id* (not content digest) so the comment is located stably across edits
and reordering (FR-003) — which is what enables update-in-place (R5). One marker
namespace (`speckit-adr:`) distinct from clarify (`speckit-note:`) keeps the two
streams isolated (FR-008).

**Alternatives.** Content-digest marker (the clarify path's scheme) — can't update
in place (an edit changes the marker → orphan + duplicate). Rejected for ADRs.

---

## R5 — Update-in-place via a normalized body digest

**Decision.** Render the ADR comment body deterministically (R6). Embed/derive a
**normalized digest** of that rendered body. On a re-run where the marker is found,
compare the desired body's digest to the existing comment's: **match → no-op**
(zero churn, FR-004); **mismatch → edit that one comment in place** (FR-005). The
digest is computed over the normalized rendered body (whitespace-collapsed) so
cosmetic noise doesn't churn.

**Rationale.** FR-005 requires exactly one comment per decision, updated when
content changes. Find-by-id-marker (R4) locates the comment; the digest decides
update vs skip. Normalizing avoids spurious updates from trailing-whitespace/ADF
re-serialization differences (the same discipline the description-diff paths use).

**Alternatives.** Always-edit-on-run — churns every reconcile (violates SC-002).
Rejected. Never-update (skip-if-present) — stale comments after an ADR edit
(violates FR-005). Rejected (this was the un-specced agent's weaker behavior).

---

## R6 — ADR comment layout: parity-locked to Linear 008 (FR-009/SC-005)

**Decision.** One comment per ADR, rendered (ADF for Jira) with this stable
field order: a title line **`ADR <id> — <title>`**, a **Status** line, then
**Decision**, **Rationale**, **Alternatives** (each omitted if the block lacks it,
FR edge case), then a **Source** back-reference `research.md#<id>` (repo-relative,
no URL — R7), then the hidden marker. Missing status → default **"Accepted"**.
This layout is captured in `contracts/adr-comment-layout.md` as the golden shape
both sinks must match; `adr_parity.bats` asserts it.

**Rationale.** FR-009/SC-005 require the user-visible shape to match the Linear
sibling so knowledge transfers between trackers. A single documented contract +
golden test is the parity oracle. ADF (not Markdown) because Jira comments are ADF
(reuse `adf::from_markdown` / the existing comment builders).

**Alternatives.** Free-form rendering — diverges from Linear, fails the parity
check. Rejected.

---

## R7 — Source back-reference = repo-relative `research.md#<id>`

**Decision.** The "source location" is the repo-relative path + anchor
`research.md#<decision-id>` — no host, no full URL.

**Rationale.** A relative path is unambiguous within the repo, identical across
both sinks (parity), and Privacy-IX-clean (a full URL could embed org/host/site
coordinates and would vary per fork). It points the reader at the canonical
source without leaking coordinates.

**Alternatives.** Full GitHub URL — host/org-specific, parity-divergent, Privacy-IX
risk. Rejected.

---

## R8 — Wiring + safety reuse (fail-closed, DRY_RUN, DRY-0)

**Decision.** `reconcile::sync_decision_records <issue_key> <item>` wraps the sink
call and is invoked **right after** `reconcile::sync_clarify_comments` at both call
sites (`process_spec`, `process_workstate_item`), with the same error handling
(rc 3 → fail-closed exit 3; rc≠0 → exit 1). It inherits the clarify path's safety:
an unreadable comment probe fails closed (FR-010); under `DRY_RUN` no write fires;
and it **skips the `DRY-0` placeholder** (the dry-run-of-an-unmirrored-spec guard
from PR #9) so a not-yet-created issue doesn't 404 the ADR probe.

**Rationale.** ADRs are the same *kind* of artifact (a spec-issue comment) as
clarify sessions, so they should inherit the identical, already-proven safety
envelope rather than invent a parallel one — minimal new surface, maximal reuse.

**Alternatives.** A bespoke ADR write path with its own error handling — more
surface, more risk, divergent behavior. Rejected.

---

## Cross-PR sequencing (not a design decision, a scheduling constraint)

005 touches `jira_sink.sh` + `reconcile.sh`, which PR #10 (multi-spec phase fix)
also touches. **Implement 005 after #10 (and #9) merge**, rebasing onto the
post-fix `main`, to avoid conflicts. Spec/plan/tasks proceed now.

## Resolved unknowns

No `NEEDS CLARIFICATION` remain. The parity oracle is `contracts/adr-comment-
layout.md` + `adr_parity.bats` (SC-005); the safety oracle is the reused
clarify-comment envelope + the new `adr_us2_idempotent.bats` (FR-004/005/010).
