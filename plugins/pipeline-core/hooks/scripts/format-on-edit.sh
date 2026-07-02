#!/usr/bin/env bash
# PostToolUse(Edit|Write): run the project's formatter on the edited file.
# Reads FORMAT_CMD from the consumer project's pipeline config; no-ops if unset.
# Replaces the inline jq pipeline previously embedded in settings.json.
set -uo pipefail
input=$(cat)
f=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$f" ] && exit 0
# shellcheck disable=SC1091
source "$CLAUDE_PROJECT_DIR/.claude/config/platform.sh" 2>/dev/null || exit 0
[ -z "${FORMAT_CMD:-}" ] && exit 0
cd "$CLAUDE_PROJECT_DIR" && eval "$FORMAT_CMD" "$f" 2>/dev/null || true
exit 0
