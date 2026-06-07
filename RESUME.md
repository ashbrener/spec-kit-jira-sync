# RESUME — spec-kit-jira-sync handoff

> Working handoff for resuming after a context compaction. The repo is the real
> source of truth (`specs/002-configurable-mapping/tasks.md` ticks + git history);
> this file just makes pickup crisp. Safe to `git rm` before the eventual
> `002 → main` PR.

## Where we are

- **Repo:** `/Users/ashbrener/Code/AI/spec-kit-jira` (local dir keeps this name).
  Project / GitHub repo is **`spec-kit-jira-sync`**, remote
  `github.com/ashbrener/spec-kit-jira-sync.git`, default branch **`main`**.
- **Branches:** `main` = trunk (001 core bridge via PR #1 *squash*-merge + hotfix
  PR #2). **`002-configurable-mapping`** = current, clean, pushed, HEAD `6c95017`.
  (Stale remote `001-core-bridge` branch intentionally left undeleted.)
- **001-core-bridge:** ✅ complete, merged to `main`.
- **002-configurable-mapping (configurable artifact mapping):**
  `specify`/`clarify`/`plan`/`tasks`/`analyze` ✅. **`implement` ~40%** — Phases
  2–4 done (Foundational, US1 default-equivalence, US2 configurable-mapping).
  **271 tests green.** `tasks.md`: **23 ticked, 33 remaining** = T001–T002 (setup)
  + T026–T056 (**US3 2-level → US4 status-rollup → US5 workstate-direct → US6
  Initiative → Polish**). **Next: T026 (US3).**

## How to finish (the agreed methodology)

Finish `implement` **by-the-book via the `/speckit-implement` command** — NOT custom
agents/workflows. (Earlier drift to agents under ultracode was course-corrected;
follow the spec-kit design used successfully all along.) `/speckit-implement`
reads `tasks.md`, runs the remaining unticked tasks in dependency order TDD-first,
and ticks them.

**Add-on (not a replacement):** after each idempotency-critical phase
(**US3, US4, US5**) do ONE light adversarial review for the Phase-4-class defects:
body/label-wipe on update, unconditional parent writes (no read-before-write),
ignored `on_absent` substitution at write time, inert `|| true` test guards, and
empty-body-only zero-churn coverage. Phase 4's review caught **3 HIGH bugs the
green gate missed** — the review earns its keep on these phases.

## Gate (must be green before any commit/push)

```bash
bats --recursive tests/unit tests/integration
shellcheck --severity=style src/*.sh
yamllint -d relaxed .github/workflows/ci.yml
npx markdownlint-cli2 "specs/**/*.md" "*.md"
bats tests/unit/no-real-identifiers.bats   # privacy guard
```

## Non-negotiables

- **Privacy IX:** no real Jira coordinates/PII in any tracked file. Real values
  live ONLY in gitignored `.env`, `.specify/extensions/jira/jira-config.yml`,
  `tests/.private-deny`.
- **Vendor-neutral engine:** all mapping/Jira logic in `config.sh` + `jira_sink.sh`;
  the engine half of `reconcile.sh` stays Jira-free (it only orchestrates).
- **Idempotent · drift-aware · fail-closed** in *every* mapping mode.
- **Default mapping = frozen regression anchor** — a no-config run is byte-for-byte
  identical to 001 (the 227-style baseline tests stay green untouched).
- **No AI-attribution trailers in commit messages** (PR bodies may keep the
  default footer).

## Useful context

- **Live dogfood:** Kanban project **`SKJS`** on the Jira instance in `.env`.
  Slash commands `/speckit-jira-push` (reconcile write) + `/speckit-jira-status`
  (read-only `--dry-run`). The merged-not-Done fix is in `main`, so a push
  transitions 001's issue to Done.
- **Git gotcha:** PR #1 was *squash*-merged, so rebasing 002 onto main needs
  `git rebase --onto main <002-branch-point> 002` (a plain rebase replays all of
  001). 002 is already cleanly rebased on current `main`.
- **Spec-kit setup:** this repo has the seeded `.specify/` artifacts + the global
  `/speckit-*` skills — NOT the `specify` CLI integration (so `specify integration`
  reports "not installed"; irrelevant to the skill-driven flow). Do **not** run
  `specify init` here — it would overwrite the seeded artifacts.

## When 002 implement is done

Final gate + a holistic review, then open the **`002 → main`** PR.

## First action on resume

```bash
cd /Users/ashbrener/Code/AI/spec-kit-jira
git status && git log --oneline -1
grep -nE '^- \[ \] T' specs/002-configurable-mapping/tasks.md | head   # remaining work
```

Then run `/speckit-implement`.
