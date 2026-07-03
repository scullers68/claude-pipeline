import test from "node:test";
import assert from "node:assert/strict";
import { promises as fsp } from "node:fs";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

import { runStateMachine } from "../src/state-machine";
import { StageResult, createStageResult } from "../src/stage-result";
import { RunStageOptions } from "../src/stage-runner";
import { STATUS_FILE_SCHEMA, readStatusFile } from "../src/status-file";
import { createAssertValid } from "./helpers";

const SCHEMA_PATH = path.resolve(
  process.cwd(),
  "..",
  "scripts",
  "schemas",
  "stage-result.json",
);
const FIXTURES_DIR = path.resolve(
  process.cwd(),
  "..",
  "..",
  "..",
  "tests",
  "implement-issue-test",
  "fixtures",
);

const assertStatusValid = createAssertValid(STATUS_FILE_SCHEMA);

/**
 * A mock CLI that stands in for `claude`: it maps the SDK_STAGE env var the
 * state machine sets per stage to one of the shared stage fixtures and prints
 * it, so the whole parse → implement → test → review → pr run is exercised
 * end-to-end over the real runStage/spawn path.
 */
async function writeMockCli(
  fixtureByStage: Record<string, string>,
): Promise<{ cliPath: string; cleanup: () => Promise<void> }> {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "state-machine-"));
  const cliPath = path.join(dir, "mock-claude");
  const script = `#!${process.execPath}
const fs = require("node:fs");
const path = require("node:path");
const map = ${JSON.stringify(fixtureByStage)};
const stage = process.env.SDK_STAGE || "";
const file = map[stage];
if (!file) { console.error("mock: no fixture for stage " + stage); process.exit(1); }
process.stdout.write(fs.readFileSync(path.join(${JSON.stringify(FIXTURES_DIR)}, file), "utf8"));
process.exit(0);
`;
  await fsp.writeFile(cliPath, script, { mode: 0o755 });
  return { cliPath, cleanup: () => fsp.rm(dir, { recursive: true, force: true }) };
}

async function withStatusPath<T>(
  fn: (statusPath: string) => Promise<T>,
): Promise<T> {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "sm-status-"));
  try {
    return await fn(path.join(dir, "status.json"));
  } finally {
    await fsp.rm(dir, { recursive: true, force: true });
  }
}

function baseOpts(statusPath: string) {
  return {
    issue: "123",
    baseBranch: "main",
    logDir: "/tmp/logs",
    statusPath,
    schemaPath: SCHEMA_PATH,
  };
}

test("mock-CLI end-to-end run over the shared fixtures ends state=success", async () => {
  const { cliPath, cleanup } = await writeMockCli({
    parse_issue: "setup-success.json",
    implement: "implement-success.json",
    test_loop: "test-passed.json",
    pr_review: "review-approved.json",
    pr: "pr-success.json",
  });
  try {
    await withStatusPath(async (statusPath) => {
      const status = await runStateMachine({ ...baseOpts(statusPath), cliPath });

      assert.equal(status.state, "success");

      // The persisted status.json is what the bash test-helper assertions read.
      const onDisk = await readStatusFile(statusPath);
      assertStatusValid(onDisk);
      assert.equal(onDisk.state, "success");
      assert.equal(onDisk.current_stage, "complete");
      for (const key of ["parse_issue", "implement", "test_loop", "pr_review", "pr", "complete"]) {
        assert.equal(onDisk.stages[key].status, "completed", `${key} should be completed`);
      }
      // parse_issue carried the branch + tasks through from setup-success.json.
      assert.equal(onDisk.branch, "feat/issue-123");
      assert.equal(onDisk.stages.implement.task_progress, "3/3");
      assert.equal(onDisk.stages.pr.pr_number, 456);
    });
  } finally {
    await cleanup();
  }
});

/** Builds an injected run() that replays a scripted result per stage. */
function scriptedRun(
  plan: Record<string, StageResult[]>,
): (opts: RunStageOptions) => Promise<StageResult> {
  const calls: Record<string, number> = {};
  return async (opts: RunStageOptions) => {
    const stage = String(opts.env?.SDK_STAGE ?? "");
    const queue = plan[stage] ?? [];
    const i = calls[stage] ?? 0;
    calls[stage] = i + 1;
    return queue[Math.min(i, queue.length - 1)];
  };
}

const ok = (result: string) =>
  createStageResult({ status: "success", output: { status: "success", result } });
const okParse = () =>
  createStageResult({
    status: "success",
    output: { status: "success", branch: "feat/x", tasks: [{ id: 1 }] },
  });

test("test loop retries failing tests within budget, then completes", async () => {
  await withStatusPath(async (statusPath) => {
    const run = scriptedRun({
      parse_issue: [okParse()],
      implement: [ok("done")],
      test_loop: [ok("failed"), ok("failed"), ok("passed")],
      pr_review: [ok("approved")],
      pr: [ok("created")],
    });

    const status = await runStateMachine({
      ...baseOpts(statusPath),
      budgets: { quality: 5, test: 7, prReview: 2 },
      run,
    });

    assert.equal(status.state, "success");
    assert.equal(status.test_iterations, 2);
    assert.equal(status.stages.test_loop.iteration, 2);
    assert.equal(status.stages.test_loop.status, "completed");
  });
});

test("review loop bails to state=failed when it exhausts the budget", async () => {
  await withStatusPath(async (statusPath) => {
    const run = scriptedRun({
      parse_issue: [okParse()],
      implement: [ok("done")],
      test_loop: [ok("passed")],
      pr_review: [ok("changes_requested")],
      pr: [ok("created")],
    });

    const status = await runStateMachine({
      ...baseOpts(statusPath),
      budgets: { quality: 5, test: 7, prReview: 2 },
      run,
    });

    assert.equal(status.state, "failed");
    assert.equal(status.current_stage, "pr_review");
    assert.equal(status.stages.pr_review.status, "failed");
    assert.equal(status.pr_review_iterations, 2);
    assert.equal(status.stages.pr.status, "pending");

    const onDisk = await readStatusFile(statusPath);
    assertStatusValid(onDisk);
    assert.equal(onDisk.state, "failed");
  });
});

test("an infrastructure error halts the run with state=failed", async () => {
  await withStatusPath(async (statusPath) => {
    const run = scriptedRun({
      parse_issue: [okParse()],
      implement: [
        createStageResult({ status: "error", error_kind: "timeout", output: null }),
      ],
    });

    const status = await runStateMachine({ ...baseOpts(statusPath), run });

    assert.equal(status.state, "failed");
    assert.equal(status.current_stage, "implement");
    assert.match(status.merge_blocked_reason ?? "", /timeout/);
  });
});
