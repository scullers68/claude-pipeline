#!/bin/bash
# Usage: create-mr.sh --source "branch" --target "main" --title "Title" --body "Body"
# Returns: MR/PR number on stdout
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

SOURCE="" TARGET="" TITLE="" BODY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$GIT_HOST" in
  github)
    gh pr create --head "$SOURCE" --base "$TARGET" --title "$TITLE" --body "$BODY" \
      2>/dev/null | grep -oE '[0-9]+$'
    ;;
  gitlab)
    glab mr create --source-branch "$SOURCE" --target-branch "$TARGET" \
      --title "$TITLE" --description "$BODY" --squash-on-merge --no-editor \
      2>/dev/null | grep -oE '![0-9]+' | tr -d '!'
    ;;
esac
