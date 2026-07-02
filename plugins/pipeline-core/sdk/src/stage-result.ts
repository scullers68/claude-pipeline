/**
 * Envelope module: builds and atomically emits the stage-result envelope
 * returned by every stage invocation. Shape mirrors the frozen contract at
 * plugins/pipeline-core/scripts/schemas/stage-result.json — do not add,
 * rename, or drop fields here without updating that schema first.
 */

import { writeJsonAtomically } from "./file-utils";

export type StageStatus = "success" | "error" | "rate_limit";

export type ErrorKind =
  | "timeout"
  | "double_timeout"
  | "schema_not_found"
  | "no_structured_output"
  | "max_turns_exhausted_at_ceiling"
  | "rate_limit"
  | "permission_denied"
  | "quality_stall"
  | "max_turns_exhausted"
  | "structured_error"
  | null;

export interface StageResult {
  status: StageStatus;
  output: Record<string, unknown> | null;
  raw: string;
  denials: string[];
  model: string;
  error_kind: ErrorKind;
  elapsed_ms: number;
}

/**
 * Fills in schema defaults for every field but `status`, matching the stub
 * envelope's shape so partial callers can't produce a non-conforming result.
 */
export function createStageResult(
  fields: Partial<StageResult> & { status: StageStatus },
): StageResult {
  return {
    status: fields.status,
    output: fields.output ?? null,
    raw: fields.raw ?? "",
    denials: fields.denials ?? [],
    model: fields.model ?? "",
    error_kind: fields.error_kind ?? null,
    elapsed_ms: fields.elapsed_ms ?? 0,
  };
}

export async function writeStageResult(
  filePath: string,
  result: StageResult,
): Promise<void> {
  await writeJsonAtomically(filePath, result);
}
