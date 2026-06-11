# Phase 0 Research — Sample Feature

Decisions that resolve the open technical choices before design. Each: what was
chosen, why, and what was rejected. No real coordinates appear here; this is a
placeholder fixture (Principle IX).

## D1. Storage format for the widget cache

**Decision**: Use a flat JSON file keyed by widget id, written atomically via a
temp-file rename. The cache is rebuilt from source on a checksum mismatch so a
corrupt file self-heals on the next run.

**Rationale**: A flat file needs no schema migration, round-trips cleanly, and
the atomic rename keeps readers from ever seeing a half-written cache.

**Alternatives rejected**: (a) SQLite — heavier dependency for a single-table
read-mostly cache. (b) One file per widget — more inodes, slower cold start.

## R5 — Retry policy for the upstream fetch

- Decision: Bounded exponential backoff (base 1s, jittered, capped at 30s) with
  a hard limit of 5 attempts, then fail closed for that widget.
- Rationale: Matches the upstream's documented throttling; bounded-then-fail
  avoids unbounded hangs in an unattended run.
- Alternatives: Immediate fail on the first error — too brittle for a flaky
  upstream.

## ADR-3: Authentication transport

Decision — Bearer token read from the environment only; never persisted to disk.

Rationale: keeps the secret confined to the process environment.

Alternatives rejected: a token cache file — widens the secret's blast radius.

## Background notes (no decision here)

This section intentionally carries no Decision statement, so it MUST NOT produce
a decision record. It exists to prove the parser skips non-decision blocks.

- Some context about the feature.
- A link to the upstream docs.
