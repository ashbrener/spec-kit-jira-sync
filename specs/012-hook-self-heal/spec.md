# Feature Specification: Hook Self-Healing — Detect + Repair Stripped Auto-Sync Hooks

**Feature Branch**: `012-hook-self-heal`

**Created**: 2026-06-29

**Status**: Draft

**Input**: Port the Linear sibling's spec-014 ("hook health") to Jira for
cross-sink parity: the bridge self-reports when its auto-sync `after_*` hooks have
gone missing and offers to repair them. Builds on feature 011 (which registers the
hooks); reuses 011's `install::register_after_hooks` for the repair.

## Why this matters

Feature 011 made spec-kit-jira an automatic mirror by registering six `after_*`
hooks into the consumer's `.specify/extensions.yml`. But the only community update
path — `specify extension add jira --from <release-zip> --force` — **silently
strips** those hooks (the `--force` overwrite drops the consumer's hook entries).
Auto-sync then quietly stops and the Jira board drifts with **no signal** — exactly
the failure the Linear sibling hit and fixed in its spec-014. The bridge must
**self-report its own hook health** so a stripped wiring is loud, not silent, and
offer a one-step repair.

This is the second half of the auto-mirror story (011 = register; 012 = keep
registered) and a direct port of the Linear sibling's shipped feature, for
cross-sink parity. It is **surface-don't-enforce** (Principle VIII): it reads only
the local `.specify/extensions.yml`, makes **no Jira writes**, never blocks the
operation it rides on, and only mutates on explicit operator consent.

## Clarifications

### Session 2026-06-29 (decisions — mirror the Linear sibling's resolved choices)

The Linear spec-014 already resolved these; adopt them verbatim for cross-sink
parity:

- Q: On missing hooks — warn-only, or also offer to self-heal? → A: **WARN +
  consented self-heal.** push/status emit the named warning; in an INTERACTIVE
  session they additionally OFFER (operator y/N, default No) to re-register the
  missing hooks in place. NON-INTERACTIVE (CI / hook-fired / no TTY) is **warn-only,
  mutates nothing**.
- Q: Does the self-heal offer also appear on `speckit.jira.status`? → A: **Both.**
  When interactive and hooks are missing, `status` also offers the y/N repair (not
  just a report line).
- Q: Does `status` change its exit code when hooks are missing? → A: **No — always
  exit 0.** Hook health is informational, never a CI gate (surface, don't enforce).
- Q: On consent, re-register all missing hooks at once or per-hook? → A: **All at
  once** — a single y/N re-registers every missing `after_*` hook in place.
- Q: (jira-specific) jira has no `src/status.sh` — `speckit.jira.status` is
  `reconcile.sh --dry-run`. How is the status report-line distinguished from the
  push warning? → A: **Branch on dry-run in the single per-run check.** The check
  wires once into `reconcile::main`; in `--dry-run` (status) it emits the
  first-class health line (all-present / partial+names / none) + offer; in a real
  push it emits the warn-once-if-missing + offer. One wiring, both surfaces.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A stripped hook set is loud, not silent (Priority: P1) 🎯 MVP

An operator updated the bridge via `specify extension add jira --from <zip>
--force`, which wiped the `after_*` hooks from `.specify/extensions.yml`. On their
next `/speckit-jira-push` (or any auto-fired reconcile), the bridge emits ONE clear
warning naming the missing hooks and the one-command fix (`/speckit-jira-install`),
so auto-sync stopping is impossible to miss. The reconcile itself still completes.

**Why this priority**: A silently-stripped hook set is the exact regression that
makes the auto-mirror untrustworthy. Surfacing it is the core value.

**Independent Test**: In a consumer project with the six hooks **absent** from
`.specify/extensions.yml`, run a reconcile; confirm exactly one warning names the
absent hooks + the remediation, and the reconcile's own outcome/exit is unchanged.

**Acceptance Scenarios**:

1. **Given** the `jira` `after_*` hooks are absent from `.specify/extensions.yml`,
   **When** the bridge reconciles, **Then** it emits one warning naming the absent
   hooks and the `/speckit-jira-install` remediation, and does not block or fail.
2. **Given** a partial set (some present, some absent — a hand-edited file), **When**
   the bridge reconciles, **Then** it warns naming exactly the absent ones.
3. **Given** the operator deliberately set a hook `enabled: false`, **When** the
   bridge reconciles, **Then** that hook is treated as intentionally disabled (NOT
   missing) — no warning for it.

---

### User Story 2 - Status reports hook health as a first-class line (Priority: P1)

An operator runs `/speckit-jira-status` to check on things. Alongside the drift
preview, status reports hook-registration health as a first-class line: all six
present, partial (naming the missing ones), or none registered — without changing
status's exit code.

**Why this priority**: The operator who proactively checks should see — and be able
to fix — the auto-sync wiring, not just drift.

**Independent Test**: With all hooks present → status shows "all present"; with some
absent → status names the missing ones; in every case status exits 0.

**Acceptance Scenarios**:

1. **Given** all six hooks registered (or intentionally disabled), **When** status
   runs, **Then** it reports hook health as fully present and exits 0.
2. **Given** some hooks absent, **When** status runs, **Then** it reports partial
   health naming the missing hooks and still exits 0 (informational, not a gate).

---

### User Story 3 - Consented one-step repair (Priority: P2)

When hooks are missing and the session is interactive, push and status offer a
single y/N (default No) to re-register **all** the missing hooks at once, in place —
reusing the install registrar (so `enabled: false` choices are preserved). A
non-interactive run (CI, hook-fired, no TTY) never prompts and never mutates.

**Why this priority**: Detection plus a one-keystroke fix on the spot is far better
UX than detection alone; but it must be consent-gated and safe in automation.

**Independent Test**: Interactive + hooks missing → a y at the prompt re-registers
all missing hooks (verify `.specify/extensions.yml`); n leaves them untouched.
Non-interactive + hooks missing → no prompt, no mutation, just the warning.

**Acceptance Scenarios**:

1. **Given** an interactive session with hooks missing, **When** the operator
   answers `y`, **Then** all missing `after_*` hooks are re-registered in place
   (reusing the install registrar; `enabled: false` entries preserved), in one step.
2. **Given** an interactive session with hooks missing, **When** the operator
   answers `n` (or just Enter — default No), **Then** nothing is mutated; the
   warning stands.
3. **Given** a non-interactive run (no TTY / CI / hook-fired) with hooks missing,
   **When** the bridge reconciles, **Then** it warns only and mutates nothing.

---

### Edge Cases

- **All present** → no warning, no offer; status reports fully present.
- **Operator-disabled hook** (`enabled: false`) → intentional, not "missing", no
  warning (distinguished from absent).
- **Malformed / unreadable `.specify/extensions.yml`** → degrades to "could not
  verify hook health" (informational), never a halt, never a false "missing".
- **No `.specify/extensions.yml` at all** → `not_installed`: the bridge isn't
  wired here yet, so no nag (the install ceremony is the path, not a self-heal).
- **Warning dedupe**: at most one hook-health warning per reconcile run (latched,
  like the existing `_RECONCILE_*_WARNED` flags), even across the multi-spec loop.
- **Self-heal mid-reconcile**: the offer/repair reads + writes only the local
  `.specify/extensions.yml`; it makes no Jira write and never alters the reconcile's
  own exit disposition.
- **Privacy**: the check + heal touch only command names + the local extensions
  file; no real Jira coordinate is read or written.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: On `speckit.jira.push` (reconcile) and `speckit.jira.status`, the
  bridge MUST classify each of the six `after_*` hooks for the `jira` extension as
  **present**, **disabled** (`enabled: false`), or **absent**; only **absent**
  counts as "missing".
- **FR-002**: When one or more hooks are **absent**, the bridge MUST emit a
  structured warning naming the missing hooks and the `/speckit-jira-install`
  remediation.
- **FR-003**: The hook-health warning MUST NOT block or fail the operation it rode
  in on; the reconcile/push completes and keeps its own exit disposition.
- **FR-004**: A hook the operator has explicitly disabled (`enabled: false`) MUST
  be treated as intentional — never reported as missing, never warned, never
  re-enabled.
- **FR-005**: When all six hooks are registered (or intentionally disabled), the
  bridge MUST surface hook health as fully present (no warning).
- **FR-006**: `speckit.jira.status` (the `reconcile --dry-run` path) MUST report
  hook-registration health as a first-class line — fully present, partial (naming
  the missing hooks), or none — and this MUST NOT change status's exit code
  (status stays exit 0; informational, not a CI gate).
- **FR-007**: Detection MUST use the **same notion of "registered"** that feature
  011's install registrar writes (reuse its `.specify/extensions.yml` block
  grammar — `_hook_already_registered`), so detection and repair agree.
- **FR-008**: The check MUST read only the consumer's local
  `.specify/extensions.yml`, make **no Jira writes**, and add no new dependency. A
  malformed/unreadable file degrades to "could not verify" (informational), never a
  halt; an absent file is `not_installed` (no nag).
- **FR-009**: On detecting missing hooks in an **interactive** session, the bridge
  MUST OFFER to re-register them in place (explicit operator y/N consent, default
  No), reusing feature 011's idempotent `install::register_after_hooks`; a
  **non-interactive** run (no TTY / CI / hook-fired) MUST be warn-only and mutate
  nothing.
- **FR-010**: On consent, the repair re-registers **all** missing `after_*` hooks
  at once (a single y/N, not one prompt per hook), preserving any `enabled: false`.
- **FR-011**: The warning MUST fire at most once per reconcile run (latched/deduped
  across the multi-spec loop).
- **FR-012**: Documentation MUST give a crisp note that `--force` updates strip
  hooks + the `/speckit-jira-install` (or self-heal) restore path.
- **FR-013**: The feature MUST keep `extension.id` as `jira` and the command as
  `speckit.jira.push`; the detection/heal mechanism is sink/config-side and MUST
  NOT alter the vendor-neutral reconcile engine (the 003 neutrality gate stays
  green). Privacy IX held (placeholder-only fixtures).

### Key Entities *(include if feature involves data)*

- **Hook classification**: per `after_*` hook — `present` | `disabled` | `absent`.
- **Hook-health state**: the per-run assessment — fully present / partial (with the
  named absent hooks) / none / `not_installed` / `unverifiable` — surfaced as a
  warning (push) and a status line (dry-run).
- **Self-heal offer**: the interactive, consent-gated, all-at-once re-registration
  (reuses 011's `install::register_after_hooks`).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With one or more `after_*` hooks absent, 100% of reconcile runs emit
  the named hook-health warning (and the reconcile still completes).
- **SC-002**: A hook set `enabled: false` is never reported as missing; an
  all-present set produces no warning — 100% of the time.
- **SC-003**: `speckit.jira.status` reports hook health as a first-class line in all
  states and **always exits 0** (hook health never changes its exit code).
- **SC-004**: In an interactive session with hooks missing, a single `y` consent
  re-registers all missing hooks in place (preserving `enabled:false`); a
  non-interactive run mutates nothing.
- **SC-005**: A malformed/unreadable `.specify/extensions.yml` yields "could not
  verify" and never a halt or a false "missing"; an absent file is a silent
  `not_installed`.
- **SC-006**: At most one hook-health warning per reconcile run (deduped).
- **SC-007**: No real identifier in any tracked file the feature adds; the 003
  neutrality + Privacy IX gates stay green.

## Assumptions

- **Feature 011 is the foundation** — its `install::register_after_hooks` +
  `.specify/extensions.yml` block grammar are the source of truth this feature
  detects against and reuses for repair.
- **`speckit.jira.status` = `reconcile --dry-run`** (jira has no `src/status.sh`),
  so one per-run check wired into `reconcile::main` covers both surfaces, branching
  on dry-run for the status report line vs the push warning.
- **Interactivity is detectable** via a TTY check (`/dev/tty`), with test overrides
  (mirroring Linear's `HOOKCHECK_TTY`/`HOOKCHECK_FORCE_INTERACTIVE` seams) so the
  consent path is unit-testable offline.
- **The detection/heal module is jira-aware but engine-neutral-safe** — it reads
  `.specify/extensions.yml` (config-side), knows the `jira` extension id +
  `speckit.jira.push` command, and is NOT part of the audited reconcile engine
  (mirrors how Linear scoped `hookcheck.sh`).
- **Cross-sink parity** with the Linear sibling's spec-014 is the target: same
  classification, same warn+consented-heal, same status-exit-0, same all-at-once
  consent.

## Out of Scope

- **Auto-healing without consent** — repair is always operator-consented (or the
  explicit `/speckit-jira-install`); never silent.
- **Local git hooks** (`post-checkout` etc.) — 011 scoped those out; this protects
  the `after_*` spec-kit-command hooks only.
- **Any Jira write** — this is local-file health only.
- **Changing the reconcile engine** — detection/heal is sink/config-side.

## Open Questions — for /speckit-clarify

The Linear sibling's spec-014 decisions are adopted verbatim (warn + consented
self-heal; offer on status too; status exit-0; all-at-once consent), plus one
jira-specific resolution: the single per-run check branches on `--dry-run` to
distinguish the status report line from the push warning (jira folds status into
`reconcile --dry-run`). Resolve any remaining nuance by the Linear leans.
