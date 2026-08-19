# Quickstart: Upgrading to v0.6.0 — the extension has one name now

**v0.6.0 is a breaking release.** The extension's name changed from `jira` to
`jira-sync`, so **the commands you type have changed**.

## Why

The catalog lists this bridge as `jira-sync`, but it used to *install* itself as
`jira` — a name already owned by a different, unrelated Jira extension. That
mismatch meant the updater could offer you **someone else's extension** as the
update for this one, silently replacing your sync engine. Now one name is used
everywhere, matching how the Linear sibling has always worked.

## What changed

| Before | After |
|--------|-------|
| `/speckit-jira-push` | `/speckit-jira-sync-push` |
| `/speckit-jira-status` | `/speckit-jira-sync-status` |
| `/speckit-jira-install` | `/speckit-jira-sync-install` |
| `/speckit-jira-seed` | `/speckit-jira-sync-seed` |
| installs to `.specify/extensions/jira/` | `.specify/extensions/jira-sync/` |

The old command names could not be kept as aliases — that namespace belongs to
the other extension, and keeping it is what caused the problem.

**Nothing in Jira changes.** Your issues, labels, and their contents are
untouched. What the bridge mirrors, and how, is exactly the same.

## Upgrading

1. Install v0.6.0 from the catalog as usual.
2. Run any spec-kit command, or `/speckit-jira-sync-status`. The bridge will
   notice your auto-sync hooks still point at the old name and tell you:

   ```text
   Auto-sync hooks: none registered — run /speckit-jira-sync-install to restore auto-sync
   ```

3. Restore them either way:
   - run **`/speckit-jira-sync-install`**, or
   - if you're at a real terminal, answer **`y`** to the offer:

     ```text
     Re-register 6 missing auto-sync hook(s) now? [y/N]
     ```

That's it — auto-sync resumes under the new name. Hooks you deliberately turned
off stay off.

## Your configuration

Your resolved binding still works. The bridge prefers
`.specify/extensions/jira-sync/jira-config.yml` but **still reads** the old
`.specify/extensions/jira/jira-config.yml`, telling you once where to move it.
It will never move or delete the file for you — that's your call, whenever suits.

## Tidying up

After upgrading you may still have the old `.specify/extensions/jira/` directory
and old hook entries naming `jira`. The bridge points them out but never deletes
anything. Remove them when you're satisfied the new setup works.

## Developing the bridge itself

The dogfood gate variable is now `SPECKIT_JIRA_SYNC_DOGFOOD_SAFE` (was
`SPECKIT_JIRA_DOGFOOD_SAFE`).
