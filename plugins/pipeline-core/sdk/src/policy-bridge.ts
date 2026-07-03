/**
 * Policy bridge: the SDK-harness counterpart to the decide-* bash backends
 * (decide-retry.sh, decide-action.sh, decide-model-fallback.sh). It reproduces
 * the inline bash decision trees — _bash_retry_decide, _bash_decide and
 * _bash_model_fallback — that those scripts run under their `bash` backend, so
 * an SDK-supervised run reaches identical routing decisions to a
 * bash-supervised one.
 *
 * Every function returns the decision as the exact compact-JSON line the
 * corresponding bash script prints (same key order, same reason text, no
 * trailing newline), so SDK policy output matches the bash goldens
 * byte-for-byte. Field order is load-bearing: the bash scripts emit fixed key
 * orders via printf / jq -c, and the object-literal insertion order here is
 * chosen to match them exactly.
 *
 * These trees mirror the frozen skill contracts:
 *   retry-policy      → decide-retry.sh          → decideRetry
 *   escalation-policy → decide-action.sh         → decideAction
 *   model-fallback    → decide-model-fallback.sh → decideModelFallback
 * Keep them in sync with those scripts; the fixture-driven parity test asserts
 * they never drift.
 */

/** Minimal view of a stage-result envelope the decision trees read. */
export interface PolicyStageResult {
  status?: string;
  model?: string;
  error_kind?: string | null;
}

/** Per-tier error record consulted by the retry-policy threshold check. */
export interface RetryHistoryEntry {
  model: string;
  error_kind: string;
}

/** Escalation-history record consulted by the escalation-policy rate-limit path. */
export interface EscalationHistoryEntry {
  from_model: string;
}

/** Query shape for the model-fallback decision (current tier + failure class). */
export interface ModelFallbackInput {
  model: string;
  error_kind: string | null;
}

/**
 * `.model // "haiku"`: mirror jq's alternative operator, which substitutes the
 * default only for a null/absent value (an empty string is preserved).
 */
function readModel(sr: PolicyStageResult): string {
  return sr.model ?? "haiku";
}

/**
 * `.error_kind` under jq -r: a null or absent value renders as the literal
 * string "null"; any present value is used verbatim.
 */
function readErrorKind(sr: PolicyStageResult): string {
  return sr.error_kind == null ? "null" : sr.error_kind;
}

/**
 * decide-retry.sh / decide-action.sh _next_model: haiku → sonnet, everything
 * else → opus. (decide-action treats sonnet explicitly, but the collapsed
 * "anything but haiku → opus" rule is equivalent for every reachable tier.)
 */
function nextModel(model: string): string {
  return model === "haiku" ? "sonnet" : "opus";
}

/**
 * model-config.sh _next_model_up: the haiku → sonnet → opus ladder, with opus
 * and any unknown tier pinned at the opus ceiling.
 */
function nextModelUp(model: string): string {
  return model === "haiku" ? "sonnet" : "opus";
}

/** decide-retry.sh _max_retries: same-tier retry budget per error class. */
function maxRetries(errorKind: string): number {
  switch (errorKind) {
    case "rate_limit":
      return 3;
    case "no_structured_output":
    case "timeout":
    case "structured_error":
      return 1;
    // Known non-retriable classes and every unknown class fail closed at 0,
    // forcing an immediate escalate-or-bail rather than a silent retry.
    default:
      return 0;
  }
}

/** model-fallback _is_upgrade_trigger: error classes a higher tier can fix. */
function isUpgradeTrigger(errorKind: string): boolean {
  switch (errorKind) {
    case "timeout":
    case "double_timeout":
    case "max_turns_exhausted":
    case "no_structured_output":
    case "structured_error":
    case "rate_limit":
      return true;
    default:
      return false;
  }
}

/**
 * decide-retry.sh _bash_retry_decide. Given a failed stage result, the
 * same-tier retry count, and the per-tier error history, decide whether to
 * retry, escalate, or bail. Returns the byte-for-byte decision line.
 */
export function decideRetry(
  stageResult: PolicyStageResult,
  retryCount: number,
  errorHistory: RetryHistoryEntry[],
): string {
  const errorKind = readErrorKind(stageResult);
  const model = readModel(stageResult);

  // Unretryable configuration/permission errors → bail immediately.
  if (
    errorKind === "permission_denied" ||
    errorKind === "schema_not_found" ||
    errorKind === "max_turns_exhausted_at_ceiling"
  ) {
    const reason = `${errorKind}: configuration error, retrying cannot fix this`;
    return JSON.stringify({ action: "bail", reason });
  }

  // max_turns_exhausted → escalate (or bail at the opus ceiling).
  if (errorKind === "max_turns_exhausted") {
    if (model === "opus") {
      return JSON.stringify({
        action: "bail",
        reason: "max_turns_exhausted: at opus ceiling, cannot escalate",
      });
    }
    const next = nextModel(model);
    return JSON.stringify({
      action: "escalate",
      reason: `max_turns_exhausted: escalating ${model} → ${next}`,
    });
  }

  // quality_stall → escalate (or bail at the opus ceiling).
  if (errorKind === "quality_stall") {
    if (model === "opus") {
      return JSON.stringify({
        action: "bail",
        reason: "quality_stall: at opus ceiling, cannot escalate",
      });
    }
    return JSON.stringify({
      action: "escalate",
      reason: "quality_stall: fix made no commits",
    });
  }

  const max = maxRetries(errorKind);
  const historyCount = errorHistory.filter(
    (e) => e.model === model && e.error_kind === errorKind,
  ).length;

  // Threshold met, or the same error already recorded at this tier → give up
  // on same-tier retries: escalate, or bail if already at the opus ceiling.
  if (retryCount >= max || historyCount > 0) {
    if (model === "opus") {
      const reason =
        `${errorKind}: retry_count=${retryCount} meets threshold` +
        " and at opus ceiling";
      return JSON.stringify({ action: "bail", reason });
    }
    const next = nextModel(model);
    const reason =
      `${errorKind}: retry_count=${retryCount} meets threshold` +
      `; escalating ${model} → ${next}`;
    return JSON.stringify({ action: "escalate", reason });
  }

  // Retry — rate_limit carries an exponential backoff capped at 120s.
  if (errorKind === "rate_limit") {
    let backoffMs = 30000 * (1 << retryCount);
    if (backoffMs > 120000) backoffMs = 120000;
    const reason =
      `rate_limit: transient throttle, retry_count=${retryCount}` +
      `, waiting ${backoffMs}ms`;
    return JSON.stringify({ action: "retry", reason, backoff_ms: backoffMs });
  }

  const reason = `${errorKind}: first retry at ${model}, retry_count=${retryCount}`;
  return JSON.stringify({ action: "retry", reason });
}

/**
 * decide-action.sh _bash_decide. Routes a completed stage to one of
 * accept / escalate / bail / retry_same. Returns the byte-for-byte decision
 * line; the escalate branch carries a `model` field between `action` and
 * `reason`, matching the bash key order.
 */
export function decideAction(
  stageResult: PolicyStageResult,
  history: EscalationHistoryEntry[],
): string {
  const status = stageResult.status;
  const errorKind = readErrorKind(stageResult);
  const model = readModel(stageResult);

  // success at top level → accept.
  if (status === "success") {
    return JSON.stringify({
      action: "accept",
      reason: "stage completed successfully",
    });
  }

  // Unrecoverable configuration/permission error → bail.
  if (
    errorKind === "permission_denied" ||
    errorKind === "schema_not_found" ||
    errorKind === "agent_not_found"
  ) {
    return JSON.stringify({
      action: "bail",
      reason: `${errorKind}: unrecoverable error`,
    });
  }

  // Explicitly ceiling-exhausted → bail.
  if (errorKind === "max_turns_exhausted_at_ceiling") {
    return JSON.stringify({
      action: "bail",
      reason: "max_turns_exhausted_at_ceiling: already at opus ceiling",
    });
  }

  // quality_stall → escalate, or bail at the opus ceiling.
  if (errorKind === "quality_stall") {
    if (model === "opus") {
      return JSON.stringify({
        action: "bail",
        reason: "quality_stall: already at opus ceiling",
      });
    }
    const next = nextModel(model);
    return JSON.stringify({
      action: "escalate",
      model: next,
      reason: `quality_stall: escalating from ${model} to ${next}`,
    });
  }

  // double_timeout → escalate, or bail at the opus ceiling.
  if (errorKind === "double_timeout") {
    if (model === "opus") {
      return JSON.stringify({ action: "bail", reason: "double_timeout" });
    }
    const next = nextModel(model);
    return JSON.stringify({
      action: "escalate",
      model: next,
      reason: "double_timeout",
    });
  }

  // Already at opus → bail (cannot escalate further).
  if (model === "opus") {
    return JSON.stringify({
      action: "bail",
      reason: "at opus ceiling: cannot escalate further",
    });
  }

  // rate_limit with no prior same-model attempt → retry_same.
  if (errorKind === "rate_limit") {
    const priorCount = history.filter((e) => e.from_model === model).length;
    if (priorCount === 0) {
      return JSON.stringify({
        action: "retry_same",
        reason: "rate_limit: transient throttle, retrying with same model",
      });
    }
  }

  // Default → escalate to the next tier.
  const next = nextModel(model);
  const ek = errorKind === "" ? "unknown" : errorKind;
  const reason = `${ek}: escalating from ${model} to ${next}`;
  return JSON.stringify({ action: "escalate", model: next, reason });
}

/**
 * decide-model-fallback.sh _bash_model_fallback. Given the current tier and
 * failure class, decide the next model up (or that the ceiling is reached).
 * Returns the byte-for-byte decision line: next_model, at_ceiling, reason.
 */
export function decideModelFallback(input: ModelFallbackInput): string {
  const model = input.model ?? "haiku";
  const errorKind = input.error_kind == null ? "null" : input.error_kind;

  // Non-escalatable errors: no higher tier can fix these at any level. Checked
  // before the opus ceiling test so haiku/sonnet also report at_ceiling=true.
  if (
    errorKind === "permission_denied" ||
    errorKind === "schema_not_found" ||
    errorKind === "max_turns_exhausted_at_ceiling"
  ) {
    return JSON.stringify({
      next_model: null,
      at_ceiling: true,
      reason: `${errorKind}: non-escalatable, no model can fix this`,
    });
  }

  // At ceiling: opus has no higher tier.
  if (model === "opus") {
    return JSON.stringify({
      next_model: null,
      at_ceiling: true,
      reason: "at opus ceiling: no higher tier available",
    });
  }

  // Recognised upgrade trigger → bump to the next tier up.
  if (isUpgradeTrigger(errorKind)) {
    const next = nextModelUp(model);
    return JSON.stringify({
      next_model: next,
      at_ceiling: false,
      reason: `${errorKind}: upgrading ${model} → ${next}`,
    });
  }

  // Unrecognised error_kind → conservative no-upgrade.
  return JSON.stringify({
    next_model: null,
    at_ceiling: false,
    reason: `${errorKind}: not a recognised upgrade trigger, no-upgrade`,
  });
}
