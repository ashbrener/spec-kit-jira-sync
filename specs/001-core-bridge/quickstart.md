# Quickstart — Core Bridge

How to run and test the reconcile bridge locally. Real secrets live only in the
gitignored `.env`; this file uses placeholders.

## 1. Prerequisites

- `bash` 4.4+, `curl`, `jq`, `git`, `gh`
- Dev/CI: `bats`, `shellcheck`, `yamllint`, `markdownlint-cli2`. For workstate
  validation, [`uv`](https://docs.astral.sh/uv/) (preferred — PEP 668-safe, no
  global install) or a `python3` able to build a throwaway venv. Never bare `pip`.

## 2. Credentials (gitignored `.env`)

```bash
JIRA_BASE_URL=https://<your-site>.atlassian.net
JIRA_EMAIL=<you@example.com>
JIRA_API_TOKEN=<atlassian-api-token>   # never commit; .env is gitignored
```

A resolved binding (`.specify/extensions/jira/jira-config.yml`) must exist —
produced by the seed/install feature (separate). This feature consumes it.

## 3. Dry run first (no writes)

```bash
src/reconcile.sh --all --dry-run
```

Reports every intended create/update/transition/comment without touching Jira
(FR-016). Inspect the summary, then drop `--dry-run` for a live run.

## 4. Live reconcile

```bash
src/reconcile.sh --all            # all specs
src/reconcile.sh --spec 001       # one spec
src/reconcile.sh --all --on-drift=abort   # never overwrite a drifted issue
```

Exit codes: 0 ok · 1 warnings (incl. drift) · 3 a spec failed closed · 2 config
error.

## 5. Validate workstate (contract gate)

```bash
# parser emits workstate; validate against the published schema
src/reconcile.sh --spec 001 --dry-run --emit-workstate > /tmp/ws.json

# The schema repo ships a one-command, zero-setup validator that auto-selects uv
# (preferred) else a throwaway venv — never bare pip:
~/Code/AI/workstate-schema/validate.sh

# Equivalent ad-hoc check of a single doc (uv provisions jsonschema ephemerally):
uv run --with jsonschema python -c '
import json, sys, jsonschema
schema = json.load(open(sys.argv[1])); doc = json.load(open(sys.argv[2]))
jsonschema.Draft202012Validator(schema).validate(doc)
' ~/Code/AI/workstate-schema/schema/workstate.schema.json /tmp/ws.json
```

## 6. Run the tests (the real gate)

```bash
bats --recursive tests/unit                  # offline, curl-shim mocked
RUN_INTEGRATION_TESTS=1 bats tests/integration  # needs a real binding + .env
```

## 7. Before pushing — run the exact CI locally

```bash
shellcheck --shell=bash --severity=style src/*.sh
yamllint -d relaxed .github/workflows/ci.yml
npx --yes markdownlint-cli2 "specs/**/*.md" "*.md"
bats --recursive tests/unit
```

Privacy guard (`tests/unit/no-real-identifiers.bats`) must stay green — no real
Jira coordinates in any tracked file.
