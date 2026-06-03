# EXTRACTION-PLAN — shared engine + `source-speckit` carve-out

> Status: **deferred, not started.** This is the post-Jira refactor that repays
> the deliberate debt recorded in `PLAN.md` §11 and `SEED-BRIEF.md` §5. It is
> written now (ahead of work) so the debt is a *move*, not a *rewrite* — and so a
> fresh agent knows the target shape, the order, and the unblocking criteria
> without reconstructing them from commit history.
>
> Privacy: tracked file — no real coordinates. Generic shapes only.

## Why this is deferred (and why that was right)

The vendor-neutral reconcile engine currently lives in **two** repos: copied
verbatim from `spec-kit-linear` into this repo (origin-headered per `PLAN.md` §3).
That duplication is intentional. Building Jira *first*, against a real seam, let
the engine↔sink interface prove itself under a second, independent consumer before
we freeze it as a shared library. Extracting earlier would have frozen an
unproven interface. Now that `001-core-bridge` is functionally complete and the
seam held, extraction is mechanical — but it should still wait behind
**feature-002** (see ordering below), because configurable mapping is the change
most likely to still reshape the interface.

## The three moves (they ship together, post-Jira)

Extraction is not one change; it's three coupled carve-outs that must land as a
set so neither repo is left half-fused:

1. **Engine → shared library.** Lift the vendor-neutral engine (the ~1500 engine
   lines of `reconcile.sh` plus `git_helpers.sh`, `summary.sh` — the files
   carrying the `# ORIGIN:` headers) out of both `spec-kit-linear` and this repo
   into one shared home.
2. **Parser → `source-speckit` producer.** The spec-kit parser (`parser.sh`)
   currently lives *inside* this sink repo as temporary debt. It leaves, becoming
   a standalone producer that emits `workstate` and nothing else. This repo then
   becomes a **pure `workstate` → Jira consumer**.
3. **Backport `spec-kit-linear`.** Rewrite the Linear tool onto the extracted
   shared engine (so the bugfix-once-benefits-all property becomes real), and
   point it at the `source-speckit` producer.

## Target shape (decisions to confirm at extraction time)

These were under-specified before this doc; recording the *proposed* answer so
the decision is explicit, not implicit. Confirm/override when the work starts.

| Question | Proposed answer | Confirm at extraction |
|---|---|---|
| Where does the shared engine live? | A new standalone repo (e.g. `workstate-engine`) — peer to `workstate-schema`, depended on by every sink. Not a package *inside* `workstate-schema` (schema = data contract; engine = behaviour — keep them separable). | ☐ |
| Where does the parser go? | A new standalone `source-speckit` repo — the first `workstate` *producer*, peer to the sinks. | ☐ |
| Does the parser leave **this** repo entirely? | Yes — per HANDOFF §14 ADDENDUM. This repo keeps only the Jira sink + the `workstate`-direct input seam. | ☐ |
| Backport workflow for `spec-kit-linear` | Rewrite onto the shared engine on a branch; keep its public history (no force-revert of `origin`). A bridge commit references the extraction. | ☐ |
| Naming / publish | This repo differentiates its public name from the existing `mbachorik/spec-kit-jira` (27★ prompt-file) and leads with the safety-engine angle (HANDOFF "What to do" §4). Candidate rename: `workstate-jira`. | ☐ |
| Timeline / unblock | **After feature-002 ships** (the interface-settling change) and **after the live dogfood** (real-world proof). Not before 1.0 of the Jira sink. | ☐ |

## Prerequisite already built in (do not regress)

HANDOFF §14 requires the sink to be runnable **directly from `workstate`**, not
only from a `specs/` tree — so the pipeline can start one stage later
(`workstate → jira`, skipping the parser). This is what lets a non-spec-kit
producer (e.g. product-mem) feed the sink, and it's what makes move #2 a clean
lift rather than a rewrite. **Verify this seam is exposed before extraction**; if
feature-002 doesn't already surface it, that feature should (it's cheap when
`workstate` is already the internal contract). Keep Jira concerns out of the
parser and spec-kit concerns out of the sink in the meantime.

## Carry this debt into the extraction

- **`git_helpers::iso_to_epoch` fix-at-source.** It misparses fractional-second
  ISO timestamps on BSD/macOS (e.g. Jira's `…000+0000`). This repo works around
  it *sink-side* (US3 normalizes timestamps before they reach the engine), so
  drift/recency are correct today — but every sink must currently normalize. When
  the engine is extracted, fix it **at the source** in the shared `git_helpers`
  so any producer feeding fractional-second timestamps parses robustly, then drop
  the per-sink normalization. Tracked in `specs/001-core-bridge/review-debt.md`
  ("Engine debt") and `PLAN.md` §11.

## Acceptance (the move is done when)

- One engine source of truth; both sinks depend on it; `# ORIGIN:` headers gone.
- `parser.sh` no longer in this repo; this repo is a pure `workstate→Jira`
  consumer with a `workstate`-direct entrypoint.
- `spec-kit-linear` builds on the shared engine; a bug fixed once is fixed for
  both.
- `iso_to_epoch` fixed at the source; per-sink timestamp normalization removed.
- Both sinks' full test suites green on the shared engine.
