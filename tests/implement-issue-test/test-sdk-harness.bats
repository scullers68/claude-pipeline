#!/usr/bin/env bats
#
# test-sdk-harness.bats
# Parity suite for the SDK harness (ORCHESTRATOR_ENGINE=sdk, issue #11).
#
# Drives the compiled TypeScript harness (plugins/pipeline-core/sdk) through a
# full single-issue run — parse → implement → test → review → pr — with a mock
# `claude` CLI that replays the same shared stage fixtures the bash engine uses,
# then asserts the emitted status.json passes the bash-side helper assertions.
# This is the cross-engine check: the SDK path must produce a status.json the
# bash test helpers accept, exactly as the bash engine does.
#
# Fast by construction (mock CLI, no real sessions); belongs in the per-push
# fast job. The SDK is built once via npm; if npm/node are unavailable the
# tests skip rather than hard-fail.

load 'helpers/test-helper.bash'

setup() {
    setup_test_env

    REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SDK_DIR="$REPO/plugins/pipeline-core/sdk"
    HARNESS="$SDK_DIR/dist/index.js"
    FIXTURES_DIR="$REPO/tests/implement-issue-test/fixtures"
    STAGE_SCHEMA="$REPO/plugins/pipeline-core/scripts/schemas/stage-result.json"

    command -v node >/dev/null 2>&1 || skip "node not available"

    # Build once; CI builds ahead of this step, so locally this is a no-op after
    # the first run. A build failure skips rather than reporting a false red.
    if [[ ! -f "$HARNESS" ]]; then
        ( cd "$SDK_DIR" && npm ci --silent && npm run build --silent ) \
            >/dev/null 2>&1 || skip "SDK build unavailable"
    fi

    # A mock `claude` that maps the SDK_STAGE the harness sets per stage to a
    # shared fixture. Per-stage output is overridable via MOCK_<UPPER_STAGE> so
    # a test can force a failing stage (e.g. MOCK_PR_REVIEW).
    MOCK_CLI="$TEST_TMP/mock-claude"
    cat > "$MOCK_CLI" <<MOCK_EOF
#!/usr/bin/env bash
stage="\${SDK_STAGE:-}"
case "\$stage" in
    parse_issue) fixture=setup-success.json ;;
    implement)   fixture=implement-success.json ;;
    test_loop)   fixture=test-passed.json ;;
    pr_review)   fixture=review-approved.json ;;
    pr)          fixture=pr-success.json ;;
    *)           echo "mock: unknown stage '\$stage'" >&2; exit 1 ;;
esac
override_var="MOCK_\$(printf '%s' "\$stage" | tr '[:lower:]' '[:upper:]')"
fixture="\${!override_var:-\$fixture}"
cat "$FIXTURES_DIR/\$fixture"
MOCK_EOF
    chmod +x "$MOCK_CLI"

    STATUS_FILE="$TEST_TMP/status.json"
}

teardown() {
    teardown_test_env
}

# Invoke the harness in orchestrator mode with the mock CLI wired in. Any
# args are extra VAR=value overrides, applied via `env` so they are parsed as
# assignments at runtime (a bare "$@" prefix would be taken as the command name
# once expanded, since bash fixes assignment-prefixes before expansion).
run_harness() {
    ORCHESTRATOR_ENGINE=sdk \
    ISSUE=123 \
    BASE_BRANCH=main \
    LOG_DIR="$TEST_TMP/logs" \
    STATUS_FILE="$STATUS_FILE" \
    STAGE_SCHEMA="$STAGE_SCHEMA" \
    CLAUDE_CLI="$MOCK_CLI" \
    env "$@" node "$HARNESS"
}

@test "sdk harness: full run over shared fixtures ends state=success" {
    run run_harness
    assert_exit_code "$status" 0

    assert_file_exists "$STATUS_FILE"
    run jq empty "$STATUS_FILE"
    assert_exit_code "$status" 0 "status.json must be valid JSON"

    assert_json_field "$STATUS_FILE" '.state' 'success'
    assert_json_field "$STATUS_FILE" '.current_stage' 'complete'
    assert_json_field "$STATUS_FILE" '.stages.parse_issue.status' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.implement.status' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.test_loop.status' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.pr_review.status' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.pr.status' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.complete.status' 'completed'
}

@test "sdk harness: parse stage carries branch + task progress into status.json" {
    run run_harness
    assert_exit_code "$status" 0

    # setup-success.json declares branch feat/issue-123 and three tasks.
    assert_json_field "$STATUS_FILE" '.branch' 'feat/issue-123'
    assert_json_field "$STATUS_FILE" '.stages.implement.task_progress' '3/3'
    assert_json_field "$STATUS_FILE" '.stages.pr.pr_number' '456'
}

@test "sdk harness: review loop bails to state=failed when it exhausts the budget" {
    # Force the review stage to keep requesting changes; the loop must stop at
    # the MAX_PR_REVIEW_ITERATIONS default (2) with a failed status, not spin.
    run run_harness MOCK_PR_REVIEW=review-changes-requested.json
    assert_exit_code "$status" 1

    assert_json_field "$STATUS_FILE" '.state' 'failed'
    assert_json_field "$STATUS_FILE" '.current_stage' 'pr_review'
    assert_json_field "$STATUS_FILE" '.stages.pr_review.status' 'failed'
    assert_json_field "$STATUS_FILE" '.pr_review_iterations' '2'
    assert_json_field "$STATUS_FILE" '.stages.pr.status' 'pending'
}
