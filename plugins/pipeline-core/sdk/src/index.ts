/**
 * Entry point for the SDK harness — the target of ORCHESTRATOR_SDK_ENTRY
 * (platform.sh), invoked when ORCHESTRATOR_ENGINE=sdk.
 *
 * Two modes, selected by the environment so the harness is driven identically
 * to the bash path:
 *
 * 1. Orchestrator mode (ISSUE set) — runs the single-issue state machine
 *    (parse → implement → test → review → pr), writing status.json per stage
 *    transition. Inputs:
 *
 *      ISSUE          issue number/key (required; selects this mode)
 *      BASE_BRANCH    target branch (default: main)
 *      LOG_DIR        run log directory recorded in status.json (default: .)
 *      STATUS_FILE    status.json path (default: status.json)
 *      STAGE_SCHEMA   stage-result schema path (default: bundled schema)
 *      STAGE_MODEL    model id (default: sonnet)
 *      STAGE_TIMEOUT  per-stage budget in ms (default: 900000)
 *      CLAUDE_CLI     CLI executable (default: claude)
 *
 * 2. Single-stage mode (STAGE_PROMPT + STAGE_SCHEMA) — spawns one stage session
 *    and prints its stage-result envelope. Inputs: STAGE_PROMPT, STAGE_SCHEMA,
 *    STAGE_MODEL, STAGE_TIMEOUT, CLAUDE_CLI.
 */

import * as path from "node:path";

import { createStageResult } from "./stage-result";
import { runStage } from "./stage-runner";
import { runStateMachine } from "./state-machine";

/** stage-result.json, bundled two levels up from the compiled dist/ entry. */
const DEFAULT_SCHEMA = path.resolve(
  __dirname,
  "..",
  "..",
  "scripts",
  "schemas",
  "stage-result.json",
);

function logErrorResult(raw: string): void {
  console.log(
    JSON.stringify(
      createStageResult({
        status: "error",
        error_kind: "structured_error",
        raw,
      }),
    ),
  );
}

async function runOrchestrator(issue: string): Promise<void> {
  const status = await runStateMachine({
    issue,
    baseBranch: process.env.BASE_BRANCH ?? "main",
    logDir: process.env.LOG_DIR ?? ".",
    statusPath: process.env.STATUS_FILE ?? "status.json",
    schemaPath: process.env.STAGE_SCHEMA ?? DEFAULT_SCHEMA,
    cliPath: process.env.CLAUDE_CLI,
    model: process.env.STAGE_MODEL ?? "sonnet",
    stageTimeoutMs: Number(process.env.STAGE_TIMEOUT ?? 900_000),
  });

  console.log(JSON.stringify({ state: status.state, issue: status.issue }));
  if (status.state !== "success") process.exitCode = 1;
}

async function runSingleStage(): Promise<void> {
  const prompt = process.env.STAGE_PROMPT;
  const schemaPath = process.env.STAGE_SCHEMA;
  const model = process.env.STAGE_MODEL ?? "sonnet";
  const timeoutMs = Number(process.env.STAGE_TIMEOUT ?? 900_000);

  if (!prompt || !schemaPath) {
    logErrorResult(
      "sdk harness: set ISSUE (orchestrator mode) or STAGE_PROMPT + STAGE_SCHEMA (single-stage mode)",
    );
    process.exitCode = 1;
    return;
  }

  const result = await runStage({ prompt, model, schemaPath, timeoutMs });

  console.log(JSON.stringify(result));
  if (result.status !== "success") process.exitCode = 1;
}

async function main(): Promise<void> {
  const issue = process.env.ISSUE;
  if (issue) {
    await runOrchestrator(issue);
    return;
  }
  await runSingleStage();
}

main().catch((err) => {
  logErrorResult(
    `sdk harness: ${err instanceof Error ? err.message : String(err)}`,
  );
  process.exitCode = 1;
});
