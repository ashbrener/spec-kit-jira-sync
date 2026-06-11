# Contract: ADR comment layout (parity-locked to Linear 008)

The **golden user-visible shape** of a mirrored ADR comment. Both sinks (Jira and
Linear) MUST render this same shape (FR-009 / SC-005); `adr_parity.bats` asserts a
Jira-rendered comment against this contract.

## Field order (stable)

1. **Title line** — `ADR <id> — <title>`
2. **Status** — `Status: <status>` (default `Accepted` when the block states none)
3. **Decision** — `Decision: <text>`
4. **Rationale** — `Rationale: <text>` *(omitted entirely if the block has none)*
5. **Alternatives** — `Alternatives: <text>` *(omitted entirely if none)*
6. **Source** — `Source: research.md#<id>` (repo-relative; no host/URL)
7. **Hidden marker** — `[speckit-adr:<spec_num>-<id>]` (a trailing, low-visibility
   text run; the idempotency anchor — not prose the reader cares about)

## Rules

- **One comment per ADR.** Never bundle multiple decisions into a comment, never
  split one across comments.
- **Omit, don't blank.** A missing sub-part (no Rationale / no Alternatives) is
  omitted, not rendered as an empty field (spec edge case).
- **Rendering surface.** Jira: ADF (reuse `adf::from_markdown` / the comment
  builders). Linear: Markdown. The *fields, order, and wording* match; only the
  serialization differs.
- **Marker namespace.** `speckit-adr:` — disjoint from the clarify-session marker
  `speckit-note:` (FR-008), so the two comment streams never collide.
- **Source format.** Always `research.md#<id>` (R7) — identical across both sinks.

## Example (illustrative — placeholders only)

```text
ADR R5 — Re-mode destruction model
Status: Accepted
Decision: Default hard-delete; archive operator-selectable per project.
Rationale: Bridge content is regenerable from the specs; archive keeps the human layer.
Alternatives: relabel/detach-only — rejected (leaves clutter on the board).
Source: research.md#R5
[speckit-adr:004-R5]
```

## Parity test (SC-005)

`adr_parity.bats` renders an ADR from a fixed `research.md` fixture and asserts the
comment body contains these fields in this order with the marker last — the same
assertion the Linear sibling runs against its renderer, so a divergence in either
sink fails its own parity test.
