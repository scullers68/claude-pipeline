#!/usr/bin/env bats
#
# test-export-metrics.bats
# Tests for the export_metrics() function
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env

    export ISSUE_NUMBER=123
    export BASE_BRANCH=main
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

    source_orchestrator_functions

    # Initialise a baseline status file with timestamps in two stages
    init_status
}

teardown() {
    teardown_test_env
}

# =============================================================================
# HELPERS
# =============================================================================

# Write a minimal valid status file with known timestamps
_write_status_with_timestamps() {
    jq --arg branch "feature/issue-123" \
       --arg state "completed" \
       '.branch = $branch |
        .state  = $state  |
        .stages.parse_issue.started_at   = "2024-01-01T10:00:00Z" |
        .stages.parse_issue.completed_at = "2024-01-01T10:00:30Z" |
        .stages.parse_issue.status       = "completed"             |
        .stages.parse_issue.model        = "claude-haiku-4-5"      |
        .stages.validate_plan.started_at   = "2024-01-01T10:00:31Z" |
        .stages.validate_plan.completed_at = "2024-01-01T10:01:01Z" |
        .stages.validate_plan.status       = "completed"' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# =============================================================================
# FILE CREATION (AC1)
# =============================================================================

@test "export_metrics creates metrics.json in LOG_BASE" {
    _write_status_with_timestamps
    export_metrics
    [ -f "$LOG_BASE/metrics.json" ]
}

@test "export_metrics writes valid JSON" {
    _write_status_with_timestamps
    export_metrics
    jq -e '.' "$LOG_BASE/metrics.json" >/dev/null 2>&1 || fail "metrics.json is not valid JSON"
}

@test "export_metrics succeeds when STATUS_FILE is missing (no crash)" {
    rm -f "$STATUS_FILE"
    run export_metrics
    [ "$status" -eq 0 ]
}

@test "export_metrics does not create metrics.json when STATUS_FILE is missing" {
    rm -f "$STATUS_FILE"
    export_metrics
    [ ! -f "$LOG_BASE/metrics.json" ]
}

# =============================================================================
# SCHEMA TOP-LEVEL FIELDS (AC2, AC4)
# =============================================================================

@test "metrics.json contains schema_version field" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.schema_version' "$LOG_BASE/metrics.json")
    [ "$v" = "2" ]
}

@test "metrics.json contains issue field" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.issue' "$LOG_BASE/metrics.json")
    [ "$v" = "123" ]
}

@test "metrics.json contains base_branch field" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.base_branch' "$LOG_BASE/metrics.json")
    [ "$v" = "main" ]
}

@test "metrics.json contains branch field" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.branch' "$LOG_BASE/metrics.json")
    [ "$v" = "feature/issue-123" ]
}

@test "metrics.json contains state field" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.state' "$LOG_BASE/metrics.json")
    [ "$v" = "completed" ]
}

@test "metrics.json contains stages object" {
    _write_status_with_timestamps
    export_metrics
    local t
    t=$(jq -r '.stages | type' "$LOG_BASE/metrics.json")
    [ "$t" = "object" ]
}

@test "metrics.json contains escalations array" {
    _write_status_with_timestamps
    export_metrics
    local t
    t=$(jq -r '.escalations | type' "$LOG_BASE/metrics.json")
    [ "$t" = "array" ]
}

@test "metrics.json contains iteration_summary object" {
    _write_status_with_timestamps
    export_metrics
    local t
    t=$(jq -r '.iteration_summary | type' "$LOG_BASE/metrics.json")
    [ "$t" = "object" ]
}

# =============================================================================
# DURATION CALCULATION (AC2)
# =============================================================================

@test "metrics.json calculates per-stage duration_seconds" {
    _write_status_with_timestamps
    export_metrics
    local dur
    dur=$(jq -r '.stages.parse_issue.duration_seconds' "$LOG_BASE/metrics.json")
    # 10:00:30 - 10:00:00 = 30 seconds
    [ "$dur" = "30" ]
}

@test "metrics.json duration_seconds is null when timestamps are missing" {
    _write_status_with_timestamps
    # validate_plan has timestamps, but remove them from one stage
    jq '.stages.quality_loop.started_at = null | .stages.quality_loop.completed_at = null' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    export_metrics
    local dur
    dur=$(jq -r '.stages.quality_loop.duration_seconds' "$LOG_BASE/metrics.json")
    [ "$dur" = "null" ]
}

@test "metrics.json calculates total_duration_seconds from earliest to latest stage" {
    _write_status_with_timestamps
    export_metrics
    local total
    total=$(jq -r '.total_duration_seconds' "$LOG_BASE/metrics.json")
    # earliest started: 10:00:00, latest completed: 10:01:01 = 61 seconds
    [ "$total" = "61" ]
}

@test "metrics.json total_duration_seconds is null when no stage timestamps exist" {
    init_status
    export_metrics
    local total
    total=$(jq -r '.total_duration_seconds' "$LOG_BASE/metrics.json")
    [ "$total" = "null" ]
}

# =============================================================================
# MODEL TRACKING (AC2)
# =============================================================================

@test "metrics.json preserves model field per stage" {
    _write_status_with_timestamps
    export_metrics
    local model
    model=$(jq -r '.stages.parse_issue.model' "$LOG_BASE/metrics.json")
    [ "$model" = "claude-haiku-4-5" ]
}

@test "metrics.json model is null for stages without model tracking" {
    _write_status_with_timestamps
    export_metrics
    local model
    model=$(jq -r '.stages.validate_plan.model // "null"' "$LOG_BASE/metrics.json")
    [ "$model" = "null" ]
}

# =============================================================================
# ESCALATION EVENTS (AC2)
# =============================================================================

@test "metrics.json escalations is empty array when no escalations occurred" {
    _write_status_with_timestamps
    export_metrics
    local count
    count=$(jq '.escalations | length' "$LOG_BASE/metrics.json")
    [ "$count" = "0" ]
}

@test "metrics.json escalations contains recorded escalation events" {
    _write_status_with_timestamps
    record_escalation "quality_loop" "claude-haiku-4-5" "claude-sonnet-4-6" "max_turns_exhausted"
    export_metrics

    local count stage from_model to_model reason
    count=$(jq '.escalations | length' "$LOG_BASE/metrics.json")
    stage=$(jq -r '.escalations[0].stage' "$LOG_BASE/metrics.json")
    from_model=$(jq -r '.escalations[0].from_model' "$LOG_BASE/metrics.json")
    to_model=$(jq -r '.escalations[0].to_model' "$LOG_BASE/metrics.json")
    reason=$(jq -r '.escalations[0].reason' "$LOG_BASE/metrics.json")

    [ "$count" = "1" ]
    [ "$stage" = "quality_loop" ]
    [ "$from_model" = "claude-haiku-4-5" ]
    [ "$to_model" = "claude-sonnet-4-6" ]
    [ "$reason" = "max_turns_exhausted" ]
}

@test "metrics.json preserves multiple escalation events" {
    _write_status_with_timestamps
    record_escalation "quality_loop" "claude-haiku-4-5" "claude-sonnet-4-6" "max_turns_exhausted"
    record_escalation "test_loop"    "claude-haiku-4-5" "claude-sonnet-4-6" "max_turns_exhausted"
    export_metrics

    local count
    count=$(jq '.escalations | length' "$LOG_BASE/metrics.json")
    [ "$count" = "2" ]
}

# =============================================================================
# ITERATION SUMMARY (AC3)
# =============================================================================

@test "metrics.json iteration_summary contains quality_iterations" {
    _write_status_with_timestamps
    increment_quality_iteration
    increment_quality_iteration
    export_metrics

    local v
    v=$(jq -r '.iteration_summary.quality_iterations' "$LOG_BASE/metrics.json")
    [ "$v" = "2" ]
}

@test "metrics.json iteration_summary contains test_iterations" {
    _write_status_with_timestamps
    increment_test_iteration
    export_metrics

    local v
    v=$(jq -r '.iteration_summary.test_iterations' "$LOG_BASE/metrics.json")
    [ "$v" = "1" ]
}

@test "metrics.json iteration_summary contains pr_review_iterations" {
    _write_status_with_timestamps
    increment_pr_review_iteration
    increment_pr_review_iteration
    increment_pr_review_iteration
    export_metrics

    local v
    v=$(jq -r '.iteration_summary.pr_review_iterations' "$LOG_BASE/metrics.json")
    [ "$v" = "3" ]
}

@test "metrics.json iteration_summary defaults to zero when no iterations occurred" {
    _write_status_with_timestamps
    export_metrics

    local q t p
    q=$(jq -r '.iteration_summary.quality_iterations'    "$LOG_BASE/metrics.json")
    t=$(jq -r '.iteration_summary.test_iterations'       "$LOG_BASE/metrics.json")
    p=$(jq -r '.iteration_summary.pr_review_iterations'  "$LOG_BASE/metrics.json")

    [ "$q" = "0" ]
    [ "$t" = "0" ]
    [ "$p" = "0" ]
}

# =============================================================================
# STARTED_AT / COMPLETED_AT ROLLUP (AC2)
# =============================================================================

@test "metrics.json started_at is earliest stage started_at" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.started_at' "$LOG_BASE/metrics.json")
    [ "$v" = "2024-01-01T10:00:00Z" ]
}

@test "metrics.json completed_at is latest stage completed_at" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.completed_at' "$LOG_BASE/metrics.json")
    [ "$v" = "2024-01-01T10:01:01Z" ]
}

# =============================================================================
# TOKEN/COST USAGE ACCOUNTING (#15)
# metrics.json must carry per-stage and run-total token/cost usage, summed
# across ALL attempts (including discarded error_max_turns retries), parsed
# from the claude -p result envelopes in $LOG_BASE/stages/*.log. Discarded
# (churn) spend must be distinguishable from kept spend.
# =============================================================================

# Write two fixture stage logs with claude-result envelopes (plus noise lines
# the parser must skip). Totals across all attempts:
#   parse_issue (kept):        weighted 60, raw 160, cost 1.0, turns 5
#   implement-task-1 discarded: weighted 20, raw 70,  cost 2.0, turns 3
#   implement-task-1 kept:      weighted 60, raw 260, cost 3.0, turns 9
#   RUN TOTAL: weighted 140, raw 490, cost 6.0, turns 17
#   DISCARDED: weighted 20, cost 2.0
_write_stage_logs_with_usage() {
    local d="$LOG_BASE/stages"
    mkdir -p "$d"
    {
        printf '=== parse_issue output ===\n'
        printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":5,"total_cost_usd":1.0,"usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":100,"output_tokens":30}}'
        printf '=== exit code: 0 ===\n'
    } > "$d/01-parse_issue.log"
    {
        printf '=== implement-task-1 output ===\n'
        printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":3,"total_cost_usd":2.0,"usage":{"input_tokens":5,"cache_creation_input_tokens":5,"cache_read_input_tokens":50,"output_tokens":10}}'
        printf '=== implement-task-1 escalation ===\n'
        printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":9,"total_cost_usd":3.0,"usage":{"input_tokens":8,"cache_creation_input_tokens":12,"cache_read_input_tokens":200,"output_tokens":40}}'
        printf '=== exit code: 0 ===\n'
    } > "$d/02-implement-task-1.log"
}

@test "usage.run_total sums weighted/raw/cost/turns across all attempts (#15)" {
    _write_status_with_timestamps
    _write_stage_logs_with_usage
    export_metrics
    local m="$LOG_BASE/metrics.json"
    [ "$(jq -r '.usage.run_total.weighted_tokens' "$m")" = "140" ] || fail "weighted: $(jq -r '.usage.run_total.weighted_tokens' "$m")"
    [ "$(jq -r '.usage.run_total.raw_tokens' "$m")" = "490" ] || fail "raw: $(jq -r '.usage.run_total.raw_tokens' "$m")"
    [ "$(jq -r '.usage.run_total.total_cost_usd' "$m")" = "6" ] || fail "cost: $(jq -r '.usage.run_total.total_cost_usd' "$m")"
    [ "$(jq -r '.usage.run_total.num_turns' "$m")" = "17" ] || fail "turns: $(jq -r '.usage.run_total.num_turns' "$m")"
}

@test "usage.run_total distinguishes discarded (error_max_turns) spend (#15)" {
    _write_status_with_timestamps
    _write_stage_logs_with_usage
    export_metrics
    local m="$LOG_BASE/metrics.json"
    [ "$(jq -r '.usage.run_total.discarded_weighted_tokens' "$m")" = "20" ] || fail "disc weighted: $(jq -r '.usage.run_total.discarded_weighted_tokens' "$m")"
    [ "$(jq -r '.usage.run_total.discarded_cost_usd' "$m")" = "2" ] || fail "disc cost: $(jq -r '.usage.run_total.discarded_cost_usd' "$m")"
}

@test "usage.by_stage carries per-stage totals summed across attempts (#15)" {
    _write_status_with_timestamps
    _write_stage_logs_with_usage
    export_metrics
    local m="$LOG_BASE/metrics.json"
    [ "$(jq -r '.usage.by_stage["parse_issue"].weighted_tokens' "$m")" = "60" ] || fail "parse: $(jq -r '.usage.by_stage["parse_issue"]' "$m")"
    [ "$(jq -r '.usage.by_stage["implement-task-1"].weighted_tokens' "$m")" = "80" ] || fail "impl: $(jq -r '.usage.by_stage["implement-task-1"]' "$m")"
    [ "$(jq -r '.usage.by_stage["implement-task-1"].discarded_weighted_tokens' "$m")" = "20" ]
}

@test "usage.run_total is zero (not null) when no stage logs exist (#15)" {
    _write_status_with_timestamps
    export_metrics
    local m="$LOG_BASE/metrics.json"
    [ "$(jq -r '.usage.run_total.weighted_tokens' "$m")" = "0" ] || fail "weighted: $(jq -r '.usage.run_total.weighted_tokens' "$m")"
    [ "$(jq -r '.usage.run_total.total_cost_usd' "$m")" = "0" ]
    # by_stage present as an (empty) object, valid JSON
    jq -e '.usage.by_stage | type == "object"' "$m" >/dev/null || fail "by_stage not an object"
}

# =============================================================================
# NO-OP WASTE ACCOUNTING (#29)
# A stage that reports success but is failed by the silent-no-op guard (no
# commits) burned tokens for nothing. It must count as no_op — non-productive,
# distinct from the error_max_turns "discarded" bucket and NOT counted as kept.
# =============================================================================

# A stage log with a success envelope (60 weighted, $1.0) AND the guard's no_op
# marker — the shape the silent-no-op guard leaves behind.
_write_noop_stage_log() {
    local d="$LOG_BASE/stages"
    mkdir -p "$d"
    {
        printf '=== implement-task-2 output ===\n'
        printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":55,"total_cost_usd":1.0,"usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":100,"output_tokens":30}}'
        printf '=== no_op: reported success, no commits (guard-failed, #29) ===\n'
    } > "$d/02-implement-task-2.log"
}

@test "usage.run_total attributes a guard-failed no-op stage to no_op, not kept (#29)" {
    _write_status_with_timestamps
    _write_noop_stage_log
    export_metrics
    local m="$LOG_BASE/metrics.json"
    [ "$(jq -r '.usage.run_total.no_op_weighted_tokens' "$m")" = "60" ] || fail "no_op weighted: $(jq -r '.usage.run_total.no_op_weighted_tokens' "$m")"
    jq -e '.usage.run_total.no_op_cost_usd == 1' "$m" >/dev/null || fail "no_op cost: $(jq -r '.usage.run_total.no_op_cost_usd' "$m")"
    # NOT counted as error_max_turns churn
    [ "$(jq -r '.usage.run_total.discarded_weighted_tokens' "$m")" = "0" ]
    # by_stage carries it too
    [ "$(jq -r '.usage.by_stage["implement-task-2"].no_op_weighted_tokens' "$m")" = "60" ]
}

@test "usage no_op is zero for a normal (unmarked) success stage (#29)" {
    _write_status_with_timestamps
    _write_stage_logs_with_usage   # from the #15 tests: kept + discarded, no no_op marker
    export_metrics
    local m="$LOG_BASE/metrics.json"
    [ "$(jq -r '.usage.run_total.no_op_weighted_tokens' "$m")" = "0" ] || fail "unmarked stages must have no_op=0, got $(jq -r '.usage.run_total.no_op_weighted_tokens' "$m")"
}
