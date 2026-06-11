# Quickstart: ADR / Decision-Record Mirroring

Your specs already record architecture decisions in `research.md` (the
`Decision / Rationale / Alternatives` blocks `/speckit-plan` produces). This
feature surfaces them on the tracker: each decision becomes **one comment on that
spec's Jira issue**, so a reviewer reads the *why* without opening the repo —
exactly as the Linear bridge does it.

## It just works — no new command

ADR mirroring rides the **existing reconcile**. Every `reconcile.sh` (and every
`after_*` hook) now also mirrors the spec's ADRs alongside its clarify-session
comments. No flag, no new command, no config required.

```bash
reconcile.sh --all        # mirrors specs + their ADR comments + clarify comments
reconcile.sh --spec 005   # just this spec
reconcile.sh --all --dry-run   # preview: shows the ADR comments it WOULD post
```

## What lands on the issue

For a `research.md` with two decisions, the spec's Jira issue gains two comments:

```text
ADR R1 — Source + parser: research.md, tolerant
Status: Accepted
Decision: Parse research.md decision blocks, tolerant of both label grammars.
Rationale: Mirrors the clarify-session reader; robust to both real-world formats.
Alternatives: A single strict grammar — rejected (brittle).
Source: research.md#R1
```

…one per decision, in `research.md` order, coexisting with any clarify-session
comments already there.

## Idempotent — re-run freely

- **No change on disk → zero churn.** Re-running posts no new comments and edits
  none.
- **You edit a decision → one comment updated in place.** No duplicate.
- **You add a decision → one new comment.** The rest are untouched.

This is the same at-most-once guarantee the clarify-session comments give — each
ADR comment carries a hidden marker (`[speckit-adr:<spec>-<id>]`) so re-runs find
and reconcile it rather than re-posting.

## Edge behavior

- **No `research.md`, or no decision blocks** → nothing happens, no error.
- **A decision with no explicit status** → shows `Status: Accepted`.
- **A decision missing Rationale or Alternatives** → that line is omitted, not blank.
- **You hand-edit or delete an ADR comment in Jira** → the next reconcile
  re-asserts it from disk (the filesystem is the source of truth).
- **First reconcile (issue not created yet)** → ADR comments land on the
  freshly-created issue in the same run; a `--dry-run` of an unmirrored spec does
  not try to read comments off the placeholder.

## Cross-tracker parity

If you run both the Jira and Linear bridges, the ADR comments look the same in
both — same source (`research.md`), same one-comment-per-decision placement, same
fields and order — so the knowledge reads identically wherever your team works.
