/**
 * Stub entry point for the SDK harness.
 *
 * Stage spawning, envelope emission, and the policy bridge land in
 * follow-up tasks. Until then this prints a schema-valid error envelope
 * (see plugins/pipeline-core/scripts/schemas/stage-result.json) so the
 * package's wiring — build, module resolution, output shape — is
 * verifiable before any real logic exists.
 */

type StageStatus = "success" | "error" | "rate_limit";

type ErrorKind =
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

interface StageResultEnvelope {
  status: StageStatus;
  output: Record<string, unknown> | null;
  raw: string;
  denials: string[];
  model: string;
  error_kind: ErrorKind;
  elapsed_ms: number;
}

const envelope: StageResultEnvelope = {
  status: "error",
  output: null,
  raw: "sdk harness stub: stage execution not yet implemented",
  denials: [],
  model: "",
  error_kind: "structured_error",
  elapsed_ms: 0,
};

console.log(JSON.stringify(envelope));
