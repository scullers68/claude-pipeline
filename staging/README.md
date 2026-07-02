# Staging — content parked during the plugin migration (Phase 1)

Nothing in this directory ships in any plugin. It exists so the Phase 1
restructure stays purely mechanical; each subdirectory has a pending Phase 2
decision (see `docs/plugin-migration-plan.md`).

## superpowers-forks/

Eleven methodology skills forked from the superpowers ecosystem
(brainstorming, TDD, systematic-debugging, writing-*, using-*, etc.).
`pipeline-core` now assumes the superpowers plugin is installed instead of
vendoring these. **Phase 2:** diff each fork against upstream superpowers;
delete forks with no meaningful divergence, promote anything worth keeping
into a documented patch or a `pipeline-methodology` plugin.

## retired/

Tooling made obsolete by plugin distribution:

- `pipeline-sync/`, `sync.sh`, `apply-local.sh`, `sync-reminder.sh` — the
  copy-and-overlay distribution machinery. Plugins version and distribute
  centrally; consumers update via the marketplace.
- `adapting-claude-pipeline/` — the per-project adaptation process. Its
  replacement (`pipeline-setup`: scaffolds project config, checks
  dependencies) is a Phase 2 deliverable.
