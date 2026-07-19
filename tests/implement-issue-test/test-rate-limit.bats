#!/usr/bin/env bats
#
# test-rate-limit.bats
# Tests for rate limit detection and handling functions
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env

    # Set required variables
    export ISSUE_NUMBER=123
    export BASE_BRANCH=test
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

    # Source the orchestrator functions
    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# DETECT_RATE_LIMIT - STRUCTURED OUTPUT
# =============================================================================

@test "detect_rate_limit returns true for rate_limit status" {
    local output='{"result":"error","structured_output":{"status":"rate_limit"}}'
    run detect_rate_limit "$output"
    [ "$status" -eq 0 ]  # 0 = true (rate limit detected)
}

@test "detect_rate_limit returns false for success status" {
    local output='{"result":"ok","structured_output":{"status":"success"}}'
    run detect_rate_limit "$output"
    [ "$status" -eq 1 ]  # 1 = false (no rate limit)
}

# =============================================================================
# DETECT_RATE_LIMIT - TEXT PATTERNS
# =============================================================================

@test "detect_rate_limit finds 'rate limit' in result" {
    local output='{"result":"Rate limit exceeded. Please try again later.","is_error":true}'
    run detect_rate_limit "$output"
    [ "$status" -eq 0 ]
}

@test "detect_rate_limit finds '429' in result" {
    local output='{"result":"HTTP 429: Too Many Requests","is_error":true}'
    run detect_rate_limit "$output"
    [ "$status" -eq 0 ]
}

@test "detect_rate_limit finds 'too many requests' in result" {
    local output='{"result":"Error: Too many requests to API","is_error":true}'
    run detect_rate_limit "$output"
    [ "$status" -eq 0 ]
}

@test "detect_rate_limit finds 'quota exceeded' in result" {
    local output='{"result":"API quota exceeded for the day","is_error":true}'
    run detect_rate_limit "$output"
    [ "$status" -eq 0 ]
}

@test "detect_rate_limit returns false for normal error" {
    local output='{"result":"File not found error"}'
    run detect_rate_limit "$output"
    [ "$status" -eq 1 ]
}

@test "detect_rate_limit returns false for normal success" {
    local output='{"result":"Task completed successfully"}'
    run detect_rate_limit "$output"
    [ "$status" -eq 1 ]
}

@test "detect_rate_limit is case insensitive" {
    local output='{"result":"RATE LIMIT hit","is_error":true}'
    run detect_rate_limit "$output"
    [ "$status" -eq 0 ]
}

# =============================================================================
# DETECT_SESSION_LIMIT (issue #13)
# A Claude session-limit 429 (api_error_status == 429 plus a "session limit" /
# "resets <time>" result) is unretriable — distinct from a transient rate
# limit. It must be classified as session_limit and short-circuit before the
# generic rate-limit / diagnostic-fallback retry path.
# =============================================================================

@test "detect_session_limit true for api_error_status 429 + session limit result" {
    local output
    output='{"is_error":true,"api_error_status":429,'
    output+='"result":"You'\''ve hit your session limit · resets 2pm (Australia/Melbourne)",'
    output+='"num_turns":1,"output_tokens":0}'
    run detect_session_limit "$output"
    [ "$status" -eq 0 ]
}

@test "detect_session_limit true when result mentions resets (no literal 'session limit')" {
    local output='{"is_error":true,"api_error_status":429,"result":"Limit reached · resets 9am"}'
    run detect_session_limit "$output"
    [ "$status" -eq 0 ]
}

@test "detect_session_limit false for a transient 429 without session-limit wording" {
    local output='{"is_error":true,"api_error_status":429,"result":"HTTP 429: Too Many Requests"}'
    run detect_session_limit "$output"
    [ "$status" -eq 1 ]
}

@test "detect_session_limit false when api_error_status is not 429" {
    local output='{"is_error":true,"api_error_status":500,"result":"You hit your session limit · resets 2pm"}'
    run detect_session_limit "$output"
    [ "$status" -eq 1 ]
}

@test "detect_session_limit false when api_error_status is absent" {
    local output='{"is_error":true,"result":"session limit reached, resets soon"}'
    run detect_session_limit "$output"
    [ "$status" -eq 1 ]
}

@test "extract_reset_time parses the reset descriptor from a 429 result" {
    local output
    output='{"is_error":true,"api_error_status":429,'
    output+='"result":"You'\''ve hit your session limit · resets 2pm (Australia/Melbourne)"}'
    run extract_reset_time "$output"
    [ "$status" -eq 0 ]
    [ "$output" = "2pm (Australia/Melbourne)" ]
}

@test "extract_reset_time returns empty when no reset time is named" {
    local output='{"is_error":true,"api_error_status":429,"result":"Too many requests"}'
    run extract_reset_time "$output"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# =============================================================================
# SET_PAUSED_STATE (issue #13, halt-resumably task)
# On a session-limit 429 the orchestrator must halt resumably: write
# state=paused with the reset time while preserving completed-task state.
# It must NOT mark any task failed and must keep prior completions.
# =============================================================================

# Seed a status.json with one completed task, one pending task, and the
# implement stage in progress — the state a real run is in when a session
# limit lands mid-way.
_seed_status_with_completion() {
    jq -n '{
        state: "running",
        issue: "123",
        current_stage: "implement",
        stages: {
            implement: {status: "in_progress", task_progress: "1/2"}
        },
        tasks: [
            {id: 1, status: "completed", review_attempts: 1},
            {id: 2, status: "in_progress", review_attempts: 0}
        ],
        escalations: []
    }' > "$STATUS_FILE"
}

@test "set_paused_state writes state=paused with the reset time" {
    _seed_status_with_completion

    set_paused_state "2pm (Australia/Melbourne)"

    assert_json_field "$STATUS_FILE" '.state' "paused"
    assert_json_field "$STATUS_FILE" '.session_limit_reset' \
        "2pm (Australia/Melbourne)"
    assert_json_field "$STATUS_FILE" '.paused_reason' "session_limit"
}

@test "set_paused_state marks NO task as failed" {
    _seed_status_with_completion

    set_paused_state "9am"

    local failed_count
    failed_count=$(jq '[.tasks[] | select(.status == "failed")] | length' \
        "$STATUS_FILE")
    [ "$failed_count" -eq 0 ]
}

@test "set_paused_state preserves prior completed-task state" {
    _seed_status_with_completion

    set_paused_state "9am"

    # Task 1 stays completed; task 2 stays whatever it was (not failed).
    assert_json_field "$STATUS_FILE" \
        '(.tasks[] | select(.id == 1)).status' "completed"
    assert_json_field "$STATUS_FILE" \
        '(.tasks[] | select(.id == 2)).status' "in_progress"

    local completed_count
    completed_count=$(jq '[.tasks[] | select(.status == "completed")] | length' \
        "$STATUS_FILE")
    [ "$completed_count" -eq 1 ]
}

@test "set_paused_state with no reset time records null, still paused" {
    _seed_status_with_completion

    set_paused_state ""

    assert_json_field "$STATUS_FILE" '.state' "paused"
    assert_json_field "$STATUS_FILE" '.session_limit_reset' "null"
}

@test "run_stage pause path persists paused state via set_paused_state" {
    local func_def
    func_def=$(declare -f run_stage)
    [[ "$func_def" == *"set_paused_state"* ]] \
        || fail "run_stage pause path does not call set_paused_state"
}

@test "run_task_in_worktree does not mark a session_limit task failed" {
    local func_def
    func_def=$(declare -f run_task_in_worktree)
    # The session-limit branch must emit a paused result and short-circuit
    # before the failed-result write at the end of the function.
    [[ "$func_def" == *"session_limit"* ]] \
        || fail "run_task_in_worktree lacks a session_limit branch"
    [[ "$func_def" == *"paused"* ]] \
        || fail "run_task_in_worktree does not write a paused result"
    # The paused write must precede the terminal failed-result write, so a
    # session_limit never falls through to being marked failed.
    local paused_line failed_line
    paused_line=$(printf '%s\n' "$func_def" \
        | grep -n "status.*paused" | head -1 | cut -d: -f1)
    failed_line=$(printf '%s\n' "$func_def" \
        | grep -n "status.*failed" | tail -1 | cut -d: -f1)
    [ -n "$paused_line" ] && [ -n "$failed_line" ] \
        || fail "could not locate both paused and failed writes"
    (( paused_line < failed_line )) \
        || fail "paused write ($paused_line) not before failed write ($failed_line)"
}

@test "run_stage detects session limit before the generic rate-limit branch" {
    local func_def
    func_def=$(declare -f run_stage)

    [[ "$func_def" == *"detect_session_limit"* ]] \
        || fail "run_stage lacks detect_session_limit"

    # The session-limit branch must be evaluated ahead of detect_rate_limit so
    # a session-limit 429 never falls into the retriable rate-limit path.
    local session_line rate_line
    session_line=$(printf '%s\n' "$func_def" \
        | grep -n "detect_session_limit" | head -1 | cut -d: -f1)
    rate_line=$(printf '%s\n' "$func_def" \
        | grep -n "detect_rate_limit" | head -1 | cut -d: -f1)
    [ -n "$session_line" ] && [ -n "$rate_line" ] \
        || fail "could not locate both detection branches"
    (( session_line < rate_line )) \
        || fail "detect_session_limit ($session_line) not before detect_rate_limit ($rate_line)"
}

# =============================================================================
# EXTRACT_WAIT_TIME
# =============================================================================

@test "extract_wait_time finds retry-after header value" {
    local output='{"result":"Rate limited. Retry-After: 300 seconds"}'
    run extract_wait_time "$output"
    [ "$output" = "300" ]
}

@test "extract_wait_time finds wait X minutes pattern" {
    local output='{"result":"Please wait 15 minutes before retrying"}'
    run extract_wait_time "$output"
    [ "$output" = "900" ]  # 15 * 60
}

@test "extract_wait_time finds wait X min pattern" {
    local output='{"result":"Wait 30 min and try again"}'
    run extract_wait_time "$output"
    [ "$output" = "1800" ]  # 30 * 60
}

@test "extract_wait_time returns default when no time found" {
    local output='{"result":"Rate limit exceeded"}'
    run extract_wait_time "$output"
    [ "$output" = "3600" ]  # RATE_LIMIT_DEFAULT_WAIT
}

@test "extract_wait_time prefers retry-after over wait minutes" {
    local output='{"result":"Retry-after: 120, or wait 30 minutes"}'
    run extract_wait_time "$output"
    [ "$output" = "120" ]
}

# =============================================================================
# RATE_LIMIT_BUFFER CONSTANT
# =============================================================================

@test "RATE_LIMIT_BUFFER is defined" {
    [ -n "$RATE_LIMIT_BUFFER" ]
    [ "$RATE_LIMIT_BUFFER" -eq 60 ]
}

@test "RATE_LIMIT_DEFAULT_WAIT is defined" {
    [ -n "$RATE_LIMIT_DEFAULT_WAIT" ]
    [ "$RATE_LIMIT_DEFAULT_WAIT" -eq 3600 ]
}

@test "RATE_LIMIT_EXHAUSTION_THRESHOLD is defined with default 1800" {
    [ -n "$RATE_LIMIT_EXHAUSTION_THRESHOLD" ]
    [ "$RATE_LIMIT_EXHAUSTION_THRESHOLD" -eq 1800 ]
}

# =============================================================================
# HANDLE_RATE_LIMIT (cannot fully test sleep, but test structure)
# =============================================================================

@test "handle_rate_limit logs wait time" {
    # Skip actual sleep by overriding
    sleep() { :; }
    export -f sleep

    local output='{"result":"Rate limited. Retry-After: 5 seconds"}'

    # Capture log output and verify rate limit message is logged
    local log_output
    log_output=$(handle_rate_limit "$output" 2>&1)
    [[ "$log_output" == *"Rate limit hit"* ]] || fail "Expected 'Rate limit hit' in output: $log_output"
}

# =============================================================================
# HANDLE_RATE_LIMIT - INFERRED EXHAUSTION (issue #364)
# =============================================================================

@test "handle_rate_limit records inferred exhaustion when wait exceeds threshold" {
    # Mock sleep to avoid actual delay
    sleep() { :; }
    export -f sleep

    # Mock record_inferred_exhaustion to record invocation in a sentinel file
    local sentinel="$TEST_TMP/exhaustion-called"
    record_inferred_exhaustion() {
        printf '%s %s\n' "$1" "$2" > "$sentinel"
    }
    export -f record_inferred_exhaustion

    # Retry-After of 7200s is well above the 1800s threshold
    local output='{"result":"Rate limited. Retry-After: 7200 seconds"}'

    handle_rate_limit "$output" "sonnet" >/dev/null 2>&1

    [ -f "$sentinel" ] || fail "record_inferred_exhaustion was not called"

    local call
    call=$(cat "$sentinel")
    [[ "$call" == sonnet\ * ]] || fail "Expected model=sonnet recorded; got: $call"

    # The recorded wait should be the parsed value (7200), not buffered
    [[ "$call" == *"7200" ]] || fail "Expected wait=7200 recorded; got: $call"
}

@test "handle_rate_limit does NOT record exhaustion when wait at or below threshold" {
    sleep() { :; }
    export -f sleep

    local sentinel="$TEST_TMP/exhaustion-called"
    record_inferred_exhaustion() {
        printf '%s %s\n' "$1" "$2" > "$sentinel"
    }
    export -f record_inferred_exhaustion

    # Retry-After of 1800s — at threshold boundary, must NOT trigger
    local output='{"result":"Rate limited. Retry-After: 1800 seconds"}'

    handle_rate_limit "$output" "sonnet" >/dev/null 2>&1

    [ ! -f "$sentinel" ] || fail "record_inferred_exhaustion was unexpectedly called for wait <= threshold"
}

@test "handle_rate_limit does NOT record exhaustion when model is empty" {
    sleep() { :; }
    export -f sleep

    local sentinel="$TEST_TMP/exhaustion-called"
    record_inferred_exhaustion() {
        printf '%s %s\n' "$1" "$2" > "$sentinel"
    }
    export -f record_inferred_exhaustion

    # Long wait but no model — should skip exhaustion recording
    local output='{"result":"Rate limited. Retry-After: 7200 seconds"}'

    handle_rate_limit "$output" "" >/dev/null 2>&1

    [ ! -f "$sentinel" ] || fail "record_inferred_exhaustion called despite empty model"
}

@test "handle_rate_limit tolerates missing record_inferred_exhaustion function" {
    sleep() { :; }
    export -f sleep

    # Ensure the function is NOT defined in this test scope
    unset -f record_inferred_exhaustion 2>/dev/null || true

    local output='{"result":"Rate limited. Retry-After: 7200 seconds"}'

    # Must complete without error even when the helper is missing
    run handle_rate_limit "$output" "sonnet"
    [ "$status" -eq 0 ]
}

# =============================================================================
# STRUCTURAL TESTS - RATE LIMIT RETRY PATH
# =============================================================================

@test "run_stage has rate limit detection" {
    # Verify run_stage includes rate limit detection logic
    local func_def
    func_def=$(declare -f run_stage)

    [[ "$func_def" == *"detect_rate_limit"* ]]
}

@test "run_stage has rate limit handling" {
    # Verify run_stage includes rate limit handling
    local func_def
    func_def=$(declare -f run_stage)

    [[ "$func_def" == *"handle_rate_limit"* ]]
}

@test "run_stage retries after rate limit handling" {
    # Verify run_stage has retry logic after rate limit
    local func_def
    func_def=$(declare -f run_stage)

    # Should have retry comment or second claude call after handle_rate_limit
    [[ "$func_def" == *"handle_rate_limit"* ]]
    [[ "$func_def" == *"Retry"* ]] || [[ "$func_def" == *"retry"* ]]
}

@test "rate limit detection integrates with handling" {
    # Test the integration: if rate limit detected, handle_rate_limit is called
    # Use a mock that simulates rate limit being detected

    # Override sleep to avoid actual wait
    sleep() { :; }
    export -f sleep

    local rate_limit_output='{"result":"Rate limit hit","structured_output":{"status":"rate_limit"}}'

    # Test detection returns true (0) for rate limited response
    run detect_rate_limit "$rate_limit_output"
    [ "$status" -eq 0 ]

    # Test handling works without error
    local log_output
    log_output=$(handle_rate_limit "$rate_limit_output" 2>&1)
    [[ "$log_output" == *"Rate limit hit"* ]] || fail "Expected rate limit log message"
}

# =============================================================================
# CHECK_RUN_BUDGET — per-run cost/turns circuit-breaker (issue #16)
# When cumulative cost/turns (parsed from the stage logs) cross a configurable
# ceiling, the run must halt resumably: state=paused (reason=budget_exceeded),
# completions preserved, NO task failed. Ceilings are env-configurable; 0
# disables a dimension. Defaults (enabled): MAX_RUN_COST_USD=50, MAX_RUN_TURNS=1000.
# =============================================================================

# Write one stage-log result envelope with the given cost + turns.
_write_usage_log() {
    local cost="$1" turns="$2"
    mkdir -p "$LOG_BASE/stages"
    printf '%s\n' \
        "{\"type\":\"result\",\"subtype\":\"success\",\"num_turns\":$turns,\"total_cost_usd\":$cost,\"usage\":{\"input_tokens\":1,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":1,\"output_tokens\":1}}" \
        > "$LOG_BASE/stages/01-implement-task-1.log"
}

@test "(B1) check_run_budget halts resumably when cost ceiling exceeded (#16)" {
    _seed_status_with_completion
    export MAX_RUN_COST_USD=50 MAX_RUN_TURNS=1000
    _write_usage_log 60 10

    run check_run_budget "1"
    [ "$status" -eq 1 ] || fail "expected breach (rc=1), got rc=$status"
    assert_json_field "$STATUS_FILE" '.state' "paused"
    assert_json_field "$STATUS_FILE" '.paused_reason' "budget_exceeded"
    # completions preserved, no task failed
    [ "$(jq '[.tasks[] | select(.status == "failed")] | length' "$STATUS_FILE")" -eq 0 ]
    assert_json_field "$STATUS_FILE" '.tasks[0].status' "completed"
}

@test "(B2) check_run_budget halts when turns ceiling exceeded (#16)" {
    _seed_status_with_completion
    export MAX_RUN_COST_USD=0 MAX_RUN_TURNS=1000
    _write_usage_log 1 1500

    run check_run_budget "1"
    [ "$status" -eq 1 ] || fail "expected breach (rc=1), got rc=$status"
    assert_json_field "$STATUS_FILE" '.state' "paused"
    assert_json_field "$STATUS_FILE" '.paused_reason' "budget_exceeded"
}

@test "(B3) check_run_budget does NOT trip a run under both ceilings (#16)" {
    _seed_status_with_completion
    export MAX_RUN_COST_USD=50 MAX_RUN_TURNS=1000
    _write_usage_log 5 100

    run check_run_budget "1"
    [ "$status" -eq 0 ] || fail "expected no breach (rc=0), got rc=$status"
    # state untouched — still running, not paused
    assert_json_field "$STATUS_FILE" '.state' "running"
}

@test "(B4) check_run_budget is opt-out: 0/0 never trips even when over (#16)" {
    _seed_status_with_completion
    export MAX_RUN_COST_USD=0 MAX_RUN_TURNS=0
    _write_usage_log 999 99999

    run check_run_budget "1"
    [ "$status" -eq 0 ] || fail "disabled breaker must not trip, got rc=$status"
    assert_json_field "$STATUS_FILE" '.state' "running"
}

@test "(B5) check_run_budget default ceilings are enabled (50/1000) (#16)" {
    _seed_status_with_completion
    unset MAX_RUN_COST_USD MAX_RUN_TURNS
    _write_usage_log 60 10   # over the default $50

    run check_run_budget "1"
    [ "$status" -eq 1 ] || fail "default cost ceiling should trip at \$60, got rc=$status"
    assert_json_field "$STATUS_FILE" '.paused_reason' "budget_exceeded"
}

@test "(B6) set_paused_state default reason stays session_limit (regression, #16 param)" {
    _seed_status_with_completion
    set_paused_state "2pm"
    assert_json_field "$STATUS_FILE" '.paused_reason' "session_limit"
}

# =============================================================================
# _retry_turns_args — raise the turn budget on a max_turns retry (issue #28)
# AC1's retry_same engages, but retrying at the SAME cap just re-exhausts and
# escalates. On a max_turns retry the same model must get MORE turns (1.5x) so
# it can finish; a rate_limit retry keeps its budget.
# =============================================================================

@test "(RT1) _retry_turns_args raises the cap 1.5x on a max_turns retry (#28)" {
    run _retry_turns_args max_turns_exhausted --max-turns 60
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--max-turns" ] || fail "flag: ${lines[0]}"
    [ "${lines[1]}" = "90" ] || fail "expected 90 (60*1.5), got ${lines[1]}"
}

@test "(RT2) _retry_turns_args leaves the cap unchanged on a rate_limit retry (#28)" {
    run _retry_turns_args rate_limit --max-turns 60
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--max-turns" ]
    [ "${lines[1]}" = "60" ] || fail "rate_limit budget must be unchanged, got ${lines[1]}"
}

@test "(RT3) _retry_turns_args rounds down (25 -> 37) and handles an uncapped stage (#28)" {
    run _retry_turns_args max_turns_exhausted --max-turns 25
    [ "${lines[1]}" = "37" ] || fail "expected 37 (25*1.5 floored), got ${lines[1]}"

    run _retry_turns_args max_turns_exhausted
    [ "$status" -eq 0 ]
    [ -z "$output" ] || fail "uncapped stage must yield no --max-turns, got: $output"
}

@test "(RT4) run_stage's retry path uses _retry_turns_args, not the raw turns_args (#28)" {
    # Structural guard: the retry claude call must pass the raised budget.
    local src="$ORCHESTRATOR_SCRIPT"
    grep -q '_retry_turns_args "\$_error_kind"' "$src" \
        || fail "retry path does not call _retry_turns_args"
    # The retry claude invocation passes _retry_turns (not turns_args).
    grep -q '\${_retry_turns\[@\]' "$src" \
        || fail "retry claude call does not use _retry_turns"
}
