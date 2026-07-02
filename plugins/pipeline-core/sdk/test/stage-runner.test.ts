import test from "node:test";
import assert from "node:assert/strict";
import { promises as fsp } from "node:fs";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

import { runStage } from "../src/stage-runner";
import { createAssertValid } from "./helpers";

const SCHEMA_PATH = path.resolve(
  process.cwd(),
  "..",
  "scripts",
  "schemas",
  "stage-result.json",
);

const schema = JSON.parse(fs.readFileSync(SCHEMA_PATH, "utf8"));
const assertValid = createAssertValid(schema);

/**
 * Writes an executable mock CLI that stands in for the real `claude` binary.
 * Its behaviour is selected by the MOCK_MODE env var passed through by runStage.
 */
async function writeMockCli(): Promise<{ cliPath: string; cleanup: () => Promise<void> }> {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "stage-runner-"));
  const cliPath = path.join(dir, "mock-claude");
  const script = `#!${process.execPath}
const mode = process.env.MOCK_MODE || "success";
if (mode === "hang") {
  // Never exit; the runner's per-stage timeout must abort us.
  setInterval(() => {}, 1000);
} else if (mode === "success") {
  process.stdout.write(JSON.stringify({
    subtype: "success",
    is_error: false,
    model: "sonnet",
    structured_output: { status: "success", summary: "did the thing" },
    result: "did the thing",
  }));
  process.exit(0);
} else if (mode === "rate_limit") {
  process.stdout.write(JSON.stringify({
    is_error: true,
    subtype: "error",
    result: "Error: HTTP 429 too many requests, rate limit exceeded",
  }));
  process.exit(1);
} else if (mode === "no_output") {
  process.stdout.write("this is not json at all");
  process.exit(1);
} else if (mode === "max_turns") {
  process.stdout.write(JSON.stringify({
    subtype: "error_max_turns",
    is_error: true,
    result: "hit max turns",
  }));
  process.exit(1);
} else if (mode === "structured_error") {
  process.stdout.write(JSON.stringify({
    is_error: false,
    structured_output: { status: "error", message: "boom" },
  }));
  process.exit(0);
} else if (mode === "permission_denied") {
  process.stdout.write(JSON.stringify({
    is_error: false,
    permission_denials: [{ tool_name: "Bash" }],
    structured_output: { status: "error", message: "blocked" },
  }));
  process.exit(0);
}
`;
  await fsp.writeFile(cliPath, script, { mode: 0o755 });
  return {
    cliPath,
    cleanup: () => fsp.rm(dir, { recursive: true, force: true }),
  };
}

function baseOpts(cliPath: string, mode: string) {
  return {
    prompt: "do the thing",
    model: "sonnet",
    schemaPath: SCHEMA_PATH,
    cliPath,
    timeoutMs: 10_000,
    env: { ...process.env, MOCK_MODE: mode },
  };
}

test("a clean stage yields a schema-valid success envelope", async () => {
  const { cliPath, cleanup } = await writeMockCli();
  try {
    const result = await runStage(baseOpts(cliPath, "success"));

    assertValid(result);
    assert.equal(result.status, "success");
    assert.equal(result.error_kind, null);
    assert.deepEqual(result.output, { status: "success", summary: "did the thing" });
    assert.ok(result.raw.length > 0, "raw stdout is captured");
    assert.equal(result.model, "sonnet");
    assert.ok(result.elapsed_ms >= 0);
  } finally {
    await cleanup();
  }
});

test("a hung stage yields error_kind=timeout within budget", async () => {
  const { cliPath, cleanup } = await writeMockCli();
  try {
    const budgetMs = 400;
    const result = await runStage({ ...baseOpts(cliPath, "hang"), timeoutMs: budgetMs });

    assertValid(result);
    assert.equal(result.status, "error");
    assert.equal(result.error_kind, "timeout");
    assert.equal(result.output, null);
    // Returned close to the budget, not after the mock's 1000s sleep.
    assert.ok(
      result.elapsed_ms < budgetMs + 5_000,
      `expected to return within budget, took ${result.elapsed_ms}ms`,
    );
  } finally {
    await cleanup();
  }
});

test("a missing schema file yields error_kind=schema_not_found without spawning", async () => {
  const { cliPath, cleanup } = await writeMockCli();
  try {
    const result = await runStage({
      ...baseOpts(cliPath, "success"),
      schemaPath: path.join(os.tmpdir(), "does-not-exist-schema.json"),
    });

    assertValid(result);
    assert.equal(result.status, "error");
    assert.equal(result.error_kind, "schema_not_found");
  } finally {
    await cleanup();
  }
});

test("a rate-limited stage maps to error_kind=rate_limit", async () => {
  const { cliPath, cleanup } = await writeMockCli();
  try {
    const result = await runStage(baseOpts(cliPath, "rate_limit"));
    assertValid(result);
    assert.equal(result.status, "error");
    assert.equal(result.error_kind, "rate_limit");
  } finally {
    await cleanup();
  }
});

test("unparseable output maps to error_kind=no_structured_output", async () => {
  const { cliPath, cleanup } = await writeMockCli();
  try {
    const result = await runStage(baseOpts(cliPath, "no_output"));
    assertValid(result);
    assert.equal(result.status, "error");
    assert.equal(result.error_kind, "no_structured_output");
  } finally {
    await cleanup();
  }
});

test("max-turns exhaustion maps to error_kind=max_turns_exhausted", async () => {
  const { cliPath, cleanup } = await writeMockCli();
  try {
    const result = await runStage(baseOpts(cliPath, "max_turns"));
    assertValid(result);
    assert.equal(result.error_kind, "max_turns_exhausted");
  } finally {
    await cleanup();
  }
});

test("max-turns at the model ceiling maps to error_kind=max_turns_exhausted_at_ceiling", async () => {
  const { cliPath, cleanup } = await writeMockCli();
  try {
    const result = await runStage({ ...baseOpts(cliPath, "max_turns"), atModelCeiling: true });
    assertValid(result);
    assert.equal(result.error_kind, "max_turns_exhausted_at_ceiling");
  } finally {
    await cleanup();
  }
});

test("a structured error with no denials maps to error_kind=structured_error", async () => {
  const { cliPath, cleanup } = await writeMockCli();
  try {
    const result = await runStage(baseOpts(cliPath, "structured_error"));
    assertValid(result);
    assert.equal(result.error_kind, "structured_error");
  } finally {
    await cleanup();
  }
});

test("a structured error with a permission denial maps to error_kind=permission_denied", async () => {
  const { cliPath, cleanup } = await writeMockCli();
  try {
    const result = await runStage(baseOpts(cliPath, "permission_denied"));
    assertValid(result);
    assert.equal(result.error_kind, "permission_denied");
    assert.deepEqual(result.denials, ["Bash"]);
  } finally {
    await cleanup();
  }
});

test("an external abort signal cancels the stage and rejects", async () => {
  const { cliPath, cleanup } = await writeMockCli();
  try {
    const controller = new AbortController();
    const pending = runStage({
      ...baseOpts(cliPath, "hang"),
      timeoutMs: 30_000,
      signal: controller.signal,
    });
    setTimeout(() => controller.abort(), 100);
    await assert.rejects(pending, (err: Error) => err.name === "AbortError");
  } finally {
    await cleanup();
  }
});
