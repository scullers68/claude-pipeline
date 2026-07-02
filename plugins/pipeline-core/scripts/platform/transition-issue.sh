#!/bin/bash
# Usage: transition-issue.sh <issue-number-or-key> [transition-name]
# GitHub: closes the issue
# Jira: transitions to the named state (defaults to JIRA_DONE_TRANSITION)
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

ISSUE="$1"
TRANSITION="${2:-$JIRA_DONE_TRANSITION}"

case "$TRACKER" in
  github) gh issue close "$ISSUE" ;;
  jira) acli jira workitem transition --key "$ISSUE" --status "$TRANSITION" ;;
esac
