# Pipeline conventions

Deltas extracted from the deleted superpowers forks (fork audit, issue #1 on
scullers68/claude-pipeline). The methodology itself lives in the
[superpowers plugin](https://github.com/obra/superpowers) — pipeline-core
assumes it is installed. This doc records only what the pipeline layers on top.

## Structured skill frontmatter

Pipeline skills document their contract in frontmatter beyond name/description:

```yaml
inputs: what the skill consumes (issue number, branch, config keys)
outputs: what it produces (files, comments, status transitions)
side_effects: anything mutated outside the repo (issues, MRs, deploys)
composes: skills this one invokes or hands off to
failure_modes: known ways it goes wrong and what to do
```

Schema enforced by `scripts/schemas/skill-frontmatter.json` via the
pre-commit-skill-validate hook. Note: pipeline convention is that
`description:` states ONLY when to use the skill; upstream superpowers says
"what it does AND when" — when writing pipeline skills, follow the pipeline
convention.

## Issues as planning I/O

Plans are written INTO the tracker issue, not local files:

- `/explore` ends by creating an issue whose body carries the parseable task
  list: `- [ ] \`[agent-name]\` **(S|M|L)** description. Scope: N files.
  Done when: <criterion>` with an **Affected files** sub-bullet.
- `/implement-issue N` reads it back via `scripts/platform/read-issue.sh`.
- Long sessions checkpoint with `create-session-summary` and resume with
  `resume-session` rather than relying on conversation memory.

## Two-stage subagent review

Implementation dispatches review in two passes, not one: a **spec-compliance
review** (did it build what the task said?) then a **code-quality review**
(is it built well?). Reviewer prompts: `prompts/subagent-review/`.

Dispatch rule: subagents have no memory of branch context — include the
branch name in every implementer dispatch.

## Token-awareness defaults for dispatched agents

Prefer the smallest model that can do the stage (haiku for mechanical
stages), truncate command output before it enters context, and use
background execution for long-running commands.

## Project-specific setup (example: Laravel worktrees)

Per-project bootstrap (e.g. worktree setup running `composer install`,
`php artisan migrate --seed`, Vite build) belongs in the PROJECT's own
`.claude/` docs or setup skill — not in forked copies of generic skills.
