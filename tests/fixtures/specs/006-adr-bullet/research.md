# Phase 0 Research: Bullet-label ADR fixture

Stock spec-kit grammar: bullet/plain labels, case-insensitive.

---

## D2 — Transport protocol

- Decision: Speak HTTP/2 to the upstream.
- Rationale: Multiplexing cuts head-of-line blocking on the fan-out.
- Alternatives considered: HTTP/1.1 keep-alive — rejected (connection storms).

---

## Retry policy

- decision: Retry idempotent reads with capped exponential backoff.
- Rationale: Smooths transient upstream blips without a thundering herd.

---

## Retry policy

- Decision: A second un-headed block sharing the same title slug.
- Rationale: Proves positional disambiguation keeps both keys distinct.

---
