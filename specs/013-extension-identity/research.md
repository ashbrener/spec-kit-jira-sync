# Phase 0 Research: Extension Identity Realignment

Align the manifest identity with the community-catalog entry. Manifest / command
surface / config-side; the vendor-neutral reconcile engine is untouched (003 gate
green). Externally forced by a maintainer review holding our v0.5.0 catalog bump.

## R1 — The collision is real, and ours is the side that moves — VERIFIED

- **Finding**: catalog key `jira` is owned by `mbachorik/spec-kit-jira`
  (`extension.id: "jira"`, commands `speckit.jira.specstoissues`,
  `.discover-fields`, `.sync-status`; repo at 3.0.0, catalog 2.1.0). Our catalog
  key is `jira-sync`, but our manifest declares `extension.id: "jira"` — so an
  install registers under `jira` and the updater resolves to **their** entry.
  We also share their install directory and command namespace.
- **Decision**: take the identity `jira-sync` everywhere. They were listed first
  and are actively maintained; we do not contest the slot or ask upstream to
  re-key it.
- **Rationale**: FR-001..FR-003. Matches the operator instruction ("ours must
  match our linear sync") and the Linear sibling's proven shape.

## R2 — The Linear sibling is the reference convention — VERIFIED

- **Finding**: Linear ships catalog key `linear` == `extension.id: "linear"` ==
  namespace `speckit.linear.*`, with catalog `provides {commands: 5, hooks: 6}`.
- **Decision**: copy the shape exactly — key == id == namespace, and publish
  capability counts that match the manifest.
- **Rationale**: it is the same codebase lineage and it demonstrably passes the
  catalog's update path. Also settles FR-010: the correct hook count is **6**
  (Linear reports 6 for the identical six `after_*` hooks).

## R3 — No alias can preserve `speckit.jira.*` — VERIFIED

- **Finding**: `extensions/EXTENSION-API-REFERENCE.md` gives the command pattern
  `^speckit\.[a-z0-9-]+\.[a-z0-9-]+$`, documents the **format** as
  `speckit.{extension-id}.{command-name}`, and states an alias's "namespace must
  match extension.id and must not shadow core or installed extension commands".
- **Decision**: **clean break**. Old command names are retired, not aliased.
  The regex alone would technically permit keeping `speckit.jira.*` under a
  `jira-sync` id, but that violates the documented format *and* shadows the other
  extension — reintroducing the bug under a new name.
- **Rationale**: FR-002. Drives FR-014 (breaking version) and the migration story.

## R4 — The identity is hardcoded TWICE (the one piece of real architecture)

- **Finding**: the writer and the reader each carry their own literal —
  `install.sh:324` renders `- extension: jira` / `command: speckit.jira.push`;
  `hookcheck.sh:102` matches `cur_ext == "jira"` inside its awk walk;
  `config.sh:70` pins `CONFIG_DEFAULT_PATH=".specify/extensions/jira/jira-config.yml"`.
  Feature 012's FR-007 ("detection and repair must agree") is currently satisfied
  only by coincidence — two literals that happen to match.
- **Decision**: introduce `src/identity.sh` (include-guarded, dependency-free)
  exporting the extension id, the push command name, and the install-dir name.
  `install.sh` renders from it; `hookcheck.sh` sources it **directly** and passes
  the id into awk via a single-line `awk -v` (BSD-safe). A pin test asserts the
  manifest, the constant, and every declared command namespace agree.
- **Rationale**: FR-005 + FR-012. Turns an invariant that is currently an accident
  into one the build enforces — and this rename is precisely the change that would
  otherwise break it. `hookcheck.sh` must not reach the constant *through*
  `install.sh`, which it sources only lazily on consent.

## R5 — Migration rides feature 012, and must be proven

- **Finding**: `hookcheck::classify` reports `absent` when no entry matches the
  configured extension id. After the rename it looks for `jira-sync`, so an
  operator's existing `extension: jira` entries classify as **absent** — which is
  exactly the state that triggers the warn/status line and the consented
  all-at-once re-register.
- **Decision**: no new migration machinery. Add an end-to-end test that starts
  from an old-identity `.specify/extensions.yml` and asserts: classify → `absent`;
  the warning/status line fires; consent re-registers under `extension: jira-sync`;
  a pre-existing `enabled: false` is preserved.
- **Rationale**: FR-006/FR-007. The claim is load-bearing for the whole upgrade
  story, so it is tested rather than assumed.

## R6 — The operator's binding must survive the move

- **Decision**: `CONFIG_DEFAULT_PATH` becomes
  `.specify/extensions/jira-sync/jira-config.yml`. If that is absent and the
  legacy `.specify/extensions/jira/jira-config.yml` exists, read the legacy file
  and emit ONE informational line naming the new location. Never auto-move,
  never delete. `.gitignore` ignores both paths.
- **Rationale**: FR-008/FR-009 + Principle I/VIII. An upgrade that silently
  invalidated a resolved binding would force every operator back through the
  install ceremony for a rename they did not ask for.

## R7 — Stale artifacts are surfaced, never removed

- **Decision**: leftover `extension: jira` hook entries and the legacy
  `.specify/extensions/jira/` directory are **reported** (one informational line
  each); removal is the operator's action. No silent deletion, no prompt-to-delete
  in this feature.
- **Rationale**: FR-009. Deletion is controlled-destruction territory (the 004
  carve-out) and is out of scope here; surfacing is sufficient and reversible.

## R8 — Constitution: doc fix, no amendment

- **Finding**: `.specify/memory/constitution.md` names `speckit.jira.push` and
  `.specify/extensions/jira/jira-config.yml` at lines 202, 238, 242, 251, 375, 379.
  These are descriptive references, not normative principles. Lines 242/379 also
  cite a `.pull` command this bridge has never shipped — inherited from the Linear
  sibling.
- **Decision**: correct the references (including the bogus `.pull`) as a
  documentation fix. **No amendment** — this feature *enforces* Principles VII and
  VIII rather than changing them. Same call as feature 011.
- **Rationale**: an amendment is for changing the rules, not for correcting a name
  the rules happen to quote.

## R9 — Scope discipline + gates

- **Decision**: rewrite only **live** surfaces (~22 files). Historical
  `specs/001`–`012` documents keep their old names — they record what was true
  when written. Command markdown files are moved with `git mv` to preserve history.
  Full CI gate must pass (shellcheck, yamllint, markdownlint, the bats matrix);
  `engine_vendor_neutral.bats` and `no-real-identifiers.bats` stay green.
- **Rationale**: FR-013 + Privacy IX + the 003 neutrality gate. Two known
  local-only bats failures (`config.bats` default-path and `no-real-identifiers`,
  both caused by the operator's gitignored files) are expected and are green in CI.

## Resolved decisions summary

| # | Decision |
|---|----------|
| R1 | Take `jira-sync` everywhere; the other extension keeps `jira` |
| R2 | Copy Linear's key == id == namespace shape; publish `{commands:4, hooks:6}` |
| R3 | Clean break — no aliases are possible; breaking version |
| R4 | NEW `src/identity.sh` single source of truth + pin test (writer/reader can't diverge) |
| R5 | Migration rides 012's self-heal; proven by an end-to-end old→new test |
| R6 | New config path preferred, legacy path still read + surfaced |
| R7 | Stale entries/dir surfaced, never deleted |
| R8 | Constitution + CLAUDE.md doc fix (incl. the bogus `.pull`); NO amendment |
| R9 | Live files only; `git mv` the command files; full gate green |
