---
name: pipeline-sync
description: Sync core pipeline files between claude-pipeline and project repos. Use when the user says "sync pipeline", "upstream this fix", "pull latest pipeline", "push to upstream", or when they've fixed a bug in a project's .claude/scripts/ that should be shared. Also use proactively after editing core files (scripts, hooks, schemas) to remind the user to sync.
---

# Pipeline Sync

Manage core pipeline files across the claude-pipeline repo and project repos that use the pipeline. Core files (scripts, hooks, schemas, universal skills) are shared; project-specific files (agents, config, prompts) are never touched.

## When This Matters

The claude-pipeline is a template that gets adapted per-project. Agents and some skills are rewritten for each project's tech stack, but the orchestration engine (scripts, hooks, schemas) stays the same. When a bug is found in a project's copy, it needs to flow back to the pipeline repo and out to other projects.

Without this workflow, fixes get stranded in individual projects and the same bug gets rediscovered repeatedly.

## Prerequisites

- `sync.sh` must exist at the root of the claude-pipeline repo
- The claude-pipeline repo is at `~/Projects/claude-pipeline` (adjust if different)

Verify with:
```bash
ls ~/Projects/claude-pipeline/sync.sh
```

## Workflows

### 1. Push upstream changes TO a project

When the pipeline repo has new features or fixes to distribute:

```bash
cd ~/Projects/claude-pipeline

# Check what's different first
./sync.sh diff ~/Projects/<project-name>

# Push core files (scripts, hooks, schemas, universal skills)
./sync.sh to ~/Projects/<project-name>
```

This never touches project-specific files (agents, `config/platform.sh`, prompts, project-only skills).

### 2. Pull a fix FROM a project back to the pipeline

When a bug was fixed in a project's `.claude/scripts/` or `.claude/hooks/`:

```bash
cd ~/Projects/claude-pipeline

# See what the project changed
./sync.sh diff ~/Projects/<project-name>

# Pull the fix
./sync.sh from ~/Projects/<project-name>

# Review what changed
git diff

# Commit
git checkout -b fix/<descriptive-name>
git add -A
git commit -m "fix: <description of the fix>"
```

### 3. Create a PR to upstream (stevegrocott/claude-pipeline)

After committing a fix to the local fork:

```bash
cd ~/Projects/claude-pipeline
git push origin fix/<branch-name>

gh pr create \
  --repo stevegrocott/claude-pipeline \
  --head scullers68:fix/<branch-name> \
  --base main \
  --title "fix: <title>" \
  --body "$(cat <<'EOF'
## Summary
- <what changed and why>

## Context
<how the bug was discovered, which project, what happened>

## Test plan
- [ ] <how to verify the fix>
EOF
)"
```

### 4. Pull upstream updates and distribute

When Steve merges PRs or pushes new features:

```bash
cd ~/Projects/claude-pipeline
git fetch upstream
git merge upstream/main
git push origin main

# Distribute to all projects
./sync.sh to ~/Projects/allied-universal-assign
./sync.sh to ~/Projects/<other-project>
```

## What Gets Synced

Run `./sync.sh list` for the definitive list. In summary:

| Synced (core) | Never synced (project-specific) |
|---------------|-------------------------------|
| `scripts/**` | `agents/*.md` |
| `hooks/**` | `config/platform.sh` |
| `settings.json` | `prompts/*.md` |
| Universal skills (brainstorming, TDD, debugging, etc.) | Project-only skills (playwright-verification, server-health-check, etc.) |

## Adding a New Universal Skill

If you create a skill in a project that should be shared across all projects:

1. Add the skill name to the `UNIVERSAL_SKILLS` array in `sync.sh`
2. Run `./sync.sh from ~/Projects/<project>` to pull it to the pipeline
3. Commit and PR upstream

## Proactive Reminders

After editing any file in `.claude/scripts/`, `.claude/hooks/`, or `.claude/skills/<universal-skill>/`, consider whether the change should be synced. If it's a bug fix or improvement to the shared engine, prompt the user:

> "This change is in a core pipeline file. Want me to sync it back to claude-pipeline and create a PR upstream?"
