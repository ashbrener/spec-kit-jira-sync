# Contributing to spec-kit-jira

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
