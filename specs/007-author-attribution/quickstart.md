# Quickstart: Author-Based Attribution

By default the bridge creates issues with no assignee, so they fall to your Jira
project's default-assignee policy (often the project lead). Turn on attribution to
make the board show **who actually authored each spec** — as a label always, and
an assignee when the author has a Jira account.

## 1. Build the authors map (gitignored — holds real ids)

Copy the sample and fill in your team:

```bash
cp .specify/extensions/jira/jira-authors.local.yml.sample \
   .specify/extensions/jira/jira-authors.local.yml   # gitignored — never committed
```

```yaml
schema_version: 1
authors:
  "ashley@your-co.com":  { accountId: "<real-account-id>", handle: "ashley" }
  "afroze@partner.com":  { accountId: null,                handle: "afroze" }  # no Jira account → label only
default_assignee: null   # null = leave unassigned (NOT the project lead)
```

- `accountId: null` (or omitted) = a known author who has **no Jira account** —
  they still get the `author:<handle>` label, just no assignee.
- `handle` is the label token — keep it a short non-PII handle (never an email).

## 2. Enable it in `jira-config.yml`

```yaml
jira:
  attribution:
    enabled: true
    assignee: true            # set the assignee when the author has an accountId
    label: true               # always stamp author:<handle>
    author_source: ["spec_owner_line", "git_first_add"]   # resolution order
    authors_file: "jira-authors.local.yml"
```

Leaving the block out (or `enabled: false`) keeps today's behavior exactly.

## 3. (Optional) Pin an author explicitly

The git first-add author is the default; override per spec with a line in
`spec.md`:

```markdown
Owner: ashley@your-co.com
```

An `Owner:`/`Author:` line wins over git — useful for re-attribution, pairing, or
when the first committer isn't the real owner.

## 4. Push

```bash
set -a && source .env && set +a
reconcile.sh --all
```

Each spec's issue is now:
- **labelled** `author:<handle>` (always), and
- **assigned** to the author's account when they have one.

The run summary names the resolved author + where it came from (`Owner:` line vs
git) per spec.

## What it never does

- **Never overwrites a manual reassignment.** Assignee is set only when the issue
  is first created; if you reassign in Jira, the next reconcile leaves it alone.
- **Never leaks PII.** The map is gitignored; labels carry a handle, never an
  email or accountId.
- **Never changes your project's assignee policy.** If `assignee` is on and your
  project default is *Project Lead*, an **unmapped** author's issue still lands on
  the lead — set the project default to **Unassigned** for a neutral mirror.
- **Never fails the whole run** on a bad accountId — it surfaces the error and
  still applies the label.
