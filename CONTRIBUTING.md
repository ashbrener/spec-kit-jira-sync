# Contributing to spec-kit-jira-sync

A Bash bridge that mirrors a spec-kit project's specs into Jira, consuming the
neutral `workstate` format. Please read `.specify/memory/constitution.md` (the
project principles) before substantial changes.

## Developer setup

Runtime tools: `bash` 4.4+, `curl`, `jq`, `git`, `gh`.
Dev/test tools: `bats`, `shellcheck`, `yamllint`, `markdownlint-cli2`. For
`workstate` schema validation, [`uv`](https://docs.astral.sh/uv/) (preferred —
PEP 668-safe, no global install) or a `python3` able to build a throwaway venv;
never bare `pip`. The schema gate provisions `jsonschema` ephemerally via `uv`.

Credentials for live runs go ONLY in a gitignored `.env` (never committed):

```bash
JIRA_BASE_URL=https://<your-site>.atlassian.net
JIRA_EMAIL=<you@example.com>
JIRA_API_TOKEN=<atlassian-api-token>
```

## Running the tests (the gate)

```bash
bats --recursive tests/unit          # offline — Jira REST is mocked by a curl-shim
RUN_INTEGRATION_TESTS=1 bats tests/integration   # needs a real binding + .env
```

Tests are the contract: green/red is the gate, not a self-report. The unit suite
is fully offline (no live Jira), via `tests/helpers/jira-shim.bash`.

## Before you push — run the exact CI locally

CI (`.github/workflows/ci.yml`) runs: shellcheck (`--severity=style`), yamllint
(`-d relaxed`), markdownlint-cli2, and the bats matrix. Mirror it locally:

```bash
shellcheck --shell=bash --severity=style src/*.sh
yamllint -d relaxed .github/workflows/ci.yml
npx --yes markdownlint-cli2 "specs/**/*.md" "*.md"
bats --recursive tests/unit
```

CI + these tests are the **only mandatory quality gate**.

## Privacy — no real identifiers in tracked files

This is a public repo. NO real Jira coordinate, workspace/company/project name,
person name, email, site, account id, UUID, or API token may appear in any
tracked file. Real values live only in gitignored `.env`,
`.specify/extensions/jira/jira-config.yml`, and `tests/.private-deny`. The
privacy guard (`tests/unit/no-real-identifiers.bats`) enforces this in CI; copy
`tests/.private-deny.example` to `tests/.private-deny` (gitignored) and fill in
your real coordinates so it catches leaks locally before you push.

### The consumer-side privacy guard (design)

A second guard protects the repos operators install the bridge into. Its
mechanism is split to preserve the engine/sink seam:

- **`src/privacy_guard.sh`** — the **vendor-neutral** scan mechanism:
  `privacy_guard::assert_git` (fail closed if the target is not a git work-tree)
  and `privacy_guard::scan SHAPES_FN KNOWN_FN IGNORE_FN`. The scan enumerates
  `git ls-files -z`, runs the caller's shape regexes (`grep -lIiE`) and
  known-value literals (`grep -lIF`) over the tracked tree, asserts the
  ignore-target paths are untracked + gitignored, and returns rc 1 **iff** any
  `block` finding exists. It is always `grep -l` (never `-n`, so the matched
  bytes are never captured — no re-leak), `-I` (binaries skipped), `--`
  terminated, and read-only. It carries **no** Jira vocabulary (it is in the
  `engine_vendor_neutral.bats` audited list and is extractable with the engine).
- **`src/jira_sink.sh`** — the only Atlassian-aware pieces:
  `jira_sink::privacy_shapes` (the five tiered shape regexes — BLOCK
  `api-token`/`site`, WARN `email`/`cloudId-uuid`/`accountId`; every literal
  fragmented across concatenation so the source never self-matches, FR-009),
  `jira_sink::privacy_known_values` (the operator's exact `JIRA_*` + authors-map
  literals, always BLOCK; absent ⇒ no line), and
  `jira_sink::privacy_ignore_targets` (the must-be-gitignored paths).
- **`reconcile::privacy_gate`** — the neutral orchestrator, wired into
  `reconcile::main` right after `load_config` and before the write fork. On a
  BLOCK finding (or a non-git target) it adds `summary::add error` rows + exits
  **4**; on WARN it adds advisory rows and proceeds.

When adding a shape: put the regex in `jira_sink::privacy_shapes`, **fragment**
any literal that could self-match, choose the tier deliberately (BLOCK only for
vendor-unique / exact signals), and prove the source stays clean via
`tests/unit/privacy_dogfood.bats` (zero block findings over this repo's own
tree). The neutral mechanism must never gain vendor vocabulary
(`tests/unit/engine_vendor_neutral.bats` enforces this).

**gitleaks / trufflehog are recommended, not bundled.** They are a complementary
broader net for *generic* secrets, **never a dependency** of the guard (the core
is dep-free `git` + `grep`), invoked only best-effort *if already on `PATH`*,
with trufflehog **live-verify off** (it would call Jira's API). The guard's
known-value pass is the precise guarantee no generic scanner can match.

## Optional: cross-model review (wingman)

This repo is **wingman-ready but wingman is optional** — a per-developer aid, not
a mandatory gate (CI + tests above are the gate). Wingman runs a *different* AI
model (codex/GPT) as a reviewer of your branch on push and saves findings to
`.reviews/`, catching blind spots the authoring model misses.

Git hooks are not cloned, so you opt in yourself:

```bash
npx skills add ashbrener/wingman   # installs the review skills
/review-setup                      # installs the pre-push hook + checks for the codex CLI
```

The repo already ships the bits wingman *reads* — `.wingman-exemptions.yaml.sample`
(copy to `.wingman-exemptions.yaml` to activate) and `.claude/rules/review-patterns.md`
(accumulated review patterns) — so once installed it works against this project
with no extra config. If you don't install it, nothing changes for you.

## Commit conventions

- Conventional-commit style subjects (`feat:`, `fix:`, `chore:`, `test:`, …).
- **No AI-attribution trailers** (`Co-Authored-By`, "Generated with …") in commit
  messages.
- Branch per feature (`NNN-short-name`); open a PR into `main`.

## Releasing (and the community catalog)

Cutting a release is two decoupled things:

1. **Tag + GitHub release** in this repo (`vX.Y.Z`). GitHub auto-publishes a
   source tarball at the tag (`…/archive/refs/tags/vX.Y.Z.zip`) — the install
   artifact.
2. **The community catalog** (`github/spec-kit` → `extensions/catalog.community.json`)
   is a static, version-pinned entry. It does **not** watch this repo. As of
   mid-2026 the spec-kit maintainers intake catalog adds/bumps through a **GitHub
   issue** using their [Extension Submission](https://github.com/github/spec-kit/issues/new?template=extension_submission.yml)
   template — **not** a hand-edited PR to the catalog JSON (direct-JSON PRs are now
   closed-with-redirect). A maintainer (or their tooling) applies the entry.

Step 2 is automated for you:

- **`scripts/publish-catalog.sh vX.Y.Z`** (no secret). Run it locally after
  `gh release create`. It verifies the tag's archive is live (HTTP 200), reads the
  metadata from `extension.yml`, and **opens the Extension Submission issue**
  upstream — pre-filled — via your existing `gh` login. **No PAT, no fork, no repo
  secret.**

It is **repo-agnostic** — to reuse in a sibling extension, copy the file and edit
the four values at the top (`CATALOG_ID`, `CATALOG_NAME`, `EXT_REPO`, `TAGS`); the
copy checklist is in the file's header. A maintainer still applies the entry.

> The older `.github/workflows/catalog-publish.yml` (a PAT-based CI variant that
> opened a *JSON PR*) is **deprecated** by the issue-template process and should
> not be used for new submissions.
