# Arm-B run-kit — `/epic-task-loop` on issue #13

Everything needed to execute **Arm B** of the pipeline-vs-loop experiment
(`../ab-pipeline-vs-epic-task-loop.md`) as a fair head-to-head against the
already-captured **Arm A** (§10.1–10.3 of that doc).

> **Arm A is done and locked** (measured from the killed `issue-13-20260703-171225`
> pipeline run): **$13.96 / 759k weighted / 166 turns, 55% of spend discarded on
> `error_max_turns` retries.** Arm B measures what the *same* issue #13 costs when a
> single warm `/epic-task-loop` session implements it instead. This kit is set up
> and ready; running it spends real budget, so it is left for a deliberate operator.

---

## The question this run answers

> **H1.** For an equivalent unit of shipped work, the orchestrated pipeline consumes
> **more weighted tokens and more model turns** than `/epic-task-loop`.

Decision rule (per §6): H1 supported if Arm A's `weighted_tokens / shipped task` is
**>+15%** above Arm B. Pre-registered prediction (§8): Arm A **1.5×–3×** higher.

---

## What is already set up

| Thing | State |
|-------|-------|
| Isolated base worktree | **created** at `../../../claude-pipeline-armB-issue13` on branch `armB/issue-13`, checked out at `c53f753` — the *exact* commit Arm A started from, with #13's work **absent** (clean base). |
| Transcript reducer | `measure-arm-b.sh` (this dir) — validated; sums the same weighted/raw/turns fields as `../tally.sh`. |
| Results template | `RESULTS-issue-13.md` (this dir) — Arm-A column pre-filled, Arm-B blank. |
| Issue + AC | Pinned below (from `gh issue view 13`). |

If the worktree is missing or dirty, recreate it:

```bash
git worktree remove --force ../../../claude-pipeline-armB-issue13 2>/dev/null
git branch -D armB/issue-13 2>/dev/null
git worktree add -b armB/issue-13 \
  /Users/russellgrocott/Projects/claude-pipeline-armB-issue13 c53f753
```

---

## Controls — pin these and record them in the results header

- **Model + reasoning effort:** pin the SAME model/effort Arm A used and record the exact
  ids. (Arm A ran sonnet→opus escalation; for a like-for-like *architecture* comparison,
  fix Arm B to one model and note it. Report the pin — do not leave it implicit.)
- **Base commit:** `c53f753` (both arms fork from here).
- **Acceptance criteria:** identical to Arm A — the #13 AC below. "Shipped" = a mergeable
  PR meeting that AC, judged against the AC, not vibes.
- **Dedicated cwd:** the Arm-B session MUST run with its `cwd` = the worktree dir. This is
  what makes token attribution work (`measure-arm-b.sh` matches transcripts by `cwd`).

### Issue #13 — acceptance criteria (the "shipped" bar for BOTH arms)

> *Orchestrator treats session-limit 429 as task failure; burns retry budget and poisons
> `status.json`.*

- A session-limit `429` no longer consumes per-task retry budget and does not mark tasks `failed`.
- After a session-limit halt, `status.json` reflects the true last-good state (completed tasks
  stay completed) and the run is resumable.
- Genuine (transient) rate-limit `429`s retain their existing retry behaviour.
- New/updated bats coverage is green in the per-push suite.

---

## Operator fairness rules (per §5.4 — do NOT skip)

1. **Let the loop do its own decomposition.** Do **not** hand it the pipeline's two pre-cut
   tasks. Ticket-analyser scoping is part of Arm B's cost.
2. **Same stop condition.** Stop when a mergeable PR meets the #13 AC above — no more, no less.
   Do not gold-plate; do not stop short.
3. **Count your turns.** Record the number of operator (human) messages as `human_turns` —
   this is the hidden cost Arm B trades for Arm A's autonomy.
4. **No cache leakage.** Run from the dedicated worktree cwd only. Don't warm the loop with a
   prior read of #13's actual diff.

---

## Procedure

```bash
# 1. Record run-start timestamp (bounds the token attribution window).
date -u +%Y-%m-%dT%H:%M:%SZ            # copy this into --since below

# 2. Capture Arm-B $ baseline: in the Claude Code session, run  /cost  and note it.

# 3. Open a Claude Code session whose cwd IS the worktree:
cd /Users/russellgrocott/Projects/claude-pipeline-armB-issue13
#    then, in that session:
#    /epic-task-loop      → drive issue #13 to a mergeable PR meeting the AC above.
#    (Obey the fairness rules. Track human_turns.)

# 4. On finish: run  /cost  again in the session; Arm-B $ = end − start.

# 5. Measure Arm-B tokens (weighted/raw/turns), bounded to the run window:
cd /Users/russellgrocott/Projects/claude-pipeline
bash docs/experiments/arm-b-runkit/measure-arm-b.sh \
  --cwd /Users/russellgrocott/Projects/claude-pipeline-armB-issue13 \
  --since <RUN_START_ISO> --label issue-13

# 6. (Reference) re-print Arm A for side-by-side:
bash docs/experiments/tally.sh
```

> **Why `--since`:** a cwd accumulates usage across every session ever run there. The
> dedicated worktree is fresh so it will only hold this run — but pass `--since` anyway as a
> guard so a second attempt in the same dir can't double-count the first.

---

## Recording results

Fill in `RESULTS-issue-13.md` (this dir): Arm-B column, the Δ / Δ% cells, `human_turns`,
`shipped (0/1)`, and — for H2 — an `escaped_defects` count from a **blind** third-party
`claude -p` review of each arm's final diff (§5.1). Then write the conclusion against the
pre-registered prediction (§8) and update the parent doc's Status line.

## Caveats baked into the comparison

- **Arm A here is a bug-afflicted run** (#13/#14 pathologies). Per §10.1, report both the
  as-is multiplier and, ideally, a post-fix Arm-A re-run for the architectural floor.
- **$ is captured differently per arm** (Arm A: `total_cost_usd` in stage logs; Arm B: `/cost`
  delta). The apples-to-apples axis is **weighted tokens** — decide H1 on that, cite $ as color.
- **N=1 is directional, not significant.** #13 is one issue. For a real result, repeat the kit
  on 2–4 more `(S)`-scoped issues (§5.2) and report the median.

## Cleanup (after results are recorded)

```bash
git worktree remove --force /Users/russellgrocott/Projects/claude-pipeline-armB-issue13
git branch -D armB/issue-13
```
