#!/usr/bin/env bats
#
# test-argument-parsing.bats
# Tests for implement-issue-orchestrator.sh argument parsing
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    # Create minimal schema so the script can start
    echo '{}' > "$TEST_TMP/schemas/implement-issue-setup.json"
    # Set GITHUB_REPO so valid-arg tests pass repo detection
    export GITHUB_REPO="test-owner/test-repo"
}

teardown() {
    teardown_test_env
}

# =============================================================================
# REQUIRED ARGUMENTS
# =============================================================================

@test "fails without any arguments" {
    run bash "$ORCHESTRATOR_SCRIPT" 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--issue and --branch are required"* ]]
}

@test "fails with only --issue" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--issue and --branch are required"* ]]
}

@test "fails with only --branch" {
    run bash "$ORCHESTRATOR_SCRIPT" --branch test 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--issue and --branch are required"* ]]
}

@test "fails with --issue but no value" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--issue requires a value"* ]]
}

@test "fails with --branch but no value" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--branch requires a value"* ]]
}

# =============================================================================
# OPTIONAL ARGUMENTS
# =============================================================================

@test "accepts --agent option" {
    # Run with timeout so the script doesn't hang past the header.
    # We only care that the header reflects the parsed --agent value.
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --agent fastify-backend-developer 2>&1
    [ -n "$output" ]
    [[ "$output" == *"Agent: fastify-backend-developer"* ]]
}

@test "fails with --agent but no value" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --agent 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--agent requires a value"* ]]
}

@test "accepts --status-file option" {
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --status-file custom-status.json 2>&1
    [ -n "$output" ]
    [[ "$output" == *"Status file: "*"custom-status.json"* ]]
}

@test "fails with --status-file but no value" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --status-file 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--status-file requires a value"* ]]
}

@test "default status file is resolved to an absolute path" {
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test 2>&1
    [ -n "$output" ]
    [[ "$output" =~ "Status file: /" ]]
}

@test "relative --status-file is resolved to an absolute path" {
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" \
        --issue 123 --branch test --status-file relative.json 2>&1
    [ -n "$output" ]
    [[ "$output" =~ "Status file: /" ]]
    [[ "$output" == *"relative.json"* ]]
}

@test "absolute --status-file is kept as-is" {
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" \
        --issue 123 --branch test --status-file /tmp/absolute.json 2>&1
    [ -n "$output" ]
    [[ "$output" == *"Status file: /tmp/absolute.json"* ]]
}

# =============================================================================
# HELP
# =============================================================================

@test "--help shows usage" {
    run bash "$ORCHESTRATOR_SCRIPT" --help 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"--issue"* ]]
    [[ "$output" == *"--branch"* ]]
}

@test "-h shows usage" {
    run bash "$ORCHESTRATOR_SCRIPT" -h 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# UNKNOWN OPTIONS
# =============================================================================

@test "fails with unknown option" {
    run bash "$ORCHESTRATOR_SCRIPT" --unknown 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"Unknown option: --unknown"* ]]
}

# =============================================================================
# VALID INVOCATION OUTPUT
# =============================================================================

@test "prints issue number in header" {
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 456 --branch main 2>&1
    [ -n "$output" ]
    [[ "$output" == *"Issue: #456"* ]]
}

@test "prints branch name in header" {
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch feature-branch 2>&1
    [ -n "$output" ]
    [[ "$output" == *"Branch: feature-branch"* ]]
}

@test "defaults agent to 'default' when not specified" {
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test 2>&1
    [ -n "$output" ]
    [[ "$output" == *"Agent: default"* ]]
}

@test "defaults status file to status.json" {
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test 2>&1
    [ -n "$output" ]
    [[ "$output" == *"Status file: "*"status.json"* ]]
}

# =============================================================================
# --quiet FLAG
# =============================================================================

@test "--quiet flag is accepted without error" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --quiet --help 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" != *"Unknown option: --quiet"* ]]
}

@test "--quiet flag does not appear as unknown option" {
    run bash "$ORCHESTRATOR_SCRIPT" --quiet 2>&1
    # --quiet without required args still fails, but NOT as unknown option
    [ "$status" -ne 0 ]
    [[ "$output" != *"Unknown option: --quiet"* ]]
}

# =============================================================================
# DRY-RUN / NO-COMMENT / STOP-AFTER (issue #18)
# --no-comment (alias of --quiet), --dry-run (quiet + skip PR/push/merge), and
# --stop-after <stage> (exit cleanly once <stage> completes). Side-effect-free
# and partial runs for measurement/testing.
# =============================================================================

@test "--no-comment is accepted (not an unknown option) (#18)" {
    run bash "$ORCHESTRATOR_SCRIPT" --no-comment 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" != *"Unknown option: --no-comment"* ]]
}

@test "--dry-run is accepted (not an unknown option) (#18)" {
    run bash "$ORCHESTRATOR_SCRIPT" --dry-run 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" != *"Unknown option: --dry-run"* ]]
}

@test "--stop-after is accepted (not an unknown option) (#18)" {
    run bash "$ORCHESTRATOR_SCRIPT" --stop-after implement 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" != *"Unknown option: --stop-after"* ]]
}

@test "--stop-after requires a stage value (#18)" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --stop-after 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" == *"--stop-after requires"* ]]
}

# Behavioral: the stop-after mechanism lives in set_stage_completed — once the
# requested stage completes, the run exits 0 (EXIT trap still writes metrics).
_seed_running_status() {
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    mkdir -p "$LOG_BASE/stages"
    echo '{"stages":{},"state":"running"}' > "$STATUS_FILE"
}

@test "set_stage_completed exits 0 and marks state=stopped after the --stop-after stage (#18)" {
    source_orchestrator_functions
    _seed_running_status
    export STOP_AFTER=implement
    run set_stage_completed implement
    [ "$status" -eq 0 ]
    [[ "$output" == *"Stopping after stage 'implement'"* ]] || {
        printf 'FAIL: no stop log. Output: %s\n' "$output" >&2; return 1; }
    [ "$(jq -r '.state' "$STATUS_FILE")" = "stopped" ]
}

@test "set_stage_completed does NOT stop for a non-matching stage (#18)" {
    source_orchestrator_functions
    _seed_running_status
    export STOP_AFTER=implement
    run set_stage_completed triage
    [ "$status" -eq 0 ]
    [[ "$output" != *"Stopping after"* ]]
    [ "$(jq -r '.state' "$STATUS_FILE")" = "running" ]
}

@test "set_stage_completed does NOT stop when --stop-after unset (default behaviour) (#18)" {
    source_orchestrator_functions
    _seed_running_status
    unset STOP_AFTER
    run set_stage_completed implement
    [ "$status" -eq 0 ]
    [[ "$output" != *"Stopping after"* ]]
    [ "$(jq -r '.state' "$STATUS_FILE")" = "running" ]
}

@test "comment_issue is a no-op when QUIET (dry-run implies --no-comment) (#18)" {
    source_orchestrator_functions
    _seed_running_status
    export QUIET=true
    run comment_issue "Test Title" "Test Body"
    [ "$status" -eq 0 ]
    # Short-circuits before formatting — the title never reaches output.
    [[ "$output" != *"Test Title"* ]]
}
