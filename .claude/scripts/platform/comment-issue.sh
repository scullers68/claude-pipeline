#!/bin/bash
# Usage: comment-issue.sh <issue-number-or-key> "Comment body"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

ISSUE="$1" COMMENT="$2"

case "$TRACKER" in
  github) gh issue comment "$ISSUE" --body "$COMMENT" ;;
  jira)
    # Convert markdown to Atlassian Document Format (ADF) JSON
    ADF_COMMENT=$(printf '%s' "$COMMENT" | python3 "$SCRIPT_DIR/markdown-to-adf.py")
    acli jira workitem comment create --key "$ISSUE" --body "$ADF_COMMENT"
    ;;
esac
