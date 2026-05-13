#!/usr/bin/env bats
#
# test-exit-trap.bats
# Tests for EXIT trap state rewriting when the orchestrator is killed mid-stage.
#
# AC2: When the orchestrator exits with state="running", the EXIT trap rewrites
# it to interrupted_during_<stage> before metrics are exported.
# AC4: BATS test covers the SIGTERM-mid-stage scenario and passes.
#
# These tests cover _rewrite_running_to_interrupted(), the helper called from
# the EXIT trap, which is implemented alongside the trap update in
# implement-issue-orchestrator.sh (issue #325 task 2).
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env

    export ISSUE_NUMBER=123
    export BASE_BRANCH=test
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# UNIT: _rewrite_running_to_interrupted
# =============================================================================

@test "_rewrite_running_to_interrupted rewrites state from running to interrupted_during_<stage>" {
    init_status
    set_stage_started "merge_pr"

    local pre_state
    pre_state=$(jq -r '.state' "$STATUS_FILE")
    [ "$pre_state" = "running" ]

    _rewrite_running_to_interrupted

    local post_state
    post_state=$(jq -r '.state' "$STATUS_FILE")
    [ "$post_state" = "interrupted_during_merge_pr" ]
}

@test "_rewrite_running_to_interrupted embeds current_stage in the new state name" {
    init_status
    set_stage_started "implement"

    _rewrite_running_to_interrupted

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "interrupted_during_implement" ]
}

@test "_rewrite_running_to_interrupted does not modify state when already completed" {
    init_status
    set_final_state "completed"

    _rewrite_running_to_interrupted

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "completed" ]
}

@test "_rewrite_running_to_interrupted does not modify state when already error" {
    init_status
    set_final_state "error"

    _rewrite_running_to_interrupted

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "error" ]
}

@test "_rewrite_running_to_interrupted uses unknown stage when current_stage is null" {
    init_status
    # Set state to running and explicitly null current_stage to simulate the
    # edge case of a very early exit before any stage has been started.
    # (init_status sets current_stage="parse_issue"; we must clear it here.)
    jq '.state = "running" | .current_stage = null' "$STATUS_FILE" \
        > "${STATUS_FILE}.tmp" \
        && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

    _rewrite_running_to_interrupted

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "interrupted_during_unknown" ]
}

@test "_rewrite_running_to_interrupted is a no-op when STATUS_FILE does not exist" {
    rm -f "$STATUS_FILE"
    # Must not error out when there is no file to rewrite.
    run _rewrite_running_to_interrupted
    [ "$status" -eq 0 ]
}

# =============================================================================
# INTEGRATION: SIGTERM mid-stage (full EXIT trap exercise)
# =============================================================================

@test "EXIT trap rewrites running state to interrupted_during_<stage> when process receives SIGTERM" {
    init_status
    set_stage_started "merge_pr"

    # Confirm precondition: we are mid-stage with state=running.
    local pre_state
    pre_state=$(jq -r '.state' "$STATUS_FILE")
    [ "$pre_state" = "running" ]

    # Build a wrapper that sources the orchestrator's extracted functions and
    # registers the post-task-2 EXIT trap, then sleeps (simulating a blocked
    # stage).  Killing it with SIGTERM triggers the EXIT trap.
    # A ready-file handshake eliminates the race between sourcing the large
    # functions file and the test sending SIGTERM.
    local wrapper="$TEST_TMP/sigterm_wrapper.sh"
    local ready_file="$TEST_TMP/wrapper_ready"
    cat > "$wrapper" << WRAPPER
#!/usr/bin/env bash
source "$TEST_TMP/orchestrator_functions.bash"
export STATUS_FILE="$STATUS_FILE"
export LOG_BASE="$LOG_BASE"
export LOG_FILE="$LOG_FILE"
# EXIT trap as it will look after issue-325 task 2 is applied:
trap '_rewrite_running_to_interrupted; write_task_summary_to_status; export_metrics' EXIT
# SIGTERM trap mirrors the orchestrator: convert signal into a clean exit so
# the EXIT trap fires reliably (bash may not run EXIT when blocked on a
# foreground child process receiving an unhandled SIGTERM).
trap 'exit 143' TERM
# Signal readiness after all traps are registered, then block.
touch "$ready_file"
sleep 30
WRAPPER
    chmod +x "$wrapper"

    "$wrapper" &
    local pid=$!
    # Wait until the wrapper has sourced functions and registered its traps.
    local i=0
    while [[ ! -f "$ready_file" ]] && ((i++ < 50)); do
        sleep 0.1
    done
    kill -TERM "$pid"
    wait "$pid" 2>/dev/null || true

    local final_state
    final_state=$(jq -r '.state' "$STATUS_FILE")
    [ "$final_state" = "interrupted_during_merge_pr" ]
}

@test "EXIT trap preserves terminal state when process exits normally" {
    init_status
    set_stage_started "merge_pr"
    set_final_state "completed"

    local wrapper="$TEST_TMP/normal_exit_wrapper.sh"
    cat > "$wrapper" << WRAPPER
#!/usr/bin/env bash
source "$TEST_TMP/orchestrator_functions.bash"
export STATUS_FILE="$STATUS_FILE"
export LOG_BASE="$LOG_BASE"
export LOG_FILE="$LOG_FILE"
trap '_rewrite_running_to_interrupted; write_task_summary_to_status; export_metrics' EXIT
trap 'exit 143' TERM
# Normal exit — state is already "completed"
exit 0
WRAPPER
    chmod +x "$wrapper"

    run "$wrapper"
    # Wrapper exits cleanly; state must remain completed, not be rewritten.
    local final_state
    final_state=$(jq -r '.state' "$STATUS_FILE")
    [ "$final_state" = "completed" ]
}
