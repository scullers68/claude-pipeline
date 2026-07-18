#!/usr/bin/env bash
# measure-arm-b.sh — sum token usage for an Arm-B (/epic-task-loop) run from
# the interactive transcript JSONL, attributed by working directory.
#
# Arm B has no metrics.json (that is a pipeline artefact), so canary-measure.sh
# cannot read it. This reducer reads the Claude Code transcripts directly and
# aggregates the SAME fields as docs/experiments/tally.sh (Arm A), so the two
# arms are directly comparable on the experiment's primary metric: WEIGHTED
# tokens (input + cache_creation + output — the cap-impact proxy; see
# ab-pipeline-vs-epic-task-loop.md §4/§5.6).
#
# Attribution (the critical fairness detail, per §5.5):
#   A transcript record counts iff its `cwd` == --cwd (or a descendant), so the
#   Arm-B session MUST run from a dedicated per-issue directory. An optional
#   --since ISO-8601 timestamp further bounds to records at/after run start, so
#   unrelated earlier activity in that cwd is excluded.
#
# Synthetic records (model == "<synthetic>", e.g. injected system reminders)
# carry zero real usage and are skipped from the turn count.
#
# Usage:
#   measure-arm-b.sh --cwd <dir> [--since <iso8601>] [--until <iso8601>]
#                    [--transcripts-dir <dir>] [--label <name>]
#
# Defaults: --transcripts-dir ~/.claude/projects
#
# The dollar figure is intentionally NOT computed here (transcripts carry
# tokens, not cost). Capture Arm-B $ from `/cost` (start→end delta) or
# `npx ccusage` per the runbook; compare arms on WEIGHTED tokens.
set -euo pipefail

CWD_MATCH=""
SINCE=""
UNTIL=""
TRANSCRIPTS_DIR="${HOME}/.claude/projects"
LABEL="arm-b"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--cwd)              CWD_MATCH="${2:?--cwd requires a value}"; shift 2 ;;
		--since)            SINCE="${2:?--since requires a value}"; shift 2 ;;
		--until)            UNTIL="${2:?--until requires a value}"; shift 2 ;;
		--transcripts-dir)  TRANSCRIPTS_DIR="${2:?--transcripts-dir requires a value}"; shift 2 ;;
		--label)            LABEL="${2:?--label requires a value}"; shift 2 ;;
		-h|--help)          sed -n '2,33p' "$0"; exit 0 ;;
		*) printf 'ERROR: unknown arg: %s\n' "$1" >&2; exit 1 ;;
	esac
done

[[ -n "$CWD_MATCH" ]] || { printf 'ERROR: --cwd is required\n' >&2; exit 1; }
[[ -d "$TRANSCRIPTS_DIR" ]] || { printf 'ERROR: transcripts dir not found: %s\n' "$TRANSCRIPTS_DIR" >&2; exit 1; }
command -v jq >/dev/null || { printf 'ERROR: jq required\n' >&2; exit 1; }

# Resolve the canonical absolute cwd so descendant matching is robust.
CWD_MATCH="$(cd "$CWD_MATCH" 2>/dev/null && pwd || echo "$CWD_MATCH")"

# Pre-filter to the project dir instead of scanning all ~10k+ transcripts
# (same optimisation as canary-measure.sh). ~/.claude/projects organises
# transcripts under a dir whose name is the cwd with every non-alphanumeric
# char replaced by '-'. Scope find to that dir (+ any descendant-cwd dirs that
# share the prefix); fall back to a full scan if the prefix yields nothing, so
# an unexpected mangling never silently under-counts. The cwd field is still
# verified inside jq, so a loose prefix cannot over-count.
MANGLED="$(printf '%s' "$CWD_MATCH" | sed 's/[^a-zA-Z0-9]/-/g')"
scope_dirs=()
while IFS= read -r d; do scope_dirs+=("$d"); done < <(
	find "$TRANSCRIPTS_DIR" -maxdepth 1 -type d -name "${MANGLED}*" 2>/dev/null)
if (( ${#scope_dirs[@]} == 0 )); then
	scope_dirs=("$TRANSCRIPTS_DIR")   # fallback: full scan
fi

# Aggregate, filtering per-record on cwd/time/synthetic. Slurp is bounded to
# the scoped project dir(s), not the whole transcript store.
find "${scope_dirs[@]}" -name '*.jsonl' -type f -print0 2>/dev/null \
| xargs -0 cat 2>/dev/null \
| jq -rs --arg cwd "$CWD_MATCH" --arg since "$SINCE" --arg until "$UNTIL" --arg label "$LABEL" '
	[ .[]
	  | select(.type == "assistant")
	  | select(.cwd == $cwd or (.cwd | tostring | startswith($cwd + "/")))
	  | select(($since == "") or ((.timestamp // "") >= $since))
	  | select(($until == "") or ((.timestamp // "") <= $until))
	  | select((.message.model // .model // "") != "<synthetic>")
	  | .message.usage // .usage
	  | select(. != null)
	]
	| {
		turns: length,
		in:  (map(.input_tokens // 0)                | add // 0),
		cw:  (map(.cache_creation_input_tokens // 0) | add // 0),
		cr:  (map(.cache_read_input_tokens // 0)     | add // 0),
		out: (map(.output_tokens // 0)               | add // 0)
	  }
	| .weighted = (.in + .cw + .out)
	| .raw      = (.in + .cw + .cr + .out)
	| "ARM-B (\($label))  cwd=\($cwd)\n" +
	  "turns(assistant messages): \(.turns)\n" +
	  "in=\(.in)  cache_write=\(.cw)  cache_read=\(.cr)  out=\(.out)\n" +
	  "WEIGHTED (in+cw+out, cap proxy): \(.weighted)\n" +
	  "RAW (incl cache-read):           \(.raw)"
	'
