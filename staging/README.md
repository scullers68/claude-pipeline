# Staging — content parked during the plugin migration (Phase 1)

Nothing in this directory ships in any plugin. It exists so the Phase 1
restructure stays purely mechanical; each subdirectory has a pending Phase 2
decision (see `docs/plugin-migration-plan.md`).

## superpowers-forks/ — RESOLVED (deleted 2026-07-02)

Audit verdict (fork issue #1): 10 of 11 forks were upstream superpowers
skills plus pipeline plumbing. Deleted. Extracted before deletion:
`writing-agents` (no upstream counterpart) promoted into pipeline-core
skills; subagent reviewer prompts moved to
`plugins/pipeline-core/prompts/subagent-review/`; remaining deltas
captured in `docs/pipeline-conventions.md`.

## retired/

Tooling made obsolete by plugin distribution:

- `pipeline-sync/`, `sync.sh`, `apply-local.sh`, `sync-reminder.sh` — the
  copy-and-overlay distribution machinery. Plugins version and distribute
  centrally; consumers update via the marketplace.
- `adapting-claude-pipeline/` — the per-project adaptation process. Its
  replacement (`pipeline-setup`: scaffolds project config, checks
  dependencies) is a Phase 2 deliverable.
