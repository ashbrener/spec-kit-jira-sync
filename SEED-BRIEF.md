# SEED BRIEF — spec-kit-jira-sync

> **Read this top-to-bottom before doing anything.** You are starting cold in
> a fresh repo. This brief is self-contained: it tells you what to build, what
> to copy from where, and the rules. It encodes decisions already made — don't
> re-litigate them. Full backstory lives in
> `~/Code/AI/workstate-schema/PROJECT-BRIEF.md` (the hub) if you need it, but
> you should be able to build from THIS file alone.

---

## 0. What this is, in one sentence

`spec-kit-jira-sync` mirrors a spec-kit project's specs into **Jira** — the exact
twin of the already-shipped `spec-kit-linear`, but targeting Jira's REST API
and consuming the neutral **`workstate`** format internally.

## 1. Why we're building it (and why greenfield, not a refactor)

- `spec-kit-linear` (shipped, v0.2.0, green, at `~/Code/AI/speckit-linear` —
  note: on-disk dir is `speckit-linear`, NO hyphens, even though the
  product/GitHub repo is `spec-kit-linear`) takes spec files → pushes them to
  Linear, safely. Its **reconcile engine** (idempotent drift detection,
  fail-closed writes, git-commit recency comparison — collectively the
  "SC-017 hardening") is the crown jewel.
- We want the SAME capability for Jira. We are building it **greenfield as a
  sibling**, NOT by refactoring spec-kit-linear, because:
  1. It doesn't risk the shipped, working tool.
  2. It delivers Jira (new value), not "same Linear, cleaner insides."
  3. **It is the real TEST of the `workstate` format.** A refactor just
     reshuffles one codebase — it can "pass" while the format is secretly
     Linear-shaped. An independent, from-scratch Jira sink that consumes the
     SAME `workstate` cannot cheat. If two independent sinks both eat
     `workstate` cleanly, the format is PROVEN. **That validation is half the
     point of this repo.**
  4. A clean engine/sink boundary emerges from TWO examples (Linear + Jira),
     not from guessing the seam off one.

## 2. The build approach (do exactly this)

```
spec files (specs/NNN-*/)  →  parser  →  workstate JSON  →  jira-sink  →  Jira REST
                              (reuse)     (the contract)     (write fresh)
```

- **COPY UNCHANGED from `~/Code/AI/speckit-linear/src/` (do NOT rewrite — you
  would lose the hardening):**
  - `git_helpers.sh` (581 lines) — git recency/drift helpers, pure infra, 0
    Linear coupling.
  - `summary.sh` (299) — structured run summary, pure infra.
  - The **drift/reconcile ENGINE portion** of `reconcile.sh` (the
    `reconcile::compute_drift`, `_drift_disposition`, `_fetch_drift_issue_json`
    pattern, fail-closed logic, recency gate). NOTE: `reconcile.sh` is 3579
    lines and MIXES the engine with the Linear writer — you must separate:
    keep the engine, replace the writer.
  - `config.sh` (560) — config loader; keep the shape, swap Linear-specific
    fields for Jira ones.
- **REUSE (spec-kit reader — already ~0 Linear coupling):**
  - `parser.sh` (432) — reads spec.md/plan.md/tasks.md, infers lifecycle
    phase. This is your `source-speckit`. Have it emit **`workstate` JSON**
    (the internal contract) rather than feeding Linear directly.
- **WRITE FRESH (everything Linear-specific):**
  - The **jira-sink**: consumes `workstate`, talks Jira REST. Replaces
    `graphql.sh` (457, Linear GraphQL) + the writer half of `reconcile.sh`.
  - Jira equivalents of `seed.sh` (1088, creates Linear workflow states +
    labels → Jira: project/issue-type/status mapping), `pull.sh` (866, read
    view), `status.sh` (888), and the Linear-discovery parts of `install.sh`
    (3489).

## 3. Jira ≠ Linear — the shape mismatch to plan for

- **Linear = one GraphQL endpoint. Jira = many REST endpoints**
  (`/rest/api/3/issue`, `/issue/{}/transitions`, `/issueLink`, `/search` via
  JQL). The engine's read/write seam was GraphQL-shaped; the jira-sink wraps
  REST behind the same internal interface the engine expects.
- **Lifecycle:** Linear has free workflow states; Jira has a configurable
  **workflow scheme** + **transitions** (you can't just set a status, you
  POST a transition). Map `workstate.state` → Jira transition.
- **Hierarchy:** Linear issue→sub-issue ≈ Jira epic→story→subtask. `workstate`
  `children[]` → Jira subtasks (or epic links).
- **Auth:** Jira Cloud = email + API token (Basic auth) or OAuth; NOT a single
  bearer token like Linear. Keep the token in a gitignored `.env`, never
  committed (mirror spec-kit-linear's secret discipline).

## 4. The `workstate` contract (your internal format)

Schema + fixtures live at `~/Code/AI/workstate-schema/`. Read
`schema/workstate.schema.json` and `fixtures/spec-kit.workstate.json`. The
shape (floor): `item { id, title, kind, state, body, coverage, children[],
notes[], links[], labels[], item_source, extensions }`. Your parser PRODUCES
this; your jira-sink CONSUMES it. **Do not invent a different internal shape**
— eating `workstate` cleanly is the validation this repo exists to provide.
If `workstate` fights you, that is a SIGNAL (record it; the format may need a
floor change) — don't silently work around it.

## 5. The debt to repay later (don't forget)

You are COPYING the engine, so it now lives in 2 places (spec-kit-linear +
here). That's deliberate, temporary, LABELED debt. The committed plan: once
Jira works, EXTRACT the shared engine from BOTH repos into one place and
backport spec-kit-linear onto it. Do NOT try to pre-extract now — build Jira
first, let the real seam reveal itself, unify after. Mark copied files with a
header comment noting their origin so the later extraction is mechanical.

## 6. product-mem is OUT OF SCOPE

Ignore product-mem entirely. spec-kit→Jira needs it nowhere. (It's a friend's
neighbouring project; door left open via the neutral schema, but build nothing
for it.)

## 7. Operational rules (hard-won; obey)

- **ONE mutating shell/tool call per message.** Batching git/gh/edits → the
  harness cancels the whole batch if any one errors, and large parallel output
  corrupts. Serialize writes; read result before next step.
- **Worktree-isolate every code-writing subagent** (`isolation: worktree`).
- **Tests are the contract** — green/red is the gate, not an agent's
  self-report. Port spec-kit-linear's bats suite (11 unit files + integration)
  as the starting safety net; adapt fixtures for Jira.
- **Cross-model review (codex/gpt-5.5 via wingman) at phase boundaries** — it
  catches real regressions, including in your own "fixes."
- **Run the EXACT CI command locally before pushing.** spec-kit-linear's CI:
  shellcheck (`--severity=style`), yamllint (`-d relaxed`), markdownlint-cli2
  (auto-discovers `.markdownlint-cli2.jsonc`), bats (macos + ubuntu × bash
  4.4/5.2). Copy that CI workflow as the starting point.
- **Push mechanic:** SSH has no key in this env. Use HTTPS-via-gh:
  `git -c credential.helper='!gh auth git-credential' push https://github.com/<acct>/spec-kit-jira-sync.git <branch>`
- **NO AI-attribution / Co-Authored-By trailers in commit messages.**
- Real secrets (Jira token) live ONLY in gitignored `.env`. Never commit.
  Use placeholder identifiers in tests/fixtures (there's a privacy-guard test
  pattern in spec-kit-linear worth copying: `tests/unit/no-real-identifiers.bats`).

## 8. First steps when you start this session

1. `git init` here (if not already). Copy `.github/workflows/ci.yml`,
   `.markdownlint-cli2.jsonc`, `.gitignore` from `~/Code/AI/speckit-linear`.
2. Copy the engine files (§2 "copy unchanged") with origin-noting headers.
3. Stand up `parser.sh` → emit `workstate` JSON; validate against
   `~/Code/AI/workstate-schema` fixtures.
4. Write the jira-sink against a MOCKED Jira REST (mirror spec-kit-linear's
   curl-shim test pattern) before touching a real instance.
5. Only then wire a real Jira (token in `.env`), behind `--dry-run` first.

The north star: **a from-scratch Jira sink eats `workstate` cleanly → Jira
sync works → `workstate` is proven → engine extraction can follow.**
