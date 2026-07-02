import test from "node:test";
import assert from "node:assert/strict";
import { promises as fsp } from "node:fs";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import Ajv from "ajv";

import { createStageResult, writeStageResult } from "../src/stage-result";

const SCHEMA_PATH = path.resolve(
  process.cwd(),
  "..",
  "scripts",
  "schemas",
  "stage-result.json",
);

const schema = JSON.parse(fs.readFileSync(SCHEMA_PATH, "utf8"));
const ajv = new Ajv({ strict: false });
const validate = ajv.compile(schema);

function assertValid(value: unknown): void {
  const ok = validate(value);
  assert.ok(ok, `expected value to satisfy stage-result.json: ${ajv.errorsText(validate.errors)}`);
}

test("createStageResult fills schema defaults for a minimal success result", () => {
  const result = createStageResult({ status: "success" });
  assertValid(result);
  assert.equal(result.output, null);
  assert.equal(result.raw, "");
  assert.deepEqual(result.denials, []);
  assert.equal(result.model, "");
  assert.equal(result.error_kind, null);
  assert.equal(result.elapsed_ms, 0);
});

test("createStageResult validates a fully populated success envelope", () => {
  const result = createStageResult({
    status: "success",
    output: { plan: "do the thing" },
    raw: '{"plan":"do the thing"}',
    denials: ["Bash"],
    model: "sonnet",
    elapsed_ms: 1234,
  });
  assertValid(result);
});

test("createStageResult validates an error envelope with an error_kind", () => {
  const result = createStageResult({
    status: "error",
    error_kind: "timeout",
    raw: "stage timed out",
    elapsed_ms: 900000,
  });
  assertValid(result);
});

test("the stub-style error envelope (from src/index.ts) satisfies the schema", () => {
  assertValid({
    status: "error",
    output: null,
    raw: "sdk harness stub: stage execution not yet implemented",
    denials: [],
    model: "",
    error_kind: "structured_error",
    elapsed_ms: 0,
  });
});

test("an envelope missing the required status field fails validation", () => {
  assert.equal(validate({ output: null }), false);
});

test("an envelope with an out-of-enum status fails validation", () => {
  assert.equal(
    validate({
      status: "ok",
      output: null,
      raw: "",
      denials: [],
      model: "",
      error_kind: null,
      elapsed_ms: 0,
    }),
    false,
  );
});

test("writeStageResult atomically writes a schema-valid envelope and leaves no temp file behind", async () => {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "stage-result-"));
  const filePath = path.join(dir, "stage-result.json");
  const result = createStageResult({ status: "success", model: "haiku", elapsed_ms: 42 });

  await writeStageResult(filePath, result);

  const written = JSON.parse(await fsp.readFile(filePath, "utf8"));
  assertValid(written);
  assert.deepEqual(written, result);

  const entries = await fsp.readdir(dir);
  assert.deepEqual(entries, ["stage-result.json"]);

  await fsp.rm(dir, { recursive: true, force: true });
});

test("writeStageResult overwrites an existing file without ever leaving it truncated", async () => {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "stage-result-"));
  const filePath = path.join(dir, "stage-result.json");

  await writeStageResult(filePath, createStageResult({ status: "success" }));
  await writeStageResult(
    filePath,
    createStageResult({ status: "error", error_kind: "rate_limit", raw: "429" }),
  );

  const written = JSON.parse(await fsp.readFile(filePath, "utf8"));
  assertValid(written);
  assert.equal(written.status, "error");
  assert.equal(written.error_kind, "rate_limit");

  await fsp.rm(dir, { recursive: true, force: true });
});
