/**
 * Config module: resolves the SDK harness's runtime knobs from the environment
 * the bash dispatch exports after sourcing platform.sh
 * (.claude/config/platform.sh). The state machine reads its iteration budgets
 * from here so the SDK and bash engines honour the same MAX_* limits — the
 * defaults below mirror templates/platform.sh exactly. Keep them in step.
 */

export interface IterationBudgets {
  /** MAX_QUALITY_ITERATIONS — per-task self-review passes. */
  quality: number;
  /** MAX_TEST_ITERATIONS — test-fix attempts before the loop bails. */
  test: number;
  /** MAX_PR_REVIEW_ITERATIONS — review→fix cycles before the loop bails. */
  prReview: number;
}

/** Mirrors the `${VAR:-N}` defaults in templates/platform.sh. */
export const DEFAULT_BUDGETS: IterationBudgets = {
  quality: 5,
  test: 7,
  prReview: 2,
};

/**
 * Parse a `MAX_*` env value the way the bash `${VAR:-N}` fallback does: an
 * unset or empty value takes the default; anything that is not a non-negative
 * integer also falls back rather than silently disabling the budget.
 */
function intFromEnv(raw: string | undefined, fallback: number): number {
  if (raw == null || raw.trim() === "") return fallback;
  const n = Number.parseInt(raw, 10);
  return Number.isInteger(n) && n >= 0 ? n : fallback;
}

export function loadBudgets(
  env: NodeJS.ProcessEnv = process.env,
): IterationBudgets {
  return {
    quality: intFromEnv(env.MAX_QUALITY_ITERATIONS, DEFAULT_BUDGETS.quality),
    test: intFromEnv(env.MAX_TEST_ITERATIONS, DEFAULT_BUDGETS.test),
    prReview: intFromEnv(
      env.MAX_PR_REVIEW_ITERATIONS,
      DEFAULT_BUDGETS.prReview,
    ),
  };
}
