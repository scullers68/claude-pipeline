/**
 * Fixture-driven parity tests for the policy bridge.
 *
 * Reuses the shared skill fixtures under
 * tests/implement-issue-test/fixtures/{retry-policy,escalation-policy,
 * model-fallback} and asserts that the TypeScript decision trees in
 * src/policy-bridge.ts produce output identical, byte-for-byte, to the bash
 * decide-* backends run over the same inputs with their `bash` backend. Each
 * fixture is also pinned against its golden.manifest.txt entry where present.
 *
 * The bash scripts are the source of truth: they are invoked live per fixture
 * (RETRY_POLICY_BACKEND / ESCALATION_POLICY_BACKEND / MODEL_FALLBACK_BACKEND =
 * bash) so any drift between the TS and bash decision trees fails the suite.
 * Requires bash and jq on PATH, matching the repo's bats golden suites.
 */

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

import {
  decideAction,
  decideModelFallback,
  decideRetry,
  type EscalationHistoryEntry,
  type RetryHistoryEntry,
} from "../src/policy-bridge";

const REPO_ROOT = path.resolve(process.cwd(), "..", "..", "..");
const FIXTURES = path.join(REPO_ROOT, "tests", "implement-issue-test", "fixtures");
const SCRIPTS = path.join(REPO_ROOT, "plugins", "pipeline-core", "scripts");

/** Run a decide-* script over one input, returning its stdout sans trailing newline. */
function runBash(script: string, args: string[], backendVar: string): string {
  const out = execFileSync("bash", [path.join(SCRIPTS, script), ...args], {
    encoding: "utf8",
    env: { ...process.env, [backendVar]: "bash" },
  });
  return out.replace(/\n+$/, "");
}

function readJson(file: string): any {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

/** Parse a golden.manifest.txt into name → {action, reasonGlob}. */
function readManifest(policy: string): Map<string, { action: string; reasonGlob: string }> {
  const file = path.join(FIXTURES, policy, "golden.manifest.txt");
  const map = new Map<string, { action: string; reasonGlob: string }>();
  if (!fs.existsSync(file)) return map;
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const [name, action, reasonGlob = "*"] = trimmed.split("|");
    map.set(name, { action, reasonGlob });
  }
  return map;
}

/** Match a value against a manifest glob (only `*` is special). */
function globMatches(glob: string, value: string): boolean {
  const re = new RegExp(
    "^" + glob.split("*").map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$",
  );
  return re.test(value);
}

/** Fixture basenames in a policy dir, excluding the manifest. */
function fixtureNames(policy: string): string[] {
  return fs
    .readdirSync(path.join(FIXTURES, policy))
    .filter((f) => f.endsWith(".json"))
    .map((f) => f.replace(/\.json$/, ""))
    .sort();
}

/** Assert a bridge decision matches its manifest entry, if one exists. */
function assertManifest(
  manifest: Map<string, { action: string; reasonGlob: string }>,
  name: string,
  decision: string,
): void {
  const entry = manifest.get(name);
  if (!entry) return;
  const parsed = JSON.parse(decision);
  assert.equal(parsed.action, entry.action, `${name}: manifest action`);
  assert.ok(
    globMatches(entry.reasonGlob, String(parsed.reason)),
    `${name}: reason ${JSON.stringify(parsed.reason)} !~ ${entry.reasonGlob}`,
  );
}

// ===========================================================================
// retry-policy → decide-retry.sh → decideRetry
// ===========================================================================

{
  const manifest = readManifest("retry-policy");
  for (const name of fixtureNames("retry-policy")) {
    test(`retry-policy/${name}: bridge matches bash golden byte-for-byte`, () => {
      const fx = readJson(path.join(FIXTURES, "retry-policy", `${name}.json`));
      const stageResult = fx.stage_result;
      const retryCount: number = fx.retry_count;
      const errorHistory: RetryHistoryEntry[] = fx.error_history ?? [];

      const bridge = decideRetry(stageResult, retryCount, errorHistory);
      const golden = runBash(
        "decide-retry.sh",
        [JSON.stringify(stageResult), String(retryCount), JSON.stringify(errorHistory)],
        "RETRY_POLICY_BACKEND",
      );

      assert.equal(bridge, golden);
      assertManifest(manifest, name, bridge);
    });
  }
}

// ===========================================================================
// escalation-policy → decide-action.sh → decideAction
// ===========================================================================

{
  const manifest = readManifest("escalation-policy");
  const history: EscalationHistoryEntry[] = [];
  for (const name of fixtureNames("escalation-policy")) {
    test(`escalation-policy/${name}: bridge matches bash golden byte-for-byte`, () => {
      const file = path.join(FIXTURES, "escalation-policy", `${name}.json`);
      const stageResult = readJson(file);

      const bridge = decideAction(stageResult, history);
      const golden = runBash(
        "decide-action.sh",
        [fs.readFileSync(file, "utf8"), JSON.stringify(history)],
        "ESCALATION_POLICY_BACKEND",
      );

      assert.equal(bridge, golden);
      assertManifest(manifest, name, bridge);
    });
  }
}

// ===========================================================================
// model-fallback → decide-model-fallback.sh → decideModelFallback
// ===========================================================================

{
  const manifest = readManifest("model-fallback");
  for (const name of fixtureNames("model-fallback")) {
    test(`model-fallback/${name}: bridge matches bash golden byte-for-byte`, () => {
      const fx = readJson(path.join(FIXTURES, "model-fallback", `${name}.json`));
      const input = { model: fx.current_model, error_kind: fx.error_kind };

      const bridge = decideModelFallback(input);
      // The bash backend reads .model/.error_kind off a stage_result, so bridge
      // the fixture's current_model onto that field before invoking it.
      const golden = runBash(
        "decide-model-fallback.sh",
        [JSON.stringify({ model: input.model, error_kind: input.error_kind })],
        "MODEL_FALLBACK_BACKEND",
      );

      assert.equal(bridge, golden);
      assertManifest(manifest, name, bridge);
    });
  }
}
