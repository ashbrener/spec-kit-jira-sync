# Phase 0 Research: Bold-lead ADR fixture

Each decision below is Decision / Rationale / Alternatives.

---

## R1 — Storage engine choice

**Decision.** Use the embedded store; no external service.
A second line of decision prose to prove multi-line values are kept.

**Rationale.** Keeps the deploy single-binary and offline-friendly.

**Alternatives.** A hosted database — rejected (adds an ops surface).

---

## Caching layer

**Decision.** Cache read paths in-process with a bounded LRU.

**Rationale.** The hot reads dominate; a bounded cache caps memory.

---
