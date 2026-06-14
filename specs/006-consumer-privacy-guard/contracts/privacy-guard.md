# Contract: Consumer-Side Privacy Guard

The seam between the **neutral scan mechanism** (`src/privacy_guard.sh`), the
**Jira shape/known-value providers** (`src/jira_sink.sh`), and the **neutral
orchestrator** (`reconcile::privacy_gate`). Preserves the engine/sink boundary
(FR-012, Architectural Constraints): the mechanism names no vendor; only the
providers are Atlassian-aware.

## 1. Neutral mechanism — `src/privacy_guard.sh`

### `privacy_guard::assert_git`

- **Input**: none (operates on cwd = consumer repo root).
- **Behavior**: `git rev-parse --is-inside-work-tree` succeeds ⇒ rc 0; else rc 1.
- **Contract (FR-010)**: caller treats rc≠0 as a hard fail (cannot enumerate ⇒
  cannot prove safe ⇒ fail closed).

### `privacy_guard::scan SHAPES_FN KNOWN_FN IGNORE_FN`

- **Inputs**: three callback names that, when called, print one item per line.
  Every pattern/known/ignore line carries a leading **severity** field
  (`block` | `warn`):
  - `SHAPES_FN` → `severity<TAB>class<TAB>extended-regex` (the shape pass).
  - `KNOWN_FN` → `severity<TAB>class<TAB>literal` (the known-value pass; may be
    empty; known values are always `block`).
  - `IGNORE_FN` → paths that must be gitignored-and-untracked (always `block`).
- **Behavior**:
  1. Enumerate `git ls-files -z`.
  2. **Shape pass**: for each `severity<TAB>class<TAB>regex`, run
     `… | xargs -0 grep -lIiE -- "$regex"`; every returned path ⇒ a finding
     `{severity, class, file}`. (`-l` = files only; matched bytes never captured.)
  3. **Known-value pass**: for each `severity<TAB>class<TAB>literal`, run
     `… | xargs -0 grep -lIFe -- "$literal"`; same finding shape (severity `block`).
  4. **Ignore assertion**: for each path, a `block` finding (`class=tracked-config`)
     if `git ls-files --error-unmatch "$path"` rc 0 (tracked) OR
     (`[ -e "$path" ]` AND `git check-ignore -q "$path"` rc≠0) (present, unignored).
- **Output**: prints `severity<TAB>class<TAB>file` per finding to a
  caller-captured stream; **rc 1 iff any `block` finding**, else **rc 0** (a run
  with only `warn` findings returns rc 0 — the caller surfaces them without
  failing closed).
- **MUST**: read-only (FR-011); never print a matched literal (FR-007); skip
  binaries via `-I` (FR-008); `--`-terminate every grep.
- **MUST NOT**: contain any Jira/Atlassian token (vendor-neutral — extractable).

## 2. Jira providers — `src/jira_sink.sh`

### `jira_sink::privacy_shapes`

Prints the five `severity<TAB>class<TAB>regex` lines, **tiered** (FR-002):
- `block<TAB>api-token<TAB>…` (the `ATATT…` prefix) and
  `block<TAB>site<TAB>…` (`<name>.atlassian.net`) — vendor-unique, fail-closed.
- `warn<TAB>email<TAB>…`, `warn<TAB>cloudId-uuid<TAB>…`,
  `warn<TAB>accountId<TAB>…` — broad, advisory only.
Each regex is built fragmented across concatenation so this file never
self-matches (FR-009).

### `jira_sink::privacy_known_values`

Prints `block<TAB>class<TAB>literal` for each present operator coordinate
(known values are always BLOCK tier — exact, zero-FP): `email`→`$JIRA_EMAIL`,
`site`→`${JIRA_BASE_URL#*://}` (host), `api-token`→`$JIRA_API_TOKEN`, and
`accountId`→each id parsed from `jira-authors.local.yml`. **Absent value ⇒ no
line** (the pass degrades to a no-op; the shape pass still covers it). Literals
are passed as grep args only — never written, never echoed.

### `jira_sink::privacy_ignore_targets`

Prints the consumer paths that must be ignored: the resolved
`jira-config.yml` path (the active `--config` value), `.env`, and
`jira-authors.local.yml`.

## 3. Neutral orchestrator — `reconcile::privacy_gate` (`src/reconcile.sh`)

- **Call site**: `reconcile::main`, immediately after `reconcile::load_config`,
  before the `remode` / `run_workstate` / per-spec write fork.
- **Behavior**:
  1. `privacy_guard::assert_git` — rc≠0 ⇒ `summary::add error "not a git repo —
     cannot verify the tracked tree; refusing to write"` + `promote_exit 4` +
     return 1.
  2. `findings=$(privacy_guard::scan jira_sink::privacy_shapes \
     jira_sink::privacy_known_values jira_sink::privacy_ignore_targets)` — capture
     rc (rc 1 iff any `block` finding).
  3. For each `warn<TAB>class<TAB>file` finding ⇒ `summary::add warn "<file>:
     possible <class> in a tracked file (advisory — verify it is not a real
     coordinate)"`. These never fail the run (FR-003 WARN tier, SC-007).
  4. rc≠0 (a `block` finding exists) ⇒ for each `block<TAB>class<TAB>file`,
     `summary::add error "<file>: forbidden <class> in a tracked file — move real
     values to the gitignored .env / jira-config.yml, replace the tracked
     occurrence with a placeholder, and scrub history if already committed
     (rotate the token if it was a credential)"` + `promote_exit 4` + return 1.
  5. rc 0 (no `block` finding) ⇒ return 0 — the reconcile proceeds. A clean tree
     adds no rows (SC-002); a tree with only broad shapes adds WARN rows but does
     not fail closed (SC-007).
- **Runs in `--dry-run` too** (R9): the verdict is computed and fails closed
  regardless of write mode; a clean tree is a silent pass in both modes.
- **MUST** stay vendor-neutral — it is added to the
  `engine_vendor_neutral.bats` audited-function list and references the sink
  callbacks by name only (no Atlassian token in its body).

## 4. Exit-code contract addition

| Code | Meaning |
|---|---|
| **4** | **consumer-tree privacy leak — fail-closed, zero Jira writes** (NEW) |

`reconcile::promote_exit 4` is **terminal** (never demoted), like `2`. Added to
the `reconcile.sh` header table, `usage()`, and the cli exit-code contract.

## 5. Behavioral assertions (testable)

| ID | Assertion |
|---|---|
| C-1 | tracked file with a BLOCK shape (`api-token` prefix / `.atlassian.net` site) ⇒ exit 4, file+class named, zero writes (curl-shim sees no mutating call) |
| C-2 | tracked file matching the operator's *exact* `$JIRA_EMAIL`/token/site/accountId ⇒ exit 4 (known-value pass, BLOCK) |
| C-3 | resolved `jira-config.yml` OR `.env` tracked/unignored ⇒ exit 4, path named |
| C-4 | placeholder-clean tree + ignored config/.env ⇒ pass, no new summary rows, reconcile proceeds (SC-002) |
| C-5 | a `block` failure report contains the class + file but NOT the matched bytes |
| C-6 | non-git target ⇒ exit 4 |
| C-7 | `reconcile::privacy_gate` passes the 003 neutrality audit; the shapes live only in `jira_sink::privacy_*` |
| C-8 | the gate fires in `--dry-run` (a leaking BLOCK tree fails the status preview) |
| C-9 | guard is read-only — the consumer tree is byte-identical after a run (FR-011) |
| C-10 | tracked file with ONLY a broad shape (generic email / UUID / 24-hex) ⇒ a non-blocking WARN row, rc 0, reconcile proceeds (SC-007) — no exit 4 |
| C-11 | **dogfood self-scan**: `privacy_guard::scan` driven by the real `jira_sink::privacy_*` over **this** repo's own tree yields zero `block` findings (the source never self-matches; reserved `example.com`/fixtures are WARN-only) — FR-009 + the bridge-is-its-own-consumer edge case |
