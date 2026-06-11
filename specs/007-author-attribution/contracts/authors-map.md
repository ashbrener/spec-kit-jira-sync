# Contract: the authors map (`jira-authors.local.yml`)

The gitignored operator file mapping a git author email → a Jira accountId + a
non-PII handle. Holds real PII → **never committed**; only a `.sample` ships.

## Shape

```yaml
schema_version: 1
authors:
  # key = the git author email (matches workstate item.author.value)
  "<email>":
    accountId: "<jira-account-id>"   # or null / omit = known but NOT assignable
    handle: "<non-pii-handle>"       # REQUIRED — the author:<handle> label token
default_assignee: null               # null = leave unassigned (NOT the project lead)
```

## Committed `.sample` (placeholders only — Privacy IX)

```yaml
# .specify/extensions/jira/jira-authors.local.yml.sample
# Copy to jira-authors.local.yml (gitignored) and fill with REAL ids.
schema_version: 1
authors:
  "dev-one@example.com":
    accountId: "0000aaaa1111bbbb2222cccc"   # placeholder shape, not a real id
    handle: "dev-one"
  "dev-two@example.com":
    accountId: null                          # known author, no Jira account → label only
    handle: "dev-two"
default_assignee: null
```

## Rules

- **Gitignored.** `.specify/extensions/jira/jira-authors.local.yml` is added to
  `.gitignore`. The privacy guard (`no-real-identifiers.bats`) fails CI if a real
  email/accountId appears in any tracked file (the `.sample` uses placeholders
  shaped not to self-match).
- **`handle` is required** per entry — it is the label token, and it MUST be a
  non-PII handle (never an email/local-part). A known author missing a `handle` is
  a **config error** surfaced to the operator (no PII fallback, no label).
- **`accountId` null/absent** ⇒ label-only (the non-Jira-user case).
- **`default_assignee: null`** ⇒ leave unassigned (do NOT fall back to the project
  lead). If set to an id, an unmapped-but-assignable author could default to it
  (operator choice; MVP leans null).
- **Loaded by the sink** (Jira-side) — the neutral engine never reads it.
