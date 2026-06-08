# Contract: Re-mode CLI surface

The operator-facing command contract for the guarded re-mode. Extends the existing
`reconcile.sh` flag set; does not change any existing flag's behavior.

## Flags

| Flag | Meaning |
|---|---|
| `--remode` | Enter the destructive re-mode: prune bridge-owned orphans the current mapping no longer projects, then regenerate the new shape. **The only flag that authorizes a destructive write.** |
| `--remode --dry-run` | Preview the exact prune + regenerate set; perform **zero** writes (FR-003). |
| `--on-drift=abort` | (existing) Under re-mode, *skip pruning* any orphan showing backward-drift (a human edited it), surfacing it instead (FR-010). |
| `--spec NNN` / `--all` | (existing) Scope the re-mode to one spec or the whole repo. `--all` is the default scope, as for ordinary reconcile. |

`--remode` composes with the existing scope/drift/config flags. It is **mutually
sensible** with `--dry-run` (preview) and `--on-drift` (drift disposition); it is
**not** auto-fired by any hook (Principle VII) — only an explicit operator
invocation.

## Behavior

```text
reconcile.sh --remode [--dry-run] [--spec NNN | --all] [--on-drift=abort|proceed]
```

1. Resolve the repo Epic (and Initiative, if enabled). If absent → nothing was
   mirrored; report "no bridge-owned artifacts found" and exit 0.
2. **Read phase** (no writes): enumerate `E`, compute `D`, derive `O = E \ D`.
   Any unreadable read ⇒ **abort with zero deletions**, exit 3 (FR-005/SC-006).
3. Report the plan: `pruned[]`, `regenerated[]`, `kept[]` (FR-008).
4. If `--dry-run`: stop (zero writes), exit 0.
5. Else: for each orphan, surface backward-drift if present (FR-010), then prune
   per `remode.destruction`; then run the ordinary projection to regenerate `D`.
6. Surface any prune failures (FR-009); exit 0 if the read gate passed and the run
   completed (failures are warned, not fatal — resumable on re-run).

## Exit codes (consistent with the existing engine)

| Code | Meaning |
|---|---|
| 0 | Re-mode completed (including a no-op re-mode and a clean dry-run). Prune failures are surfaced as warnings, not a non-zero exit. |
| 2 | Workspace/config error (missing or invalid `jira-config.yml`; `archive` selected with no archive status id). |
| 3 | Jira unreadable during the read phase → **fail-closed**, zero destructive writes. |

## Guarantees (map to Success Criteria)

- **SC-003**: the dry-run preview equals the real action's set (same computation).
- **SC-004**: without `--remode`, **zero** destructive operations occur in any
  mapping mode.
- **SC-002**: across a mixed board, **zero** operator-created issues are modified.
- **SC-006**: an unreadable read ⇒ zero destructive writes.

## Slash-command surface (follow-on, not in this contract's scope)

The hook/slash wrappers (`/speckit-jira-push`) stay non-destructive and never pass
`--remode`. A dedicated destructive surface (e.g. `/speckit-jira-remode`) is a
documentation/packaging follow-on; the engine contract above is the source of
truth for behavior.
