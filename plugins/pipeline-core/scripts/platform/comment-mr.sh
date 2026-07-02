#!/bin/bash
# Usage: comment-mr.sh <mr-number> "Comment body" [repo]
# Adds a comment to a PR (GitHub) or MR (GitLab)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Config resolution: explicit project first, script-relative second (test
# sandboxes / legacy copied trees), cwd-project last.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.claude/config/platform.sh" ]; then
    PLATFORM_CONFIG="$CLAUDE_PROJECT_DIR/.claude/config/platform.sh"
elif [ -f "$SCRIPT_DIR/../../config/platform.sh" ]; then
    PLATFORM_CONFIG="$SCRIPT_DIR/../../config/platform.sh"
else
    PLATFORM_CONFIG="$PWD/.claude/config/platform.sh"
fi
if [[ -f "$PLATFORM_CONFIG" ]]; then source "$PLATFORM_CONFIG"; fi

MR="$1" COMMENT="$2" REPO_ARG="${3:-}"

case "${GIT_HOST:-github}" in
  github)
    if [[ -n "$REPO_ARG" ]]; then
      gh pr comment "$MR" -R "$REPO_ARG" --body "$COMMENT"
    else
      gh pr comment "$MR" --body "$COMMENT"
    fi
    ;;
  gitlab) glab mr note "$MR" --message "$COMMENT" ;;
esac
