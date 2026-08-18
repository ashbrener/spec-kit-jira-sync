# Feature Specification: Extension Identity Realignment — One Name, Everywhere

**Feature Branch**: `013-extension-identity`

**Created**: 2026-08-18

**Status**: Draft

**Input**: Align the bridge's manifest identity with its community-catalog entry
(`jira-sync`), mirroring the Linear sibling's convention, so the catalog updater
stops resolving our users to an unrelated extension. Unblocks the v0.5.0 catalog
submission (github/spec-kit PR #4168).

## Why this matters

The bridge currently answers to **two different names**. Its manifest declares
the identity `jira`, but the community catalog lists it as `jira-sync` — because
the `jira` catalog slot is already owned by an **unrelated** Jira extension from
a different author.

The consequences are not cosmetic:

1. **Users are offered the wrong update.** Installing our extension registers it
   under the identity `jira`. When the updater later looks up `jira`, it finds
   the *other* author's extension and offers **their** newer version as the
   update for **our** bridge. A user accepting it silently loses the sync engine.
2. **Both extensions want the same folder.** Each installs to the same
   extension directory, so having both is a collision rather than a choice.
3. **Both claim the same command namespace.** Their commands and ours share the
   `jira` prefix; today's leaf names differ by luck, not by design.

This has been latent since the first release, but feature 011 made it dangerous:
now that the bridge auto-mirrors on every lifecycle command, a mis-resolved
update replaces a *working automatic mirror* with something unrelated — and the
user has no reason to suspect it.

The Linear sibling shows the correct shape: its catalog entry, its manifest
identity, and its command namespace are all the same word. This feature adopts
that rule for Jira. Since the other extension holds the `jira` name and was
there first, **ours is the one that moves**: everything becomes `jira-sync`.

### A reversed decision, recorded

An earlier project constraint held that the manifest identity **must stay
`jira`**. This feature **reverses** it. The reason: that constraint was set
before we knew the identity mismatch breaks the update path for real users, and
before the upstream maintainer's review made it a blocker for publishing. The
constraint was never wrong about the cost of renaming — only about the cost of
*not* renaming.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A user is never offered someone else's extension (Priority: P1) 🎯 MVP

An operator installs the bridge from the catalog and later checks for updates.
They are offered **this bridge's** next version — never a different author's
extension that happens to share a name.

**Why this priority**: This is the whole point. A user silently swapping a
working mirror for an unrelated tool is the worst outcome the bridge can produce.

**Independent Test**: Install from the catalog entry; confirm the recorded
identity matches the catalog entry's identity, and that an update check resolves
to this bridge's repository.

**Acceptance Scenarios**:

1. **Given** the bridge is installed from the catalog, **When** its recorded
   identity is inspected, **Then** it equals the catalog entry's identity
   (`jira-sync`) — not `jira`.
2. **Given** the bridge is installed, **When** an update is resolved for it,
   **Then** the candidate is this bridge's own repository and version.
3. **Given** the unrelated `jira` extension is also installed, **When** both are
   present, **Then** they occupy separate directories and separate command
   namespaces with no overlap.

---

### User Story 2 - An existing user is told what changed and fixed in one step (Priority: P1)

An operator upgrading from an older version finds their old commands gone and
their auto-sync hooks no longer firing. The bridge **tells them** the hooks are
missing and offers to re-register them, so the rename is a one-step recovery
rather than a silent breakage.

**Why this priority**: A breaking rename with no migration path is how projects
lose users. The bridge already has the machinery to make this graceful.

**Independent Test**: Start from a project wired to the old identity; install the
renamed version; confirm the bridge reports the hooks as missing and, on consent,
re-registers them under the new identity.

**Acceptance Scenarios**:

1. **Given** a project whose hook entries reference the old identity, **When** the
   bridge next runs, **Then** it reports the auto-sync hooks as missing and names
   the one-step remedy — it does not fail.
2. **Given** that report and an operator who consents, **When** the repair runs,
   **Then** the hooks are registered under the new identity and auto-sync resumes.
3. **Given** an operator who declines, **When** the run completes, **Then**
   nothing is mutated and the operation still succeeds.
4. **Given** the upgrade, **When** the operator reads the release notes, **Then**
   the renamed commands and the migration steps are stated plainly.

---

### User Story 3 - The published listing describes the bridge accurately (Priority: P2)

Someone browsing the community catalog sees a listing whose stated capabilities
match what the bridge actually ships — including that it registers auto-sync
hooks.

**Why this priority**: The listing is the shop window. It currently under-reports
the bridge's headline capability, and the mismatch was raised in review.

**Independent Test**: Compare the published listing's declared capability counts
against the shipped manifest; they agree.

**Acceptance Scenarios**:

1. **Given** the published listing, **When** its declared capabilities are
   compared to the manifest, **Then** the command count and the hook count both
   match what the bridge ships.
2. **Given** a future release, **When** the listing is updated, **Then** identity
   and capability counts are re-checked rather than carried over stale.

---

### Edge Cases

- **Both extensions installed** — separate directories, separate namespaces; no
  clobbering, no ambiguity about which command belongs to which.
- **Old hook entries left behind** — stale entries naming the old identity are
  surfaced, never silently deleted; removal is offered, not imposed.
- **Old install directory left behind** — reported so the operator can clean up;
  the bridge does not delete it unprompted.
- **A deliberately disabled hook** — an operator who turned a hook off keeps it
  off through the rename; the migration never re-enables it.
- **Partial migration** — some hooks re-registered, some not: reported honestly
  as partial rather than as fully healthy.
- **Existing binding/config** — the operator's resolved settings survive the move;
  the rename must not force them to re-resolve their project binding from scratch.
- **Privacy** — nothing about this rename introduces real coordinates into
  tracked files.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The bridge's manifest identity MUST equal the identity of its
  community-catalog entry (`jira-sync`).
- **FR-002**: Every command the bridge publishes MUST live under a namespace
  derived from that same identity, so no command collides with another
  extension's namespace.
- **FR-003**: The bridge MUST install into a directory named for its own
  identity, distinct from any other extension's directory.
- **FR-004**: The auto-sync hooks the bridge registers MUST invoke the renamed
  command, and MUST record the bridge under its new identity.
- **FR-005**: The mechanism that *detects* registered hooks and the mechanism
  that *registers* them MUST agree on the new identity — a hook written by one
  is recognised by the other.
- **FR-006**: On encountering a project still wired to the old identity, the
  bridge MUST report the auto-sync hooks as missing and offer the existing
  consented one-step repair; it MUST NOT fail, and MUST NOT mutate without
  consent.
- **FR-007**: The migration MUST preserve an operator's deliberate choice to
  disable a hook — a disabled hook is never re-enabled by the rename.
- **FR-008**: The migration MUST preserve the operator's existing resolved
  configuration/binding; the rename MUST NOT require re-resolving it from scratch.
- **FR-009**: Stale artifacts from the old identity (hook entries, the old
  install directory) MUST be surfaced to the operator; any removal MUST be
  explicitly consented, never silent.
- **FR-010**: The published catalog listing MUST state capability counts that
  match the shipped manifest — including the six auto-sync hooks currently
  reported as zero.
- **FR-011**: Documentation MUST state the rename, the renamed commands, and the
  migration steps, so an existing user is not left guessing.
- **FR-012**: The new identity MUST be pinned by an automated check, so a future
  change cannot silently reintroduce a mismatch between the manifest identity,
  the command namespace, and the published listing.
- **FR-013**: The realignment MUST NOT change what the bridge projects into the
  tracker, its exit codes, or its data contract — this is an identity change
  only.
- **FR-014**: This release MUST be published as a **breaking** version change,
  because command names an operator invokes are changing.

### Key Entities *(include if feature involves data)*

- **Extension identity**: the single name the bridge answers to — used by the
  catalog listing, the install directory, the command namespace, and the hook
  registration record. Currently split; after this feature, one value.
- **Command surface**: the four operator-facing commands, each renamed under the
  new namespace, with their documented twins kept in step.
- **Hook registration record**: the per-project entry naming which extension owns
  an auto-sync hook — the token both the registrar and the health check match on.
- **Catalog listing**: the published description, including capability counts
  that must mirror the manifest.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of the bridge's published surfaces — catalog listing, manifest
  identity, command namespace, install directory, hook registration — use the
  same single name.
- **SC-002**: An update check for an installed bridge resolves to this bridge's
  own repository in 100% of cases; it can never resolve to the unrelated
  extension.
- **SC-003**: Both extensions can be installed together with zero directory or
  command-name collisions.
- **SC-004**: An operator upgrading from the old identity is told their auto-sync
  hooks are missing and can restore them in one consented step; the run that
  reports it still succeeds.
- **SC-005**: A deliberately disabled hook, and the operator's existing resolved
  configuration, both survive the migration unchanged.
- **SC-006**: The published listing's stated command and hook counts match the
  shipped manifest exactly.
- **SC-007**: An automated check fails if the manifest identity, the command
  namespace, or the published identity ever diverge again.
- **SC-008**: No tracked file gains a real coordinate, and the projection the
  bridge produces is unchanged by this feature.

## Assumptions

- **The other extension keeps the `jira` name.** It was listed first and is
  actively maintained, so ours is the side that moves. We are not asking them or
  the maintainers to give up the slot.
- **Aliases cannot preserve the old commands.** The published rules require an
  alias to sit in the extension's own namespace, and the old namespace belongs to
  the other extension — so this is a clean break, not a soft deprecation.
- **The existing hook self-healing carries the migration.** Because the health
  check matches on the identity token, old entries read as "missing" and the
  already-shipped consented repair re-registers them under the new name. No new
  migration machinery is needed.
- **Historical specifications stay as written.** Superseded feature documents
  record what was true at the time; they are history, not live contracts, and are
  not rewritten by this feature.
- **This is an identity change only** — no change to what is mirrored, how
  conflicts are handled, or what the bridge writes to the tracker.

## Out of Scope

- **Renaming the tracker-side artifacts** — issues, labels, and their contents
  are untouched; nothing the bridge already created needs to move.
- **Automatic deletion** of the old install directory or stale hook entries —
  surfaced and offered, never silent.
- **Preserving the old command names** by any mechanism — not possible, and not
  attempted.
- **Changing the projection, mapping, exit codes, or data contract.**
- **Asking upstream to re-key or transfer the `jira` catalog slot.**

## Dependencies

- Builds directly on the shipped auto-registration and hook self-healing
  features: the first supplies the registrar the migration reuses, the second
  supplies the detection and the consented one-step repair that make the rename
  survivable.
- Unblocks the pending catalog submission, which a maintainer review has held
  pending exactly this correction.
