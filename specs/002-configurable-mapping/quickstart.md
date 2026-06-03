# Quickstart — Configurable Mapping

How an operator drives the configurable artifact mapping. Mapping, detection, and
validation live entirely in the Jira sink + config; the engine stays
vendor-neutral. Real coordinates live only in the gitignored
`.specify/extensions/jira/jira-config.yml`; this file uses placeholders (`PROJ`
for the project key).

Every mode below preserves the constitutional differentiator: idempotency
(zero-churn re-run), drift-awareness on the spec→Story unit, and fail-closed reads.

## 1. Zero-config (the safe upgrade)

Do nothing. With no `mapping:` block, the alias layer synthesizes today's shipped
default — `repo→Epic`, `spec→Story`, `phase→Subtask`, `task→in-body checklist` —
byte-for-byte. No file rewrite, no version bump.

```bash
src/reconcile.sh --all --dry-run    # confirm: same creates/updates as before
src/reconcile.sh --all
```

A no-config upgrade changes nothing; a re-run is zero churn.

## 2. Configure a custom mapping

Add a `mapping:` block under `jira:` in
`.specify/extensions/jira/jira-config.yml`. Each level declares its `artifact`
and its `relationship_to_parent`. Unspecified levels inherit the synthesized
default (per-level inheritance — not all-or-nothing).

**3-level** (`spec→Epic`, `phase→Story`, `task→Task` as individual issues):

```yaml
jira:
  project_key: "PROJ"
  mapping:
    levels:
      spec:
        artifact: "Epic"
        relationship_to_parent: "none"
      phase:
        artifact: "Story"
        relationship_to_parent: "Epic-link"   # or "parent" on team-managed
      task:
        artifact: "Task"
        relationship_to_parent: "parent"
```

**2-level** (phases and tasks collapse into an in-body checklist — no child
issues):

```yaml
jira:
  project_key: "PROJ"
  mapping:
    levels:
      spec:
        artifact: "Story"
        relationship_to_parent: "parent"
      phase:
        artifact: "checklist"
        relationship_to_parent: "checklist"
      task:
        artifact: "checklist"
        relationship_to_parent: "checklist"
```

In 2-level mode each checklist item is keyed by its workstate task id and only the
checklist sub-tree is byte-compared, so a re-run against unchanged tasks performs
zero writes and an unrelated description edit never forces a rewrite.

Hierarchy links are restricted to `parent`, `Epic-link`, `none`, and `checklist`.
A dependency-style link (`Blocks` / `Relates` / `Implements`) used as a hierarchy
link, or an `Epic-link` declared between two non-Epic levels, is rejected at
config-load — before any write.

## 3. Available-type validation

Before any write, the sink probes the target project's available issue types and
validates every configured `artifact` against that set. A configured type the
project lacks — e.g. `Story` on a Kanban template that ships only Task/Epic/Subtask
— hard-errors at config-load (exit `2`) and writes nothing.

The only escape is an explicit per-level `on_absent` fallback:

```yaml
jira:
  mapping:
    levels:
      spec:
        artifact: "Story"
        relationship_to_parent: "parent"
        on_absent: "Task"        # Story unavailable here -> project to Task
```

## 4. Status rollup (optional, off by default)

Off by default, only the spec-level status is set — exactly today's behavior. Turn
it on to roll completion up to issue status:

```yaml
jira:
  mapping:
    status_rollup:
      enabled: true
```

When on: a phase whose tasks are all complete transitions its issue to a done
status, and a repo whose specs are all complete transitions its top issue to done.
Target statuses reuse the existing `phase_status` / `transitions` config. A
transition fires only when the computed completion state actually changed (forward
and backward), so a re-run against unchanged completion fires nothing.

## 5. Initiative super-level (optional, off by default)

Off by default, no narrative level is created. Turn it on to add a narrative level
above the Epic:

```yaml
jira:
  mapping:
    initiative:
      enabled: true
      artifact: "Initiative"     # Jira Premium / Advanced Roadmaps primitive
      on_absent: "degrade"       # fold narrative onto the Epic + repo label
      source: "spec_input"       # spec.md "Input:" line; NEVER inferred
```

Where the instance supports Initiative, one is created above the Epic. Where it
does not, the run degrades gracefully — the narrative folds onto the Epic behind a
stable marker and repo grouping is carried by the existing repo label — never a
hard failure. The narrative is populated only from the explicit `source`, never
inferred. The `spec→Story` unit remains the drift anchor; the super-level is not a
new drift surface.

## 6. workstate-direct input

Run the sink straight from a workstate document, skipping the parser and any
`specs/` tree. The document is validated against the pinned workstate schema on
entry; a malformed or unsupported document is rejected fail-closed (no partial
write).

```bash
src/reconcile.sh --workstate /tmp/ws.json     # from a file
cat /tmp/ws.json | src/reconcile.sh --workstate -   # from stdin
```

The result matches the `specs/`-tree projection of the same content. In this mode
the `spec_input` narrative source is gracefully absent (the Initiative narrative
is simply unavailable, not an error).

## 7. Before pushing — run the exact CI locally

```bash
shellcheck --shell=bash --severity=style src/*.sh
yamllint -d relaxed .github/workflows/ci.yml
npx --yes markdownlint-cli2 "specs/**/*.md" "*.md"
bats --recursive tests/unit
```

Privacy guard (`tests/unit/no-real-identifiers.bats`) must stay green — no real
Jira coordinates in any tracked file.
