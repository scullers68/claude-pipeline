#!/bin/bash
# Usage: read-mr-comments.sh <mr-number>
# Returns: JSON array of comment bodies
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

case "$GIT_HOST" in
  github) gh pr view "$MR" --json comments --jq '[.comments[].body]' ;;
  gitlab) glab mr note list "$MR" --output json 2>/dev/null | jq '[.[].body]' ;;
esac
