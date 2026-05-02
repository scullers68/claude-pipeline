#!/usr/bin/env bash
#
# triage-validate.sh
#
# Real-Claude golden tests for the triage classifier prompt. Asks the live
# Haiku model to classify each fixture in implement-issue-test/fixtures/triage/
# and compares the returned route against the expected outcome encoded in
# the manifest below.
#
# WHY THIS EXISTS (vs the bats mock tests):
#   - test-surgical-fast-path.bats locks down the *shell logic* around the
#     classifier (kill switch, confidence demotion, grep verification, status
#     bookkeeping). It mocks the model — so it can't catch prompt regressions.
#   - This script locks down the *prompt itself*. If a Haiku update or a
#     prompt edit causes the model to flip a fixture's route, this is how
#     we find out before shipping.
#
# RUN CADENCE (READ BEFORE TOUCHING):
#   - Cost:    ~10 fixtures x 1 Haiku call = ~$0.05–$0.10 per run.
#   - Latency: ~5–15s per fixture, ~60–150s total wall clock.
#   - Run BEFORE merging changes to:
#       * .claude/scripts/implement-issue-orchestrator.sh
#         (build_triage_prompt, run_triage_stage, schema)
#       * .claude/scripts/schemas/implement-issue-triage.json
#       * .claude/scripts/model-config.sh (triage tier)
#   - Run MONTHLY as a regression sweep against model drift.
#   - Run after upgrading the Haiku tier model in model-config.sh.
#
# DO NOT AUTO-UPDATE FIXTURES OR EXPECTATIONS.
#   If a fixture flips, that is signal — investigate before changing the
#   manifest. The manifest is the contract; flips mean the prompt or the
#   model changed behavior, and that needs a human decision.
#
# Usage:
#   .claude/scripts/triage-validate.sh                  # run all fixtures
#   .claude/scripts/triage-validate.sh issue-2836       # run one fixture
#   TRIAGE_MODEL=sonnet .claude/scripts/triage-validate.sh   # override model
#
# Exit codes:
#   0 — all fixtures classified as expected
#   1 — one or more fixtures flipped
#   2 — environment / setup error (claude CLI missing, jq missing, etc.)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/implement-issue-test/fixtures/triage"
SCHEMA_FILE="$SCRIPT_DIR/schemas/implement-issue-triage.json"

CLAUDE_CLI="${CLAUDE_CLI:-claude}"
TRIAGE_MODEL="${TRIAGE_MODEL:-haiku}"

# =============================================================================
# MANIFEST: fixture -> expected_route[:expected_disqualifying_criterion]
# =============================================================================
#
# Format: "fixture_basename|expected_route|expected_dq_or_*"
#   expected_dq is checked only when route is "full". Use "*" to accept any
#   reason (the route alone is the contract). Use a specific name when the
#   prompt should pinpoint a particular criterion (e.g. auth-test must fail
#   on no_security_concerns specifically — no other reason is acceptable).
#
MANIFEST=(
    "issue-2836|fast-path|*"
    "issue-2837|fast-path|*"
    "issue-2838|fast-path|*"
    "issue-2839|fast-path|*"
    "issue-2752|full|test_only_scope"
    "issue-2754|full|test_only_scope"
    "issue-2776|full|test_only_scope"
    "issue-auth-test|full|no_security_concerns"
    "issue-vague|full|precise_specification"
    "issue-novel-pattern|full|established_pattern"
)

# =============================================================================

red()    { printf '\033[31m%s\033[0m' "$1"; }
green()  { printf '\033[32m%s\033[0m' "$1"; }
yellow() { printf '\033[33m%s\033[0m' "$1"; }
dim()    { printf '\033[2m%s\033[0m' "$1"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: required command not found: %s\n' "$1" >&2
        exit 2
    }
}

require_cmd jq
require_cmd "$CLAUDE_CLI"
[[ -f "$SCHEMA_FILE" ]] || { printf 'error: schema not found: %s\n' "$SCHEMA_FILE" >&2; exit 2; }
[[ -d "$FIXTURE_DIR" ]] || { printf 'error: fixture dir not found: %s\n' "$FIXTURE_DIR" >&2; exit 2; }

# Build the same prompt the orchestrator uses. Kept verbatim with
# build_triage_prompt() in implement-issue-orchestrator.sh — if you edit one,
# edit the other and re-run this script.
build_prompt() {
    local issue_body="$1"
    cat <<TRIAGE_PROMPT
You are the triage classifier for an issue-implementation pipeline. Classify
the GitHub issue below into one of two routes:

  "fast-path" — surgical, test-only, well-specified change. Pipeline runs:
                branch -> implement -> commit -> PR -> squash-merge. Skips
                test loop, code review, deploy verify, docs.
  "full"      — default. Runs the full verification pipeline.

Be CONSERVATIVE. False negatives (missing a fast-path opportunity) cost time.
False positives (skipping verification when it was needed) cost quality. Bias
hard toward "full" whenever uncertain.

Check ALL SIX criteria. Every criterion must be true for "fast-path". If ANY
criterion is false, route is "full".

CRITERIA:

1. test_only_scope — All file paths in the issue's Implementation Tasks
   section match: tests/**, playwright/**, **/*.spec.ts, **/*.test.ts,
   **/*.e2e.ts. Any reference to apps/, packages/, src/, or migration files
   disqualifies.

2. surgical_size — Estimated diff under 30 lines net, across no more than
   3 files.

3. established_pattern — The change applies a pattern that already exists in
   the codebase. Identify the pattern as a grep-able regex and place it in
   "established_pattern_grep". The shell wrapper will run \`git grep -lE\` and
   verify >= 3 matching files. Set to null if you cannot identify one
   specific regex (this criterion then fails).

4. precise_specification — Issue body has an "## Implementation Tasks"
   section AND each task names specific file paths AND (line numbers OR
   exact code snippets).

5. benign_failure_mode — Worst outcome of a wrong change is "a test still
   fails" or "a test skips" — NOT "production breaks", "data corrupts", or
   "users see incorrect behavior". Test files always pass; production code
   never passes.

6. no_security_concerns — Skip fast-path for: auth flows, RBAC, encryption,
   secret handling, input validation, CORS, CSP, session management, token
   handling. Auth tests deserve review even if test-only.

CONFIDENCE: high (all criteria clearly evaluated) | medium (some criteria
required inference) | low (vague issue). If confidence is medium or low,
route MUST be "full".

OUTPUT: schema-enforced JSON with route, criteria.{test_only_scope,
surgical_size, established_pattern, precise_specification,
benign_failure_mode, no_security_concerns}.{passed, reason},
established_pattern_grep, confidence, disqualifying_criterion, summary,
status.

ISSUE BODY:
<<<
${issue_body}
>>>
TRIAGE_PROMPT
}

run_one() {
    local entry="$1"
    local fixture expected_route expected_dq
    IFS='|' read -r fixture expected_route expected_dq <<<"$entry"

    local body_file="$FIXTURE_DIR/${fixture}.md"
    if [[ ! -f "$body_file" ]]; then
        printf '  %s missing fixture: %s\n' "$(red "FAIL")" "$body_file"
        return 1
    fi

    local prompt schema_compact start end elapsed_ms output
    prompt=$(build_prompt "$(cat "$body_file")")
    schema_compact=$(jq -c . "$SCHEMA_FILE")

    start=$(date +%s%N 2>/dev/null || echo 0)
    if ! output=$(env -u CLAUDECODE "$CLAUDE_CLI" -p "$prompt" \
        --model "$TRIAGE_MODEL" \
        --dangerously-skip-permissions \
        --output-format json \
        --json-schema "$schema_compact" 2>&1); then
        printf '  %s %-28s claude invocation failed\n' "$(red "FAIL")" "$fixture"
        printf '%s\n' "$output" | head -5 | sed 's/^/      /'
        return 1
    fi
    end=$(date +%s%N 2>/dev/null || echo 0)
    elapsed_ms=$(( (end - start) / 1000000 ))

    local result_payload route confidence dq summary
    # Claude CLI with --json-schema returns the validated payload as a JSON
    # object on .structured_output. Older CLIs put it on .result (sometimes
    # as a stringified JSON). Fall back to the top-level object if neither
    # field exists. This MUST mirror run_stage's extraction in the
    # orchestrator — if these diverge, the validator stops reflecting prod.
    result_payload=$(printf '%s' "$output" \
        | jq -c '.structured_output // (.result | if type == "string" then fromjson? else . end) // .' \
        2>/dev/null || echo '{}')
    if ! printf '%s' "$result_payload" | jq -e . >/dev/null 2>&1; then
        result_payload='{}'
    fi

    route=$(printf '%s' "$result_payload" | jq -r '.route // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")
    confidence=$(printf '%s' "$result_payload" | jq -r '.confidence // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")
    dq=$(printf '%s' "$result_payload" | jq -r '.disqualifying_criterion // ""' 2>/dev/null || echo "")
    summary=$(printf '%s' "$result_payload" | jq -r '.summary // ""' 2>/dev/null || echo "")

    local label="$fixture" timing_label
    timing_label=$(printf '%6dms' "$elapsed_ms")

    if [[ "$route" != "$expected_route" ]]; then
        printf '  %s %-28s %s  expected=%s got=%s confidence=%s\n' \
            "$(red "FAIL")" "$label" "$timing_label" "$expected_route" "$route" "$confidence"
        [[ -n "$summary" ]] && printf '      %s\n' "$(dim "summary: $summary")"
        return 1
    fi

    if [[ "$expected_route" == "full" && "$expected_dq" != "*" && "$dq" != "$expected_dq" ]]; then
        printf '  %s %-28s %s  route=full ok, but dq=%s expected=%s\n' \
            "$(yellow "WARN")" "$label" "$timing_label" "${dq:-<empty>}" "$expected_dq"
        [[ -n "$summary" ]] && printf '      %s\n' "$(dim "summary: $summary")"
        # WARN does not fail the run — the route is the primary contract.
        # Tighten manifest entries to "*" if a specific dq is too brittle.
        return 0
    fi

    printf '  %s %-28s %s  route=%s confidence=%s\n' \
        "$(green "PASS")" "$label" "$timing_label" "$route" "$confidence"
    return 0
}

# =============================================================================

filter="${1:-}"
total=0
passed=0
failed=0
run_start=$(date +%s)

printf 'triage-validate: %d fixtures, model=%s\n' "${#MANIFEST[@]}" "$TRIAGE_MODEL"
printf '\n'

for entry in "${MANIFEST[@]}"; do
    fixture="${entry%%|*}"
    if [[ -n "$filter" && "$fixture" != "$filter" ]]; then
        continue
    fi
    total=$((total + 1))
    if run_one "$entry"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
done

run_end=$(date +%s)
elapsed=$((run_end - run_start))

printf '\n'
printf 'triage-validate: %d/%d passed in %ds\n' "$passed" "$total" "$elapsed"

if (( total == 0 )); then
    printf 'no fixtures matched filter: %s\n' "$filter" >&2
    exit 2
fi

if (( failed > 0 )); then
    printf '%s\n' "$(red "FAIL")"
    exit 1
fi

printf '%s\n' "$(green "PASS")"
exit 0
