/**
 * Entry point for the SDK harness.
 *
 * Spawns a single stage session via the stage runner and prints the resulting
 * stage-result envelope (see plugins/pipeline-core/scripts/schemas/
 * stage-result.json) to stdout — the side-by-side SDK counterpart to the bash
 * orchestrator's run_stage. Inputs are taken from the environment so the
 * harness can be driven identically to the bash path:
 *
 *   STAGE_PROMPT   stage prompt text (required)
 *   STAGE_MODEL    model id (default: sonnet)
 *   STAGE_SCHEMA   path to the JSON Schema file (required)
 *   STAGE_TIMEOUT  per-stage budget in ms (default: 900000)
 *   CLAUDE_CLI     CLI executable (default: claude)
 */

import { createStageResult } from "./stage-result";
import { runStage } from "./stage-runner";

function emitErrorResult(raw: string): void {
  console.log(
    JSON.stringify(
      createStageResult({
        status: "error",
        error_kind: "structured_error",
        raw,
      }),
    ),
  );
  process.exitCode = 1;
}

async function main(): Promise<void> {
  const prompt = process.env.STAGE_PROMPT;
  const schemaPath = process.env.STAGE_SCHEMA;
  const model = process.env.STAGE_MODEL ?? "sonnet";
  const timeoutMs = Number(process.env.STAGE_TIMEOUT ?? 900_000);

  if (!prompt || !schemaPath) {
    emitErrorResult("sdk harness: STAGE_PROMPT and STAGE_SCHEMA are required");
    return;
  }

  const result = await runStage({
    prompt,
    model,
    schemaPath,
    timeoutMs,
  });

  console.log(JSON.stringify(result));
  if (result.status !== "success") process.exitCode = 1;
}

main().catch((err) => {
  emitErrorResult(
    `sdk harness: ${err instanceof Error ? err.message : String(err)}`,
  );
});
