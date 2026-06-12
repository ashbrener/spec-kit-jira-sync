# Phase 1 Data Model: Author-Based Attribution

No persisted engine state (Principle II). The "model" is the neutral `author`
field on the workstate item, the gitignored operator map, and the two Jira
attributes (assignee + label) it projects.

## Entities

### Author (neutral — on the workstate item)

`item.author = { value, source }` — the resolved authorship, vendor-neutral.

| Field | Meaning |
|---|---|
| `value` | the author email (git first-add) or the `Owner:`/`Author:` string |
| `source` | `owner_line` \| `git_first_add` (absent ⇒ unknown) |

Empty/absent when neither an `Owner:` line nor git history resolves an author
(unknown → no label, no assignee, not an error). Added to the workstate schema as
an **optional, additive** floor field (no Jira id; the sink maps it).

### Authors map (`jira-authors.local.yml`, gitignored — sink side)

```yaml
schema_version: 1
authors:
  "<email>": { accountId: "<id> | null", handle: "<non-pii-handle>" }
default_assignee: "<id> | null"   # null = leave unassigned (NOT project lead)
```

- key = git email (matches `item.author.value`).
- `accountId` `null`/absent ⇒ known author, **not assignable** (label only).
- `handle` **required** — the non-PII label token (FR-004).
- Real values (PII) ⇒ gitignored; only a `.sample` with placeholders is committed.

### Authorship label (always — on the spec issue)

`author:<handle>` — the durable, account-independent attribution. Strip-stale
(`author:*`) then set the current one (the `phase:*` hygiene). Works for everyone,
including non-Jira-users.

### Assignee (create-only — on the spec issue)

`fields.assignee.accountId` — set **only on create**, only when the author maps to
a non-null accountId. Never sent on update (manual reassignment survives — FR-003).

## Resolution → projection (per spec)

```text
  Owner:/Author: line?  ──yes──▶ author.value = owner, source = owner_line
        │ no
  git first-add author? ──yes──▶ author.value = email, source = git_first_add
        │ no
   author = unknown ──▶ no label, no assignee (graceful)
                          │
        ┌─────────────────┴──────────────── author known ────────────────┐
        ▼                                                                  ▼
  map[value].handle ──▶ label  author:<handle>      map[value].accountId ──▶ assignee
  (always, idempotent; missing handle = config       (CREATE only; null ⇒ omit;
   error → surfaced, no PII fallback)                  bad id ⇒ fail-soft, label still applied)
```

## Validation rules

- **VR-1 (FR-003/SC-003)**: assignee appears in a CREATE payload only; an UPDATE
  payload for the spec issue contains **no** assignee field (manual reassignment
  survives; re-run zero-churn).
- **VR-2 (FR-004)**: at most one `author:*` label on the spec issue after a run;
  stale `author:*` labels are removed (no stacking).
- **VR-3 (FR-006/SC-004)**: `attribution.enabled` false/absent ⇒ the create/update
  payloads have **no** assignee and **no** `author:*` label (byte-identical).
- **VR-4 (FR-008)**: a rejected assignee write is surfaced (warned, with detail)
  and the spec still completes with its label.
- **VR-5 (FR-010/SC-005)**: no real email/accountId in any tracked file or label;
  labels contain a `handle`, never an email; the map + `.sample` carry no real PII.
- **VR-6 (FR-009)**: `item.author` is neutral (email/owner + source enum); the
  engine path carries no Jira vocabulary (neutrality gate green).
