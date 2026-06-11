# Phase 0 Research: Author-Based Attribution

The three user-facing forks are pinned in clarify. This resolves the
implementation decisions on the 003 engine/sink seam. Decision / Rationale /
Alternatives.

## R1 — Author resolution (neutral, engine/parser)

**Decision.** Per spec, resolve one author in priority order:
1. `parser::spec_author <spec.md>` — an explicit `Owner:` or `Author:` line in the
   spec's front-matter/top matter (case-insensitive `^(Owner|Author):\s*(.+)`).
2. `git_helpers::spec_first_author <spec_dir>` — the first commit that ADDED the
   spec dir: `git log --diff-filter=A --reverse --format='%ae' -- <spec_dir>/ |
   head -1`. (Email; the dir-add commit = "who started it".)
3. Neither → author = **unknown** (empty); no label, no assignee, **not an error**.

**Rationale.** An explicit `Owner:` is authoritative + account-independent (covers
renames, re-attribution, pairing). git first-add is the stable default ("who
started it", unaffected by later edits). Unknown-is-graceful preserves the
non-destructive, surface-don't-fail contract (Principle VIII).

**Alternatives.** git *last* author or *most-commits* — churn-sensitive and less
meaningful than "who started it"; rejected (clarify b). Resolving author in the
sink — would couple git to the sink, breaking the engine/sink seam; rejected.

## R2 — Neutral `author` floor field on the workstate item

**Decision.** The parser/workstate emits `item.author = {value, source}` where
`value` is the resolved email or `Owner:` string and `source ∈ {owner_line,
git_first_add}` (empty/absent when unknown). Add `author` as an **optional,
additive** floor field to the workstate schema (vendor-neutral — no Jira id).

**Rationale.** The sink consumes only `workstate` (Principle X), so author must be
expressible there; it stays neutral (an email/owner string + a source enum — no
accountId, no Jira vocabulary). The sink does the email→accountId/handle mapping.

**Alternatives.** Carry author under `extensions.*` — but `extensions` is for
vendor-specific keys the engine must *not* depend on; author is neutral → a floor
field. Pass author in-memory (not in workstate) — violates "sink consumes only
workstate". Both rejected. (Additive-safe, like 005's `decisions[]`; same
cross-repo schema note.)

## R3 — The operator authors map (gitignored, sink-side)

**Decision.** `jira-authors.local.yml` (gitignored), loaded by the sink:

```yaml
schema_version: 1
authors:
  "<email>": { accountId: "<id-or-null>", handle: "<non-pii-handle>" }
default_assignee: null      # null = leave unassigned (NOT project lead)
```

- A `null`/absent `accountId` = **known author, not assignable** → label only.
- `handle` is **required** per entry (the non-PII label token, clarify a).
- Only `jira-authors.local.yml.sample` (placeholder ids) is committed.

**Rationale.** Email→accountId cannot be resolved at runtime (GDPR-restricted user
search — the dogfood finding), so a static operator map is mandatory. It holds
real emails + accountIds (PII) → gitignored, like `.env`/`jira-config.yml`
(Principle VI/IX). An explicit per-entry `handle` keeps PII out of labels and
removes ambiguity.

**Alternatives.** Dynamic email→account lookup — impossible (GDPR). Deriving the
handle from the email local-part — can leak a real name (PII) + ambiguous;
rejected (clarify a).

## R4 — Assignee: create-only, never on update (Linear FR-034)

**Decision.** The sink sets `fields.assignee.accountId` **only on the create** of
the spec-level artifact, and only when the author maps to a non-null accountId. On
**update** it never includes assignee. The create-vs-update branch already exists
in the spec sync (`sync_level_artifact` / the spec path distinguishes
absent→create from present→update).

**Rationale.** Exactly the Linear FR-034 semantics — assignee is an *initial*
attribution, and a manual reassignment in Jira is an operator signal the bridge
must not clobber (Principle I: surface, don't enforce; Principle II: zero update
churn). It also keeps re-runs idempotent (no assignee diff to write).

**Alternatives.** Set assignee on every reconcile — clobbers manual reassignment +
churns; rejected. A config to force-overwrite — out of MVP scope (an explicit
escape hatch would be a separate decision).

## R5 — `author:<handle>` label: strip-stale-then-set idempotency

**Decision.** On the spec-level issue, the desired label set includes
`author:<handle>` (the map handle). Reconcile **strips any existing `author:*`
label and sets the current one** — the same hygiene the lifecycle `phase:*` labels
already use, so a re-run is zero-churn and an author change replaces (not stacks).

**Rationale.** Labels carry identity in this bridge (`speckit-spec:NNN`,
`phase:*`); an `author:*` label is the same pattern and reuses the existing label
diff. It's the **always-on** track that works for non-Jira-users (US2).

**Alternatives.** A custom field for author — vendor-specific, needs per-project
field-id binding, fragile; the label is universal + free. Rejected for MVP.

## R6 — Fail-soft on a bad assignee write

**Decision.** If the create with `assignee.accountId` is rejected (e.g. a stale or
deactivated account), the sink surfaces the failure (a named summary warning, with
the field-level error detail via the existing `_error_detail`) and **still applies
the label** / completes the spec — it does NOT abort the reconcile.

**Rationale.** A bad accountId is operator-fixable config drift, not a reason to
halt the whole mirror (Principle VIII — observable, not fatal). The label track is
the durable guarantee, so attribution still lands.

**Alternatives.** Abort on a bad assignee — turns a config typo into a full-mirror
outage; rejected. Silently drop — violates Principle VIII; rejected.

## R7 — Config, gitignore, sample, privacy

**Decision.** An opt-in `attribution:` block in `jira-config.yml`:
`{enabled, assignee, label, author_source: [spec_owner_line, git_first_add],
authors_file}`. Absent/`enabled:false` ⇒ **byte-identical to today** (no assignee,
no author label). `.gitignore` gains `.specify/extensions/jira/jira-authors.local.yml`
(the bridge currently ignores `.env` + `jira-config.yml`, not a `*.local.yml`
glob — add the explicit path). A committed `jira-authors.local.yml.sample` shows
the shape with placeholder ids. The privacy guard (`no-real-identifiers.bats`)
covers the `.sample` + every fixture (no real email/accountId; non-PII handles).

**Rationale.** Opt-in default-OFF is the backward-compat contract (US4/SC-004) and
the standard pattern (002 mapping, 004 remode, 005 ADR all additive). Gitignoring
the map + placeholder-only sample is the Privacy-IX guarantee for the new PII
surface.

**Alternatives.** On-by-default — would change every existing consumer's board +
risk leaking the lead assignee; rejected. A `*.local.yml` glob — broader but the
explicit path is clearer and matches the existing two ignored files. (Either is
acceptable; the plan uses the explicit path.)

## Resolved unknowns

No `NEEDS CLARIFICATION` remain. The regression anchor is US4 (off-by-default
byte-identical); the safety gates are the privacy guard (FR-010) + the 003
neutrality gate (FR-009); idempotency is US3 (assignee create-only + stable label).
