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

No clarification session has been run yet. Three genuinely-open design forks are
recorded under **Open Questions (to resolve in /speckit-clarify)** with leading
leans, rather than guessed in `specify`. The leans carry the operator's stated
intent ("after install/reconcile … scan … fail closed") and stay symmetric with
the spec-kit-linear sibling guard.

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
fixture that matches a forbidden shape (e.g. a placeholder
`<token-prefix>…`-shaped string, a `<name>.atlassian.net` host, a UUID), run the
guarded lifecycle point, and confirm the bridge exits non-zero, names the
offending file + shape, and performs no Jira write. Then remove the offending
value and confirm the bridge proceeds normally.

**Acceptance Scenarios**:

1. **Given** a consumer repo with a tracked file containing an Atlassian
   API-token-shaped string, **When** the guarded lifecycle point runs, **Then**
   the bridge exits non-zero, names the file and the matched shape, and writes
   nothing to Jira.
2. **Given** a consumer repo with a tracked file containing a
   `<something>.atlassian.net` site host, **When** the guard runs, **Then** the
   bridge fails closed with that file named.
3. **Given** a consumer repo with a tracked file containing a UUID-shaped
   cloudId or an Atlassian accountId shape, **When** the guard runs, **Then** the
   bridge fails closed with that file named.
4. **Given** a consumer repo whose tracked tree contains only neutral
   placeholders, **When** the guard runs, **Then** it passes silently and the
   bridge proceeds with its normal work.

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
- **FR-002**: The guard MUST detect, at minimum, these Jira/Atlassian
  real-identifier **shapes** in tracked files: (a) a Jira login **email**
  address, (b) an Atlassian **API-token** prefix shape, (c) a **cloudId / UUID**
  shape, (d) an Atlassian **accountId** shape, and (e) a **site** host of the
  form `<name>.atlassian.net`.
- **FR-003**: On detecting any forbidden shape in a tracked file, the guard MUST
  **fail closed** — the bridge refuses to proceed and exits non-zero — rather than
  warn-and-continue. [Lean carried; see Open Question (c).]
- **FR-004**: The guard MUST assert that, in the consumer repo, the resolved
  `jira-config.yml` (`.specify/extensions/jira/jira-config.yml`) and `.env` are
  **gitignored** and not tracked; if either is tracked or not ignored, the guard
  MUST fail closed and name it.
- **FR-005**: The guard MUST run at the correct lifecycle point so that real
  identifiers cannot be written to Jira from a leaking consumer tree. [Lean:
  on every reconcile (the write path), as a pre-write gate; see Open Question
  (a).]
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
  tracked tree), the guard MUST fail closed rather than silently skip. [Lean
  carried; revisit under Open Question (b).]
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
  workspace/team/UUID).

### Key Entities *(include if feature involves data)*

- **Consumer repo**: the git repository the operator installed the bridge into;
  the subject of the scan. Distinct from this bridge-development repo.
- **Tracked tree**: the set of files git tracks in the consumer repo (what
  `git ls-files` enumerates) — the only files that can leak into history, and thus
  the scan scope. [Whole tree vs `.specify/` only is Open Question (b).]
- **Forbidden shape**: a pattern class describing a real Jira/Atlassian
  identifier without naming any real value — email, API-token prefix, cloudId/UUID,
  accountId, `.atlassian.net` site host.
- **Resolved config + `.env`**: the two consumer-repo files that legitimately
  hold real values; both MUST be gitignored (the assertion in FR-004).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a consumer repo containing a tracked file with any of the five
  forbidden shapes, the bridge fails closed (exits non-zero, performs zero Jira
  writes) 100% of the time the guarded lifecycle point runs.
- **SC-002**: In a consumer repo whose tracked tree is placeholder-clean and
  whose resolved config + `.env` are gitignored, the guard passes and adds no
  observable failure on an otherwise-successful run.
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

## Open Questions (to resolve in /speckit-clarify)

These are the genuinely-open design forks. Each carries a leading lean from the
operator's brief / the spec-kit-linear sibling; clarify pins the final answer.

- **(a) Lifecycle point** — does the guard run at **install** time, on **every
  reconcile** (the write path), or as a **dedicated `speckit.jira.check` command /
  hook**? *Lean*: run on **every reconcile** as a pre-write gate (so no Jira write
  ever proceeds from a leaking tree), and *also* at install (so a leak is caught
  the moment the bridge first touches the consumer repo). A dedicated
  `speckit.jira.check` could additionally expose it as an on-demand escape hatch
  (Principle VII). [NEEDS CLARIFICATION: install-only vs every-reconcile vs
  dedicated check command vs a combination — and whether it is a blocking
  pre-write gate.]
- **(b) Scan scope** — does the guard scan the consumer repo's **whole tracked
  tree** or only its **`.specify/` subtree** (where the bridge writes)? *Lean*:
  **whole tracked tree** — a leaked token in a README or a debug paste is exactly
  the case the existing guard catches, and narrowing to `.specify/` would miss it.
  [NEEDS CLARIFICATION: whole tracked tree vs `.specify/`-only — trade-off is
  coverage vs scan cost / false-positive surface on large consumer repos.]
- **(c) Fail-closed semantics** — on a finding, does the guard **abort the
  reconcile write** (hard stop, exit non-zero) or **warn-and-continue**? *Lean*:
  **abort / fail closed** — a real credential or PII shape in a tracked file is a
  security incident, not a soft warning; the operator's brief says "fail closed."
  [NEEDS CLARIFICATION: hard-abort-the-write vs warn-and-continue — and whether
  any escape-hatch override exists, noting the MVP intends none.]
