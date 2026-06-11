# Feature Specification: Author-Based Attribution (label-first, optional assignee)

**Feature Branch**: `007-author-attribution`

**Created**: 2026-06-11

**Status**: Draft

**Input**: User description: "The bridge creates issues with no assignee, so they
fall to the consumer project's default-assignee policy (in the HUR dogfood,
`assigneeType: PROJECT_LEAD` → every spec shows the project lead, never the actual
author). Make the board reflect WHO authored each spec — as a two-track
attribution: an account-independent authorship **label** always, plus a Jira
**assignee** only when the author maps to a real accountId. Opt-in, backward
compatible, no PII in any tracked file. Mirrors the Linear bridge's FR-034
assignee semantics (assignee on create; never on update)."

## Why this is a careful feature

Two real-world constraints, discovered during the HUR dogfood, shape the whole
design — assignee *alone* cannot represent authorship:

- **Not every author has a Jira account.** Jira assigns only to licensed members.
  In the dogfood, specs 009–011 were authored by someone with no Jira account, so
  they can never be an assignee — yet their authorship must still be visible.
- **Email → accountId cannot be resolved dynamically.** Jira's user-search by
  email is GDPR-restricted (returns nothing); only name search works. So a git
  email cannot be turned into an accountId at runtime — a **static, operator-
  provided map** is required, and it holds real emails + accountIds (PII) so it
  must never be committed.

Therefore attribution is **two-track**: (1) a durable, account-independent
**authorship label** that works for everyone, and (2) an **assignee** set only
when the author resolves to a real accountId. The label is the guarantee; the
assignee is the nicety.

## Clarifications

### Session 2026-06-11

No clarification session has run yet. Three design forks are recorded under
**Open Questions** with leading leans (carried from the operator's brief); they
are resolved in `/speckit-clarify` before `/speckit-plan`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The board shows who authored each spec (Priority: P1) 🎯 MVP

A lead or teammate opens the Jira board and can see, per spec, **who wrote it** —
rather than every spec showing the project lead (the default-assignee policy). For
authors who have a Jira account, the spec's issue is also **assigned** to them.

**Why this priority**: This is the whole point — today the board misattributes
every spec to the project lead. Surfacing the real author (as a label always, and
an assignee when possible) is the complete, valuable slice.

**Independent Test**: With attribution enabled and an author mapped to an
accountId, reconcile a spec and confirm its issue is created **assigned to that
account** and carries an **`author:<handle>` label**.

**Acceptance Scenarios**:

1. **Given** attribution is enabled and the spec's author maps to a Jira
   accountId, **When** the spec's issue is created, **Then** it is assigned to
   that account AND labelled `author:<handle>`.
2. **Given** a spec whose author is resolved from an explicit `Owner:` line in
   `spec.md`, **When** it reconciles, **Then** that author (not the git-derived
   one) is used.

---

### User Story 2 - Non-Jira-users are still attributed (Priority: P1)

A spec authored by someone **without** a Jira account still shows who wrote it —
via the authorship label — even though they cannot be an assignee.

**Why this priority**: This is the constraint that makes assignee-alone
insufficient. Without the label track, every non-member author would be invisible
(or wrongly shown as the project lead). The label is the universal guarantee.

**Independent Test**: With a known author who has **no** accountId (null in the
map), reconcile their spec and confirm the issue is **unassigned** but carries the
`author:<handle>` label.

**Acceptance Scenarios**:

1. **Given** a known author whose map entry is `null` (no Jira account), **When**
   their spec reconciles, **Then** the issue is left unassigned but labelled
   `author:<handle>`.
2. **Given** a spec whose author cannot be resolved at all (no `Owner:` line, no
   git history), **When** it reconciles, **Then** no author label and no assignee
   are set, and the run completes normally (not an error).

---

### User Story 3 - Idempotent and never clobbers a manual reassignment (Priority: P1)

An operator reconciles repeatedly, and may manually reassign an issue in Jira.
Re-running never re-sends the assignee (so the manual reassignment persists) and
keeps exactly one stable `author:*` label.

**Why this priority**: Idempotency is constitutional, and "never overwrite a
manual reassignment" is the operator escape hatch that makes the assignee track
safe to enable — exactly the Linear FR-034 semantics.

**Independent Test**: Reconcile a spec (assignee set on create), manually
reassign it in Jira, reconcile again, and confirm the manual assignee survives and
no assignee field was sent on the update; the `author:*` label is unchanged (not
duplicated).

**Acceptance Scenarios**:

1. **Given** a spec issue already created with an assignee, **When** it is
   reconciled again (update path), **Then** the reconcile sends **no** assignee
   field (a manual reassignment in Jira survives).
2. **Given** a spec whose author label is already present, **When** it reconciles
   again, **Then** exactly one `author:<handle>` label remains (stale `author:*`
   labels are replaced, not stacked).

---

### User Story 4 - Off by default, zero behavior change (Priority: P2)

An operator who has not opted in sees **no change** — issues are created exactly as
today (no assignee, no author label).

**Why this priority**: Backward compatibility is the contract that lets the
feature ship without disturbing every existing consumer; it is the regression
anchor.

**Independent Test**: With `attribution.enabled` absent/false, reconcile and
confirm the issue payloads are byte-for-byte identical to today (no assignee, no
`author:*` label).

**Acceptance Scenarios**:

1. **Given** `attribution.enabled` is false or absent, **When** any spec
   reconciles, **Then** no assignee and no author label are applied — identical to
   current behavior.

### Edge Cases

- **Author has no Jira account** (map value `null`/absent) → label only, no
  assignee (US2).
- **Author unresolvable** (no `Owner:` line, no git history — e.g. a brand-new
  uncommitted spec) → author = unknown; no label, no assignee; not an error.
- **Multi-author spec** (several committers touched the dir) → one author is
  chosen per the resolution policy (see Open Questions (b)); an explicit `Owner:`
  line always overrides.
- **Manual reassignment in Jira** → survives every subsequent reconcile (assignee
  never re-sent on update).
- **A real email appears in a label or tracked file** → forbidden (PII); the label
  carries a non-PII handle, and the map/sample is gitignored/placeholder.
- **The accountId in the map is stale / the user was deactivated** → the assignee
  write may fail; surface it (don't abort the whole reconcile) and keep the label.
- **`Owner:` line names someone absent from the map** → author is known
  (account-independent label still applied), assignee omitted.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001** (author resolution): The system MUST resolve one author per spec, in
  priority order: (1) an explicit `Owner:` (or `Author:`) line in the spec's
  front-matter — authoritative and account-independent; (2) git fallback — the
  first author to add the spec directory (the first commit creating
  `specs/NNN-*/`); (3) neither resolves → author = **unknown** (no label, no
  assignee), and the reconcile MUST NOT fail. The resolved author and its source
  MUST be surfaced in the run summary.
- **FR-002** (identity map): Email → Jira accountId MUST come from a **static,
  operator-provided map** (dynamic resolution is impossible — the GDPR finding).
  The map holds real emails + accountIds (PII) so it MUST live in a **gitignored**
  operator file (`.specify/extensions/jira/jira-authors.local.yml`), never
  committed — mirroring the Linear `*.local.yml` gitignore guarantee. A map value
  of `null`/absent = **known author, not assignable** (label only). A
  `default_assignee: null` = leave unassigned (NOT the project lead). Only a
  `jira-authors.local.yml.sample` with placeholder ids is committed.
- **FR-003** (assignee — create-only, never clobber): On **create** of the
  spec-level artifact, if the author resolves to a non-null accountId, the system
  MUST set the assignee to that account. On **update**, the system MUST NEVER send
  an assignee field (a manual reassignment in Jira persists — idempotency +
  operator escape hatch, matching Linear FR-034). An unresolved/null accountId →
  omit assignee.
- **FR-004** (authorship label — always, account-independent): The system MUST
  stamp an `author:<handle>` label on the spec-level issue, where `<handle>` is a
  stable **non-PII** token (NEVER a raw email — an email is PII on a shareable
  issue). The label MUST be idempotent: stale `author:*` labels are stripped and
  the current one set (the same hygiene as `phase:*` labels).
- **FR-005** (level scoping): Attribution applies at the **spec → Task** level
  (one author per spec). The repo Epic and phase Subtasks are left unassigned;
  they MAY inherit the spec author's **label** (not assignee) behind a config
  toggle, default **spec-level only**.
- **FR-006** (config wiring, opt-in, backward-compatible): An opt-in
  `attribution:` block in `jira-config.yml` governs the feature —
  `{enabled, assignee, label, author_source, authors_file}`. When
  `attribution.enabled` is absent/false, behavior MUST be **byte-for-byte
  identical to today** (no assignee, no author label).
- **FR-007** (project default-assignee — document, don't mutate): The bridge MUST
  NOT change the consumer's project assignee policy. It MUST document loudly that
  if `attribution.assignee` is on and the project default is `PROJECT_LEAD`, an
  unmapped author's issue still lands on the lead — and recommend operators set the
  project default to **Unassigned** for a neutral mirror. (Omitting an assignee is
  not the same as "unassigned" unless the project allows it.)
- **FR-008** (observable failure, fail-soft): A failed assignee write (e.g. a
  stale/deactivated accountId) MUST be surfaced (named in the summary) and MUST NOT
  abort the whole reconcile; the authorship label is still applied.
- **FR-009** (vendor-neutral engine): Author **resolution** (from the spec front-
  matter / git history) is vendor-neutral and lives in the engine/parser; the Jira
  **assignee/accountId** mechanics live in the sink. The 003 neutrality gate
  (`engine_vendor_neutral.bats`) MUST stay green.
- **FR-010** (Privacy IX): No real email, accountId, or other coordinate may
  appear in any tracked file or in any Jira label. The authors map and its sample
  are gitignored/placeholder-only; labels carry a non-PII handle, never an email.
  The privacy guard (`no-real-identifiers.bats`) MUST stay green.

### Key Entities *(include if feature involves data)*

- **Author**: the resolved authorship identity for a spec — an email (from git) or
  an explicit `Owner:` value, plus the resolution source. The unit attribution is
  computed from.
- **Identity map** (`jira-authors.local.yml`, gitignored): the static operator
  table mapping a git email → a Jira accountId (or `null` = not assignable) → and a
  non-PII `handle`. Plus `default_assignee`.
- **Authorship label**: `author:<handle>` on the spec-level issue — the durable,
  account-independent attribution that works for non-Jira-users.
- **Assignee**: the Jira `accountId` set on the spec issue at create time only,
  when the author is mapped to a real account.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With attribution enabled and a mapped author, the spec's issue is
  created **assigned to that account** AND labelled `author:<handle>` (100% of
  mapped authors).
- **SC-002**: A known author with **no** Jira account → the issue is **unassigned
  but labelled** `author:<handle>` (the non-member is still attributed).
- **SC-003**: Re-running reconcile is idempotent — the update path sends **zero**
  assignee fields (a manual reassignment survives), and exactly **one** stable
  `author:*` label remains (no duplication).
- **SC-004**: With `attribution.enabled` false/absent, the issue payloads are
  **byte-for-byte identical** to current behavior (no assignee, no author label).
- **SC-005**: **Zero** PII (email/accountId) appears in any tracked file or in any
  Jira label; the privacy guard stays green.

## Open Questions (to resolve in /speckit-clarify)

Three design forks, each with a leading lean from the operator's brief:

- **(a) Handle scheme for `author:<handle>`** — derive the handle from the
  **local-part of the email**, or require an explicit `handle:` in the map? *Lean*:
  an **explicit `handle:` in the map** — avoids putting PII (email local-part can
  be a real name) in a label and removes ambiguity. [NEEDS CLARIFICATION:
  email-local-part vs explicit map handle for the label token.]
- **(b) Multi-author specs** — when several committers touched the spec dir, pick
  **first-add**, **last**, or **most-commits**? *Lean*: an explicit `Owner:` line
  is the override; **git first-add** is the default. [NEEDS CLARIFICATION:
  first-add vs last vs most-commits as the git-fallback author.]
- **(c) Description memory block** — in addition to the label, also write the
  author into the spec issue's **human-visible description** (a memory block)?
  *Lean*: optional/deferred — the label is the machine-readable attribution; a
  description line is a nicety. [NEEDS CLARIFICATION: also write a human-visible
  author line in the description, or label-only.]

## Assumptions

- **Spec authorship = first git commit adding the spec dir** (the brief's finding),
  overridable by an explicit `Owner:`/`Author:` line.
- **A static map is mandatory** — email→accountId cannot be resolved at runtime
  (GDPR-restricted user search). The map is operator-maintained.
- **Assignee semantics mirror Linear FR-034** — set on create, never on update —
  for cross-sink parity and to preserve manual reassignments.
- **Opt-in, default OFF** — absent/false `attribution` block = today's behavior.
- **Out of scope**: auto-provisioning Jira accounts for non-members (operators
  invite manually); reporter manipulation (the reporter is inherently the API-token
  owner, not changeable without per-developer tokens); dynamic email→account
  resolution (impossible per the GDPR finding).
- **Dependencies**: builds on the 001 core bridge (spec-level issue create/update +
  labels), the 002 configurable mapping (the spec issue may be an Epic/Story/Task),
  the 003 neutral engine (the neutrality gate), and the gitignored credential /
  binding files.
