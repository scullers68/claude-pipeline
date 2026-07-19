#!/usr/bin/env bash
#
# git-safety.sh — safe git-stash helpers (issue #17)
#
# Sourceable library. The pipeline stashes a dirty working tree before a branch
# checkout and pops afterwards. A bare `git stash pop` pops whatever is on TOP
# of the stash stack — which may be a *concurrent* pipeline run's stash or the
# user's own stash that landed on top in the meantime. That is how the A/B
# experiment lost (then luckily recovered) an unrelated stash.
#
# These helpers scope stash operations to the exact stash WE created, keyed by
# its commit SHA, so a stranger's stash is never touched. Source this file and
# call safe_stash_push / safe_stash_pop; do NOT use a bare `git stash pop`
# anywhere else in the pipeline (enforced by a lint test).
#
# No side effects at source time. Idempotent to re-source.

# safe_stash_push <message>
# Push the working tree (including untracked files) onto the stash and print
# the created stash's commit SHA to stdout. The SHA is the durable handle the
# caller passes to safe_stash_pop later — it survives other stashes landing on
# top. Returns non-zero (and prints nothing) if the push fails.
safe_stash_push() {
    local msg="${1:-pipeline auto-stash}"
    git stash push --include-untracked -m "$msg" >/dev/null 2>&1 || return 1
    # The just-created stash is stash@{0}; its commit SHA is our durable handle.
    git rev-parse -q --verify 'stash@{0}' 2>/dev/null || return 1
}

# safe_stash_pop <stash_sha>
# Pop ONLY the stash whose commit SHA matches <stash_sha>, wherever it now sits
# in the stack — never a bare pop of whatever is on top. Returns:
#   0  popped our stash successfully
#   1  our stash is not present (gone / bad sha) — nothing popped, no stranger
#      touched
#   2  our stash was found but `git stash pop` reported a conflict
safe_stash_pop() {
    local sha="${1:-}"
    [[ -n "$sha" ]] || return 1

    # Locate our stash by commit SHA. `git stash list --format='%gd %H'` prints
    # one "stash@{N} <commit-sha>" per line; match ours and pop that ref only.
    local ref
    ref=$(git stash list --format='%gd %H' 2>/dev/null \
        | awk -v s="$sha" '$2 == s { print $1; exit }')
    [[ -n "$ref" ]] || return 1

    git stash pop "$ref" >/dev/null 2>&1 || return 2
    return 0
}
