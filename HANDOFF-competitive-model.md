# HANDOFF — competitive dig + model upgrades to fold into spec-kit-jira

> Date: 2026-06-01. Source: a competitive investigation done in the
> spec-kit-linear design session. This is an ACTIONABLE handoff — it asks you
> to make specific model/config changes to this repo. Read it, then see
> "What to do" at the bottom. Decisions here are recommendations, not orders —
> sanity-check them against the current build before applying.

---

## TL;DR

We searched the Linear/Jira spec-sync space. **You have NOT reinvented the
wheel** — no serious, safe, tested sync engine exists out there. BUT the one
direct competitor (`mbachorik/spec-kit-jira`, 27★) has a **more mature domain
model** than this repo currently does, in 3 specific config dimensions. **Steal
those 3 things and fold them onto our (superior) engine.** Net: we end up
strictly dominating — their flexible model + our safe engine.

---

## The competitive landscape (why this matters)

| Tool | Stars | State | What it actually is |
|---|---|---|---|
| `schpet/linear-cli` | 746, active | a CLI for humans/agents (list/create issues). NOT sync, NOT specs. Adjacent. |
| `kovetskiy/mark` | 1470, active | markdown→Confluence. Different target. |
| **`mbachorik/spec-kit-jira`** | **27, quiet ~2mo** | **our direct twin. 3 markdown command files + config + README. NO src/, NO tests, NO engine.** It's a PROMPT that tells an AI agent to call a Jira MCP server. "Status sync" = agent reads a checkbox and POSTs — no idempotency, no drift, no fail-closed. |
| `Tr3ffel/linear-md` | 4, dead 16mo | tiny bidirectional md↔Linear |
| `md-linear-sync` (npm) | 68 downloads/MONTH, dead 1yr | md↔Linear |
| `zales/GitLab2Jira` | 3, one-day | migration script |

**Read:** demand is real (27★ for a prompt file in ~4 months) but UNMET at our
quality level. Every serious-sync attempt died (sustainability warning — which
is exactly why our tracker-agnostic engine, fix-once-all-sinks-benefit, is the
right bet). Our spec-kit-jira (4.8k LOC, 123 tests, drift-aware engine,
workstate layer) is in a different category of robustness from anything shipping.

**Our defensible positioning (they cannot make this claim):**
> "Unlike prompt extensions that ask an agent to POST to Jira, this is a real
> sync engine — idempotent, drift-aware, fail-closed, never corrupts your board."

---

## The 3 model upgrades to STEAL (this is the actionable part)

Their **execution** is shallow, but their **domain model** is more mature than
ours in these ways. All three belong in our `jira-config.yml` + the
workstate→Jira mapping layer (this is exactly the per-sink mapping that
workstate was meant to enable — they've essentially designed our config file
for us):

### 1. Configurable artifact mapping (THE big one — do not skip)
Do NOT hardcode spec→Epic, phase→Story, task→sub-issue. Real Jira instances
vary enormously (Epic Link vs native parent vs Initiative→Epic→Story). Expose:

```yaml
mapping:
  spec_artifact:  "Epic"     # issue type for the spec
  phase_artifact: "Story"    # issue type for a phase
  task_artifact:  "Task"     # issue type for a task; "" or "none" → collapse (see #2)
  relationships:
    spec_phase:  "Epic Link" # how a phase links to its spec
    phase_task:  "Parent"    # how a task links to its phase
    spec_task:   "Epic Link" # direct task→spec link when 2-level
```
Relationship options to support: `Parent`, `Epic Link`, `Relates`, `Blocks`,
`Implements`, `is child of`, `none`.

### 2. 2-level mode (collapse tasks into a checklist)
When `task_artifact` is `""`/`"none"`: do NOT create individual task issues.
Instead embed the tasks as a **checklist in the Phase/Story description**. Many
teams don't want 40 sub-task issues cluttering the board. Our `workstate`
`children[]` already carries the structure; this is a render-mode lever:
"children → sub-issues" vs "children → checklist in parent body (ADF)".

### 3. Config back-compat migration
They map old config keys → new (e.g. `hierarchy.epic_type` →
`mapping.spec_artifact`). We'll rename our config too — build in a small
migration/alias path now so we don't break early users later.

---

## The discipline (DON'T copy them blindly)

Adopt the **configurability**, not raw exposure:
- Ship **sane defaults** (Epic→Story→Task; `Epic Link`/native parent) so the
  zero-config path is correct.
- **Validate** the chosen relationship types — arbitrary `Blocks`/`Implements`
  wiring can produce semantically nonsensical Jira graphs. Reject/ warn on
  combos that don't make sense rather than passing them through.
- Keep our **idempotency + drift** guarantees intact across BOTH modes
  (2-level checklist mode must still be idempotent — re-running must not
  duplicate the checklist or the story).

---

## What to do

1. Read this + check it against the current state of `jira-config.yml` and the
   jira_sink mapping code — some of this may already be partially present.
2. Decide which of the 3 to fold in now vs defer (the build may be far enough
   along that #1 is the priority and #3 can wait).
3. If adopting: extend `jira-config.yml` schema + `config.sh` validation +
   the workstate→Jira mapping in the sink, with sane defaults + relationship
   validation. Add tests for: default mapping, an overridden mapping, and
   2-level checklist mode (incl. idempotent re-run in 2-level mode).
4. Naming note for later: `mbachorik/spec-kit-jira` already holds that public
   name (27★). When we publish, differentiate our name and lead with the
   safety-engine angle so we don't look like a fork.

Full landscape + rationale also lives in
`~/Code/AI/workstate-schema/PROJECT-BRIEF.md` §11 if you want the source.

---

## ADDENDUM (2026-06-01) — keep the sink decoupled from the source

Architecture correction (full rationale: `~/Code/AI/workstate-schema/PROJECT-BRIEF.md` §14):

The spec-kit parser currently lives INSIDE this repo. That's expected,
TEMPORARY debt — but it means the sink is fused to spec-kit. The end state:
**sinks consume `workstate` and nothing else; the spec-kit parser is extracted
to a standalone `source-speckit` producer.**

Two concrete implications for THIS build:
1. **Expose `workstate` as a DIRECT input now.** The Jira sink must be runnable
   from a `workstate` JSON file/stdin, not only from a specs/ tree. (Pipeline
   should be startable one stage later: `workstate → jira`, skipping the
   parser.) This is what lets product-mem / any non-spec-kit source feed it.
   Cheap if workstate is already the internal contract — just expose the seam.
2. **Keep parser ↔ sink cleanly separable.** Don't let Jira-specific concerns
   leak into the parser, or spec-kit concerns into the sink. At the planned
   engine-extraction step, the parser LEAVES this repo (→ source-speckit) and
   this repo becomes a pure workstate→Jira consumer. Build so that's a move,
   not a rewrite (origin-header the parser files; keep the boundary clean).

Do NOT extract source-speckit now — finish Jira first; extraction is the
post-Jira shared step (engine + source-speckit together).
