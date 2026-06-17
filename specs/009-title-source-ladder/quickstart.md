# Quickstart: Readable Issue Titles

The bridge now derives a human-readable issue title from your `spec.md`, instead
of falling back to the directory slug or mirroring a pasted-input heading. It's
automatic — nothing to enable.

## How the title is chosen (first match wins)

1. **An explicit `Title:` line** in `spec.md` (same shape as `Owner:`/`Author:`):

   ```markdown
   Title: Seed-data contract for the AML demo
   ```

   This always wins — your crisp title, verbatim.
2. **The `# Feature Specification: <Name>` heading** — used when it's a real,
   concise name (not the `[FEATURE NAME]` placeholder, not the kebab slug, and not
   a pasted wall).
3. **The first sentence of your `## Summary`** — the deterministic fallback when
   the heading is weak.
4. **The directory slug** (e.g. `seed-data-contract`) — only if none of the above
   exist.

Titles are capped at **120 characters** on a word boundary (the full text stays in
the issue description). No AI/summarization is involved — it's deterministic, so
the same spec always produces the same title.

## If your titles look wrong today

- **Title is the directory slug** → your `spec.md` has no usable `#` heading and no
  `## Summary`. Add a `## Summary` (or a `Title:` line) and re-sync.
- **Title is a long wall of text** → your `#` heading is the pasted input. Add a
  `Title:` line with a crisp title, or rely on the `## Summary` first sentence — the
  bridge now demotes an over-long heading automatically.

## No churn on good specs

A spec that already has a clean `# Feature Specification: <Name>` heading keeps the
**exact same title** — re-syncing won't rewrite it. Only weak/verbose/slug titles
improve.
