---
name: implement-issue
description: Use when given an issue number/key and base branch to implement end-to-end
argument-hint: "[issue-number] [base-branch]"
---

# Implement Issue

End-to-end issue implementation — reads plan from issue tracker, implements with quality gates.

**Announce at start:** "Using implement-issue to run orchestrator for #$ISSUE against $BRANCH"

**Arguments:**
- `$1` — Issue number or key (required, e.g., "123" or "KIN-123")
- `$2` — Base branch name (required)

## Invocation

The orchestrator is a long-running process (10-60 minutes) that spawns Claude CLI subprocesses for each stage. It must be launched in the background to avoid SIGPIPE — if the Bash tool's output buffer fills or a pipe truncates (e.g., `| head`), the orchestrator is killed silently mid-stage.

### Step 1: Launch in background

```bash
LOG_DIR="logs/implement-issue/issue-${ISSUE_NUMBER}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

nohup .claude/scripts/implement-issue-orchestrator.sh \
  --issue $ISSUE_NUMBER \
  --branch $BASE_BRANCH \
  > "$LOG_DIR/orchestrator-stdout.log" 2>&1 &

ORCH_PID=$!
echo "Orchestrator PID: $ORCH_PID"
```

With explicit agent override:

```bash
nohup .claude/scripts/implement-issue-orchestrator.sh \
  --issue $ISSUE_NUMBER \
  --branch $BASE_BRANCH \
  --agent bulletproof-frontend-developer \
  > "$LOG_DIR/orchestrator-stdout.log" 2>&1 &
```

### Step 2: Monitor via status.json

Poll `status.json` to track progress. Do NOT pipe the orchestrator through `head`, `tail`, or any command that truncates output — this sends SIGPIPE and kills the process.

```bash
# Quick status check
jq -c '{state, stage: .current_stage, task: .current_task, quality: .quality_iterations}' status.json

# Check if still running
kill -0 $ORCH_PID 2>/dev/null && echo "Running" || echo "Finished"

# Recent log lines
tail -5 logs/implement-issue/issue-*/orchestrator.log
```

### Step 3: Handle completion

When `status.json` shows `state: "completed"` or `state: "error"`:

```bash
jq '{state, current_stage, error, pr_url}' status.json
```

## Fallback: Manual implementation

If the orchestrator fails (missing CLI auth, rate limits, infrastructure issues), implement manually following the same quality gates:

1. **Parse issue** — read issue body via platform CLI or MCP, extract implementation tasks
2. **Create branch** — `git checkout -b feature/issue-$ISSUE_NUMBER $BASE_BRANCH`
3. **Implement** — execute each task, using the specified agent type as guidance
4. **Test** — run unit tests and E2E tests per `platform.sh` config
5. **Commit and push** — commit changes, push branch
6. **Create MR/PR** — via platform wrapper or CLI

This fallback ensures the issue gets implemented even when the orchestrator can't run.

## Stages

| Stage | Agent | Description |
|-------|-------|-------------|
| parse-issue | default | read issue body, extract implementation tasks |
| validate-plan | default | verify referenced files/patterns still exist |
| implement | per-task | execute each task from GH issue task list |
| task-review | spec-reviewer | verify task achieved goal |
| fix | per-task | address review findings |
| test | default | run test suite |
| review | code-reviewer | internal code review |
| pr | default | create/update PR |
| spec-review | spec-reviewer | verify PR achieves issue goals |
| code-review | code-reviewer | final code quality check |
| complete | default | post summary |

## Schemas

Located in `.claude/scripts/schemas/implement-issue-*.json`

## Logging

Logs written to `logs/implement-issue/issue-N-timestamp/`:
- `orchestrator.log` — main log
- `orchestrator-stdout.log` — raw stdout/stderr from nohup launch
- `stages/` — per-stage Claude output
- `context/` — parsed outputs (tasks.json, etc.)
- `status.json` — final status snapshot

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success, PR created and approved |
| 1 | Error during a stage |
| 2 | Max iterations exceeded |
| 3 | Configuration/argument error |

## Common Failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| Orchestrator dies immediately | SIGPIPE from piped output | Use `nohup ... &`, never pipe through `head`/`tail` |
| "unauthorized" from acli | CLI not authenticated | Run `acli jira auth login` |
| status.json stuck at "running" | Process killed externally | Check `kill -0 $PID`, restart if needed |
| Claude CLI rate limited | Too many API calls | Orchestrator handles retry automatically |

## Integration

Called by `handle-issues` via `batch-orchestrator.sh`.
