# Claude Pipeline → Plugin Marketplace: Migration Plan

**Status:** Proposal · **Date:** 2026-06-13 · **Audience:** Steve (upstream), Russell (fork)
**Repo analysed:** `scullers68/claude-pipeline` (fork of `aaddrick/claude-pipeline`), local clone @ `a3c05f2`

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

README states: *"pipeline-core assumes the superpowers plugin is installed"* — and `pipeline-setup` checks for it. If the forks have meaningful divergence worth keeping, the alternative is a fifth plugin (`pipeline-methodology`) — but audit the diff first; carrying a fork of someone else's actively-maintained skill set is the same drift problem this migration is killing.

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

**Phase 6 (later, optional) — Orchestrator on the Agent SDK**
`implement-issue-orchestrator.sh` is 6,047 lines of bash implementing a state machine (JSON parsing, retries, rate limits, timeout escalation, review loops). It works and is tested — ship it as-is in v2.0. But its replacement is a TypeScript Agent SDK program (or Claude Code workflow script): real data structures, native subagent management, and the retry/rate-limit machinery for free. The issue-format conventions and test fixtures all carry over. Do this only when the next substantial orchestrator feature is needed — not as part of this migration.

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Skill name changes (`explore` → `pipeline-core:explore`) break muscle memory / cross-references | Grep all SKILL.md + orchestrator prompts for skill invocations in Phase 1; short names still resolve when unambiguous |
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
- **Separation**: engine (core) / methodology (superpowers dependency) / stack opinions (packs) each evolve independently; third parties can add stack packs without touching core.
- **The good parts are untouched**: the issue-as-source-of-truth convention, the platform abstraction, the parseable task-list format, and the bats discipline all survive verbatim — they're the product; the copying was just the packaging.

---
*Total estimated effort: ~3.5 days with Claude Code doing the mechanical work, phased so the pipeline stays usable throughout.*
