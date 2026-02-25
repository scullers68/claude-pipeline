# Claude Pipeline Fork Improvements — Implementation Plan

> **For Claude Code:** This document is an implementation plan for enhancing stevegrocott/claude-pipeline. Execute each phase sequentially. Each phase produces working, testable output before moving to the next. Use the pipeline’s own skills where applicable (`/writing-skills`, `/writing-agents`, `/writing-plans`).

## Context

This plan enhances a fork of [stevegrocott/claude-pipeline](https://github.com/stevegrocott/claude-pipeline) — a portable `.claude/` folder for structured Claude Code development workflows. You clone it into any project, run `/adapting-claude-pipeline`, and it customises everything for that project’s stack.

The fork currently hardcodes GitHub Issues (`gh` CLI) for issue tracking and GitHub for git hosting. This plan makes the pipeline portable across issue trackers and git hosts, adds E2E testing support, and formalises MCP tool usage — all while preserving the core design principle that **each project gets its own adapted `.claude/` folder**.

### Goals

1. **Abstract the platform layer** — decouple from GitHub Issues/PRs to support Jira (via ACLI) and GitLab (via `glab`)
1. **Add Playwright E2E testing** as a core skill alongside existing unit test support
1. **Formalise MCP tool usage** — Context7 and Serena are used but not systematically integrated
1. **Enhance `/adapting-claude-pipeline`** to handle platform config and E2E setup during the brainstorming phase
1. **Maintain upstream merge compatibility** — all changes are designed as clean contributions to the fork

### Design Principle: No Profiles, No Shared Config

The pipeline’s core design is **one `.claude/` folder per project**, adapted in place via `/adapting-claude-pipeline`. This plan does NOT introduce profiles, shared configuration directories, or any abstraction that fights this principle.

When you adapt the pipeline for a Totara project, the Totara-specific agents and skills live in that project’s `.claude/agents/` and `.claude/skills/`. When you adapt it for a React/Next.js project, different agents and skills are created in that project’s `.claude/` folder. The adaptation skill handles this — it’s the customisation mechanism, not a profile system.

What this plan DOES add to the core portable `.claude/` folder:

- **Platform wrapper scripts** that work with GitHub, GitLab, or Jira out of the box — configured during `/adapt`
- **Playwright skill and agent** available for any project to use (or delete during adaptation if not needed)
- **MCP tools reference** available for any project (or delete if not using MCP)
- **Enhanced `/adapt`** that asks about your issue tracker, git host, and E2E testing during brainstorming

### Constraints

- **ACLI preferred over Atlassian MCP** for Jira interactions (faster, fewer tokens)
- **GitLab for git hosting** at work — PRs become Merge Requests, `gh` becomes `glab`
- **Jira for task management** at work — transitions are stateful (not just open/closed)
- **Each project’s `.claude/` folder is self-contained** — no external dependencies on shared config
- **Existing core skills are preserved** — brainstorming, TDD, systematic-debugging, writing-plans, improvement-loop, etc. remain unchanged

-----

## Phase 1: Platform Abstraction Layer

**Goal:** Replace all hardcoded `gh` CLI calls with configurable wrapper scripts that support GitHub, GitLab, and Jira. After adaptation, each project’s `.claude/config/platform.sh` records which tools that project uses.

### Task 1.1: Create platform configuration

**Create:** `.claude/config/platform.sh`

This ships with GitHub defaults. The `/adapt` skill will modify it for the target project.

```bash
#!/bin/bash
# Platform configuration for this project
# Modified by /adapting-claude-pipeline during setup

# Issue tracker
TRACKER="${TRACKER:-github}"              # github | jira
TRACKER_CLI="${TRACKER_CLI:-gh}"          # gh | acli
JIRA_PROJECT="${JIRA_PROJECT:-}"          # Jira project key (e.g., KIN) — only used when TRACKER=jira
JIRA_DEFAULT_ISSUE_TYPE="${JIRA_DEFAULT_ISSUE_TYPE:-Task}"
JIRA_DONE_TRANSITION="${JIRA_DONE_TRANSITION:-Done}"
JIRA_IN_PROGRESS_TRANSITION="${JIRA_IN_PROGRESS_TRANSITION:-In Progress}"

# Git host
GIT_HOST="${GIT_HOST:-github}"            # github | gitlab
GIT_CLI="${GIT_CLI:-gh}"                  # gh | glab

# Merge strategy
MERGE_STYLE="${MERGE_STYLE:-squash}"      # squash | merge | rebase

# Test commands (set during /adapt based on project stack)
TEST_UNIT_CMD="${TEST_UNIT_CMD:-}"        # e.g., "npm test", "vendor/bin/phpunit", "pytest"
TEST_E2E_CMD="${TEST_E2E_CMD:-}"          # e.g., "npx playwright test" — empty if no E2E
TEST_E2E_BASE_URL="${TEST_E2E_BASE_URL:-}"

# Lint and format (set during /adapt)
LINT_CMD="${LINT_CMD:-}"
FORMAT_CMD="${FORMAT_CMD:-}"
```

### Task 1.2: Create issue tracker wrapper scripts

**Create:** `.claude/scripts/platform/` directory with the following scripts. Each sources `platform.sh` and dispatches to the correct CLI. All scripts output normalised JSON regardless of backend.

**`.claude/scripts/platform/create-issue.sh`**

```bash
#!/bin/bash
# Usage: create-issue.sh --title "Title" --body "Body" [--labels "bug,critical"]
# Returns: issue number or key on stdout (e.g., "42" or "KIN-123")
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

TITLE="" BODY="" LABELS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --labels) LABELS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$TRACKER" in
  github)
    ARGS=(gh issue create --title "$TITLE" --body "$BODY")
    [[ -n "$LABELS" ]] && ARGS+=(--label "$LABELS")
    "${ARGS[@]}" 2>/dev/null | grep -oE '[0-9]+$'
    ;;
  jira)
    acli jira create-issue \
      --project "$JIRA_PROJECT" \
      --type "$JIRA_DEFAULT_ISSUE_TYPE" \
      --summary "$TITLE" \
      --description "$BODY" 2>/dev/null \
      | grep -oE '[A-Z]+-[0-9]+'
    ;;
esac
```

**`.claude/scripts/platform/read-issue.sh`**

```bash
#!/bin/bash
# Usage: read-issue.sh <issue-number-or-key>
# Returns: JSON { title, body, status }
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

ISSUE="$1"

case "$TRACKER" in
  github)
    gh issue view "$ISSUE" --json title,body,state \
      | jq '{ title, body, status: .state }'
    ;;
  jira)
    acli jira get-issue --issue "$ISSUE" --outputFormat json 2>/dev/null \
      | jq '{ title: .fields.summary, body: .fields.description, status: .fields.status.name }'
    ;;
esac
```

**`.claude/scripts/platform/comment-issue.sh`**

```bash
#!/bin/bash
# Usage: comment-issue.sh <issue-number-or-key> "Comment body"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

ISSUE="$1" COMMENT="$2"

case "$TRACKER" in
  github) gh issue comment "$ISSUE" --body "$COMMENT" ;;
  jira) acli jira add-comment --issue "$ISSUE" --comment "$COMMENT" ;;
esac
```

**`.claude/scripts/platform/transition-issue.sh`**

```bash
#!/bin/bash
# Usage: transition-issue.sh <issue-number-or-key> [transition-name]
# GitHub: closes the issue
# Jira: transitions to the named state (defaults to JIRA_DONE_TRANSITION)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

ISSUE="$1"
TRANSITION="${2:-$JIRA_DONE_TRANSITION}"

case "$TRACKER" in
  github) gh issue close "$ISSUE" ;;
  jira) acli jira transition-issue --issue "$ISSUE" --transition "$TRANSITION" ;;
esac
```

**`.claude/scripts/platform/list-issues.sh`**

```bash
#!/bin/bash
# Usage: list-issues.sh [--jql "JQL query"] [--state open] [--assignee @me] [--labels "bug"]
# Returns: JSON array of { id, title, status }
# For GitHub: uses gh issue list flags
# For Jira: uses JQL (auto-built from flags or explicit --jql)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

JQL="" STATE="open" ASSIGNEE="" LABELS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jql) JQL="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --assignee) ASSIGNEE="$2"; shift 2 ;;
    --labels) LABELS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$TRACKER" in
  github)
    ARGS=(gh issue list --state "$STATE" --json number,title,state --limit 100)
    [[ -n "$ASSIGNEE" ]] && ARGS+=(--assignee "$ASSIGNEE")
    [[ -n "$LABELS" ]] && ARGS+=(--label "$LABELS")
    "${ARGS[@]}" | jq '[.[] | { id: (.number | tostring), title, status: .state }]'
    ;;
  jira)
    if [[ -z "$JQL" ]]; then
      JQL="project = $JIRA_PROJECT AND status != Done ORDER BY priority DESC"
    fi
    acli jira list-issues --jql "$JQL" --outputFormat json 2>/dev/null \
      | jq '[.[] | { id: .key, title: .fields.summary, status: .fields.status.name }]'
    ;;
esac
```

**`.claude/scripts/platform/create-mr.sh`**

```bash
#!/bin/bash
# Usage: create-mr.sh --source "branch" --target "main" --title "Title" --body "Body"
# Returns: MR/PR number on stdout
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

SOURCE="" TARGET="" TITLE="" BODY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$GIT_HOST" in
  github)
    gh pr create --head "$SOURCE" --base "$TARGET" --title "$TITLE" --body "$BODY" \
      2>/dev/null | grep -oE '[0-9]+$'
    ;;
  gitlab)
    glab mr create --source-branch "$SOURCE" --target-branch "$TARGET" \
      --title "$TITLE" --description "$BODY" --squash-on-merge --no-editor \
      2>/dev/null | grep -oE '![0-9]+' | tr -d '!'
    ;;
esac
```

**`.claude/scripts/platform/read-mr-comments.sh`**

```bash
#!/bin/bash
# Usage: read-mr-comments.sh <mr-number>
# Returns: JSON array of comment bodies
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

MR="$1"

case "$GIT_HOST" in
  github) gh pr view "$MR" --json comments --jq '[.comments[].body]' ;;
  gitlab) glab mr note list "$MR" --output json 2>/dev/null | jq '[.[].body]' ;;
esac
```

**`.claude/scripts/platform/merge-mr.sh`**

```bash
#!/bin/bash
# Usage: merge-mr.sh <mr-number>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

MR="$1"

case "$GIT_HOST" in
  github)
    case "$MERGE_STYLE" in
      squash) gh pr merge "$MR" --squash --delete-branch ;;
      merge) gh pr merge "$MR" --merge --delete-branch ;;
      rebase) gh pr merge "$MR" --rebase --delete-branch ;;
    esac
    ;;
  gitlab)
    case "$MERGE_STYLE" in
      squash) glab mr merge "$MR" --squash --remove-source-branch --yes ;;
      merge) glab mr merge "$MR" --remove-source-branch --yes ;;
      rebase) glab mr merge "$MR" --rebase --remove-source-branch --yes ;;
    esac
    ;;
esac
```

### Task 1.3: Refactor orchestrator scripts

**Modify:** `.claude/scripts/implement-issue-orchestrator.sh`

At the top of the script, source platform config:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config/platform.sh"
PLATFORM_DIR="$SCRIPT_DIR/platform"
```

Replace all direct `gh` calls throughout the script:

|Current call                                                         |Replacement                                                                                     |
|---------------------------------------------------------------------|------------------------------------------------------------------------------------------------|
|`gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json body -q '.body'`|`"$PLATFORM_DIR/read-issue.sh" "$ISSUE_NUMBER" | jq -r '.body'`                                 |
|`gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$comment"`  |`"$PLATFORM_DIR/comment-issue.sh" "$ISSUE_NUMBER" "$comment"`                                   |
|`gh pr create --base $BASE_BRANCH --title ...`                       |`"$PLATFORM_DIR/create-mr.sh" --source "$branch" --target "$BASE_BRANCH" --title ... --body ...`|
|`gh pr list --repo "$REPO" --head "$branch" ...`                     |`"$PLATFORM_DIR/read-mr-comments.sh" "$mr_number"`                                              |
|`gh pr merge ...`                                                    |`"$PLATFORM_DIR/merge-mr.sh" "$mr_number"`                                                      |

Also replace hardcoded test commands with config variables:

```bash
run_tests() {
  local exit_code=0

  if [[ -n "${TEST_UNIT_CMD:-}" ]]; then
    log "Running unit tests: $TEST_UNIT_CMD"
    eval "$TEST_UNIT_CMD" || exit_code=$?
  fi

  if [[ $exit_code -eq 0 ]] && [[ -n "${TEST_E2E_CMD:-}" ]]; then
    log "Running E2E tests: $TEST_E2E_CMD"
    eval "$TEST_E2E_CMD" || exit_code=$?
  fi

  return $exit_code
}
```

**Modify:** `.claude/scripts/batch-runner.sh` — same treatment for any `gh` calls.

**Important:** The orchestrator and status.json must use string issue identifiers throughout (not integers), since Jira keys are strings like `KIN-123`.

### Task 1.4: Refactor skills that call `gh` directly

**Modify these skills** to use wrapper scripts instead of `gh` CLI:

|Skill                                     |File                                                     |Changes                                                                                                                                                                                                                                                                                 |
|------------------------------------------|---------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|`/explore`                                |`skills/explore/SKILL.md`                                |Step 5: replace `gh issue create` with `create-issue.sh`. Update the example command block.                                                                                                                                                                                             |
|`/process-pr`                             |`skills/process-pr/SKILL.md`                             |Replace all `gh pr` and `gh issue` calls with wrappers. Replace `gh pr merge` with `merge-mr.sh`. Replace `gh issue close` with `transition-issue.sh`. Update user-facing references from “PR” to “MR/PR” where appropriate.                                                            |
|`/handle-issues`                          |`skills/handle-issues/SKILL.md`                          |Step 2: replace `gh issue list` with `list-issues.sh`. Step 4: update manifest to use string issue IDs. Remove hardcoded agent references to `bulletproof-frontend-developer` and `laravel-backend-developer` — these are stack-specific and belong in adapted copies, not the template.|
|`/executing-plans`                        |`skills/executing-plans/SKILL.md`                        |Step 1: replace `gh issue view` with `read-issue.sh`.                                                                                                                                                                                                                                   |
|`/subagent-driven-development`            |`skills/subagent-driven-development/SKILL.md`            |Replace `gh issue view` with `read-issue.sh`.                                                                                                                                                                                                                                           |
|`/investigating-codebase-for-user-stories`|`skills/investigating-codebase-for-user-stories/SKILL.md`|Replace `gh issue create` with `create-issue.sh`.                                                                                                                                                                                                                                       |
|`/implement-issue`                        |`skills/implement-issue/SKILL.md`                        |Update monitoring examples to use wrapper output format.                                                                                                                                                                                                                                |

For each skill, the change pattern is the same: replace the direct `gh` command with the equivalent wrapper script call, keeping the same data flow.

### Task 1.5: Add BATS tests for platform wrappers

**Create:** `.claude/scripts/platform-test/` with BATS tests.

Test approach: mock the underlying CLI tools (`gh`, `glab`, `acli`) and verify that:

- Each wrapper correctly dispatches based on `TRACKER` / `GIT_HOST` config
- Output is normalised JSON in the expected shape
- Error cases (CLI not found, auth failure, rate limit) are handled
- String issue IDs work throughout (not just integers)

Minimum test coverage:

- `create-issue.sh` — GitHub mode, Jira mode, missing required args
- `read-issue.sh` — GitHub mode, Jira mode, issue not found
- `transition-issue.sh` — GitHub close, Jira transition with custom state
- `create-mr.sh` — GitHub PR, GitLab MR
- `merge-mr.sh` — squash/merge/rebase for both hosts
- `list-issues.sh` — GitHub with filters, Jira with JQL, Jira with auto-built JQL

-----

## Phase 2: Playwright E2E Testing Skill

**Goal:** Add first-class Playwright testing support as a core skill. Projects that don’t use Playwright can delete it during `/adapt`.

### Task 2.1: Create Playwright testing skill

**Create:** `.claude/skills/playwright-testing/SKILL.md`

Follow the pipeline’s own `/writing-skills` process: RED (baseline without skill) → GREEN (write skill) → REFACTOR (close loopholes).

```yaml
---
name: playwright-testing
description: Use when writing, reviewing, or debugging Playwright E2E tests. Use when converting manual test scripts to automated tests. Use when test failures involve browser interaction, page navigation, or UI assertions.
---
```

**Skill content must cover:**

**Page Object Model conventions:**

- One POM class per page or significant component
- Encapsulate selectors and actions in the POM
- POMs return new POM instances for navigation (e.g., `loginPage.login()` returns `DashboardPage`)
- Assertions live in test files, not POMs
- Constructor takes `page` fixture

Example:

```typescript
// pages/login.page.ts
export class LoginPage {
  constructor(private page: Page) {}

  async goto() { await this.page.goto('/login'); }
  async login(user: string, pass: string) {
    await this.page.getByLabel('Username').fill(user);
    await this.page.getByLabel('Password').fill(pass);
    await this.page.getByRole('button', { name: 'Log in' }).click();
    return new DashboardPage(this.page);
  }
}
```

**Selector strategy** (priority order):

1. `data-testid` attributes — most resilient to UI changes
1. Role-based: `getByRole('button', { name: 'Submit' })`
1. Label-based: `getByLabel('Email')`
1. Text-based: `getByText('Welcome')` — for content assertions
1. CSS selectors — last resort, document why in a comment
1. **Never** XPath

**Waiting patterns:**

- Prefer Playwright’s built-in auto-waiting (`click`, `fill`, `expect` all auto-wait)
- `waitForResponse(resp => resp.url().includes('/api/...'))` for API calls
- `expect(locator).toBeVisible()` — not manual `isVisible()` checks
- `page.waitForLoadState('networkidle')` — sparingly, only when genuinely needed
- **Anti-pattern:** `page.waitForTimeout()` — always replace with condition-based waiting. Reference the existing `systematic-debugging/condition-based-waiting.md` technique.

**Test data management:**

- Seed via API or database before tests, never via UI
- Each test sets up its own state — no test interdependence
- `test.beforeEach` for shared setup within a describe block
- Clean up in `test.afterEach` or `test.afterAll` where practical

**Parallel execution and isolation:**

- Tests run in isolated browser contexts by default — don’t fight this
- Avoid shared cookies, localStorage, or global state between tests
- `test.describe.serial` only when order genuinely matters (rare)

**Anti-patterns table:**

|Anti-pattern                           |Why it fails                    |Fix                                                                     |
|---------------------------------------|--------------------------------|------------------------------------------------------------------------|
|`page.waitForTimeout(5000)`            |Arbitrary delay, flaky in CI    |Use `waitForResponse`, `expect(...).toBeVisible()`, or condition polling|
|`.css-1a2b3c` selectors                |Break on any style change       |Use `data-testid` or role-based selectors                               |
|Test B depends on Test A               |Parallel execution breaks it    |Each test sets up its own state                                         |
|Assertions in page objects             |Hides test intent, hard to debug|POMs do actions, tests do assertions                                    |
|`page.$(selector)`                     |Doesn’t auto-wait               |Use `page.locator(selector)` or `getBy*` methods                        |
|Screenshot comparison without baselines|Fails on first run              |Use `toHaveScreenshot` with `--update-snapshots` for initial baseline   |

**Integration with TDD skill:**

- E2E tests follow the same RED-GREEN-REFACTOR cycle
- Write the failing E2E test first (RED) — verify it fails because the feature doesn’t exist
- Implement the feature (GREEN)
- Refactor (keep tests green)
- The TDD skill’s Iron Law applies: no feature code without a failing test first

**Quick reference table:**

|Pattern          |Example                                                                  |
|-----------------|-------------------------------------------------------------------------|
|Navigate         |`await page.goto('/dashboard')`                                          |
|Click button     |`await page.getByRole('button', { name: 'Save' }).click()`               |
|Fill input       |`await page.getByLabel('Email').fill('test@example.com')`                |
|Select dropdown  |`await page.getByLabel('Country').selectOption('AU')`                    |
|Assert visible   |`await expect(page.getByText('Success')).toBeVisible()`                  |
|Assert URL       |`await expect(page).toHaveURL(/\/dashboard/)`                            |
|Assert title     |`await expect(page).toHaveTitle(/Dashboard/)`                            |
|Wait for API     |`await page.waitForResponse(resp => resp.url().includes('/api/save'))`   |
|Screenshot       |`await expect(page).toHaveScreenshot('dashboard.png')`                   |
|Network intercept|`await page.route('**/api/slow', route => route.fulfill({ body: '{}' }))`|

### Task 2.2: Create Playwright test developer agent

**Create:** `.claude/agents/playwright-test-developer.md`

Follow the pipeline’s own `/writing-agents` process: research → codebase context → write → test.

```yaml
---
name: playwright-test-developer
description: Playwright E2E test specialist. Use for writing, reviewing, or debugging Playwright test specs, page objects, and test fixtures. Defers to project-specific agents for application logic.
model: sonnet
---
```

**Agent content:**

- **Persona:** Senior QA automation engineer specialising in Playwright. Deep knowledge of browser automation, test design, and CI integration.
- **Scope:** E2E test files (`*.spec.ts`, `*.test.ts` in e2e/tests directory), page objects, test fixtures, `playwright.config.ts`, test utilities.
- **Not in scope** (defer to project’s implementation agent): Application code, business logic, API implementation, database schema. This agent writes tests against the application, not the application itself.
- **Anti-patterns:** All items from the skill’s anti-patterns table, plus:
  - Testing implementation details rather than user-visible behaviour
  - Over-mocking (if you mock everything, you’re not testing the real system)
  - Ignoring CI differences (tests pass locally but fail in headless CI)
- **Key commands:**
  - `npx playwright test` — run all tests
  - `npx playwright test --ui` — interactive UI mode
  - `npx playwright test path/to/test.spec.ts` — run specific test
  - `npx playwright codegen URL` — record interactions
  - `npx playwright show-report` — view HTML report
  - `npx playwright test --update-snapshots` — update screenshot baselines
- **Coordination:** When dispatched from subagent-driven-development, expects acceptance criteria (maps to assertions), affected pages/flows (maps to page objects), and test data requirements (maps to beforeEach setup).

### Task 2.3: Modify `/explore` task generation for E2E

**Modify:** `.claude/skills/explore/SKILL.md`

In Step 4 (Generate Implementation Plan), add guidance after the existing task format specification:

```markdown
**E2E test tasks:**

When the issue affects user-facing flows and `TEST_E2E_CMD` is configured in `.claude/config/platform.sh`, include an E2E test task:

- [ ] `[playwright-test-developer]` **(S)** Write Playwright E2E test for [flow description]

E2E test tasks should:
- Reference specific pages/flows affected
- Include acceptance criteria that map directly to assertions
- Be sized S unless covering multiple complex flows
- Come after implementation tasks (the feature must exist before E2E tests run against it)
```

-----

## Phase 3: MCP Tool Integration

**Goal:** Formalise Context7 and Serena usage so agents use them consistently. Projects without these MCP servers can delete the skill during `/adapt`.

### Task 3.1: Create MCP tools reference skill

**Create:** `.claude/skills/mcp-tools/SKILL.md`

```yaml
---
name: mcp-tools
description: Use when you need framework documentation, structured code navigation, or are unsure which exploration tool to use. Reference for available MCP tools and when to prefer each.
---
```

**Content:**

```markdown
# MCP Tools Reference

## When to Use This Skill

Before exploring a codebase or looking up framework documentation, check which MCP tools are available and use the most efficient one.

## Available Tools

### Context7 — Framework & Library Documentation

**Use when:** You need API docs, usage patterns, or configuration reference for a framework or library.

**Workflow:**
1. `context7.resolve_library_id` — find the library by name
2. `context7.get_library_docs` — retrieve relevant documentation

**Prefer over web search** for framework APIs. Faster, more targeted, fewer tokens.

### Serena — Structured Code Navigation

**Use when:** You need to understand code structure — class hierarchies, method signatures, call graphs, file relationships.

**Prefer over Grep/Glob** when you need structural understanding, not just text matching.

### Grep / Glob — Text Search & File Discovery

**Use when:** You need to find text patterns across files or discover files by name/path.

## Decision Matrix

| Need | First choice | Fallback |
|---|---|---|
| Framework/library API docs | Context7 | Web search |
| Library usage patterns | Context7 | Web search |
| Class/method/call structure | Serena | Grep + manual reading |
| Text search across files | Grep | — |
| File discovery by name/path | Glob | — |
| Current events / release notes | Web search | — |

## Critical: Fully Qualified Tool Names

Always use the MCP server prefix to avoid "tool not found" errors:

- `context7.resolve_library_id` — not `resolve_library_id`
- `context7.get_library_docs` — not `get_library_docs`

## When Tools Are Not Available

If a tool call fails with "tool not found", fall back to the next option in the decision matrix. Do not retry the same tool. Note in your output that the MCP tool was unavailable.
```

### Task 3.2: Wire Context7 into `/explore`

**Modify:** `.claude/skills/explore/SKILL.md`

Replace the current Step 2 research guidance with:

```markdown
### Step 2: Research the Codebase

**Framework/library documentation (use Context7 first):**
- `context7.resolve_library_id` → `context7.get_library_docs` for framework API docs
- Fall back to web search only if Context7 doesn't have the library or is unavailable
- See `mcp-tools` skill for full decision matrix

**Code structure and patterns (use Serena for structural queries):**
- Use Serena for class hierarchies, method signatures, call graphs
- Use Grep/Glob for text-based file search and discovery

**Document findings:**
- Identify affected files, services, components
- Document current behaviour vs desired behaviour
- Note architectural patterns to follow
```

### Task 3.3: Wire MCP tools into agent research phases

**Modify:** `.claude/skills/writing-agents/SKILL.md`

In Step 1 (Research Domain Best Practices), add before the WebSearch instructions:

```markdown
**Check Context7 first** for framework-specific best practices:
1. `context7.resolve_library_id` for the project's framework
2. `context7.get_library_docs` for best practices, anti-patterns, common mistakes

Fall back to WebSearch for general patterns, recent developments, or topics Context7 doesn't cover.
```

### Task 3.4: Add MCP awareness to subagent implementer prompt

**Modify:** `.claude/skills/subagent-driven-development/implementer-prompt.md`

Add to the tools/context section:

```markdown
## Research Tools

Before implementing, use available tools to understand existing patterns:
- **Context7:** Framework/library API docs — check before making assumptions about APIs
- **Serena:** Code structure — understand class hierarchies and method relationships before adding new code
- **Grep/Glob:** Text search and file discovery

If a tool is unavailable (call fails), fall back to manual exploration. Do not block on missing tools.
```

-----

## Phase 4: Enhance `/adapting-claude-pipeline`

**Goal:** The adaptation skill handles platform configuration, E2E testing setup, and MCP availability as part of its brainstorming phase. This is the mechanism that makes everything project-specific.

### Task 4.1: Add platform configuration to brainstorming phase

**Modify:** `.claude/skills/adapting-claude-pipeline/SKILL.md`

In Phase 1 (Brainstorm), add these focus questions:

```markdown
**Platform & workflow:**
- **Issue tracker:** GitHub Issues or Jira? If Jira: project key, preferred CLI (acli recommended), workflow transitions (what are the states, what's the "done" transition name?)
- **Git host:** GitHub or GitLab? Merge strategy preference (squash/merge/rebase)?
- **CI/CD:** What runs in CI? How are tests triggered?
```

Add a new task to Phase 5 (Execute with Subagents):

```markdown
**Platform configuration task:**
Based on brainstorming answers, modify `.claude/config/platform.sh`:
- Set TRACKER, TRACKER_CLI, GIT_HOST, GIT_CLI
- Set JIRA_PROJECT, JIRA_DONE_TRANSITION, JIRA_IN_PROGRESS_TRANSITION if Jira
- Set MERGE_STYLE
- Set TEST_UNIT_CMD, TEST_E2E_CMD, LINT_CMD, FORMAT_CMD based on project stack
```

### Task 4.2: Add E2E testing to brainstorming phase

**Modify:** `.claude/skills/adapting-claude-pipeline/SKILL.md`

In Phase 1 (Brainstorm), add:

```markdown
**Testing:**
- **Unit tests:** What test runner? What command?
- **E2E tests:** Does the project have or need browser-based testing? If yes: Playwright already configured or needs setup? Base URL for test environment?
- **Manual QA:** Is there a manual testing process that could be automated with Playwright?
```

### Task 4.3: Add MCP tool detection to brainstorming phase

**Modify:** `.claude/skills/adapting-claude-pipeline/SKILL.md`

In Phase 1 (Brainstorm), add:

```markdown
**MCP tools:**
- **Context7:** Available? What frameworks/libraries should agents look up via Context7?
- **Serena:** Available? Useful for codebase navigation in this project?
- **Other MCP servers:** Any project-specific MCP integrations?
```

### Task 4.4: Update the adaptation inventory tables

**Modify:** `.claude/skills/adapting-claude-pipeline/SKILL.md`

The existing inventory tables reference specific stacks (Laravel, PHP). Update them to be stack-agnostic.

**Skills inventory — update/add entries:**

|Skill                 |Category        |Typical Decision                                               |
|----------------------|----------------|---------------------------------------------------------------|
|playwright-testing    |Domain (E2E)    |Keep if project has browser UI to test; delete for CLI/API-only|
|mcp-tools             |Reference (MCP) |Keep if using Context7/Serena; delete if no MCP servers        |
|write-docblocks       |Domain (PHP)    |Replace with language-specific doc skill, or delete            |
|bulletproof-frontend  |Domain (web/CSS)|Keep if web project with CSS focus; delete otherwise           |
|review-ui             |Domain (web/CSS)|Keep if web project; delete otherwise                          |
|ui-design-fundamentals|Domain (web/CSS)|Keep if web project; delete otherwise                          |

**Agents inventory — update/add entries:**

|Agent                         |Category        |Typical Decision                                 |
|------------------------------|----------------|-------------------------------------------------|
|playwright-test-developer     |Domain (E2E)    |Keep if keeping playwright-testing skill         |
|laravel-backend-developer     |Domain (Laravel)|Replace with project-specific developer agent    |
|bulletproof-frontend-developer|Domain (web)    |Replace or delete based on project frontend needs|
|code-simplifier               |Domain (PHP)    |Replace with language-specific version           |
|phpdoc-writer                 |Domain (PHP)    |Replace or delete                                |
|php-test-validator            |Domain (PHP)    |Replace with language-specific test validator    |

**Scripts — add platform wrappers section:**

```markdown
**Platform wrappers (`scripts/platform/`):**

| Script | Typical Decision |
|---|---|
| All platform wrapper scripts | Keep as-is — they are platform-agnostic. Just configure `config/platform.sh` during brainstorming. |
```

**Config — add section:**

```markdown
**Platform config (`config/platform.sh`):**

| Setting | Typical Decision |
|---|---|
| TRACKER / TRACKER_CLI | Set during brainstorming: github+gh or jira+acli |
| GIT_HOST / GIT_CLI | Set during brainstorming: github+gh or gitlab+glab |
| JIRA_PROJECT / transitions | Set if using Jira |
| MERGE_STYLE | Set during brainstorming |
| TEST_UNIT_CMD / TEST_E2E_CMD | Set based on project stack |
| LINT_CMD / FORMAT_CMD | Set based on project tooling |
```

-----

## Phase 5: Documentation & Cleanup

### Task 5.1: Update README.md

Add or update these sections:

**Platform configuration:**

- How the wrapper scripts work (dispatch based on `config/platform.sh`)
- How `/adapt` configures the platform during brainstorming
- Supported platforms: GitHub, GitLab (git hosting) + GitHub Issues, Jira via ACLI (issue tracking)
- ACLI setup requirements for Jira users

**E2E testing:**

- Playwright skill and agent overview
- How E2E tests integrate with the orchestrator (unit tests first, then E2E — fail fast)
- How `/explore` generates E2E test tasks when `TEST_E2E_CMD` is configured

**MCP tools:**

- Optional dependency on Context7 and Serena
- How the `mcp-tools` skill guides tool selection
- Graceful degradation when MCP servers aren’t available

### Task 5.2: Remove hardcoded stack references from core

Audit all core skills and agents for remaining references to specific stacks (Laravel, PHP, Blade, etc.) that should only exist in adapted copies, not the template.

**Files to audit:**

- All `.claude/skills/` — remove Laravel/PHP-specific examples unless the skill is inherently stack-specific (like `write-docblocks` which is already marked for replacement during adaptation)
- All `.claude/agents/` — shipped agents should be generic roles (reviewer, orchestrator, spec-reviewer). Stack-specific implementer agents (laravel-backend-developer, bulletproof-frontend-developer) should either be removed from the template or clearly marked as examples to be replaced during `/adapt`
- `.claude/settings.json` — remove PHP-specific formatter config, replace with comments pointing to `platform.sh`
- `.claude/hooks/post-pr-simplify.sh` — remove PHP-specific references
- `.claude/prompts/` — remove or generalise Laravel-specific prompt templates (frontend/audit-blade.md, etc.)

**Principle:** After this cleanup, the shipped `.claude/` folder works for any project. Stack-specific content is created during `/adapt`.

### Task 5.3: Update BATS test suite

**Modify:** `.claude/scripts/implement-issue-test/`

Update existing tests to account for:

- Platform wrapper calls instead of direct `gh` calls
- String issue IDs (not just integers)
- `TEST_UNIT_CMD` / `TEST_E2E_CMD` variables instead of hardcoded test commands
- The `run_tests()` function running both unit and E2E when configured

-----

## Execution Notes

### Phase order

Execute phases 1 → 2 → 3 → 4 → 5 sequentially. Each builds on the previous.

### Verification after each phase

**After Phase 1:** Run the BATS tests. Manually verify wrapper scripts with both `gh` and `acli`/`glab` if available. Verify the orchestrator can read an issue, create an MR, and transition an issue using wrappers.

**After Phase 2:** Write a sample Playwright test using the new skill. Verify the `playwright-test-developer` agent produces tests that follow the skill’s conventions. Verify the orchestrator’s `run_tests()` runs both unit and E2E tests when configured.

**After Phase 3:** Run `/explore` on a sample problem and verify it attempts Context7 before web search. Verify MCP tool calls use fully qualified names.

**After Phase 4:** Run `/adapting-claude-pipeline` on a fresh project and verify it asks about platform, E2E, and MCP during brainstorming. Verify `platform.sh` is populated correctly.

**After Phase 5:** Verify no core template files reference specific stacks. Run full BATS suite.

### Upstream contribution strategy

All five phases are designed as upstream contributions to stevegrocott/claude-pipeline:

- Phase 1: platform abstraction — structural improvement, benefits everyone
- Phase 2: Playwright skill + agent — broadly useful
- Phase 3: MCP tools reference — lightweight, broadly useful
- Phase 4: enhanced `/adapt` — improves the existing adaptation flow
- Phase 5: cleanup — removes tech-stack assumptions from the shipped template

### Per-project customisation (after upstream changes land)

When you run `/adapt` on each of your projects, the adapted `.claude/` folder will contain:

- `config/platform.sh` configured for your issue tracker and git host
- Project-specific agents created by `/adapt` (e.g., totara-developer, react-frontend-developer, python-developer)
- Project-specific skills if needed (e.g., manual-to-playwright for Totara QA migration)
- Anti-patterns and conventions captured via `/improvement-loop` over time

These per-project customisations live in each project’s `.claude/` folder and are not shared across projects.
