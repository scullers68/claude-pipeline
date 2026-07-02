/**
 * Stub entry point for the SDK harness.
 *
 * Stage spawning, envelope emission, and the policy bridge land in
 * follow-up tasks. Until then this prints a schema-valid error envelope
 * (see plugins/pipeline-core/scripts/schemas/stage-result.json) so the
 * package's wiring — build, module resolution, output shape — is
 * verifiable before any real logic exists.
 */

import { createStageResult } from "./stage-result";

const envelope = createStageResult({
  status: "error",
  error_kind: "structured_error",
  raw: "sdk harness stub: stage execution not yet implemented",
});

console.log(JSON.stringify(envelope));
