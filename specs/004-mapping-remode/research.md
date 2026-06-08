# Phase 0 Research: Mapping Re-mode / Orphan Pruning

All five spec Open Questions were pinned in `/speckit-clarify` (Session
2026-06-08). This document resolves the *implementation* decisions those answers
imply, on the merged 003 foundation. Each decision is stated as
Decision / Rationale / Alternatives.

---

## R1 — Orphan identification: a set diff over identity labels

**Decision.** Compute orphans as `O = E \ D`, keyed by **identity label**:

- **Desired-shape set `D`** = `{ reconcile::compose_identity(level, item, slug[, idx]) }`
  over every spec and every level the *current* mapping projects an *issue* for.
  This reuses the 003 neutral composer verbatim — the same call the projection
  uses to find-or-create. The checklist/task **sentinel** level projects no issue
  (it renders into the parent body), so it contributes **no** issue identity to
  `D` — exactly why its prior issue-shaped artifacts become orphans.
- **Existing bridge-owned set `E`** = issues discovered by walking the repo Epic's
  descendant tree (repo Epic → child spec issues → child phase subtasks, via the
  existing `parent = "<key>"` JQL pattern already in
  `query_subissue_for_phase`) and keeping only those that satisfy the **bridge-
  owned predicate** (R3).
- **Orphans `O = E \ D`**: bridge-owned issues whose identity label is not in the
  desired set. These are the prune targets. Everything in `D ∩ E` is kept (and
  reconciled normally); everything in `D \ E` is created normally.

**Rationale.** The identity label is *already* the idempotency key the bridge
mints and matches on. Diffing on it means orphan detection reuses the exact tokens
the projection produces — no second notion of identity, no drift between "what we
create" and "what we'd prune". The diff is pure set logic over strings: vendor-
neutral, so it lives in the engine and keeps the 003 neutrality gate green.

**Alternatives considered.**
- *Project-scoped JQL per identity family* (`labels = "speckit-spec:001"` …). Jira
  JQL has **no label wildcard**, so enumerating "all bridge labels" this way is
  impossible without already knowing every value — circular. Rejected.
- *A stored manifest of what-we-last-created* (sidecar file). Violates Principle II
  (no fs-side cache of "what Jira last saw"). Rejected.
- *Descendant walk + predicate* (chosen): needs no wildcard and no cache — the live
  tree under the repo Epic plus the prefix predicate is the manifest.

---

## R2 — Enumerating `E`: bounded descendant walk from the repo Epic

**Decision.** `jira_sink::enumerate_bridge_descendants <repo_epic_key>` returns the
bridge-owned issues beneath the repo Epic by level:

1. The repo Epic is found by its repo identity label (reuse `_repo_epic_key` /
   `query_spec_issue`). If absent, `E = ∅` (nothing was ever mirrored → nothing to
   prune).
2. Child issues: `parent = "<epic_key>"` → candidate spec-level issues.
3. Grandchild issues: for each spec issue, `parent = "<spec_key>"` → candidate
   phase-level issues.
4. Each candidate is filtered through the **bridge-owned predicate** (R3).

The walk is bounded by the live tree (one search per parent), not the full project.

**Rationale.** The bridge always parents its artifacts (spec under repo Epic, phase
under spec issue), so the descendant tree *is* the complete bridge-owned set for a
repo — reachable with the `parent = …` query the sink already uses. Scoping the
walk to the repo Epic's subtree (not the whole project) also bounds the blast
radius: an operator issue in an unrelated part of the project is never even read.

**Alternatives considered.** Whole-project scan filtered by predicate — broader
reads, larger surface, no benefit since bridge artifacts are always under the Epic.
Rejected. *Note for the Initiative super-level:* when an Initiative is configured,
the repo Epic's parent (the Initiative) is itself a bridge artifact; the walk
starts one level up (Initiative → Epic → …) when `mapping::initiative_enabled`.

---

## R3 — The bridge-owned predicate (the load-bearing safety net)

**Decision.** An issue is **bridge-owned** iff it carries **at least one label whose
value begins with a configured identity prefix** — `repo_prefix`, `spec_prefix`,
`phase_prefix`, or `task_prefix` (read from config; the operator-chosen `speckit-*`
namespace). The `lifecycle_prefix` (`phase:*`) does **not** count — it is a status
label, not an identity, and an operator could plausibly use it. An issue with no
identity-prefix label is the operator's and is **structurally excluded** from `E`
(and therefore can never enter `O`).

This predicate is evaluated **client-side** on labels already returned by the
descendant search — it requires no extra read and no JQL wildcard.

**Rationale.** Per the spec, the identity labels are the manifest (FR-015) and this
predicate is the *sole* load-bearing safety net under the destructive-by-default +
hard-delete defaults — so it must be (a) explicit, (b) conservative (fail to
"operator-owned" when ownership can't be proven, FR-002), and (c) adversarially
tested. Matching on the *prefix* (not an exact value) means a stale label from a
prior mapping shape (e.g. an old `speckit-subtask:` value the new mapping never
mints) is still recognized as bridge-owned and thus prunable — which is the whole
point. An operator who manually applies a `speckit-*` identity label opts that
issue in: a documented consequence of the identity contract (spec Assumptions).

**Alternatives considered.**
- *Exact-match against the set the bridge could currently mint*: would miss
  orphans whose label family the new mapping no longer produces — defeating the
  feature. Rejected.
- *A single constant `speckit-owned` marker label on every artifact*: cleaner
  predicate, but existing already-mirrored boards lack it until re-mirrored, so it
  can't recognize today's orphans. Recorded as a possible future hardening
  (belt-and-suspenders), not the v1 mechanism.

---

## R4 — Re-mode = prune(O) then reconcile(D); preview fidelity is structural

**Decision.** `reconcile::remode` runs:

1. **Read phase** (no writes): resolve the repo Epic, enumerate `E`, compute `D`
   from the current mapping, derive `O = E \ D` and the regenerate set.
2. **Plan**: emit the prune list and the regenerate list to the summary.
3. **If `--dry-run`**: stop here (zero writes).
4. **Else**: prune each `o ∈ O` (R5/R6), then run the ordinary projection for `D`
   (the unchanged 003 path) to regenerate/converge the new shape.

Preview fidelity (SC-003) is **structural, not a re-derivation**: the dry-run and
the real run compute `O` and `D` through the *same* function on the *same* read
snapshot; `--dry-run` only gates whether step 4 executes. There is no second code
path that could diverge.

**Rationale.** Making the preview the *prefix* of the real run (same computation,
gated tail) is the only way to guarantee "the preview faithfully matched the
action" without a fragile re-comparison. It mirrors how the existing engine's
`ARG_DRY_RUN` gate already works (log-what-would-fire, issue none).

**Alternatives considered.** Compute a preview, then independently recompute for
the action — two code paths, two chances to drift; rejected as exactly the failure
SC-003 forbids.

---

## R5 — Destruction model: hard-delete (default) | archive, operator-selectable

**Decision.** `jira_sink::prune_artifact <key>` dispatches on a config key
`remode.destruction` (default `hard-delete`):

- **`hard-delete`** → `DELETE /rest/api/3/issue/{key}` (the cleanest board; bridge
  content is regenerable, so no backup is needed). Comments/links on the issue are
  lost — the operator is warned first when the issue shows human edits (R6 / FR-010).
- **`archive`** → preserve the human layer by **transitioning** the issue to a
  configured archived/superseded status *and* stripping its identity labels (so it
  leaves `E` and is never re-matched), optionally adding a `speckit-archived`
  marker. Requires the operator to have configured an archive status id (Principle
  V: id, not name). If unset, archive mode hard-errors with copy-paste remediation
  (Principle VIII) rather than silently hard-deleting.

Either way the **scope is identical** — only bridge-owned `O` (FR-002/FR-011).

**Rationale.** The clarify answer is "operator-selectable, default hard-delete".
Hard-delete is the regenerable-content default; archive is the escape hatch for
teams that accumulate human collaboration on issues and would rather not lose it.
Stripping identity labels under archive is what makes archive *idempotent*: an
archived orphan no longer satisfies the bridge-owned predicate, so a subsequent
re-mode won't see it again.

**Alternatives considered.** Relabel/detach-only (no status change) — leaves the
issue visibly on the active board, contradicting the "clean mirror" goal. Offered
conceptually but folded into "archive" (which both detaches identity and moves the
issue off the active board via status). A delete-always model — rejected: ignores
the clarify decision and destroys the human layer with no opt-out.

---

## R6 — Fail-closed ordering + backward-drift warning before deletion

**Decision.** Ordering is strict:

1. Complete **all** reads that build `E` and `D` first. If *any* read is unreadable
   (rc 3 from the REST layer), **abort the entire re-mode with zero deletions**
   (FR-005 / SC-006) — a partial `E` could misclassify an orphan or, worse, fail to
   see an operator issue's identity.
2. For each `o ∈ O`, before pruning, run the **existing** backward-drift check
   (`reconcile::compute_drift` against the issue's `updated` / lifecycle): if Jira
   is ahead (a human edited it), surface a named WARNING (FR-010) identifying the
   issue. Honor `--on-drift=abort` to *skip pruning that issue* (leave it,
   surfaced); default disposition proceeds-and-warns (Principle IV — surface,
   don't block).

**Rationale.** Fail-closed-before-write is the hard guarantee the spec leans on:
no destructive write may precede a complete, trustworthy read of the existing set.
Reusing the existing drift machinery for FR-010 means the "human edited a
to-be-pruned issue" warning is consistent with every other drift warning the
bridge already emits — no new policy surface.

**Alternatives considered.** Interleave reads and deletes (stream-prune) — faster
but a mid-walk read failure would leave the board partially destroyed with an
incomplete picture. Rejected outright; it is the exact SC-006 violation.

---

## R7 — Partial-failure: surface + resumable, never silent

**Decision.** Each prune is independent. A failed delete/transition increments a
**warned** summary counter naming the issue and continues with the rest (no abort
on a single failure *after* the fail-closed read gate passed). A re-run recomputes
`O` from live reads — the still-present failures reappear in `O` and are retried;
the succeeded ones are gone and don't. Re-mode is therefore **resumable and
idempotent** (FR-009): converges over re-runs.

**Rationale.** Recompute-from-live-state is the Principle II convergence property
applied to deletion: the set diff is recomputed every run, so "what's left to
prune" is always exactly "what's still there but unwanted". No partial-progress
cursor or cache needed.

**Alternatives considered.** Abort-on-first-failure — leaves a half-pruned board
and forces the operator to reason about ordering; rejected. Silent best-effort —
forbidden by Principle VIII.

---

## R8 — Ordinary reconcile warns on orphans (FR-014), never prunes

**Decision.** After the ordinary (non-`--remode`) reconcile projects `D`, it
enumerates `E` and, if `E \ D ≠ ∅`, emits a single WARNING row listing the
orphans and suggesting `--remode` — but performs **zero** destructive writes
(FR-004/FR-014). The enumeration reuses R2; to keep the ordinary path cheap, the
warning is computed from the same descendant reads the reconcile already needs
where possible, with at most a bounded extra descendant query otherwise.

**Rationale.** Surfacing stale-shape drift (Principle VIII) means an operator who
changed the mapping but ran a plain reconcile isn't silently left with orphans —
they're told, and told the remedy, without the bridge ever acting destructively on
its own (Principle VII: auto-path stays non-destructive).

**Alternatives considered.** Silent (no warning) — operator discovers orphans only
by eyeballing the board; rejected. Auto-prune in the ordinary path — explicitly
out of scope and a Principle I/VII violation; rejected.

---

## R9 — Constitutional amendment (gating prerequisite)

**Decision.** Amend `constitution.md` **before** any destructive code lands,
bumping **v1.0.0 → v1.1.0 (MINOR)**. The amendment adds a scoped controlled-
destruction carve-out to Principle I (and a cross-reference in the Architectural
Constraints), of the form:

> The mirror is non-destructive **except** through the explicit, opt-in re-mode
> operation, which MAY remove bridge-owned artifacts (those carrying the
> `speckit-*` identity labels) when the current mapping no longer projects them.
> Re-mode MUST be (a) reachable only via an explicit flag — never auto-fired on a
> hook; (b) restricted to bridge-owned artifacts (never operator-created); (c)
> dry-run-previewable with byte-faithful fidelity; (d) fail-closed (an unreadable
> read aborts before any destructive write). The ordinary reconcile remains
> strictly non-destructive and only *warns* on detected orphans.

**Rationale (MINOR, not MAJOR).** The semver rules make MAJOR = "removing a
principle, redefining the data-model mapping, eliminating a layer." This does none
of those: Principle I stays, the data-model mapping (repo→Project, spec→Issue,
phase→subtask) is unchanged, both layers remain. It *adds a new scoped
constitutional constraint* — squarely the MINOR definition. The departure is
real but bounded, so it is recorded as a guarded exception, not a rewrite.

**Process (Governance).** The amendment must (a) update `constitution.md`, (b)
propagate the Sync Impact Report header, (c) bump the version, (d) land in a PR
whose description names the principle redefined. The plan sequences this as the
**first** task in Phase 2, gating the destructive implementation tasks. If a
reviewer judges the departure MAJOR, the bump changes but the gating order does
not.

**Alternatives considered.** Ship destruction without amending (silent behavior
change) — forbidden by Governance and by FR-013. Treat as MAJOR pre-emptively —
defensible, but over-reads the semver rules for what is an additive scoped
constraint; left to reviewer discretion at amendment time.

---

## Resolved unknowns

No `NEEDS CLARIFICATION` remain. The five spec Open Questions are pinned in
clarify; R1–R9 resolve their implementation. The equivalence/safety oracle is the
new adversarial scoping suite (US2) plus the idempotent-flip suite (US4), layered
on the unchanged 003 projection (which the existing 365-test suite already guards).
