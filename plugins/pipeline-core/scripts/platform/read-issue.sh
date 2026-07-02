#!/bin/bash
# Usage: read-issue.sh <issue-number-or-key>
# Returns: JSON { title, body, status }
# Body is always returned as plain markdown text.
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
source "$PLATFORM_CONFIG"

ISSUE="$1"

case "$TRACKER" in
  github)
    gh issue view "$ISSUE" --json title,body,state \
      | jq '{ title, body, status: .state }'
    ;;
  jira)
    # acli returns description as ADF (Atlassian Document Format) JSON.
    # Pipe through adf-to-markdown.py to convert to { title, body, status }.
    acli jira workitem view "$ISSUE" --fields summary,description,status --json 2>/dev/null \
      | python3 "$SCRIPT_DIR/adf-to-markdown.py"
    ;;
esac
