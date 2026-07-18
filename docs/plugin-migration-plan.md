# Claude Pipeline → Plugin Marketplace: Migration Plan

**Status:** Proposal · **Date:** 2026-06-13 (rev. 2026-07-05) · **Audience:** Steve (upstream), Russell (fork)
**Repo analysed:** `scullers68/claude-pipeline` (fork of `aaddrick/claude-pipeline`), local clone @ `a3c05f2`

> **This is one of three companion docs — read together:** (1) this plan — *what to build*; (2) `docs/experiments/ab-pipeline-vs-epic-task-loop.md` — an empirical pipeline-vs-`/epic-task-loop` cost A/B showing *why the orchestrator is the weak point*; (3) `docs/experiments/pipeline-findings.md` — a cost/robustness audit with *the concrete fixes* (tickets #13–#18). The 2026-07-05 revision cross-links (2) and (3) into §3.4 and §6.

---

## 1. The problem in one paragraph

The pipeline is distributed by **copying the whole `.claude/` tree into every consuming project**, then pruning it with the 6-step `adapting-claude-pipeline` process, then keeping copies alive with a hand-rolled overlay system (`.claude/local/` + `apply-local.sh` + `sync.sh`). Every copy drifts immediately and propagates partially. Real-world evidence: nine of Russell's projects carried the `post-pr-simplify` hook wiring, but the `code-simplifier` agent it depends on existed in only one of them, and one project (precis) had the wiring without the script at all — every MR in eight projects errored with "agent not found". That failure mode is structural to copy-based distribution. Claude Code **plugins** solve exactly this: versioned central repo, one-line enablement per project, no adaptation step, no drift.

## 2. Target architecture

One marketplace repo (this repo, restructured) publishing four plugins. Consumers add the marketplace once, then enable only what fits the project.

```
claude-pipeline/                        (marketplace repo)
├── .claude-plugin/marketplace.json
├── plugins/
│   ├── pipeline-core/                  the engine — always installed
│   ├── pipeline-frontend/              web/UI stack pack — optional
│   ├── pipeline-fastify/               backend stack pack — optional
│   └── pipeline-extras/                nice-to-haves — optional
├── tests/                              bats suites (run in CI, not shipped)
├── docs/
└── README.md
```

**Consumer experience after migration:**

```bash
/plugin marketplace add stevegrocott/claude-pipeline
/plugin install pipeline-core@claude-pipeline
# optionally: pipeline-frontend, pipeline-fastify
```

or declaratively in a project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "claude-pipeline": { "source": { "source": "github", "repo": "stevegrocott/claude-pipeline" } }
  },
  "enabledPlugins": { "pipeline-core@claude-pipeline": true }
}
```

Updating every project = pushing to the marketplace repo. No `sync.sh`, no `apply-local.sh`, no adaptation pass, no ninth broken copy.

## 3. The split — every current asset mapped

### 3.1 `pipeline-core` (the product)

| Asset type | Contents |
|---|---|
| Skills (15) | `explore`, `implement-issue`, `handle-issues`, `process-pr`, `pr-creation`, `pr-review`, `fix-from-review`, `test-validation`, `complete-summary`, `resume-session`, `create-session-summary`, `improvement-loop`, `investigating-codebase-for-user-stories`, `mcp-tools`, `pipeline-setup` (new — replaces `adapting-claude-pipeline`, see §5) |
| Agents (6) | `code-reviewer`, `spec-reviewer`, `research-agent`, `project-manager-backlog`, `cc-orchestration-writer`, `bash-script-craftsman` |
| Scripts | `scripts/platform/*` (GitHub/GitLab/Jira abstraction + ADF/wiki converters), `implement-issue-orchestrator.sh`, `batch-orchestrator.sh`, `batch-runner.sh`, `explore-orchestrator.sh`, `model-config.sh` |
| Hooks | See §3.5 — all converted from inline one-liners to script files |
| Prompts | `review-checklist.md` |

### 3.2 `pipeline-frontend` (stack pack)

| Asset type | Contents |
|---|---|
| Skills (5) | `ui-design-fundamentals` (14 refs), `bulletproof-frontend`, `review-ui`, `playwright-testing`, `write-docblocks` |
| Agents (2) | `react-frontend-developer`, `playwright-test-developer` |
| Prompts | `prompts/frontend/*` (blade audit/refactor) |

### 3.3 `pipeline-fastify` (stack pack)

| Asset type | Contents |
|---|---|
| Agents (1) | `fastify-backend-developer` |

Thin today, but the right home for future fastify skills/prompts. Stack packs are the extension point: a `pipeline-totara` pack (Russell's TKE world) or `pipeline-laravel` pack slots in without touching core.

### 3.4 Deleted — replaced by a declared dependency on **superpowers**

These 11 skills are forks of the superpowers ecosystem and duplicate what consumers can install directly (Russell already runs the superpowers plugin — the duplication is live today, with both copies loaded):

`brainstorming`, `systematic-debugging`, `test-driven-development`, `subagent-driven-development`, `dispatching-parallel-agents`, `executing-plans`, `using-git-worktrees`, `using-skills`, `writing-agents`, `writing-plans`, `writing-skills`

README states: *"pipeline-core assumes the superpowers plugin is installed"* — and `pipeline-setup` checks for it.

**Why split methodology out — the benefit, not just dedup.** Superpowers is actively maintained upstream on its own cadence. Depending on it instead of forking it means:

- **Free upstream fixes.** New and improved superpowers skills land in every consumer via `git push` to superpowers — zero merge effort on our side. A fork means every superpowers release becomes a diff *we* must reconcile, forever.
- **No fork-maintenance tax.** The engine (core) and the methodology (brainstorming, TDD, debugging…) have *different maintainers and cadences*. Keeping them in one tree is precisely what forces the drift this whole migration exists to kill — applied to someone else's code, where we have the least leverage.
- **The both-loaded waste ends.** Today a consumer already running superpowers loads **two** copies of `brainstorming`, `test-driven-development`, etc. — extra metadata tokens for a skill that is, at best, identical and, at worst, a stale fork silently shadowing the maintained one.

**Open question — Phase 2 gate (not yet decided).** Whether these forks carry divergence worth keeping needs a diff audit against current superpowers. If real divergence exists it becomes a documented patch or a fifth `pipeline-methodology` plugin; if not — the likely case — they are simply deleted. Either way, the default is *depend, don't fork*.

Also retired: `pipeline-sync` and `adapting-claude-pipeline` (the plugin system replaces both), `apply-local.sh`, `sync.sh`.

### 3.5 Hooks — from inline one-liners to shipped scripts

Current state: two `PreToolUse` guards are Python one-liners embedded in settings.json strings (unreadable, quoting-fragile); `notify-send` is Linux-only. Each becomes a file in `plugins/pipeline-core/hooks/scripts/`, wired via the plugin's `hooks/hooks.json` using `${CLAUDE_PLUGIN_ROOT}`:

| Current | Becomes |
|---|---|
| inline python: block `.env`/`.git/`/`credentials`/lockfile edits | `guard-sensitive-files.sh` |
| inline python: block `deploy_to_production` commands | `guard-deploy.sh` |
| inline jq: run `$FORMAT_CMD` after edits (reads project `platform.sh`) | `format-on-edit.sh` (reads project config, §4) |
| `pipeline-sync/scripts/detect-core-edit.sh` | `detect-core-edit.sh` (repurposed: warns when a consumer edits plugin-managed files) |
| `notify-send` notification | `notify.sh` with macOS/Linux detection, or drop |
| `session-start.sh` | `session-start.sh` unchanged |

## 4. What remains per-project (the config contract)

The *only* thing that legitimately varies per project is configuration, not code. Replace the copied tree with one file the plugin reads:

```
project/.claude/pipeline/platform.sh     # committed to the project repo
```

```bash
# Which issue tracker and git host this project uses
ISSUE_PLATFORM=jira          # github | jira
GIT_PLATFORM=gitlab          # github | gitlab
JIRA_PROJECT=MER
DEFAULT_BRANCH=main
FORMAT_CMD="npx prettier --write"
TEST_CMD="npm test"
```

All plugin scripts/hooks resolve config as `$CLAUDE_PROJECT_DIR/.claude/pipeline/platform.sh`, falling back to sensible defaults. Project-specific skills/agents (the old `.claude/local/` role) live in the project's own `.claude/skills/` — Claude Code merges them natively; no overlay tooling needed.

## 5. Does the adapt step survive?

The `adapting-claude-pipeline` workflow — updating, pruning, and rewriting skills per project context — is the pipeline's most distinctive feature, so it's the natural first objection to a read-only plugin model. It survives, but changes shape: **adaptation stops being "edit the shared copy" and becomes "generate the project layer".** Broken into its four actual operations:

**Pruning irrelevant skills → mostly unnecessary.** Coarse-grained pruning becomes plugin selection: a CLI project never installs `pipeline-frontend` (the files currently marked `STACK-SPECIFIC: delete during adaptation` are precisely the frontend pack). Fine-grained pruning loses its economic rationale: plugin skills are lazy-loaded at ~100 tokens of metadata each until invoked, so an unused skill is no longer clutter worth a deletion pass.

**Tuning conventions and patterns → already survives, unchanged.** The orchestrator *already* injects `config/context.md` into every agent prompt via `PLATFORM_CONTEXT_FILE`, and seven skills read the config layer — the parameterization mechanism exists today. In the plugin model that file moves to `.claude/pipeline/context.md` in the consumer repo, **committed**. That is strictly better than the current arrangement, where adaptations live gitignored in `local/` and the docs warn that `sync.sh` overwrites `platform.sh`.

**Customising stack agents → survives via the native project layer.** Today: copy `fastify-backend-developer.md` into `.claude/local/agents/` and edit. Plugin model: the consumer repo's own `.claude/agents/` does this natively, no overlay script. Stack-pack agents become starting points that get copied project-side when a project needs to diverge. Upstream commits #567 (strip stack-specific comments from local agent copies) and #569 (sync agent definitions to consumer repos) are already implementing this manually — customised agents belong in the consumer repo.

**Deep rewrites of a core skill's body → the one genuine loss.** A project that needs a fundamentally different `implement-issue` flow cannot edit the plugin's copy. Mitigations in order of preference: make the core skill branch on config (usually sufficient); define a project-level skill that takes over (Phase 3 must verify how same-name project skills interact with namespaced plugin skills — flagged in §8); or pin/fork the plugin for that project. In practice this case is rare: observed adaptations across nine consumer projects were pruning and agent tuning, not core-flow rewrites.

Net: `adapting-claude-pipeline` becomes `pipeline-setup` — same interviewing intelligence, different output target. Instead of mutating a copied tree, it generates `platform.sh`, `context.md`, and any project-side agent overrides. Adaptation products finally live in git, in the project, where an upstream update can never clobber them.

## 6. Manifests

### 6.1 `.claude-plugin/marketplace.json` (repo root)

```json
{
  "name": "claude-pipeline",
  "owner": { "name": "Steve Grocott", "url": "https://github.com/stevegrocott" },
  "metadata": {
    "description": "Issue-driven development pipeline: /explore an idea into a planned issue, /implement-issue to ship it",
    "version": "2.0.0"
  },
  "plugins": [
    {
      "name": "pipeline-core",
      "source": "./plugins/pipeline-core",
      "description": "Explore→issue→implement→PR engine with GitHub/GitLab/Jira support. Requires the superpowers plugin.",
      "category": "workflow"
    },
    {
      "name": "pipeline-frontend",
      "source": "./plugins/pipeline-frontend",
      "description": "Web stack pack: UI design fundamentals, frontend review, Playwright testing, React agent",
      "category": "stack-pack"
    },
    {
      "name": "pipeline-fastify",
      "source": "./plugins/pipeline-fastify",
      "description": "Fastify/Node backend stack pack",
      "category": "stack-pack"
    }
  ]
}
```

### 6.2 `plugins/pipeline-core/.claude-plugin/plugin.json`

```json
{
  "name": "pipeline-core",
  "version": "2.0.0",
  "description": "Issue-driven pipeline: /explore writes the plan into an issue with a parseable task list; /implement-issue reads it back, implements task-by-task with subagents, tests, reviews, and opens the PR/MR.",
  "author": { "name": "Steve Grocott" },
  "homepage": "https://github.com/stevegrocott/claude-pipeline",
  "keywords": ["workflow", "issues", "jira", "gitlab", "github", "orchestration"]
}
```

### 6.3 `plugins/pipeline-core/hooks/hooks.json`

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/guard-sensitive-files.sh" }]
      },
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/guard-deploy.sh" }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/format-on-edit.sh" }]
      }
    ],
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/session-start.sh" }] }
    ]
  }
}
```

### 6.4 Plugin directory layout (core)

```
plugins/pipeline-core/
├── .claude-plugin/plugin.json
├── skills/
│   ├── explore/SKILL.md
│   ├── implement-issue/SKILL.md
│   └── ... (15 skills)
├── agents/
│   ├── code-reviewer.md
│   └── ... (6 agents)
├── hooks/
│   ├── hooks.json
│   └── scripts/            # guard-*, format-on-edit, session-start, notify
├── scripts/
│   ├── platform/           # create-mr.sh, list-issues.sh, adf converters…
│   ├── implement-issue-orchestrator.sh
│   ├── batch-orchestrator.sh
│   └── model-config.sh
└── prompts/review-checklist.md
```

## 7. Migration phases

**Phase 0 — Fork & baseline** (½ day)
Fork to `russellgrocott/claude-pipeline` (or branch on Steve's). Tag current state `v1-final`. Get bats suites green as the regression baseline.

**Phase 1 — Mechanical restructure** (1 day)
Create marketplace/plugin scaffolding; `git mv` assets per §3; convert inline hooks to scripts (§3.5); replace `$CLAUDE_PROJECT_DIR/.claude/scripts/...` self-references in orchestrators and skills with `${CLAUDE_PLUGIN_ROOT}/...` (grep says this is the bulk of the work — the orchestrator and several SKILL.md files hardcode the old paths). Move bats suites to `tests/`, pointed at the new script locations.

**Phase 2 — Dedupe & config contract** (½ day)
Delete the 11 superpowers forks (§3.4) after a divergence audit. Implement the `platform.sh` config contract (§4). Write `pipeline-setup` skill: checks superpowers is installed, scaffolds `.claude/pipeline/platform.sh` interactively, verifies `gh`/`glab`/`acli` availability.

**Phase 3 — Pilot** (½ day)
Enable the marketplace + `pipeline-core` on one real project (suggestion: `ai-coach` — small, already a consumer). Run `/explore` and `/implement-issue` end-to-end against a real issue. Fix path/namespace fallout (plugin skills are invoked as `pipeline-core:explore`; update any cross-skill references).

**Phase 4 — Rollout & demolition** (½ day)
Enable in the remaining consumer projects; delete their copied `.claude/` pipeline trees (keep only `platform.sh` + genuinely project-specific skills). This is the payoff commit: net −15k lines per project.

**Phase 5 — CI** (½ day)
GitHub Action: bats suites + shellcheck + a smoke test that installs the marketplace into a scratch project and asserts skills/hooks resolve.

**Phase 6 (later, but now evidence-backed) — Orchestrator on the Agent SDK**
`implement-issue-orchestrator.sh` is **~8,000 lines** of bash implementing a state machine — JSON parsing, retries, rate limits, timeout escalation, review loops. (It was 6,047 lines when this plan was first drafted; it has grown ~2k lines in three weeks — the monolith is *accreting*, not stabilising.) It is shippable as-is in v2.0 — it works and is tested — **but treat it as a named robustness risk, not a future nicety.** The cost/robustness audit (`docs/experiments/pipeline-findings.md`, Findings 9–10) found that:

- **Both current critical bugs live inside this one file** — #13 (session-limit 429 misclassification) and #14 (max-turns cold-retry churn). A monolith with no stage-isolation or test seams is where bugs hide and compound.
- **Its supervision code is the least-tested in the suite** — the watchdog/timeout tests in `test-stage-runner.bats` exceed 5 hours and are exiled to a nightly job, so the safety-critical paths are exercised least.
- **The cost is measured, not hypothetical** — the A/B (`docs/experiments/ab-pipeline-vs-epic-task-loop.md`) shows this orchestrator spending **~3.4× the tokens** of a warm single-context loop on issue #13 and shipping *less*, ~55% of it fixable churn from #14.

The replacement is the TypeScript Agent SDK harness **already scaffolded** under `plugins/pipeline-core/sdk/` (issue #11, wired side-by-side via `ORCHESTRATOR_ENGINE=bash|sdk`): real data structures, native subagent management, retry/rate-limit machinery for free. Issue-format conventions and test fixtures carry over. **Recommendation:** ship v2.0 on the bash engine, but (a) land the #13/#14 fixes first — they roughly halve the as-is cost — and (b) prioritise completing the SDK harness as the *durable* fix rather than deferring it to "when the next feature is needed." The file is growing and it is where the bugs live; waiting makes the eventual port harder, not easier.

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Skill name changes (`explore` → `pipeline-core:explore`) break muscle memory / cross-references | **RESOLVED (Phase 1 pilot):** all 22 core skills + 6 agents load namespaced via `--plugin-dir` in a live session; guard-deploy hook blocked a test command with the shipped script's message. Cross-references rewritten. |
| Orchestrator hardcodes `.claude/scripts/` paths | Central `PIPELINE_ROOT` variable resolved from `${CLAUDE_PLUGIN_ROOT}`, single change point |
| Consumers with `.claude/local/` customisations | They migrate to project-level `.claude/skills/` (native merge); document in CHANGELOG |
| Unverified: can a same-name project skill cleanly take over from a namespaced plugin skill? (§5, deep-rewrite case) | Explicit test in Phase 3 pilot; fallback is config-driven branching in the core skill or a pinned plugin version |
| Superpowers forks contain real divergence | Phase 2 diff audit; anything worth keeping becomes a documented patch or a `pipeline-methodology` plugin |
| Headless/CI use (`claude -p` from orchestrator) | Plugins load in headless mode; verify explicitly in Phase 3 pilot |
| Upstream (`aaddrick`) sync story | The marketplace repo still tracks upstream via git; syncs now land in ONE place instead of N projects |

## 9. Why this is worth it (summary for Steve)

- **Distribution**: `cp -r` + 6-step adaptation + overlay scripts → one `/plugin install`. Updates propagate by `git push`.
- **Reliability**: kills the partial-copy failure class outright (nine differently-broken hook copies found in Russell's projects this week).
- **Footprint**: consumers stop carrying ~17.7k lines of skills they must prune; backend repos no longer ship pricing-page design guidance.
- **Separation**: engine (core) / methodology (**a dependency on upstream superpowers, not a fork**) / stack opinions (packs) each evolve independently — you inherit superpowers' fixes for free, third parties add stack packs without touching core, and the both-loaded skill duplication ends (§3.4).
- **The good parts are untouched**: the issue-as-source-of-truth convention, the platform abstraction, the parseable task-list format, and the bats discipline all survive verbatim — they're the product; the copying was just the packaging.
- **Now evidence-backed**: a pipeline-vs-`/epic-task-loop` A/B (`docs/experiments/`) shows the orchestrator costs ~3.4× the tokens for this class of work (~55% fixable churn) — the 8k-line bash monolith is the measured weak point, and the SDK harness (#11) is its durable fix. The companion findings doc turns this into ticketed work (#13–#18).

---
*Total estimated effort: ~3.5 days with Claude Code doing the mechanical work, phased so the pipeline stays usable throughout.*

**Phase 1 status (2026-07-02): complete on `feat/plugin-marketplace`.** Full bats verification against a pristine-main baseline: zero regressions; three pre-existing upstream test failures fixed in passing; remaining reds reproduce identically on main (documented in the Phase 1 commit message).
