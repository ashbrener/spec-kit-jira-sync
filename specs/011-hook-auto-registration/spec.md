# Feature Specification: Auto-Register `after_*` Hooks — the Automatic Mirror

**Feature Branch**: `011-hook-auto-registration`

**Created**: 2026-06-27

**Status**: Draft

**Input**: User description: "Why operator-driven? Surely the purpose of sk-jira is
an automatic mirror? Implement Principle VII — auto-register the `after_*` hooks so
the board updates on every spec-kit command, mirroring the Linear sibling."

## Why this matters

spec-kit-jira-sync is meant to be a **live, unidirectional mirror** of a project's
specs (Principle I), and its own constitution (Principle VII, "Memory-Just-Works")
is emphatic that this happens **automatically**:

> "At `specify extension add jira` time the bridge MUST auto-register every relevant
> `after_*` hook … with `optional: false`. Default UX: run a spec-kit command, Jira
> updates. … A bridge whose primary UI is 'remember to run sync' drifts and gets
> abandoned. Auto-firing on every lifecycle transition is what earns the bridge its
> toolchain slot."

But the bridge as shipped does the **opposite**: it registers **zero** hooks (there
is no `after_*` registration anywhere in the code, and `extension.yml` declares
"registers NO hooks — reconcile is operator-driven"). So the board only updates when
the operator *remembers* to run `/speckit-jira-push`. That is the exact failure mode
Principle VII warns against — and it is why dogfood boards silently drift out of date.
The "operator-driven" stance is an **unbuilt gap rationalized after the fact** (the
install ceremony itself only just shipped and deliberately scoped hooks out), not a
considered architectural choice. The Linear sibling auto-fires by design and proves
the pattern.

This feature closes that gap: register the six `after_*` hooks so every spec-kit
lifecycle command auto-mirrors to Jira — turning sk-jira into the automatic mirror it
was always specified to be. It is the **foundation** for a follow-on feature (porting
the Linear sibling's hook self-healing, which detects + repairs hooks an update
strips) — out of scope here.

## Clarifications

### Session 2026-06-27 (open decisions — leans recorded, resolve in /speckit-clarify)

Mirror the best-practice decisions the Linear sibling took:

- **(a) Which command the hooks fire.** LEAN: all six `after_*` hooks fire
  **`speckit.jira.push`** (the write/mirror). `status` is read-only and not the point.
- **(b) Blocking vs non-blocking on a push failure inside a fired hook** (the critical
  one). LEAN: **non-blocking** — a fired hook NEVER fails or blocks the host
  `/speckit-*` command. When the push can't run (no creds, no config, Jira
  unreachable) it surfaces a warning and the lifecycle command still succeeds.
- **(c) Registration mechanism.** LEAN: **both** — the `extension.yml`
  `provides.hooks:` block is the source of truth the spec-kit CLI registers at
  `add` time, AND an idempotent install-side registration is the repair path the
  future hook self-heal reuses.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Installing the bridge makes the board auto-sync (Priority: P1) 🎯 MVP

An operator adds the extension to their project (`specify extension add jira`, or
runs the install ceremony). From then on, every `/speckit-specify`, `.clarify`,
`.plan`, `.tasks`, `.implement`, `.analyze` automatically mirrors the spec state to
Jira — with no manual push and nothing to remember. The board stays current as a
side effect of normal spec-kit work.

**Why this priority**: This is the entire feature — an automatic mirror instead of a
manual export. Without it the bridge does not deliver its core promise.

**Independent Test**: In a throwaway consumer project, install the extension; confirm
the consumer's `.specify/extensions.yml` carries all six `after_*` hooks pointing at
`speckit.jira.push` (`optional: false`); run a spec-kit lifecycle command and confirm
a reconcile fired (Jira updated) with no manual step.

**Acceptance Scenarios**:

1. **Given** a fresh consumer project, **When** the extension is installed, **Then**
   the consumer's `.specify/extensions.yml` contains all six `after_*` hooks
   (`after_specify`, `after_clarify`, `after_plan`, `after_tasks`, `after_implement`,
   `after_analyze`) each firing `speckit.jira.push` with `optional: false`.
2. **Given** an installed bridge, **When** any `/speckit-*` lifecycle command runs,
   **Then** the spec state is reconciled to Jira automatically (same outcome as a
   manual `/speckit-jira-push`), with no operator action.
3. **Given** an installed bridge, **When** the same unchanged state is reconciled
   again by a later hook, **Then** it is zero-churn (no spurious writes — Principle II).

---

### User Story 2 - A lifecycle command never breaks when Jira can't be reached (Priority: P1)

An operator runs `/speckit-plan` but has not exported their `.env` credentials (or
`jira-config.yml` is missing, or Jira is unreachable). The plan command **still
completes successfully**; the bridge surfaces a single warning that the mirror could
not run, with the fix — it never fails or blocks the spec-kit command.

**Why this priority**: Auto-firing on every command is only safe if a missing
credential or a Jira outage can never break the operator's spec-kit workflow.
Surface-don't-enforce (Principle VIII) is what makes always-on hooks acceptable.

**Independent Test**: With creds/config absent, run a lifecycle command and confirm
it exits successfully (the host command is not failed), and a warning naming the
cause + remediation was surfaced; nothing was written to Jira.

**Acceptance Scenarios**:

1. **Given** missing/unexported `.env` credentials, **When** an `after_*` hook fires,
   **Then** the host `/speckit-*` command still succeeds and a warning is surfaced
   (no Jira write, no command failure).
2. **Given** a missing `jira-config.yml` (not yet bound), **When** a hook fires,
   **Then** the host command succeeds with a "run `/speckit-jira-install`" warning.
3. **Given** Jira unreachable, **When** a hook fires, **Then** the host command
   succeeds and the transport failure is surfaced as a warning, not an error halt.

---

### User Story 3 - Operators keep control; reinstall doesn't fight them (Priority: P2)

An operator who wants a particular hook off edits `.specify/extensions.yml` to set it
`enabled: false`. Reinstalling or re-running the bridge **honours that** — it never
silently re-enables a disabled hook, never duplicates an existing hook, and a re-run
against an already-registered project is a byte-identical no-op.

**Why this priority**: Auto-registration must be idempotent and must not override the
operator's explicit choices, or it becomes adversarial (Principle VII rule + VIII).

**Independent Test**: Set one hook `enabled: false`; re-run install; confirm that hook
stays disabled and the others are unchanged; confirm a second re-run produces a
byte-identical `.specify/extensions.yml` (no duplicates, no churn).

**Acceptance Scenarios**:

1. **Given** a hook the operator set to `enabled: false`, **When** install re-runs,
   **Then** the hook remains disabled (never re-enabled).
2. **Given** all six hooks already registered, **When** install re-runs unchanged,
   **Then** `.specify/extensions.yml` is byte-identical (no duplicate entries, no
   reordering, no churn).
3. **Given** a consumer `.specify/extensions.yml` that already has *other*
   extensions' hooks, **When** the bridge registers its hooks, **Then** only the
   `jira` hooks are added/updated; other extensions' entries are untouched.

---

### Edge Cases

- **Malformed / unreadable `.specify/extensions.yml`**: registration MUST surface an
  informational "could not register hooks — verify `.specify/extensions.yml`" rather
  than corrupt the file or halt; it never writes a partial/broken file.
- **No `.specify/extensions.yml` yet**: registration creates it (or the minimal hooks
  section) with the six hooks.
- **`before_*` hooks**: none — the bridge never pre-empts a lifecycle step (only
  `after_*`).
- **Hook fires during the bridge's own development (dogfooding)**: a fired hook in the
  bridge repo must not break the bridge's own spec-kit workflow (non-blocking, US2);
  the existing dogfood guards still apply.
- **Concurrent / repeated fires**: each fire is an independent full reconcile
  (Principle II) — safe to fire on every command; zero-churn when nothing changed.
- **Privacy**: the registered hooks reference command names + the gitignored config;
  no real Jira coordinate ever appears in `.specify/extensions.yml`, `extension.yml`,
  or any committed fixture.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001 (Manifest hooks)**: `extension.yml` `provides.hooks:` MUST declare all six
  `after_*` hooks (`after_specify`, `after_clarify`, `after_plan`, `after_tasks`,
  `after_implement`, `after_analyze`), each firing `speckit.jira.push` with
  `optional: false`, so the spec-kit CLI auto-registers them into the consumer's
  `.specify/extensions.yml` at `specify extension add jira` time. No `before_*` hooks.
  `extension.id` stays `jira`.
- **FR-002 (Install registration)**: The install ceremony MUST idempotently
  register/repair the six `after_*` hooks in the consumer's `.specify/extensions.yml`,
  mirroring the Linear sibling's registration, so the auto-mirror works whether the
  CLI or the ceremony performed the install — and so a future hook-health/self-heal
  detector and this registrar agree on what "present" means. Re-running is byte-
  identical (no duplication, no churn).
- **FR-003 (Honour `enabled: false`)**: The bridge MUST honour an operator-set
  `enabled: false` on any hook and MUST NOT silently re-enable it on reinstall. A
  disabled hook is intentionally off.
- **FR-004 (Non-blocking auto-sync)**: A fired `after_*` hook MUST run the reconcile
  such that the host `/speckit-*` lifecycle command ALWAYS succeeds — even when the
  push cannot run (missing/unexported `.env`, missing `jira-config.yml`, unreadable
  Jira). The bridge surfaces a WARNING with remediation (Principle VIII) but NEVER
  fails or blocks the spec-kit command.
- **FR-005 (One sync path)**: The hook-fired sync and the on-demand `/speckit-jira-push`
  MUST share one code path and produce identical outcomes (Principle II); auto-sync on
  unchanged state is zero-churn. This feature wires *when* reconcile fires — it adds
  no new sync logic.
- **FR-006 (Docs flip)**: Documentation MUST present the auto-sync flow FIRST; the
  on-demand commands (`push`/`status`/`install`/`seed`) move to a recovery /
  escape-hatch section. The stale "registers no hooks / operator-driven" wording in
  `extension.yml` and the README MUST be corrected to reflect the auto-mirror.
- **FR-007 (Privacy IX)**: No real Jira coordinate may appear in any committed hook,
  manifest, or fixture; `no-real-identifiers.bats` and the 006 consumer-side guard
  MUST stay green.
- **FR-008 (Vendor-neutral seam)**: Hook registration is install/config-side (it
  reads the manifest and writes `.specify/extensions.yml`); it MUST NOT touch the
  vendor-neutral reconcile engine — the 003 engine-neutrality gate stays green.
- **FR-009 (Resilient registration)**: A malformed/unreadable `.specify/extensions.yml`
  MUST yield an informational message, never a corrupted file or a halt; registration
  never writes a partial/broken file and never disturbs other extensions' entries.

### Key Entities *(include if feature involves data)*

- **`after_*` hook**: a consumer `.specify/extensions.yml` entry firing
  `speckit.jira.push` on a lifecycle transition, with `optional: false` and an
  `enabled` flag the operator controls.
- **`extension.yml provides.hooks`**: the manifest declaration the spec-kit CLI reads
  to register the hooks at install (the source of truth).
- **Hook registrar**: the install-side, idempotent, block-grammar writer/repairer of
  the six hooks in `.specify/extensions.yml` (honours `enabled: false`; the future
  self-heal reuses it).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After install, the consumer's `.specify/extensions.yml` carries all six
  `after_*` hooks → `speckit.jira.push` (`optional: false`) — 100% of the time.
- **SC-002**: Running any `/speckit-*` lifecycle command mirrors the spec state to
  Jira automatically, identical in outcome to a manual `/speckit-jira-push`, with no
  operator action.
- **SC-003**: A fired hook with missing creds/config/unreachable Jira does NOT fail
  the host command (the command exits successfully) and surfaces a warning — 100% of
  the time.
- **SC-004**: Re-running install is byte-identical (no duplicate or churned hooks);
  an `enabled: false` hook stays disabled across reinstall — 100% of the time.
- **SC-005**: No real identifier in any tracked file the feature adds; the privacy +
  003 neutrality gates stay green.
- **SC-006**: Documentation presents auto-sync first; on-demand commands appear in a
  recovery section.

## Assumptions

- **The spec-kit CLI registers manifest-declared `provides.hooks`** into the
  consumer's `.specify/extensions.yml` at `specify extension add` time (the mechanism
  the Linear sibling relies on). The install-side registrar is the parity/repair path.
- **The reconcile engine is unchanged** — it is already idempotent + drift-aware; this
  feature only makes it fire automatically.
- **Non-blocking is achievable** at the hook seam (a fired hook can warn without
  failing the host command), matching the Linear sibling's behaviour.
- **Principle VII is the design intent** — implementing it needs no amendment; the
  contradicting "operator-driven, no hooks" wording is a documentation error to fix.
- **Cross-sink parity** with the Linear sibling is the target: same six hooks, same
  `optional: false`, same `enabled: false` honour, same non-blocking posture.

## Out of Scope

- **Feature 012 — hook self-healing** (the Linear spec-014 port: detect hooks an
  update stripped + consent-heal). This feature is its prerequisite foundation.
- **`before_*` hooks** — the bridge never pre-empts a lifecycle step.
- **Any change to the reconcile engine's sync logic** — this wires *when* it fires,
  not *what* it does.
- **A `.pull` command** — the bridge is a one-way mirror (filesystem → Jira); there is
  nothing to pull back.

## Open Questions — for /speckit-clarify

The three forks in Clarifications (Session 2026-06-27) carry leans: (a) all six hooks
fire `speckit.jira.push`; (b) **non-blocking** on a push failure (the critical
decision — warn, never fail the host command); (c) registration via **both** the
manifest `provides.hooks` and an idempotent install-side registrar. Resolve by the
leans (they mirror the Linear sibling) unless one is genuinely contentious.
