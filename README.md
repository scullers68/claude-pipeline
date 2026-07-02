# Claude Pipeline

**Issue-driven development for Claude Code.** Plan work into tracker issues with parseable task lists, then hand them to a supervised agent pipeline that implements, tests, reviews, and opens the PR — with your tracker as the single source of truth throughout.

Distributed as Claude Code plugins: install in one line, update centrally, nothing copied into your repos except your own configuration.

```
/plugin marketplace add scullers68/claude-pipeline
/plugin install pipeline-core@claude-pipeline
```

## The loop

```
 idea ──▶ /explore ──▶ tracker issue ──▶ /implement-issue N ──▶ PR/MR
              │        (the plan lives     │
              │         in the issue)      ├─ branch + implement (subagents)
              │                            ├─ test loop (smart-targeted)
              └─ research, evaluate,       ├─ two-stage review
                 plan, decompose           └─ create + optionally merge PR
```

**`/explore "vague idea"`** researches your codebase, evaluates approaches, and writes the full plan *into a tracker issue* — with a machine-parseable task list:

```markdown
## Implementation Tasks
- [ ] `[backend-developer]` **(M)** Update service with new logic. Scope: 2 files.
      Done when: unit tests pass.
  - **Affected files:** `src/services/user.ts`, `src/services/user.test.ts`
```

**`/implement-issue 42`** reads the issue back and drives the implementation: one branch, task-by-task subagent dispatch with two-stage review (spec compliance, then code quality), a smart-targeted test loop, timeout/retry/model-escalation supervision, and a PR at the end. **`/handle-issues`** batches this across many issues, including parallel execution in worktrees for non-overlapping tasks.

Works with **GitHub Issues or Jira** for tracking, and **GitHub or GitLab** for code — mix and match (e.g. Jira + GitLab) via one config file.

## Plugins

| Plugin | What you get |
|---|---|
| **pipeline-core** | The engine: 24 skills (`explore`, `implement-issue`, `enrich-issue`, `handle-issues`, `process-pr`, policy + recovery skills, `pipeline-setup`, …), 7 agents (code-reviewer, spec-reviewer, research-agent, …), the platform abstraction scripts, guard/format hooks, orchestrators |
| **pipeline-frontend** | Web stack pack: UI design fundamentals, bulletproof-frontend patterns, UI review, Playwright testing, React + Playwright developer agents |
| **pipeline-fastify** | Fastify/Node backend stack pack |

Methodology skills (TDD, systematic debugging, brainstorming, planning) come from the [superpowers plugin](https://github.com/obra/superpowers) — install it alongside pipeline-core; the pipeline composes with it rather than vendoring copies.

## Getting started

1. Install the marketplace and `pipeline-core` (above), plus `superpowers`.
2. In your project, run **`/pipeline-setup`** — it detects what it can (git host from your remote, test/format commands from your manifests), interviews you for the rest (tracker, merge style), writes `.claude/config/platform.sh` and `context.md` into your repo, and verifies the tracker CLI round-trip before reporting success.
3. `/explore "your first idea"` → review the issue it creates → `/implement-issue <n>`.

### Requirements

- Claude Code with plugin support; `bash`, `jq`
- Tracker/host CLIs for your platforms: `gh` (GitHub), `glab` (GitLab), `acli` (Jira) — authenticated
- The superpowers plugin (checked by `pipeline-setup`)

## Configuration

Everything project-specific lives in your repo, in git — plugin updates can never clobber it:

- **`.claude/config/platform.sh`** — tracker (`TRACKER=github|jira`), git host (`GIT_HOST=github|gitlab`), merge style, test/format commands, iteration limits, wall-clock budgets. All `VAR="${VAR:-default}"`, so env overrides always win.
- **`.claude/config/context.md`** — your project's conventions and anti-patterns, injected into every agent prompt. Keep it under 20 rules; every line costs tokens on every stage.
- **`.claude/skills/`, `.claude/agents/`** — project-level skills and agents merge natively with the plugin's; a project skill of the same name overrides the plugin copy.

## Guardrails

pipeline-core ships hooks that run wherever it's enabled: sensitive-file edit blocking (`.env`, credentials, lockfiles), destructive DB command blocking, ad-hoc production-deploy blocking, SKILL.md schema validation on write, per-edit formatting via your `FORMAT_CMD`, and forced routing of issue creation through validated wrappers (so every issue has parseable tasks). Full table and user-level opt-ins (RTK token filtering, notifications): `plugins/pipeline-core/hooks/README.md`.

## Testing & quality

~2,000 bats tests run in CI on every push (platform abstraction, orchestrator logic, policy golden tests), gated by `tests/ci-run.sh`: it fails only on failures **not** documented in `tests/known-reds.txt` — a provenance-annotated burn-down of pre-existing issues. Fix a red, delete its line; the gate stops new ones getting in. The heaviest real-clock supervision suite (`test-stage-runner`) runs nightly rather than per-push.

## Roadmap

- **Config contract** — `.claude/config/` is the current location; a move to `.claude/pipeline/` is under discussion (issue #3)
- **Agent SDK orchestrator** — the bash orchestrator's process-supervision layer (watchdogs, retries, escalation) maps directly onto the Claude Agent SDK; a rewrite would retire the machinery and most of the nightly suite (issue #5)

## Lineage

Original pipeline concept by [aaddrick/claude-pipeline](https://github.com/aaddrick/claude-pipeline). Issue-driven two-phase workflow, platform abstraction, and orchestrator engineering by [stevegrocott/claude-pipeline](https://github.com/stevegrocott/claude-pipeline). Plugin architecture, marketplace packaging, and CI by this fork. See `LICENSE` and `NOTICE`.
