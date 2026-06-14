# Feature Specification: Consumer-Side Privacy Guard

**Feature Branch**: `006-consumer-privacy-guard`

**Created**: 2026-06-11

**Status**: Draft

**Input**: User description: "Confirm the bridge can never write a real
identifier (Jira email, account id, token, site) into a tracked file in a
CONSUMER repo — resolved config must stay gitignored, creds only in `.env`. Add
the same consumer-side assertion the linear session is getting: after
install/reconcile, scan the consumer's tracked tree (not just this repo) for
email/token/site patterns and fail closed. Today `no-real-identifiers.bats` only
guards THIS repo; extend the contract to the consumer. Defense-in-depth —
symmetric with linear."

## Why this is a careful feature

The bridge ships a CI privacy guard (`tests/unit/no-real-identifiers.bats`,
Principle IX) that scans **this** bridge-development repo's tracked tree for real
Jira coordinates and Atlassian token shapes. That guard protects the bridge's own
public repository. It does **nothing** for the repositories operators install the
bridge into — the **consumer repos**, whose specs the bridge mirrors to Jira.

Yet the consumer repo is exactly where the bridge resolves real coordinates: at
install it writes the resolved `jira-config.yml` (project key, issue-type ids,
status/transition ids) and the operator supplies a real Jira email + Atlassian
API token in `.env`. If any of those real values lands in a **tracked** file in
the consumer repo — a hand-edited config committed by mistake, a debug dump, a
paste into a spec or a README, a `.env` that was never gitignored — it is
committed to the operator's history, and for a public consumer repo it is an
unrecoverable credential/PII leak. The bridge owns that risk because the bridge
is what wrote the real values into the consumer tree in the first place.

This feature closes that gap: a **consumer-side** privacy guard that scans the
**consumer repo's** tracked tree (the repo the extension is installed into, not
this bridge repo) for real Jira-identifier shapes, asserts the resolved
`jira-config.yml` and `.env` are gitignored there, and **fails closed** when a
real identifier shape is found tracked. It is defense-in-depth, symmetric with
the equivalent guard being added to the spec-kit-linear sibling.

## Clarifications

### Session 2026-06-11

The three design forks are resolved per the operator's stated intent ("after
install/reconcile … scan the consumer's tracked tree … fail closed"), plus a
fourth decision on build-vs-off-the-shelf scanners:

- Q: (a) Lifecycle point — install, every reconcile, or a dedicated check? → A:
  **A blocking pre-write gate on every reconcile, AND at install.** No Jira write
  proceeds from a leaking tree (reconcile is the only write path — Principles
  I/II), and a leak is caught the moment the bridge first touches the consumer
  repo. A dedicated on-demand check may additionally expose it (Principle VII),
  but is not the only trigger.
- Q: (b) Scan scope — whole tracked tree or `.specify/` only? → A: **The whole
  tracked tree** (`git ls-files` content) — a leaked value in a README or a debug
  paste is exactly the case to catch; narrowing to `.specify/` would miss it.
- Q: (c) Fail-closed semantics — abort or warn? → A: **Hard abort: exit non-zero,
  zero Jira writes, no MVP override.** A real credential/PII shape in a tracked
  file is a security incident, not a soft warning.
- Q: (d) Build a bespoke guard, or use gitleaks/trufflehog? → A: **Build the
  bespoke, dependency-free known-value + shape guard as the core; recommend (do
  NOT bundle) gitleaks/trufflehog as a complementary, broader net.** The guard's
  forbidden set is mostly **low-entropy PII** (the operator's Jira email, the
  `*.atlassian.net` site, the accountId, the cloudId/UUID) that generic secret
  scanners **miss** (not "secrets") or **false-positive** on (every UUID looks
  like a cloudId). Only the bridge knows its **own exact resolved coordinates**
  (it just read them from the gitignored `.env`/`jira-config.yml` to reach Jira),
  so it can assert "these specific values never appear in the tracked tree" with
  **zero false positives** — something no generic scanner can do. A dep-free
  `grep` over `git ls-files` also keeps the bash/`jq`/`curl` minimal footprint and
  integrates cleanly into the fail-closed pre-write gate. gitleaks/trufflehog are
  **recommended in the install docs** for broader generic-secret hygiene and MAY
  be invoked best-effort if already on `PATH`, but are NEVER a dependency and
  NEVER the core guarantee. (trufflehog live-verification is explicitly out — it
  would hit Jira's API.)

### Session 2026-06-14 (analyze finding C1 — shape-tier scoping)

- Q: The broad shapes (generic email / UUID / 24-hex accountId) under a hard
  fail-closed false-positive heavily — a live scan hit 10+ of this repo's own
  tracked files (reserved `example.com` emails in the sample/docs, fixture UUIDs,
  accountId placeholders), so an all-shapes-fail-closed guard would abort on its
  own repo (breaking the dogfooding edge case + SC-002) and on any consumer repo
  with a contributor email or lockfile UUID. How should the fail-closed set be
  scoped? → A: **Two-tier verdict.** BLOCK (fail-closed, exit 4) on the
  high-precision signals only — the operator's *exact* known coordinates + the two
  vendor-unique shapes (`ATATT…` token prefix, `<name>.atlassian.net` site). WARN
  (surface + proceed) on the broad shapes (generic email / UUID / accountId).
  Best-practice tiering (precision-blocks, recall-warns) that is also more
  faithful to Principle VIII than the original all-shapes-block. FR-002/FR-003
  updated; SC-001/SC-002 re-scoped to the BLOCK tier.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A real identifier in the consumer tree stops the bridge (Priority: P1) 🎯 MVP

An operator has installed the bridge into their own consumer repo. At some point
a real Jira identifier — their Jira login email, an Atlassian API token, the
cloudId/UUID of their site, their Atlassian accountId, or their
`<site>.atlassian.net` host — ends up in a **tracked** file there (a committed
config, a debug paste in a spec, a `.env` that was never gitignored). The next
time the bridge runs its guarded lifecycle point, it scans the consumer repo's
tracked tree, detects the forbidden shape, refuses to proceed, and tells the
operator exactly which file and which shape tripped it.

**Why this priority**: This is the entire point of the feature — the bridge must
never be complicit in committing the operator's real Jira credentials or PII to
their tracked history. Without this slice there is no consumer-side guard.

**Independent Test**: In a throwaway consumer repo, commit a file containing a
BLOCK-tier fixture (a placeholder `<token-prefix>…`-shaped string or a
`<name>.atlassian.net` host), run the guarded lifecycle point, and confirm the
bridge exits 4, names the offending file + shape, and performs no Jira write. Then
remove the offending value and confirm the bridge proceeds normally (a broad-shape
UUID/email left behind surfaces only a non-blocking WARN).

**Acceptance Scenarios**:

1. **Given** a consumer repo with a tracked file containing an Atlassian
   API-token-shaped string (BLOCK tier), **When** the guarded lifecycle point
   runs, **Then** the bridge exits 4, names the file and the matched shape, and
   writes nothing to Jira.
2. **Given** a consumer repo with a tracked file containing a
   `<something>.atlassian.net` site host (BLOCK tier), **When** the guard runs,
   **Then** the bridge fails closed with that file named.
3. **Given** a consumer repo with a tracked file containing the operator's
   **exact** known coordinate (email / token / site / accountId, BLOCK tier via
   the known-value pass), **When** the guard runs, **Then** the bridge fails
   closed with that file named.
4. **Given** a consumer repo with a tracked file containing only a broad-shape
   match (a generic UUID / 24-hex accountId / unrelated email, WARN tier), **When**
   the guard runs, **Then** the bridge **surfaces a warning and proceeds** (it does
   NOT fail closed — the broad shapes are advisory, FR-003).
5. **Given** a consumer repo whose tracked tree carries no BLOCK-tier signal,
   **When** the guard runs, **Then** it does not fail closed and the bridge
   proceeds with its normal work.

---

### User Story 2 - Resolved config and credentials are gitignored in the consumer (Priority: P1)

The bridge writes the operator's resolved `jira-config.yml` into the consumer
repo at install, and the operator keeps real credentials in `.env` there. The
guard asserts both are **ignored by git** in the consumer repo (so they can never
be staged or committed), and fails closed if either the resolved config path or
`.env` is tracked or not ignored.

**Why this priority**: The resolved config and `.env` are the two files that
*legitimately* hold real values in a consumer repo. If they are not gitignored,
the operator's real coordinates and token are one `git add .` away from history.
Asserting the ignore status is the structural safety net that the shape-scan
(US1) backstops — together they are belt-and-suspenders.

**Independent Test**: In a consumer repo, (a) confirm the guard passes when the
resolved `jira-config.yml` and `.env` are gitignored and untracked; (b) make the
resolved config tracked (or remove its ignore rule) and confirm the guard fails
closed naming it; (c) repeat for `.env`.

**Acceptance Scenarios**:

1. **Given** a consumer repo where the resolved `jira-config.yml` and `.env` are
   gitignored and untracked, **When** the guard runs, **Then** it passes.
2. **Given** a consumer repo where the resolved `jira-config.yml` is tracked (or
   not ignored), **When** the guard runs, **Then** the bridge fails closed and
   names the resolved-config path as the violation.
3. **Given** a consumer repo where `.env` is tracked (or not ignored), **When**
   the guard runs, **Then** the bridge fails closed and names `.env` as the
   violation.

---

### User Story 3 - The guard explains what it found and how to fix it (Priority: P2)

When the guard fails closed, the operator gets an actionable message: which
file(s), which forbidden shape class (email / API token / cloudId-UUID /
accountId / site), and the remediation (move the real value into the gitignored
`.env` or resolved `jira-config.yml`, replace the tracked occurrence with a
neutral placeholder, scrub it from history if already committed). The message
MUST NOT echo the full matched secret back in a way that re-leaks it.

**Why this priority**: A guard that fails with an opaque message gets disabled.
Surface-don't-enforce (Principle VIII): the bridge tells the operator precisely
what is wrong and how to fix it, then stops — it does not edit the operator's
files itself.

**Independent Test**: Trigger each forbidden-shape class in a consumer repo and
confirm the failure message names the file, the shape class, and the
remediation, without printing the entire matched value verbatim.

**Acceptance Scenarios**:

1. **Given** a guard failure on a tracked token shape, **When** the bridge
   reports it, **Then** the message names the file, identifies the shape class,
   and states the remediation.
2. **Given** a guard failure, **When** the bridge reports it, **Then** the full
   matched secret is not echoed verbatim (the report identifies the shape, not
   the literal value).

---

### Edge Cases

- **Bridge repo is its own consumer (dogfooding)**: when the bridge repo is the
  repo under guard, the consumer-side scan MUST behave identically and MUST NOT
  conflict with the existing `tests/unit/no-real-identifiers.bats` (the two cover
  the same tree from different entry points; both must agree).
- **No git / detached worktree / shallow clone**: if the consumer "repo" is not a
  git repo (no `git ls-files` possible), the guard cannot enumerate a tracked
  tree. It MUST fail closed (refuse to proceed) rather than silently skip —
  symmetric with the constitution's fail-closed reads (Principle I carve-out
  precedent), unless the clarify decides a narrower scope.
- **Binary files**: the scan MUST skip binary blobs (they cannot be sensibly
  pattern-matched and would produce noise), the same way the existing guard does.
- **Self-match of the guard's own fixtures**: any placeholder/fixture the guard
  ships here MUST be shaped so it does not itself match a forbidden pattern
  (Principle IX — the guard names nobody and embeds no real value, not even
  fragmented across concatenation).
- **A real value split across lines / concatenation**: out of scope for a
  shape-based line scan; the structural shape patterns (token prefix, UUID,
  `.atlassian.net`) catch the high-value cases. Documented as a known limitation,
  not a silent gap.
- **Operator override**: there is intentionally no "ignore this finding" flag in
  the MVP — a real-identifier shape in a tracked file is always a hard stop. (If
  an escape hatch is ever wanted it is a separate, explicitly-amended decision.)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The bridge MUST provide a consumer-side privacy guard that scans
  the **consumer repo's** tracked tree (the repo the extension is installed into),
  not merely this bridge-development repo.
- **FR-002**: The guard MUST detect leaks in tracked files across a **precision
  tier** and a **recall tier** (clarified 2026-06-14):
  - **BLOCK tier (high-precision, fail-closed)** — (1) **KNOWN values**: the
    operator's *own resolved* Jira coordinates, read from the gitignored
    `.env` / `jira-config.yml` / authors-map the bridge just used to reach Jira
    (the exact email, site, token, cloudId, accountId), matched **exactly** for a
    zero-false-positive guarantee; and (2) **high-signal shapes**: the Atlassian
    **API-token** prefix and the **site** host `<name>.atlassian.net` — vendor-
    unique patterns that effectively never occur by accident.
  - **WARN tier (high-recall, non-blocking)** — the broad shapes that match real
    coordinates but also legitimate content: a generic **email**, a
    **cloudId/UUID**, and an Atlassian **accountId** (24-hex). These are
    **surfaced as warnings, never fail-closed**, because under a hard block they
    false-positive on ordinary repo content (a contributor email, a lockfile UUID,
    a 24-hex hash) — and on this repo's own reserved `example.com` placeholders.
  The known-value tier is the primary precise guarantee; the high-signal shapes
  back it; the broad shapes are advisory.
- **FR-003**: On detecting a **BLOCK-tier** value/shape in a tracked file, the
  guard MUST **fail closed** — the bridge refuses to proceed and exits non-zero
  (exit 4) — with no override. On detecting only **WARN-tier** broad shapes, the
  guard MUST **surface a named warning** and **proceed** (Principle VIII —
  surface, don't enforce; a low-confidence heuristic must not halt the operator's
  workflow, the failure mode that gets guards disabled). Rationale (clarified
  2026-06-14): a blocking control with false positives is removed by operators and
  leaves them with zero protection; precision-blocks + recall-warns is the
  industry-standard tiering (GitHub push-protection, gitleaks/trufflehog
  verified-vs-unverified) and is faithful to Principle VIII.
- **FR-004**: The guard MUST assert that, in the consumer repo, the resolved
  `jira-config.yml` (`.specify/extensions/jira/jira-config.yml`) and `.env` are
  **gitignored** and not tracked; if either is tracked or not ignored, the guard
  MUST fail closed and name it.
- **FR-005**: The guard MUST run as a **blocking pre-write gate on every
  reconcile** (so no Jira write proceeds from a leaking tree) **and at install**
  (so a leak is caught the moment the bridge first touches the consumer repo); it
  MAY additionally be exposed as an on-demand check (clarified 2026-06-11).
- **FR-006**: When the guard fails, the bridge MUST report which file(s) tripped
  it and which forbidden-shape class matched, with copy-paste remediation
  (move the real value to the gitignored `.env`/`jira-config.yml`; replace the
  tracked occurrence with a neutral placeholder; scrub history if already
  committed), per surface-don't-enforce (Principle VIII).
- **FR-007**: The guard's failure report MUST NOT echo a full matched secret
  verbatim in a way that re-leaks it; it identifies the shape class and location,
  not the literal value.
- **FR-008**: The guard MUST skip binary files when scanning, consistent with the
  existing `tests/unit/no-real-identifiers.bats`.
- **FR-009**: Every fixture, placeholder, or pattern this feature commits into
  **this** repo MUST itself contain zero real values and MUST be shaped so it does
  not self-match a forbidden pattern (Principle IX); real coordinates stay only in
  the gitignored `.env`, `jira-config.yml`, and `tests/.private-deny`.
- **FR-010**: When the consumer target is not a usable git repo (no enumerable
  tracked tree), the guard MUST fail closed rather than silently skip.
- **FR-011**: The guard MUST be idempotent and side-effect-free on the consumer
  tree — it only reads and reports; it MUST NOT edit, stage, or commit any
  consumer file (Principle I: the bridge never writes back to the filesystem).
- **FR-012**: The consumer-side guard MUST stay vendor-neutral where it can: the
  *mechanism* (enumerate tracked tree, shape-scan, fail closed) is generic; only
  the Jira/Atlassian **shape definitions** (token prefix, `.atlassian.net`,
  accountId/cloudId) are Jira-specific and live with the sink/config, never in the
  shared engine — preserving the engine/sink seam (Architectural Constraints).
- **FR-013**: The guard's behavior MUST be symmetric, at the user-visible level,
  with the spec-kit-linear consumer-side guard (same lifecycle point, same
  fail-closed posture, same gitignore assertion), differing only in the
  vendor-specific shapes (Atlassian token/site/accountId/cloudId vs Linear
  workspace/team/UUID). *(Note: as of 2026-06-11 the Linear sibling guard is not
  yet landed — this repo may lead; symmetry is reconciled when both exist.)*
- **FR-014**: The core guard MUST be **dependency-free** — implemented as a scan
  (`git ls-files` + the known-value/shape match) using only the bridge's existing
  toolchain (bash/`jq`/`grep`), NOT a required third-party binary. Off-the-shelf
  secret scanners (gitleaks, trufflehog) are **recommended in the install docs**
  as a complementary, broader net for *generic* secrets the bridge does not know
  about, and MAY be invoked best-effort **if already present on `PATH`**, but MUST
  NOT be a dependency and MUST NOT be the core guarantee (clarified 2026-06-11).
  Rationale: the forbidden set is mostly low-entropy PII (email/site/accountId/
  cloudId) that generic scanners miss or false-positive on, and only the bridge
  knows its own exact resolved coordinates (FR-002 known-value pass).

### Key Entities *(include if feature involves data)*

- **Consumer repo**: the git repository the operator installed the bridge into;
  the subject of the scan. Distinct from this bridge-development repo.
- **Tracked tree**: the set of files git tracks in the consumer repo (what
  `git ls-files` enumerates) — the only files that can leak into history, and thus
  the scan scope (the **whole** tracked tree, clarified).
- **Known-value set**: the operator's own resolved Jira coordinates (email, site,
  token, cloudId, accountId) read from the gitignored `.env`/`jira-config.yml` —
  matched exactly for a zero-false-positive guarantee (FR-002 pass 1). Never
  written anywhere; held in memory for the scan only.
- **Forbidden shape**: a pattern class describing a real Jira/Atlassian
  identifier without naming any real value, carrying a **tier** (FR-002):
  BLOCK-tier high-signal shapes (API-token prefix, `.atlassian.net` site host) vs
  WARN-tier broad shapes (generic email, cloudId/UUID, accountId). The tier
  decides fail-closed (BLOCK) vs surface-and-proceed (WARN).
- **Resolved config + `.env`**: the two consumer-repo files that legitimately
  hold real values; both MUST be gitignored (the assertion in FR-004).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a consumer repo containing a tracked file with any **BLOCK-tier**
  signal (an exact known coordinate, the `ATATT…` token prefix, or a
  `<name>.atlassian.net` site), the bridge fails closed (exits 4, performs zero
  Jira writes) 100% of the time the guarded lifecycle point runs.
- **SC-002**: In a consumer repo whose tracked tree carries no BLOCK-tier signal
  and whose resolved config + `.env` are gitignored, the guard does **not** fail
  closed and the reconcile proceeds — even when the tree contains broad-shape
  content (placeholder emails, UUIDs, 24-hex strings), which surfaces only as a
  non-blocking WARN. This includes the dogfooding case: running the guard over
  **this** repo's own tree must not fail closed.
- **SC-003**: When the resolved `jira-config.yml` or `.env` is tracked or not
  ignored in the consumer repo, the guard fails closed and names the file 100% of
  the time.
- **SC-004**: Every guard failure names at least one offending file and the
  matched shape class, and no failure message echoes a full matched secret
  verbatim.
- **SC-005**: The feature adds zero real identifiers to this repo's tracked tree:
  the existing `tests/unit/no-real-identifiers.bats` and the new fixtures both
  stay green, and the new guard's own fixtures do not self-match.
- **SC-006**: The user-visible guard behavior matches the spec-kit-linear
  consumer-side guard on lifecycle point, fail-closed posture, and gitignore
  assertion (only the vendor shapes differ).
- **SC-007**: A tracked file carrying only a broad-shape match (a generic email /
  UUID / 24-hex accountId, with no exact known-value and no high-signal shape)
  produces a **non-blocking WARN** and the reconcile still proceeds (exit 0/1, not
  4) — the WARN tier never halts the operator.

## Assumptions

- **Consumer repos are git repositories.** The scan scope is the git-tracked
  tree (`git ls-files`); non-git targets are handled by the fail-closed default
  (FR-010), to be confirmed in clarify.
- **The existing guard's design is the template.** This feature reuses the proven
  pattern of `tests/unit/no-real-identifiers.bats` — shape patterns reconstructed
  so the guard never self-matches, binary-skip, `--`-terminated grep — extended
  from "this repo" to "the consumer repo."
- **Real values live only in gitignored files** (`.env`, resolved
  `jira-config.yml`, `tests/.private-deny`) per Principles VI and IX; the guard
  asserts that arrangement in the consumer rather than introducing a new storage
  location.
- **Lifecycle point and scope leans** ("after install/reconcile," "scan the
  consumer's tracked tree," "fail closed") are carried from the operator's brief
  and the spec-kit-linear sibling as leading leans, to be pinned in clarify.
- **No new hosted backend, daemon, or database** (Architectural Constraints): the
  guard is a read-only scan over the consumer filesystem + git index, run inline
  in the operator's session.
- **Symmetry with spec-kit-linear** is a design goal, not a code dependency: the
  two guards share a contract shape, but the Jira guard ships independently with
  Jira-specific shapes.

## Open Questions — RESOLVED (Clarifications, Session 2026-06-11)

All four forks are pinned in the Clarifications section above:

1. **Lifecycle** → a blocking pre-write gate on **every reconcile**, AND at
   install (optionally also an on-demand check).
2. **Scan scope** → the **whole tracked tree** (`git ls-files`).
3. **Fail-closed** → **hard abort**, exit non-zero, zero Jira writes, no MVP
   override.
4. **Build vs scanners** → build the **bespoke dep-free known-value + shape**
   guard as the core; **recommend (not bundle)** gitleaks/trufflehog as a
   complementary broader net, optionally invoked if on `PATH`, never a dependency.

No open `[NEEDS CLARIFICATION]` markers remain.
