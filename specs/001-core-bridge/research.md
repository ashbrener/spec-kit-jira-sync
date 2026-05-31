# Phase 0 Research — Core Bridge

Decisions that resolve the open technical choices before design. Each: what was
chosen, why, and what was rejected. No real Jira coordinates appear here; all
instance values are resolved at install time into the gitignored config.

## D1. Engine vs sink boundary (the seam)

**Decision**: Copy the vendor-neutral engine from the sibling's `reconcile.sh`
**unchanged** (origin-headed) and re-implement only the writer half as
`jira_sink.sh`. The engine calls a fixed interface the sink provides.

The engine keeps: drift comparator (`compute_drift`, `_phase_ordinal`,
`_drift_verdict_field`), disposition (`_drift_disposition`, `_drift_prompt`),
fail-closed fetch (`_fetch_drift_issue_json`, rc 3 = unreadable), recency gate,
lifecycle aggregation, exit-code escalation, arg/spec enumeration, and the
Markdown description composers (they depend on `git_helpers`, not the tracker).

The sink must expose (same names/return shapes as the sibling so the engine is
untouched): `mutate_issue_create`, `mutate_issue_update`, `mutate_comment_create`,
`query_spec_issue`, `query_subissue_for_phase`, `query_issue_blocks`,
`query_existing_comment_body`, `_fetch_drift_issue_json`, the `sync_*`
orchestrators, label resolution, and `config::get_status_transition` (the single
vendor lever; the sibling's `config::get_workflow_state_uuid`).

**Rationale**: The hardening (idempotency, fail-closed, recency) lives in the
engine; rewriting it would lose it. Two independent sinks (Linear + Jira) behind
one interface is what later justifies extracting a shared engine package.

**Alternatives rejected**: (a) Rewrite the engine fresh — loses hardening,
defeats the extraction goal. (b) Pre-extract the shared engine now — premature;
the brief mandates building Jira first so the real seam reveals itself.

## D2. Jira REST API version and body format

**Decision**: Target **REST API v3** and render issue/comment bodies as **ADF**
(Atlassian Document Format, JSON). A minimal `adf.sh` converts the engine's
Markdown blocks to ADF (paragraphs, headings, bullet/ordered lists, code, links).

**Rationale**: v3 is the current, supported surface; ADF is its native body
representation and round-trips cleanly. A small converter covers everything the
engine emits.

**Alternatives rejected**: (a) REST v2 with wiki-markup/plain `text` bodies —
simpler but deprecated-trending and lossy for structured bodies. (b) Full
Markdown→ADF library — none in pure bash; we only need a bounded subset.

## D3. Task-phase checklist rendering

**Decision**: Render each phase's tasks as an **ADF `taskList`** (interactive
checkboxes with `state: DONE | TODO`) inside the Subtask body, derived from the
`tasks.md` checkbox state.

**Rationale**: Gives real Jira checkboxes that visually match `tasks.md`; the
done/not-done state is a direct map. Idempotent: same tasks.md → same taskList.

**Alternatives rejected**: A plain bullet list with `[x]`/`[ ]` text — renders
as literal characters, not checkboxes; weaker fidelity.

## D4. Idempotency key representation

**Decision**: Identify mirrored issues by **Jira labels queried via JQL**, no
custom field required:

- Spec Story ↔ label `speckit-spec:NNN` (JQL `labels = "speckit-spec:NNN"`).
- Phase Subtask ↔ parent Story + label `task-phase:N`.
- Repo Epic ↔ label `speckit-repo:<slug>` (slug derived from `workstate.source.repo`).

**Rationale**: Mirrors the sibling's label-as-identity approach; Jira labels are
free strings and JQL-queryable; needs no schema/custom-field provisioning, so
this core feature stays independent of seed. Visible and auditable.

**Alternatives rejected**: (a) Jira **issue properties** (hidden metadata,
JQL-queryable) — more robust against label edits but heavier and less visible;
revisit if label collisions appear. (b) A marker line in the description —
fragile to body edits.

## D5. Per-repository Epic identity and linking

**Decision**: The sink ensures exactly one Epic per repo, found/created by the
`speckit-repo:<slug>` label, and links each spec Story to it via the Story's
`parent` (team-managed) or epic-link field (resolved from config). The Epic is a
**sink projection of `workstate.source.repo`**, not a `workstate` item.

**Rationale**: Satisfies the clarified hierarchy without polluting the neutral
`workstate` floor — a positive Principle X result (the contract didn't need to
grow). Idempotent via the repo label.

**Alternatives rejected**: Adding a repo-container item to `workstate` — would
couple the floor schema to a tracker-grouping concern; unnecessary.

## D6. Status transitions

**Decision**: Set a Story's status by **POSTing a transition**, not by setting a
status field. The sink fetches available transitions, selects the one whose
`to` status id equals the config-mapped target for the lifecycle phase, and
POSTs it. Config supplies `phase → status-id` and the transition map.

**Rationale**: Jira has no "set status" write; transitions are the only path.
The observed target board uses **global transitions** (any status reachable,
no screens, non-conditional), so a single transition POST suffices with no
workflow-graph walking. Where a direct transition is unavailable, surface a
warning (Principle VIII) rather than forcing a multi-hop path in this feature.

**Alternatives rejected**: Multi-hop transition pathfinding — unnecessary given
global transitions; deferred unless a non-global workflow appears.

## D7. Rate-limit (HTTP 429) handling

**Decision**: On 429, honor the `Retry-After` header; if absent, exponential
backoff (base ~1s, doubling, jittered) capped (~60s), **bounded** to a small
retry count (default 5). On exceeding the bound, **fail closed** for that spec
and report it (FR-022, SC-008). Same policy for transient 5xx.

**Rationale**: Matches real Jira Cloud throttling (we observed transient
429/401 during exploration); bounded-then-fail-closed avoids unbounded hangs
while tolerating normal throttling.

**Alternatives rejected**: (a) Immediate fail on 429 — flaky on larger repos.
(b) Unbounded retry — risks indefinite hangs, weakest operational story.

## D8. Authentication

**Decision**: HTTP **Basic auth** with `JIRA_EMAIL:JIRA_API_TOKEN` against
`JIRA_BASE_URL`, all read from the gitignored `.env`. The Atlassian MCP (OAuth)
is for interactive exploration only; the sink/seed/Action use the token.

**Rationale**: Jira Cloud's token model is Basic auth; the brief mandates REST.
Token confined to `.env` (local) / repo secret (CI) per Principle VI.

**Alternatives rejected**: OAuth 3LO in the sink — heavy for an unattended CLI;
the MCP can't be assumed present in CI/headless runs.

## D9. workstate validation mechanism

**Decision**: The parser emits `workstate` JSON; a **test/CI gate validates it
against the published schema using `python3` + `jsonschema`** (the schema repo's
`validate.py` approach). Runtime bash does lightweight structural checks (`jq`)
only; authoritative Draft-2020-12 validation is the test gate.

**Rationale**: `jq` cannot do full JSON-Schema validation; `jsonschema` is
authoritative. Keeping it in the test/CI gate (not runtime) avoids adding a
Python runtime dependency to the bridge while still proving the contract.

**Alternatives rejected**: (a) Hand-rolled bash/jq schema validation — partial,
error-prone. (b) Python at runtime — adds a runtime dep the bridge otherwise
avoids.

## D10. Jira REST mock for tests (curl-shim)

**Decision**: In bats, shadow `curl` with a stub function that returns fixture
JSON from `tests/fixtures/jira_responses/` keyed by method + URL pattern (and
records the request for assertions). Mirrors the sibling's curl-shim.

**Rationale**: Deterministic, offline, fast; lets unit/integration tests cover
create/update/transition/comment/idempotency/drift/429/fail-closed without a
live instance. Integration against a real instance stays behind
`RUN_INTEGRATION_TESTS=1`.

**Alternatives rejected**: A local HTTP mock server — heavier, adds a runtime
dep and port management to CI for no extra coverage.

## D11. Lifecycle inference (disk-only)

**Decision**: Reuse the sibling parser's phase inference from on-disk artifacts
(`spec.md`/`plan.md`/`tasks.md` presence/content + recorded sessions). "merged"
is inferred from disk only; `gh`-based PR/merge detection is **out of scope**
(clarified). The phase vocabulary and ordinal ordering come from the shared
engine unchanged.

**Rationale**: Keeps this feature dependency-light and deterministic/testable;
honors the clarification. The engine's `_phase_ordinal` already encodes the
ordering used by drift.

**Alternatives rejected**: gh/git merge heuristics in this feature — deferred to
a later spec to keep the core path pure.
