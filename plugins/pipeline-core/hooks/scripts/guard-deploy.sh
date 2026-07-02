#!/usr/bin/env bash
# PreToolUse(Bash) guard: block direct production deploy commands.
# Replaces the inline python3 one-liner previously embedded in settings.json.
set -euo pipefail
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0
for part in $cmd; do
  if [[ "$part" == *deploy_to_production* ]]; then
    echo "Blocked production deploy command: $cmd — deploys go through the pipeline, not ad-hoc." >&2
    exit 2
  fi
done
exit 0
