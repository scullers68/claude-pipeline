#!/usr/bin/env bash
# PreToolUse(Edit|Write) guard: block edits to sensitive or generated files.
# Replaces the inline python3 one-liner previously embedded in settings.json.
set -euo pipefail
input=$(cat)
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$path" ] && exit 0
case "$path" in
  *.env*|*/.git/*|*credentials*|*package-lock.json)
    echo "Blocked edit to sensitive/generated file: $path" >&2
    exit 2 ;;
esac
exit 0
