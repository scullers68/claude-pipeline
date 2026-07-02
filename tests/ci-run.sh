#!/usr/bin/env bash
# CI test runner: runs a bats target and fails only on failures that are not
# in tests/known-reds.txt. Prints new failures loudly, known reds as warnings.
#
# Usage: tests/ci-run.sh <bats-target> [<bats-target>...]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KNOWN_REDS="$REPO_ROOT/tests/known-reds.txt"
LOG=$(mktemp)

bats "$@" 2>&1 | tee "$LOG"
suite_rc=${PIPESTATUS[0]}

# Guard against false greens: if bats produced no TAP plan, it crashed
# before running anything — that is a failure, not a pass.
if ! grep -qE '^1\.\.[0-9]+' "$LOG"; then
    echo "CI: FATAL — bats produced no test plan (launch failure, rc=$suite_rc)." >&2
    exit 1
fi

# Collect failure descriptions (strip "not ok N ") — portable, no mapfile
failures=()
while IFS= read -r line; do
    failures+=("$line")
done < <(grep '^not ok' "$LOG" | sed -E 's/^not ok [0-9]+ //')

if (( ${#failures[@]} == 0 )); then
    echo "CI: all tests passed."
    exit 0
fi

new_failures=()
known_hits=()
for f in "${failures[@]}"; do
    if grep -Fxq "$f" "$KNOWN_REDS" 2>/dev/null; then
        known_hits+=("$f")
    else
        new_failures+=("$f")
    fi
done

if (( ${#known_hits[@]} > 0 )); then
    echo ""
    echo "CI: ${#known_hits[@]} known pre-existing failure(s) (tracked in tests/known-reds.txt):"
    printf '  KNOWN: %s\n' "${known_hits[@]}"
fi

if (( ${#new_failures[@]} > 0 )); then
    echo ""
    echo "CI: ${#new_failures[@]} NEW failure(s) — not in tests/known-reds.txt:"
    printf '  NEW: %s\n' "${new_failures[@]}"
    exit 1
fi

echo ""
echo "CI: no new failures (suite rc=$suite_rc ignored — all failures are known reds)."
exit 0
