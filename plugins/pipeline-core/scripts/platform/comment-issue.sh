#!/bin/bash
# Usage: comment-issue.sh <issue-number-or-key> "Comment body" [repo]
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

ISSUE="$1" COMMENT="$2" REPO_ARG="${3:-}"

case "${TRACKER:-github}" in
  github)
    if [[ -n "$REPO_ARG" ]]; then
      gh issue comment "$ISSUE" -R "$REPO_ARG" --body "$COMMENT"
    else
      gh issue comment "$ISSUE" --body "$COMMENT"
    fi
    ;;
  jira)
    # Convert markdown to Atlassian Document Format (ADF) JSON
    ADF_COMMENT=$(printf '%s' "$COMMENT" | python3 "$SCRIPT_DIR/markdown-to-adf.py")
    acli jira workitem comment create --key "$ISSUE" --body "$ADF_COMMENT"
    ;;
esac
