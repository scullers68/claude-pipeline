/**
 * Single-issue state machine: the SDK-harness counterpart to the bash
 * orchestrator's top-level stage loop (implement-issue-orchestrator.sh). It
 * drives one issue through parse → implement → test → review → pr, updating
 * status.json on every stage transition, and honours the same iteration
 * budgets the bash engine reads from platform.sh (see config.ts).
 *
 * Each stage is a real stage session spawned through runStage, so under a mock
 * CLI the whole run is exercised end-to-end. The `run` seam lets tests inject a
 * stand-in, but the default is the production runStage — nothing here knows it
 * is being mocked.
 *
 * Scope note: this is the happy-path spine plus the two budgeted retry loops
 * (test, review). Infrastructure failures (a non-success stage envelope) halt
 * the run with state=failed rather than threading the decide-*.sh retry policy
 * through every stage — that richer supervision stays in policy-bridge.ts and
 * the stage runner, and can be wired in as the harness matures.
 */

import { RunStageOptions, runStage } from "./stage-runner";
import { StageResult } from "./stage-result";
import { IterationBudgets, loadBudgets } from "./config";
import {
  StatusFile,
  createInitialStatus,
  isoNow,
  writeStatusFile,
} from "./status-file";

export interface StateMachineOptions {
  /** Issue number/key being implemented. */
  issue: string;
  /** Branch the work targets (status.base_branch). */
  baseBranch: string;
  /** Run log directory recorded in status.json. */
  logDir: string;
  /** Where status.json is written and atomically updated per transition. */
  statusPath: string;
  /** JSON Schema file every stage session validates structured output against. */
  schemaPath: string;
  /** CLI executable; forwarded to runStage (defaults to $CLAUDE_CLI, "claude"). */
  cliPath?: string;
  /** Model id handed to each stage session. */
  model?: string;
  /** Per-stage wall-clock budget in ms. */
  stageTimeoutMs?: number;
  /** Iteration budgets; defaults to loadBudgets(env). */
  budgets?: IterationBudgets;
  /** Base environment for spawned stages; SDK_STAGE is added per stage. */
  env?: NodeJS.ProcessEnv;
  /** Injection seam for tests; defaults to the real runStage. */
  run?: (opts: RunStageOptions) => Promise<StageResult>;
}

/** Structured-output shape the stage fixtures expose to the state machine. */
interface StageOutput {
  result?: string;
  branch?: string;
  tasks?: unknown[];
  pr_number?: number;
  pr_url?: string;
  [extra: string]: unknown;
}

function output(result: StageResult): StageOutput {
  return (result.output as StageOutput) ?? {};
}

export async function runStateMachine(
  opts: StateMachineOptions,
): Promise<StatusFile> {
  const run = opts.run ?? runStage;
  const budgets = opts.budgets ?? loadBudgets(opts.env);
  const model = opts.model ?? "sonnet";
  const timeoutMs = opts.stageTimeoutMs ?? 900_000;

  const status = createInitialStatus({
    issue: opts.issue,
    baseBranch: opts.baseBranch,
    logDir: opts.logDir,
  });

  const persist = async (): Promise<void> => {
    status.last_update = isoNow();
    await writeStatusFile(opts.statusPath, status);
  };

  const beginStage = async (key: string): Promise<void> => {
    const now = isoNow();
    status.current_stage = key;
    status.stage_started_at = now;
    status.stages[key] = {
      ...status.stages[key],
      status: "in_progress",
      started_at: now,
    };
    await persist();
  };

  const completeStage = async (
    key: string,
    extra: Record<string, unknown> = {},
  ): Promise<void> => {
    status.stages[key] = {
      ...status.stages[key],
      ...extra,
      status: "completed",
      completed_at: isoNow(),
    };
    await persist();
  };

  const failRun = async (
    key: string,
    reason: string,
  ): Promise<StatusFile> => {
    status.state = "failed";
    status.current_stage = key;
    status.merge_blocked_reason = reason;
    status.stages[key] = {
      ...status.stages[key],
      status: "failed",
      completed_at: isoNow(),
    };
    await persist();
    return status;
  };

  const runStageFor = (stageName: string, prompt: string): Promise<StageResult> =>
    run({
      prompt,
      model,
      schemaPath: opts.schemaPath,
      timeoutMs,
      cliPath: opts.cliPath,
      env: { ...(opts.env ?? process.env), SDK_STAGE: stageName },
    });

  status.state = "running";
  await persist();

  // ── parse ────────────────────────────────────────────────────────────────
  await beginStage("parse_issue");
  let result = await runStageFor("parse_issue", `Parse issue #${opts.issue}`);
  if (result.status !== "success") {
    return failRun("parse_issue", `parse failed: ${result.error_kind}`);
  }
  const parsed = output(result);
  if (typeof parsed.branch === "string") status.branch = parsed.branch;
  if (Array.isArray(parsed.tasks)) status.tasks = parsed.tasks;
  await completeStage("parse_issue");

  // ── implement ──────────────────────────────────────────────────────────────
  await beginStage("implement");
  result = await runStageFor("implement", `Implement issue #${opts.issue}`);
  if (result.status !== "success") {
    return failRun("implement", `implement failed: ${result.error_kind}`);
  }
  const taskCount = status.tasks.length;
  await completeStage("implement", { task_progress: `${taskCount}/${taskCount}` });

  // ── test loop ──────────────────────────────────────────────────────────────
  await beginStage("test_loop");
  while (true) {
    result = await runStageFor("test_loop", `Run tests for issue #${opts.issue}`);
    if (result.status !== "success") {
      return failRun("test_loop", `test stage failed: ${result.error_kind}`);
    }
    if (output(result).result === "passed") break;

    status.test_iterations += 1;
    status.stages.test_loop = {
      ...status.stages.test_loop,
      iteration: status.test_iterations,
    };
    if (status.test_iterations >= budgets.test) {
      return failRun(
        "test_loop",
        `tests still failing after ${budgets.test} iterations`,
      );
    }
    await persist();
  }
  await completeStage("test_loop", { iteration: status.test_iterations });

  // ── review loop ────────────────────────────────────────────────────────────
  // pr_review models the review gate that precedes PR creation in the issue's
  // parse → implement → test → review → pr sequence.
  await beginStage("pr_review");
  while (true) {
    result = await runStageFor("pr_review", `Review changes for issue #${opts.issue}`);
    if (result.status !== "success") {
      return failRun("pr_review", `review stage failed: ${result.error_kind}`);
    }
    if (output(result).result === "approved") break;

    status.pr_review_iterations += 1;
    status.stages.pr_review = {
      ...status.stages.pr_review,
      iteration: status.pr_review_iterations,
    };
    if (status.pr_review_iterations >= budgets.prReview) {
      return failRun(
        "pr_review",
        `review still requesting changes after ${budgets.prReview} iterations`,
      );
    }
    await persist();
  }
  await completeStage("pr_review", { iteration: status.pr_review_iterations });

  // ── pr ─────────────────────────────────────────────────────────────────────
  await beginStage("pr");
  result = await runStageFor("pr", `Open PR for issue #${opts.issue}`);
  if (result.status !== "success") {
    return failRun("pr", `pr failed: ${result.error_kind}`);
  }
  const pr = output(result);
  await completeStage("pr", { pr_number: pr.pr_number, pr_url: pr.pr_url });

  // ── done ───────────────────────────────────────────────────────────────────
  await beginStage("complete");
  status.state = "success";
  await completeStage("complete");

  return status;
}
