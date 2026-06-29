# Quickstart: The Automatic Mirror

After this feature, spec-kit-jira **mirrors automatically** — you no longer run a
manual sync.

## How it works

Installing the extension registers six `after_*` hooks into your project's
`.specify/extensions.yml`. From then on, every spec-kit lifecycle command —
`/speckit-specify`, `.clarify`, `.plan`, `.tasks`, `.implement`, `.analyze` —
automatically reconciles the spec state to Jira when it finishes. Run a spec-kit
command; Jira updates. Nothing to remember.

- **Idempotent**: a sync over unchanged state writes nothing.
- **Non-blocking**: if your credentials or config are missing, or Jira is
  unreachable, the spec-kit command **still succeeds** — you just get a warning
  (e.g. "couldn't sync — run `/speckit-jira-install`"). The mirror never breaks
  your workflow.

## Turning a hook off

Don't want auto-sync after a particular phase? Edit `.specify/extensions.yml` and
set that hook `enabled: false`. The bridge honours it and **never re-enables it**
on reinstall.

## On-demand commands (recovery)

The manual commands are still there as escape hatches — for recovery after a missed
hook, ad-hoc inspection, or incident response:

- `/speckit-jira-push` — force a full reconcile now.
- `/speckit-jira-status` — read-only drift preview (disk vs Jira).
- `/speckit-jira-install` / `/speckit-jira-seed` — (re)bind the project.

## Developing the bridge itself

If you install the bridge **into its own repo** (dogfooding), the hooks are gated
on `SPECKIT_JIRA_DOGFOOD_SAFE` so your development work doesn't auto-push to a
board. Export `SPECKIT_JIRA_DOGFOOD_SAFE=true` to opt in.
