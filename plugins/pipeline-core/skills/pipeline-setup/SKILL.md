---
name: pipeline-setup
description: Use when onboarding a project to the claude-pipeline plugin — first-time setup after installing pipeline-core, re-configuring tracker/git-host settings, migrating a project off the legacy copied .claude/ tree, or when pipeline scripts report missing platform config. Triggers on "set up the pipeline", "pipeline setup", "onboard this project to the pipeline", "configure platform.sh", or a fresh project where /explore and /implement-issue have never run.
inputs: interview answers (tracker, git host, merge style, test/format commands, project conventions); detected repo facts (remote URL, default branch, package manifests)
outputs: .claude/config/platform.sh and .claude/config/context.md in the consumer project; optional project-side agent copies; setup verification report
side_effects: writes config files into the consumer repo (commit-worthy); runs a read-only tracker CLI call to verify auth; may touch-edit a scratch file to verify the format hook
composes: explore and implement-issue (unblocked by this setup); platform scripts (list-issues.sh for verification)
failure_modes: required CLI missing or unauthenticated (report, do not write partial config silently); superpowers plugin absent (warn and continue); legacy copied tree present (flag for user-confirmed removal, never delete unprompted); no git remote yet (skip tracker verification, note it)
---

# Pipeline Setup

Generate the per-project layer the pipeline needs: `platform.sh` (which
tracker, which git host, which commands), `context.md` (project conventions
injected into every agent prompt), and optional project-side agent copies.
This replaces the retired `adapting-claude-pipeline` process — nothing in the
plugin gets edited; everything project-specific lands in the project's own
repo, in git, where plugin updates can never clobber it.

## Step 1: Preflight

Check and report, but only block on hard requirements:

1. **superpowers plugin installed** (methodology skills: TDD, debugging,
   planning). Check for any `superpowers` entry in enabled plugins or an
   available `brainstorming`/`test-driven-development` skill. If absent, tell
   the user pipeline-core assumes it and how to install; continue setup.
2. **CLIs for the platforms they'll choose** — check `gh`, `glab`, `acli`
   with `command -v`. Only the ones matching their tracker/host answers are
   required; report what's present.
3. **Legacy tree detection**: if the project has `.claude/scripts/` or
   `.claude/skills/` copies of pipeline content (old copy-based distribution),
   flag them for removal AFTER config is generated — the plugin supersedes
   them. Keep `.claude/config/` (that's the layer this skill writes) and any
   genuinely project-specific skills/agents.

## Step 2: Interview

Ask only what cannot be detected. Detect first:

- Git host: parse `git remote get-url origin` (github.com → `github`,
  gitlab → `gitlab`).
- Test/format commands: look for `package.json` scripts, `composer.json`,
  `pyproject.toml`, `Makefile` targets. Propose, don't assume.
- Default branch: `git symbolic-ref refs/remotes/origin/HEAD` or ask.

Then ask:

1. **Issue tracker** — GitHub Issues or Jira? If Jira: project key, done
   transition name, in-progress transition name.
2. **Merge style** — squash / merge / rebase; auto-merge when checks pass?
3. **Test commands** — unit test command, optional E2E command.
4. **Format command** — run on every edit via the plugin's PostToolUse hook;
   empty disables.

## Step 3: Generate `.claude/config/platform.sh`

Copy the template from `${CLAUDE_PLUGIN_ROOT}/templates/platform.sh` and fill
in the interview answers. Every value uses the `VAR="${VAR:-value}"` form so
environment overrides keep working. Commit-worthy: tell the user this file
belongs in git.

> Location note: `.claude/config/platform.sh` is the current contract. If the
> config-contract decision (fork issue #3) moves it, this skill and the
> resolvers move together.

## Step 4: Generate `.claude/config/context.md`

Start from `${CLAUDE_PLUGIN_ROOT}/templates/context.md`. Interview briefly:
top 3-5 conventions agents must follow, known anti-patterns, banned
libraries. Keep it under 20 rules — every line costs tokens on every stage.
If the user has nothing yet, leave the commented examples in place.

## Step 5: Stack-pack agents (optional)

If `pipeline-frontend` / `pipeline-fastify` are installed, their agents load
from the plugin automatically. Offer project-side copies ONLY if the user
wants to customise one (copy `agents/<name>.md` from the pack into the
project's `.claude/agents/` and note that the project copy is now theirs to
maintain).

## Step 6: Verify, then report

Run real checks — do not report success without them:

1. `bash ${CLAUDE_PLUGIN_ROOT}/scripts/platform/list-issues.sh --state open`
   (or `--help` if the repo has no remote yet) — proves config loads and the
   tracker CLI authenticates.
2. If a format command was configured: touch-edit a scratch file and confirm
   the PostToolUse hook formats it.
3. Report: files written (with paths), CLIs verified, anything skipped, and
   the suggested first command (`/explore "an idea"` or
   `/implement-issue <n>` if issues already exist).

If legacy tree content was flagged in Step 1, list the exact paths and ask
the user to confirm deletion — do not delete pipeline copies unprompted.
