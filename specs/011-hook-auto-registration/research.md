# Phase 0 Research: Auto-Register `after_*` Hooks — the Automatic Mirror

Implements Constitution Principle VII (the hook mandate the bridge never built).
Install/config-side; the vendor-neutral reconcile engine is untouched. Mirrors the
Linear sibling's mechanism exactly so a later feature 012 (the spec-014 self-heal
port) and this registrar agree on what "registered" means.

## R1 — The firing mechanism (the clarify-flagged item) — VERIFIED

- **Finding**: the spec-kit **skills themselves** fire the hooks. Every `/speckit-*`
  skill's **last step** reads the consumer's `.specify/extensions.yml` under
  `hooks.after_<phase>`; for an `optional: false` hook it emits
  `EXECUTE_COMMAND: {command}` (the agent runs it), for `optional: true` it merely
  offers it. This runs **after** the command's actual work, and auto-exec also
  requires `settings.auto_execute_hooks: true` in the consumer file.
- **Consequence**: **non-blocking is structural** — a push fired by an `after_*`
  hook cannot fail the already-completed lifecycle command (FR-004 (d)).
  `optional: false` (Principle VII) is the *registration* mandate (non-skippable),
  not a "host fails if hook fails" rule. ✅ Confirmed; no framework change needed.

## R2 — Manifest hooks (`extension.yml provides.hooks`)

- **Decision**: add a `provides.hooks:` block declaring the six `after_*` hooks
  (`after_specify`, `after_clarify`, `after_plan`, `after_tasks`, `after_implement`,
  `after_analyze`), each `- command: "speckit.jira.push"`, `optional: false`,
  `enabled: true`, with a jira-flavoured `description`/`prompt`. No `before_*`.
  `extension.id` stays `jira`. The spec-kit CLI registers these into the consumer's
  `.specify/extensions.yml` at `specify extension add jira` time.
- **Rationale**: FR-001; mirrors Linear's manifest (`after_specify: - command:
  "speckit.linear.push" … optional: false`). The manifest is the source of truth.

## R3 — Install registrar (mirror Linear's block grammar exactly)

- **Decision** (in `src/install.sh`): add `INSTALL_EXTENSIONS_YML=".specify/extensions.yml"`,
  `INSTALL_AFTER_HOOK_NAMES=(after_specify … after_analyze)`, and:
  - `install::register_after_hooks` — create a minimal `.specify/extensions.yml`
    (with `installed:`, `settings: { auto_execute_hooks: true }`, `hooks:`) if
    absent, then loop the six names → `_register_one_hook`. Wire into `install::main`
    after the binding write.
  - `install::_register_one_hook <hook>` — if `_hook_already_registered` →
    **preserve** the existing entry (honouring any operator `enabled: false`) and
    return; else render the block and append via two paths.
  - `install::_hook_already_registered <hook>` — awk over the `^  <hook>:` block,
    match `extension:[[:space:]]*jira` inside it.
  - `install::_render_hook_block <hook>` — emit the consumer entry: a list item
    `- extension: jira` with `command: speckit.jira.push`, `enabled: true`,
    `optional: false`, a per-phase `prompt`/`description`, and
    `condition: <null | dogfood-gate>` (see R4). (Exact YAML in
    contracts/hook-registration.md §2.)
  - `install::_append_under_hook` / `_create_hook_section` / `_create_minimal_extensions_yml`.
- **Rationale**: FR-002/003. The consumer-file entry shape is keyed by
  `<hook>:` with a list of `- extension: <id>` blocks; `_hook_already_registered`
  anchored on `extension: jira` makes re-runs idempotent and `enabled: false`
  durable. Mirroring Linear's exact shape means the 012 detector reuses the same
  grammar.

## R4 — Dogfood gate on the `condition` (important — this repo dogfoods)

- **Decision**: when the install **target is the bridge's own checkout** (the
  008 install ceremony already detects source==target via
  `install::guard_source_target`), render the hook's `condition:` as
  `"${SPECKIT_JIRA_DOGFOOD_SAFE:-false}"` (literal text the host agent evaluates at
  fire time) so the bridge's *own* spec-kit work does not auto-push to a board
  unless the operator opts in; otherwise `condition: null`.
- **Rationale**: mirrors Linear's `INSTALL_DOGFOOD_DETECTED` /
  `${SPECKIT_LINEAR_DOGFOOD_SAFE}` gate. Without it, developing the bridge (like
  this very session) would fire auto-pushes. The literal `${…}` is written verbatim
  (shellcheck SC2016 disabled at that line).

## R5 — Portability: pure-bash block append (no multi-line `awk -v`)

- **Decision**: append the multi-line rendered block with a **pure-bash
  line-by-line state machine** (walk the file, emit the block at the insertion
  point), NOT `awk -v block=<multiline>`.
- **Rationale**: Linear's dogfood run hit `awk: newline in string` on **BSD awk
  (macOS)** with multi-line `-v`. This session already saw macOS/BSD divergences
  (009-D1 locale, the drift SIGPIPE flake); keep the awk dependency to single-line
  vars. Mirrors `seed.sh`'s config-write approach.

## R6 — Non-blocking push hardening (the `.env` source)

- **Finding**: `commands/jira-push.md` runs
  `… && set -a && source .env && set +a && bash src/reconcile.sh …` — `source .env`
  **fails the `&&` chain when `.env` is absent**, so an auto-fired hook with no
  creds would hard-fail instead of degrading.
- **Decision**: harden the one-liner to source `.env` only when present, then run
  reconcile regardless:
  `cd "$(git rev-parse --show-toplevel)" && { [ -f .env ] && { set -a; source .env; set +a; }; } ; bash src/reconcile.sh <FLAGS>`
  so reconcile still runs and exits **2** (missing/invalid config) or **3** (Jira
  unreadable) with its clean message instead of a broken pipe-of-`&&`. Update the
  "report back" guidance to frame a hook-fired failure as a gentle **WARNING**
  (no creds → run `/speckit-jira-install`; unreadable → check the token), never
  alarming. Apply to both `commands/jira-push.md` and the
  `.claude/commands/speckit-jira-push.md` twin.
- **Rationale**: FR-004 — the auto-fired path must never spew a hard error; the
  reconcile's existing exit-code messaging is already operator-friendly, we just
  must reach it.

## R7 — Docs flip (Principle VII rule)

- **Decision**: README presents the **auto-sync flow first**; `push`/`status`/
  `install`/`seed` move to a recovery / escape-hatch section. Correct the stale
  "registers NO hooks — operator-driven" wording in `extension.yml`'s header and
  the README to describe the auto-mirror.
- **Rationale**: FR-006 + the Principle VII documentation rule ("Documentation MUST
  present the auto-sync flow first; on-demand commands appear in a recovery
  section").

## R8 — Constitution + neutrality + privacy

- **Constitution**: **implements** Principle VII (the explicit `after_*` mandate) —
  additive, **no amendment**. The only constitutional touch is correcting the
  contradicting documentation wording (a doc fix). Data-model mapping unchanged.
- **Neutrality (003)**: hook registration is install/config-side (reads the
  manifest, writes `.specify/extensions.yml`); it touches no audited `reconcile::*`
  function → the neutrality gate stays green.
- **Privacy (IX)**: the registered hooks reference command names + the gitignored
  config — no real Jira coordinate in `extension.yml`, `.specify/extensions.yml`,
  or any committed fixture.

## R9 — Testing (pure-filesystem; no curl-shim)

- **Decision**: `bats` over the registrar (no Jira): fresh-file create includes
  `settings.auto_execute_hooks: true` + the six hooks; **idempotent** re-run is
  byte-identical (no dup/churn); an operator `enabled: false` is **preserved**
  across re-run; **other extensions'** hook entries (e.g. a `speckit-git` block)
  are untouched; a **malformed** `.specify/extensions.yml` yields an informational
  message + no corruption (FR-009); the **dogfood** target renders the
  `condition` gate. Plus: a manifest assertion (`extension.yml` declares the six
  `after_*` hooks → `speckit.jira.push`, `optional: false`), a push-body safety
  check (the one-liner runs reconcile with **and** without `.env`), and a
  `no-real-identifiers` pass on the new fixtures. `engine_vendor_neutral.bats`
  stays green.

## Resolved decisions summary

| # | Decision |
|---|---|
| R1 | Firing = skill last-step EXECUTE_COMMAND (post-work) → non-blocking structural; needs `auto_execute_hooks:true` |
| R2 | `extension.yml provides.hooks` declares 6 after_* → `speckit.jira.push`, optional:false |
| R3 | `install::register_after_hooks` + helpers mirror Linear's block grammar (idempotent, honour enabled:false) |
| R4 | Dogfood `condition` gate (reuse 008 source==target) so the bridge's own dev doesn't auto-push |
| R5 | Pure-bash block append (BSD-awk macOS lesson) |
| R6 | Harden `jira-push.md` `.env` source → reconcile always runs, degrades to a clean warning |
| R7 | Docs flip: auto-sync first, on-demand recovery; fix the stale "no hooks" wording |
| R8 | Implements VII (no amendment); 003 neutral; Privacy IX |
| R9 | Pure-fs bats registrar + manifest + push-body + privacy; no curl-shim |
