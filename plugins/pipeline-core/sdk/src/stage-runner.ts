/**
 * Stage runner: the SDK-harness counterpart to the bash orchestrator's
 * run_stage (implement-issue-orchestrator.sh). It spawns a single stage
 * session over the Claude CLI — the same headless execution model the Agent
 * SDK drives — enforces a per-stage timeout (with abort), and classifies the
 * outcome into the frozen stage-result envelope.
 *
 * The error_kind classification mirrors run_stage's mapping exactly (see the
 * "Classify error_kind based on the run outcome" block in that script) so an
 * SDK-supervised run is indistinguishable from a bash-supervised one to
 * downstream policy code. The only shape that never reaches here is
 * `agent_not_found`: bash emits it, but it is absent from the frozen
 * stage-result.json enum, so this harness does not produce it.
 */

import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";

import { createStageResult, ErrorKind, StageResult } from "./stage-result";

export interface RunStageOptions {
  /** Stage prompt handed to the CLI via `-p`. */
  prompt: string;
  /** Model id, e.g. "haiku" | "sonnet" | "opus". */
  model: string;
  /** Path to the JSON Schema file the CLI validates structured output against. */
  schemaPath: string;
  /** Per-stage wall-clock budget; on expiry the session is aborted. */
  timeoutMs: number;
  /** CLI executable; defaults to $CLAUDE_CLI, then "claude". */
  cliPath?: string;
  /** Extra CLI arguments, prepended before the stage flags. */
  cliArgs?: string[];
  /** Working directory for the spawned session. */
  cwd?: string;
  /** Environment for the spawned session; defaults to the parent's. */
  env?: NodeJS.ProcessEnv;
  /**
   * True when `model` is already the escalation ceiling, so max-turns
   * exhaustion cannot be escalated further — mirrors run_stage's
   * effective_fallback == model check.
   */
  atModelCeiling?: boolean;
  /**
   * Supervisor abort signal. When it fires, the session is killed and
   * runStage rejects with an AbortError — distinct from a per-stage timeout,
   * which resolves to a `timeout` envelope.
   */
  signal?: AbortSignal;
}

const RATE_LIMIT_RE = /rate.?limit|429|too many requests|quota.?exceeded/i;

/** Grace period between SIGTERM and an escalating SIGKILL for a killed stage. */
const KILL_GRACE_MS = 2_000;

/**
 * Mirrors detect_rate_limit(): trust a structured status first, then only
 * fall back to text matching when the run is a genuine error (so a stage whose
 * output merely mentions "rate limiting" is not misclassified).
 */
function detectRateLimit(parsed: Record<string, unknown> | null): boolean {
  if (!parsed) return false;
  const structured = parsed.structured_output as Record<string, unknown> | undefined;
  const status = structured?.status;
  if (status === "success") return false;
  if (status === "rate_limit") return true;
  if (parsed.is_error !== true) return false;
  const result = typeof parsed.result === "string" ? parsed.result : "";
  return RATE_LIMIT_RE.test(result);
}

/** Mirrors _extract_denials(): permission_denials[].tool_name, or []. */
function extractDenials(parsed: Record<string, unknown> | null): string[] {
  if (!parsed || !Array.isArray(parsed.permission_denials)) return [];
  return (parsed.permission_denials as Array<Record<string, unknown>>)
    .map((d) => d?.tool_name)
    .filter((name): name is string => typeof name === "string");
}

/**
 * Pull structured output, falling back to a `{status:"success", summary}`
 * object built from `.result` when the CLI returned text but no
 * structured_output — the same fallback run_stage applies.
 */
function extractStructured(
  parsed: Record<string, unknown> | null,
): Record<string, unknown> | null {
  if (!parsed) return null;
  const structured = parsed.structured_output;
  if (structured && typeof structured === "object") {
    return structured as Record<string, unknown>;
  }
  if (parsed.is_error === false && parsed.result != null) {
    return { status: "success", summary: parsed.result };
  }
  return null;
}

function safeParse(raw: string): Record<string, unknown> | null {
  try {
    const value = JSON.parse(raw);
    return value && typeof value === "object" ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

export async function runStage(opts: RunStageOptions): Promise<StageResult> {
  const start = Date.now();

  // Validate the schema file exists before spawning — run_stage's first guard.
  let schema: string;
  try {
    schema = await fs.readFile(opts.schemaPath, "utf8");
    JSON.parse(schema);
  } catch {
    return createStageResult({
      status: "error",
      error_kind: "schema_not_found",
      raw: `schema file not found: ${opts.schemaPath}`,
      model: opts.model,
      elapsed_ms: Date.now() - start,
    });
  }

  if (opts.signal?.aborted) {
    throw abortError(opts.signal.reason);
  }

  const cliPath = opts.cliPath ?? process.env.CLAUDE_CLI ?? "claude";
  const args = [
    ...(opts.cliArgs ?? []),
    "-p",
    opts.prompt,
    "--model",
    opts.model,
    "--dangerously-skip-permissions",
    "--output-format",
    "json",
    "--json-schema",
    schema,
  ];

  const { raw, timedOut } = await spawnSession(cliPath, args, opts);
  const elapsed_ms = Date.now() - start;
  const parsed = safeParse(raw);

  const errorKind = classify(parsed, timedOut, opts.atModelCeiling ?? false);
  const denials = extractDenials(parsed);
  const model =
    (parsed && typeof parsed.model === "string" ? parsed.model : "") || opts.model;

  if (errorKind === null) {
    return createStageResult({
      status: "success",
      output: extractStructured(parsed),
      raw,
      denials,
      model,
      error_kind: null,
      elapsed_ms,
    });
  }

  // run_stage emits status="error" for every non-null error_kind (rate_limit
  // included); the distinct "rate_limit" status value is reserved for the
  // stage_end event, not this envelope. Mirror that so downstream policy code
  // sees identical shapes from either orchestrator.
  return createStageResult({
    status: "error",
    output: null,
    raw,
    denials,
    model,
    error_kind: errorKind,
    elapsed_ms,
  });
}

/** Classify the run outcome into an error_kind, or null on success. */
function classify(
  parsed: Record<string, unknown> | null,
  timedOut: boolean,
  atModelCeiling: boolean,
): ErrorKind {
  if (timedOut) return "timeout";
  if (parsed?.subtype === "error_max_turns") {
    return atModelCeiling ? "max_turns_exhausted_at_ceiling" : "max_turns_exhausted";
  }
  if (detectRateLimit(parsed)) return "rate_limit";

  const structured = extractStructured(parsed);
  if (structured === null) return "no_structured_output";

  if (structured.status === "error") {
    return extractDenials(parsed).length > 0 ? "permission_denied" : "structured_error";
  }
  return null;
}

function abortError(reason: unknown): Error {
  if (reason instanceof Error) return reason;
  const err = new Error(
    typeof reason === "string" ? reason : "The stage session was aborted",
  );
  err.name = "AbortError";
  return err;
}

/**
 * Spawn the CLI, capturing combined stdout+stderr. Resolves when the process
 * closes; the per-stage timeout kills it (resolving with timedOut=true), while
 * an external abort kills it and rejects with an AbortError.
 */
function spawnSession(
  cliPath: string,
  args: string[],
  opts: RunStageOptions,
): Promise<{ raw: string; timedOut: boolean }> {
  return new Promise((resolve, reject) => {
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(cliPath, args, {
        cwd: opts.cwd,
        env: opts.env ?? process.env,
      });
    } catch {
      // Executable missing / not runnable: no output produced, mirroring an
      // empty-output run that run_stage classifies as no_structured_output.
      resolve({ raw: "", timedOut: false });
      return;
    }

    const chunks: string[] = [];
    let timedOut = false;
    let abortReason: unknown;
    let killTimer: NodeJS.Timeout | undefined;

    const kill = () => {
      child.kill("SIGTERM");
      // Escalate to SIGKILL if the session ignores the graceful signal.
      killTimer = setTimeout(() => child.kill("SIGKILL"), KILL_GRACE_MS);
      killTimer.unref?.();
    };

    const timeout = setTimeout(() => {
      timedOut = true;
      kill();
    }, opts.timeoutMs);

    const onAbort = () => {
      abortReason = opts.signal?.reason;
      kill();
    };
    if (opts.signal) opts.signal.addEventListener("abort", onAbort, { once: true });

    const cleanup = () => {
      clearTimeout(timeout);
      if (killTimer) clearTimeout(killTimer);
      if (opts.signal) opts.signal.removeEventListener("abort", onAbort);
    };

    child.stdout?.on("data", (d) => chunks.push(d.toString()));
    child.stderr?.on("data", (d) => chunks.push(d.toString()));

    child.on("error", () => {
      // spawn failure surfaced asynchronously (e.g. ENOENT).
      cleanup();
      if (abortReason !== undefined) reject(abortError(abortReason));
      else resolve({ raw: chunks.join(""), timedOut });
    });

    child.on("close", () => {
      cleanup();
      if (abortReason !== undefined && !timedOut) reject(abortError(abortReason));
      else resolve({ raw: chunks.join(""), timedOut });
    });
  });
}
