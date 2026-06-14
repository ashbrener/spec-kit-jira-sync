# Phase 1 Data Model: Consumer-Side Privacy Guard

No persisted state (Principle II / Architectural Constraints — no backend, no
database, no sidecar). The "model" is the transient input/output of one read-only
scan run inline in the operator's reconcile. Everything below lives in memory for
the duration of `reconcile::privacy_gate` and is never written anywhere.

## Entities

### Tracked tree (the scan subject)

The set of files `git ls-files` enumerates in the **consumer repo** (cwd at
reconcile time) — the only files that can leak into history, hence the whole
scope (clarified). Binary blobs are skipped (`grep -I`, FR-008). Enumerated
NUL-safe (`-z | xargs -0`) so paths with spaces/newlines are handled.

### Known-value set (pass 1 — exact, zero false positive)

The operator's *own* resolved coordinates, read from the gitignored sources the
bridge already uses, matched as **fixed strings** (`grep -F`):

| Value | Source | Present when |
|---|---|---|
| Jira login email | `$JIRA_EMAIL` | slash command exported `.env` |
| Site host | `$JIRA_BASE_URL` (scheme stripped) | same |
| API token | `$JIRA_API_TOKEN` | same |
| accountId(s) | `jira-authors.local.yml` (007 map) | the map exists |

Held in memory only; never echoed; absent values simply contribute no pattern
(the pass degrades to a no-op, the shape pass still runs).

### Forbidden shape (pass 2 — the defensive net), TIERED

Five Atlassian pattern classes (extended-regex, `grep -IiE`), each describing a
real identifier **without naming any value**, supplied by the sink with a
**severity** that decides the action:

| Class label | Shape (conceptual) | Tier | Action |
|---|---|---|---|
| `api-token` | the Atlassian Cloud token prefix | **block** | fail closed (exit 4) |
| `site` | `<name>.atlassian.net` host | **block** | fail closed (exit 4) |
| `email` | `local@domain.tld` | warn | surface, proceed |
| `cloudId-uuid` | 8-4-4-4-12 hex UUID | warn | surface, proceed |
| `accountId` | 24-hex, or `NNNNNN:UUID` | warn | surface, proceed |

Committed fragmented across concatenation so this repo's own source never
self-matches (FR-009, Principle IX). The **known-value pass** is always `block`
(exact, zero-FP) regardless of class.

### Ignore-target (the FR-004 assertion set)

The consumer paths that legitimately hold real values and therefore MUST be
gitignored-and-untracked, named by the sink:

- `.specify/extensions/jira/jira-config.yml` (resolved binding)
- `.env` (credentials)
- `.specify/extensions/jira/jira-authors.local.yml` (007 map, if used)

Assertion per path: **not tracked** (`git ls-files --error-unmatch` ≠ 0) AND, if
it exists, **ignored** (`git check-ignore -q` = 0). A non-existent path is
vacuously safe.

### Guard verdict (the output)

```text
{ findings: [ { severity, class, file }… ]   # class only — never the matched bytes
  blocked: bool   # true iff any finding.severity == "block" }
```

On `blocked=true`: `summary::add error` per BLOCK finding (file + class +
remediation) + `reconcile::promote_exit 4` + return non-zero — the write fork
never runs. WARN findings → `summary::add warn` and the run **proceeds** (rc 0).
A non-git target is itself a synthetic `block` finding (`class=not-git`).

## Interfaces (the seam — see contracts/privacy-guard.md)

| Function | Module | Neutral? | Responsibility |
|---|---|---|---|
| `privacy_guard::scan` | `src/privacy_guard.sh` | **yes** | enumerate, match, assert-ignored, build verdict |
| `privacy_guard::assert_git` | `src/privacy_guard.sh` | **yes** | confirm an enumerable tracked tree (FR-010) |
| `jira_sink::privacy_shapes` | `src/jira_sink.sh` | no (Jira) | emit the five shape regexes |
| `jira_sink::privacy_known_values` | `src/jira_sink.sh` | no (Jira) | emit the operator's exact literals |
| `jira_sink::privacy_ignore_targets` | `src/jira_sink.sh` | no (Jira) | emit the must-be-ignored paths |
| `reconcile::privacy_gate` | `src/reconcile.sh` | **yes** (audited) | orchestrate; map a hit to exit 4 |

## Validation rules

- **VR-1 (FR-002/FR-003/SC-001)**: a tracked file matching any **BLOCK-tier**
  signal (any known-value, the `ATATT…` token prefix, or a `.atlassian.net` site)
  ⇒ exit 4, zero Jira writes. A tracked file matching only a **WARN-tier** broad
  shape (generic email / UUID / 24-hex accountId) ⇒ a non-blocking WARN row,
  rc 0, reconcile proceeds (SC-007).
- **VR-2 (FR-004/SC-003)**: a tracked-or-unignored ignore-target ⇒ `ok=false`,
  exit 4, the path named.
- **VR-3 (FR-007/SC-004)**: every violation carries a `class` and a file; the
  report never contains the matched bytes (scanner uses `grep -l`, not `-n`).
- **VR-4 (FR-010)**: a non-git / unenumerable target ⇒ `ok=false`, exit 4.
- **VR-5 (FR-011)**: the guard performs only reads (`git ls-files`,
  `git check-ignore`, `grep`); it never edits/stages/commits a consumer file.
- **VR-6 (FR-009/SC-005)**: this feature's committed fixtures/patterns contain
  zero real values and do not self-match; `no-real-identifiers.bats` stays green.
- **VR-7 (FR-012/SC-006)**: `reconcile::privacy_gate` carries no Jira vocabulary
  (003 neutrality gate green); only `jira_sink::privacy_*` is vendor-aware.
- **VR-8 (US4/byte-identical default)**: on a placeholder-clean tree the gate is
  a silent pass — no new summary rows, no behavior change vs today (SC-002).
