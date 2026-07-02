/**
 * Status module: the SDK-side counterpart to the bash orchestrator's
 * STATUS_FILE management (implement-issue-orchestrator.sh, init_status()
 * and friends). status.json has no standalone schema file in the repo — its
 * shape is defined by that bash implementation, so STATUS_FILE_SCHEMA below
 * is this module's copy of that frozen contract. Keep both in step.
 */

import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import * as crypto from "node:crypto";

/** Stage keys initialized by the bash orchestrator's init_status(). */
export const STAGE_KEYS = [
  "parse_issue",
  "triage",
  "validate_plan",
  "implement",
  "quality_loop",
  "test_loop",
  "e2e_verify",
  "acceptance_test",
  "deploy_verify",
  "docs",
  "pr",
  "pr_review",
  "complete",
  "fast_path_implement",
  "fast_path_pr",
  "fast_path_merge",
] as const;

export interface StageEntry {
  status: string;
  started_at?: string | null;
  completed_at?: string | null;
  [extra: string]: unknown;
}

export interface Escalation {
  stage: string;
  from_model: string;
  to_model: string;
  reason: string;
}

export interface StatusFile {
  state: string;
  issue: string;
  base_branch: string;
  branch: string;
  current_stage: string;
  current_task: number | null;
  route: string | null;
  stages: Record<string, StageEntry>;
  tasks: unknown[];
  quality_iterations: number;
  test_iterations: number;
  pr_review_iterations: number;
  stage_started_at: string | null;
  last_update: string;
  log_dir: string;
  merge_blocked_reason: string | null;
  escalations: Escalation[];
}

/** JSON Schema (draft-07) for StatusFile — mirrors init_status()'s jq output. */
export const STATUS_FILE_SCHEMA = {
  $schema: "http://json-schema.org/draft-07/schema#",
  type: "object",
  description:
    "Real-time progress file written by an orchestrator (bash or SDK) for a single issue run",
  properties: {
    state: { type: "string" },
    issue: { type: "string" },
    base_branch: { type: "string" },
    branch: { type: "string" },
    current_stage: { type: "string" },
    current_task: { type: ["integer", "null"] },
    route: { type: ["string", "null"] },
    stages: {
      type: "object",
      additionalProperties: {
        type: "object",
        properties: {
          status: { type: "string" },
          started_at: { type: ["string", "null"] },
          completed_at: { type: ["string", "null"] },
        },
        required: ["status"],
        additionalProperties: true,
      },
    },
    tasks: { type: "array" },
    quality_iterations: { type: "integer", minimum: 0 },
    test_iterations: { type: "integer", minimum: 0 },
    pr_review_iterations: { type: "integer", minimum: 0 },
    stage_started_at: { type: ["string", "null"] },
    last_update: { type: "string" },
    log_dir: { type: "string" },
    merge_blocked_reason: { type: ["string", "null"] },
    escalations: {
      type: "array",
      items: {
        type: "object",
        properties: {
          stage: { type: "string" },
          from_model: { type: "string" },
          to_model: { type: "string" },
          reason: { type: "string" },
        },
        required: ["stage", "from_model", "to_model", "reason"],
      },
    },
  },
  required: [
    "state",
    "issue",
    "base_branch",
    "branch",
    "current_stage",
    "current_task",
    "route",
    "stages",
    "tasks",
    "quality_iterations",
    "test_iterations",
    "pr_review_iterations",
    "stage_started_at",
    "last_update",
    "log_dir",
    "merge_blocked_reason",
    "escalations",
  ],
  additionalProperties: false,
} as const;

function isoNow(): string {
  // jq's `now | todate` emits RFC3339 UTC with second precision, e.g.
  // "2026-07-03T12:00:00Z" — match that instead of Date#toISOString's
  // millisecond-precision output so SDK and bash timestamps are comparable.
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Mirrors init_status()'s jq filter: same keys, same defaults. */
export function createInitialStatus(params: {
  issue: string;
  baseBranch: string;
  logDir: string;
}): StatusFile {
  // Mirrors init_status()'s jq object literal exactly: only parse_issue,
  // triage, and validate_plan get started_at/completed_at up front. The
  // other stages gain those keys later, when set_stage_started() /
  // set_stage_completed() first touch them.
  const stages: Record<string, StageEntry> = {
    parse_issue: { status: "pending", started_at: null, completed_at: null },
    triage: {
      status: "pending",
      started_at: null,
      completed_at: null,
      route: null,
      confidence: null,
      disqualifying_criterion: null,
    },
    validate_plan: { status: "pending", started_at: null, completed_at: null },
    implement: { status: "pending", task_progress: "0/0" },
    quality_loop: { status: "pending", iteration: 0 },
    test_loop: { status: "pending", iteration: 0 },
    e2e_verify: { status: "pending" },
    acceptance_test: { status: "pending" },
    deploy_verify: { status: "pending" },
    docs: { status: "pending" },
    pr: { status: "pending" },
    pr_review: { status: "pending", iteration: 0 },
    complete: { status: "pending" },
    fast_path_implement: { status: "pending" },
    fast_path_pr: { status: "pending" },
    fast_path_merge: { status: "pending" },
  };

  return {
    state: "initializing",
    issue: params.issue,
    base_branch: params.baseBranch,
    branch: "",
    current_stage: "parse_issue",
    current_task: null,
    route: null,
    stages,
    tasks: [],
    quality_iterations: 0,
    test_iterations: 0,
    pr_review_iterations: 0,
    stage_started_at: null,
    last_update: isoNow(),
    log_dir: params.logDir,
    merge_blocked_reason: null,
    escalations: [],
  };
}

/**
 * Atomically writes status.json: serialize to a sibling temp file, then
 * rename over the destination, mirroring the bash orchestrator's
 * "$STATUS_FILE.tmp" && mv pattern so readers never see a partial write.
 */
export async function writeStatusFile(
  filePath: string,
  status: StatusFile,
): Promise<void> {
  const dir = path.dirname(filePath);
  const tmpPath = path.join(
    dir,
    `.${path.basename(filePath)}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`,
  );

  await fs.writeFile(tmpPath, JSON.stringify(status, null, 2) + os.EOL, "utf8");
  await fs.rename(tmpPath, filePath);
}

export async function readStatusFile(filePath: string): Promise<StatusFile> {
  const raw = await fs.readFile(filePath, "utf8");
  return JSON.parse(raw) as StatusFile;
}
