# PLAN — spec-kit-jira build

> Strategy doc for review (per SEED-BRIEF §8). It fixes the engine-*copy* vs
> rewrite-*fresh* boundary before any build code lands, and precedes the formal
> `/speckit-plan` (this is its seed, not a substitute). **Stop here for sign-off.**
>
> Privacy: this file is tracked. It contains NO real workspace/company/project
> names, person names, emails, UUIDs, or instance IDs. All such values are
> discovered at install time and written only to the gitignored `jira-config.yml`
> / `.env`. The local workflow shape below is described generically.

## 0. North star

A from-scratch Jira sink eats the neutral `workstate` format cleanly → Jira sync
works → `workstate` is proven by a second, independent consumer → the shared
engine can later be extracted from both spec-kit-linear and here.

## 1. Pipeline

```
specs/NNN-*/  →  parser  →  workstate JSON  →  jira-sink  →  Jira REST
                (reuse)      (the contract)     (write fresh)   (many endpoints)
```

## 2. The engine ↔ writer seam (the crux)

`spec-kit-linear/src/reconcile.sh` (3579 lines) MIXES a vendor-neutral drift
engine with a Linear GraphQL writer. The seam is stable and well-defined: the
engine CALLS a fixed set of read/write functions that the writer PROVIDES. The
jira-sink re-implements those same signatures against Jira REST.

**Engine (vendor-neutral — copy):** drift comparator (`compute_drift`,
`_phase_ordinal`, `_drift_verdict_field`), disposition fork (`_drift_disposition`,
`_drift_prompt`), fail-closed fetch (`_fetch_drift_issue_json` — rc 3 = sink
unreadable), recency gate, lifecycle aggregation (`_desired_project_state`,
`_record_lifecycle`), exit-code escalation (`promote_exit`), arg/spec
enumeration, and the Markdown description composers (`render_*_block`,
`compose_issue_description`) which depend on git_helpers, not on any tracker.

**Writer interface the jira-sink must expose (same names/JSON shapes):**

| Engine calls | Linear today | Jira sink (fresh) |
|---|---|---|
| `mutate_issue_create(input)` | `issueCreate` | `POST /rest/api/3/issue` |
| `mutate_issue_update(id,input)` | `issueUpdate` | `PUT /rest/api/3/issue/{key}` |
| `mutate_comment_create(id,body)` | `commentCreate` | `POST /issue/{key}/comment` |
| `query_spec_issue(label,scope)` | `issues` by label | `GET /search` (JQL) |
| `query_subissue_for_phase(parent,label)` | `issues` by parent | JQL on parent + label |
| `query_issue_blocks(id)` | `relations` | `GET /issue/{key}` issuelinks |
| `_fetch_drift_issue_json(n)` | read-only issue view | JQL (status, labels, updated) |
| `sync_spec_issue / sync_task_phase_subissues / sync_inter_phase_blocks / sync_clarify_comments / sync_project_status` | Linear orchestration | Jira orchestration |
| `_resolve_label_ids_array(names…)` | label→UUID | **Jira uses label names directly — no UUID indirection** |
| `config::get_workflow_state_uuid(token)` | phase→stateId | **phase→status, driven via a transition POST** |

The single vendor lever is `config::get_workflow_state_uuid`: Linear sets a
`stateId`; Jira instead resolves a target status and POSTs the matching
**transition**.

## 3. COPY UNCHANGED (engine — origin-header each file)

Add a header to every copied file: `# ORIGIN: copied unchanged from
spec-kit-linear/src/<f> @ <shortsha> — shared engine, pending extraction
(SEED-BRIEF §5).` so the later extraction is mechanical.

| File | Lines | Why copy |
|---|---|---|
| `src/git_helpers.sh` | 581 | git recency/drift helpers; 0 tracker coupling |
| `src/summary.sh` | 299 | structured run summary; pure infra |
| `src/parser.sh` | 432 | spec reader (see §4 — reused, lightly adapted) |
| engine portion of `src/reconcile.sh` | ~1500 of 3579 | drift/recency/disposition/lifecycle per §2 |

`src/config.sh` (560): copy the **shape**, swap Linear fields → Jira fields
(site, project key, issue-type ids, status/transition map, story-points field).

## 4. REUSE — parser emits `workstate`

`parser.sh` already has ~0 Linear coupling. Change: instead of feeding the
writer directly, it emits **`workstate` JSON** (schema at
`~/Code/AI/workstate-schema`). Mapping spec-kit → workstate:

- spec dir → `item{ id, title, kind:"spec", state:<lifecycle token>, body,
  coverage, labels:["speckit-spec:NNN"], item_source{path,last_commit_iso} }`
- task phases → `children[]` (`kind:"task"`)
- clarify sessions → `notes[]`; cross-spec deps → `links[]`
- Validate every emitted doc against the schema fixtures (the contract gate).

## 5. WRITE FRESH (Jira-specific)

- **jira-sink** — replaces `graphql.sh` (457) + the writer half of
  `reconcile.sh`. Thin REST client (curl + jq), Basic auth (`email:token` from
  `.env`), implementing the §2 interface. Behind `--dry-run` first.
- Jira analogues of `seed.sh` (1088), `pull.sh` (866), `status.sh` (888), and
  the discovery half of `install.sh` (3489). `seed` discovers/validates the
  per-instance mapping (issue types, statuses, transitions, story-points field)
  and writes the gitignored `jira-config.yml`.

## 6. workstate → Jira mapping (from the legacy board; generic form)

The legacy team-managed board observed has a standard shape — encode it as
config, not hard-code:

- **Hierarchy:** `kind:spec` → Epic (L1) or Story (L0); `children[]` → Subtask
  (L−1) via the `parent` field. (Board offers Epic/Story/Task/Bug/Subtask.)
- **State → status via transition:** statuses span the three standard
  categories (To-Do / In-Progress / Done) plus a review and a hold state. **All
  transitions are global** (no screens, non-conditional) → the sink resolves
  the target status and POSTs the one transition whose `to` matches; no
  workflow-graph walking needed. Map: `specifying/planning/tasking` → To-Do
  category; `implementing` → In-Progress; `ready_to_merge` → review status;
  `merged` → Done; blocked → hold status.
- **Story points:** the standard "Story point estimate" `jsw-story-points`
  number field (id discovered at install → config). This is the Jira home for
  the engine's `estimate`.
- **Labels:** Jira labels are plain strings (no UUID resolution) — the engine's
  `speckit-spec:*` / `phase:*` scheme maps 1:1; `_resolve_label_ids_array`
  becomes a near-passthrough.
- **Description:** ADF vs Markdown — Jira v3 wants ADF; the sink converts the
  engine's Markdown body (or uses the wiki-markup/`text` representation). TBD in
  build: confirm ADF conversion path.

## 7. Config & secrets

- `.env` (gitignored): `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`.
- `.specify/extensions/jira/jira-config.yml` (gitignored): per-instance ids +
  mapping, produced by `seed`. Committed `config-template.yml` holds placeholders.
- Privacy guard (`tests/unit/no-real-identifiers.bats`) scans the tracked tree
  for shape-based leaks (e.g. `ATATT…` tokens) plus operator literals from the
  gitignored `tests/.private-deny`.

## 8. Test strategy (the gate)

- Port spec-kit-linear's bats suite (11 unit files + integration) as the safety
  net; adapt fixtures Linear→Jira (the `fixtures/linear_responses/*.json` become
  `fixtures/jira_responses/*.json`).
- Mock Jira REST with the **curl-shim** pattern (mirror spec-kit-linear) — no
  live instance in unit/CI. Integration gated on `RUN_INTEGRATION_TESTS=1`.
- CI already seeded: shellcheck (`--severity=style`), yamllint (`-d relaxed`),
  markdownlint-cli2, bats matrix (ubuntu+macos × bash 4.4/5.2). Run exact CI
  locally before every push.

## 9. Build sequence

1. Copy engine files (§3) with origin headers; get them shellcheck-clean.
2. Adapt `parser.sh` → emit `workstate`; validate against schema fixtures.
3. Port bats suite + Jira fixtures; stand up the curl-shim mock.
4. Build jira-sink against the mock, behind `--dry-run`; satisfy the §2 interface.
5. `seed`/`install` discovery → gitignored `jira-config.yml`.
6. Only then: wire a real instance (token in `.env`), `--dry-run` first, then live.
7. Cross-model review at each phase boundary.

## 10. Open items / decisions

- **Canonical project: RESOLVED.** The legacy team-managed board is the sync
  target for dogfooding. Its real ids live only in the gitignored config /
  `.private-deny`.
- **Automation triggers: investigated via REST (read-only).** Rule *definitions*
  are not readable through the token API (the automation gateway returns 401 —
  it needs admin/session auth or a UI export). Changelog forensics show status
  transitions are performed **manually** by human accounts — no automation actor
  drives status — so the sink's transitions won't collide with existing
  status-automation. To capture actual rule definitions, export them from
  Automation settings (JSON) into a gitignored path for me to read.
- **Confluence scope:** current OAuth grants Jira only; the Story Points Guide
  (if a Confluence page) needs a re-auth with Confluence read scope. The Story
  Points *field* itself is already identified (standard number field; id in
  config).
- **`.env`:** add `JIRA_BASE_URL` + `JIRA_EMAIL` alongside the token (both now
  known) so the sink's Basic auth is complete. The privacy guard is now ACTIVE
  locally (real coordinates in gitignored `tests/.private-deny`, verified to
  catch leaks).

## 11. Debt (labeled, temporary — SEED-BRIEF §5)

The engine now lives in two repos. Deliberate: build Jira first, let the real
seam reveal itself, THEN extract the shared engine from both and backport
spec-kit-linear onto it. Origin headers (§3) make that extraction mechanical.
