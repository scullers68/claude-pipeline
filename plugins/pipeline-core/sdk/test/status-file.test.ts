import test from "node:test";
import assert from "node:assert/strict";
import { promises as fsp } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { execFileSync } from "node:child_process";

import {
  STAGE_KEYS,
  STATUS_FILE_SCHEMA,
  createInitialStatus,
  writeStatusFile,
  readStatusFile,
  type StatusFile,
} from "../src/status-file";
import { createAssertValid } from "./helpers";

const assertValid = createAssertValid(STATUS_FILE_SCHEMA);
const validate = (assertValid as any).validator;

/**
 * Produces a status.json fixture with jq, using the identical filter the
 * bash orchestrator's init_status() runs (implement-issue-orchestrator.sh).
 * This is real bash/jq output, not a TypeScript re-implementation, so it
 * catches drift between the two contracts rather than just agreeing with
 * itself.
 */
function bashProducedStatusFixture(params: {
  issue: string;
  baseBranch: string;
  logDir: string;
}): StatusFile {
  const filter = `{
        state: $state,
        issue: $issue,
        base_branch: $base_branch,
        branch: $branch,
        current_stage: $current_stage,
        current_task: $current_task,
        route: null,
        stages: {
            parse_issue: {status: "pending", started_at: null, completed_at: null},
            triage: {status: "pending", started_at: null, completed_at: null,
                     route: null, confidence: null, disqualifying_criterion: null},
            validate_plan: {status: "pending", started_at: null, completed_at: null},
            implement: {status: "pending", task_progress: "0/0"},
            quality_loop: {status: "pending", iteration: 0},
            test_loop: {status: "pending", iteration: 0},
            e2e_verify: {status: "pending"},
            acceptance_test: {status: "pending"},
            deploy_verify: {status: "pending"},
            docs: {status: "pending"},
            pr: {status: "pending"},
            pr_review: {status: "pending", iteration: 0},
            complete: {status: "pending"},
            fast_path_implement: {status: "pending"},
            fast_path_pr: {status: "pending"},
            fast_path_merge: {status: "pending"}
        },
        tasks: [],
        quality_iterations: 0,
        test_iterations: 0,
        pr_review_iterations: 0,
        stage_started_at: null,
        last_update: (now | todate),
        log_dir: $log_dir,
        merge_blocked_reason: null,
        escalations: []
    }`;

  const stdout = execFileSync(
    "jq",
    [
      "-n",
      "--arg", "state", "initializing",
      "--arg", "issue", params.issue,
      "--arg", "base_branch", params.baseBranch,
      "--arg", "branch", "",
      "--arg", "current_stage", "parse_issue",
      "--argjson", "current_task", "null",
      "--arg", "log_dir", params.logDir,
      filter,
    ],
    { encoding: "utf8" },
  );

  return JSON.parse(stdout) as StatusFile;
}

test("a bash-produced status.json fixture satisfies STATUS_FILE_SCHEMA", () => {
  const fixture = bashProducedStatusFixture({
    issue: "11",
    baseBranch: "main",
    logDir: "/tmp/logs/issue-11",
  });
  assertValid(fixture);
  assert.equal(fixture.state, "initializing");
  assert.equal(fixture.issue, "11");
  assert.deepEqual(Object.keys(fixture.stages).sort(), [...STAGE_KEYS].sort());
});

test("createInitialStatus produces the same shape as the bash-produced fixture", () => {
  const params = { issue: "11", baseBranch: "main", logDir: "/tmp/logs/issue-11" };
  const fixture = bashProducedStatusFixture(params);
  const sdkStatus = createInitialStatus(params);

  assertValid(sdkStatus);

  // last_update is a live timestamp on both sides — compare everything else.
  const { last_update: _fixtureUpdate, ...fixtureRest } = fixture;
  const { last_update: _sdkUpdate, ...sdkRest } = sdkStatus;
  assert.deepEqual(sdkRest, fixtureRest);

  assert.deepEqual(Object.keys(sdkStatus).sort(), Object.keys(fixture).sort());
  assert.deepEqual(Object.keys(sdkStatus.stages).sort(), Object.keys(fixture.stages).sort());
});

test("a status.json missing a required top-level field fails validation", () => {
  const status = createInitialStatus({ issue: "11", baseBranch: "main", logDir: "/tmp" });
  const { log_dir: _dropped, ...withoutLogDir } = status;
  assert.equal(validate(withoutLogDir), false);
});

test("a status.json with an unknown top-level field fails validation", () => {
  const status = createInitialStatus({ issue: "11", baseBranch: "main", logDir: "/tmp" });
  assert.equal(validate({ ...status, unexpected_field: true }), false);
});

test("writeStatusFile atomically writes a schema-valid file", async () => {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "status-file-"));
  const filePath = path.join(dir, "status.json");
  const status = createInitialStatus({ issue: "11", baseBranch: "main", logDir: dir });

  await writeStatusFile(filePath, status);

  const written = await readStatusFile(filePath);
  assertValid(written);
  assert.deepEqual(written, status);

  await fsp.rm(dir, { recursive: true, force: true });
});

test("writeStatusFile overwrites in place without ever exposing a truncated file", async () => {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "status-file-"));
  const filePath = path.join(dir, "status.json");

  const initial = createInitialStatus({ issue: "11", baseBranch: "main", logDir: dir });
  await writeStatusFile(filePath, initial);

  const updated: StatusFile = {
    ...initial,
    state: "running",
    current_stage: "triage",
    stages: {
      ...initial.stages,
      triage: { ...initial.stages.triage, status: "in_progress" },
    },
  };
  await writeStatusFile(filePath, updated);

  const written = await readStatusFile(filePath);
  assertValid(written);
  assert.equal(written.state, "running");
  assert.equal(written.stages.triage.status, "in_progress");

  await fsp.rm(dir, { recursive: true, force: true });
});
