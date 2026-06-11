# Phase 1 Data Model: ADR / Decision-Record Mirroring

No persisted engine state (Principle II) — idempotency rides the hidden comment
marker. The "model" is the neutral `decisions[]` workstate field and the per-run
mirror decision. Identity is carried by Jira labels/markers + the decision id.

## Entities

### ADR (decision record)

One decision extracted from a spec's `research.md` decision block.

| Field | Meaning | Source |
|---|---|---|
| `id` | stable decision key | heading id (`D<N>`/`R<N>`/`ADR-<N>`) else title-slug (positionally disambiguated) — research R2 |
| `title` | the decision heading text / first line | heading |
| `status` | decision status; default **"Accepted"** when absent | block, else default |
| `decision` | the Decision text (multi-line) | block label |
| `rationale` | the Rationale text (omitted if absent) | block label |
| `alternatives` | the Alternatives text (omitted if absent) | block label |
| `source` | repo-relative back-ref `research.md#<id>` (no URL) | composed — research R7 |

### `workstate.decisions[]` (neutral floor field — the Jira-sibling delta)

The vendor-neutral carrier: `item.decisions[]` is an array of ADR records (above).
The parser PRODUCES it; the Jira sink CONSUMES only it (Principle X). Empty `[]`
when the spec has no `research.md` or no decision blocks. Added to the committed
workstate schema as an **optional** floor field (back-compatible — absent on items
that predate it). Carries NO Jira vocabulary (neutrality gate unaffected).

### ADR comment + identity marker

The mirrored Jira comment on the spec issue:

- **Marker**: hidden `[speckit-adr:<spec_num>-<id>]` — locates the one comment by
  identity (not content), distinct from the clarify marker `[speckit-note:…]`.
- **Body**: the parity-locked ADR layout (research R6 / `contracts/adr-comment-layout.md`).
- **Digest**: a normalized digest of the rendered body — decides update vs skip (R5).

## State transition (an ADR's fate per reconcile)

```text
                research.md has this decision block?
                          │
              ┌───────────┴───────────┐
            yes                        no
             │                          │
   marker found on the issue?      (nothing — and an
        │            │              already-mirrored ADR
       no           yes             whose block was deleted
        │            │              is left as-is; out of
     CREATE      digest changed?    scope to prune)
   (1 comment)    │          │
              yes │          │ no
                  │          │
              UPDATE in     SKIP
              place         (zero churn)
            (1 comment)
```

## Validation rules

- **VR-1 (FR-003)**: every ADR maps to exactly one marker `[speckit-adr:<spec>-<id>]`;
  the id is deterministic across runs (heading-id else slug).
- **VR-2 (FR-004/SC-002)**: an unchanged corpus ⇒ 0 comment creates, 0 edits
  (digest match → skip).
- **VR-3 (FR-005/SC-003)**: a changed ADR ⇒ exactly 1 edit, 0 creates (find-by-marker
  + digest mismatch → in-place update).
- **VR-4 (FR-006)**: a new ADR ⇒ exactly 1 create, existing untouched.
- **VR-5 (FR-007/SC-004)**: no `research.md` / no blocks ⇒ `decisions[] == []` ⇒ 0
  comments, 0 errors.
- **VR-6 (FR-008)**: ADR comments never touch clarify (`speckit-note:`) comments —
  disjoint marker namespaces.
- **VR-7 (FR-010)**: an unreadable comment probe ⇒ rc 3 fail-closed (no blind
  duplicate); a `DRY-0` placeholder issue ⇒ the probe is skipped.
- **VR-8 (FR-011)**: `decisions[]` validates against the workstate schema; the
  engine path carries no Jira vocabulary (neutrality gate green).
