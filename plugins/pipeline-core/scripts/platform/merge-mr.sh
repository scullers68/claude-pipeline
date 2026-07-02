#!/bin/bash
# Usage: merge-mr.sh <mr-number>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Config resolution: explicit project first, script-relative second (test
# sandboxes / legacy copied trees), cwd-project last.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.claude/config/platform.sh" ]; then
    PLATFORM_CONFIG="$CLAUDE_PROJECT_DIR/.claude/config/platform.sh"
elif [ -f "$SCRIPT_DIR/../../config/platform.sh" ]; then
    PLATFORM_CONFIG="$SCRIPT_DIR/../../config/platform.sh"
elif [ -f "$SCRIPT_DIR/../../../../.claude/config/platform.sh" ]; then
    # Plugin living inside a checked-out repo (dogfood/CI): repo-level config.
    PLATFORM_CONFIG="$SCRIPT_DIR/../../../../.claude/config/platform.sh"
else
    PLATFORM_CONFIG="$PWD/.claude/config/platform.sh"
fi
source "$PLATFORM_CONFIG"

MR="$1"

wait_for_mergeable() {
  local pr="$1"
  local interval=10
  local max=90
  local elapsed=0

  while [ "$elapsed" -lt "$max" ]; do
    local state
    state=$(gh pr view "$pr" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")

    case "$state" in
      MERGEABLE)
        return 0
        ;;
      CONFLICTING)
        echo "PR has unresolvable merge conflicts" >&2
        return 1
        ;;
      *)
        echo "Waiting for PR #$pr to become mergeable (state: $state, ${elapsed}s elapsed)..." >&2
        sleep "$interval"
        elapsed=$((elapsed + interval))
        ;;
    esac
  done

  echo "Timed out waiting for GitHub to compute mergeability" >&2
  return 1
}

case "$GIT_HOST" in
  github)
    wait_for_mergeable "$MR" || exit 1
    case "$MERGE_STYLE" in
      squash) gh pr merge "$MR" --squash --delete-branch ;;
      merge) gh pr merge "$MR" --merge --delete-branch ;;
      rebase) gh pr merge "$MR" --rebase --delete-branch ;;
    esac
    ;;
  gitlab)
    case "$MERGE_STYLE" in
      squash) glab mr merge "$MR" --squash --remove-source-branch --yes ;;
      merge) glab mr merge "$MR" --remove-source-branch --yes ;;
      rebase) glab mr merge "$MR" --rebase --remove-source-branch --yes ;;
    esac
    ;;
esac
