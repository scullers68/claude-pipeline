#!/usr/bin/env bats
#
# test-fast-path.bats
# Tests for is_single_s_task() fast-path detection function.
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    install_mocks

    # Set required variables
    export ISSUE_NUMBER=123
    export BASE_BRANCH=main
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0
    export SCHEMA_DIR="$TEST_TMP/schemas"

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"
    mkdir -p "$SCHEMA_DIR"

    # Create required schemas
    for schema in implement-issue-implement implement-issue-test implement-issue-review implement-issue-fix implement-issue-simplify; do
        echo '{"type":"object"}' > "$SCHEMA_DIR/${schema}.json"
    done

    # Source the orchestrator functions
    source_orchestrator_functions

    # Initialize status
    init_status
}

teardown() {
    teardown_test_env
}

# =============================================================================
# is_single_s_task() — fast-path detection
# =============================================================================

@test "is_single_s_task returns true for single S-task" {
    local tasks='[{"id":1,"description":"**(S)** Add threshold check to hook","agent":"default","status":"pending"}]'
    run is_single_s_task "$tasks"
    [ "$status" -eq 0 ]
}

@test "is_single_s_task returns false for single M-task" {
    local tasks='[{"id":1,"description":"**(M)** Wire fast-path flag to skip stages","agent":"default","status":"pending"}]'
    run is_single_s_task "$tasks"
    [ "$status" -eq 1 ]
}

@test "is_single_s_task returns false for single L-task" {
    local tasks='[{"id":1,"description":"**(L)** Refactor entire orchestrator","agent":"default","status":"pending"}]'
    run is_single_s_task "$tasks"
    [ "$status" -eq 1 ]
}

@test "is_single_s_task returns false for multiple S-tasks" {
    local tasks='[{"id":1,"description":"**(S)** Task one","agent":"default","status":"pending"},{"id":2,"description":"**(S)** Task two","agent":"default","status":"pending"}]'
    run is_single_s_task "$tasks"
    [ "$status" -eq 1 ]
}

@test "is_single_s_task returns false for mixed S and M tasks" {
    local tasks='[{"id":1,"description":"**(S)** Small task","agent":"default","status":"pending"},{"id":2,"description":"**(M)** Medium task","agent":"default","status":"pending"}]'
    run is_single_s_task "$tasks"
    [ "$status" -eq 1 ]
}

@test "is_single_s_task returns false for empty task list" {
    local tasks='[]'
    run is_single_s_task "$tasks"
    [ "$status" -eq 1 ]
}

@test "is_single_s_task returns false for single task without size marker" {
    local tasks='[{"id":1,"description":"Add threshold check to hook","agent":"default","status":"pending"}]'
    run is_single_s_task "$tasks"
    [ "$status" -eq 1 ]
}
