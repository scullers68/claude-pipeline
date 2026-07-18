# Findings — implement-issue pipeline cost & robustness audit

**Date:** 2026-07-05
**Provenance:** Derived from the pipeline-vs-`/epic-task-loop` A/B experiment
(`ab-pipeline-vs-epic-task-loop.md`, `arm-b-runkit/RESULTS-issue-13.md`) plus a source read of
`implement-issue-orchestrator.sh`, `decide-action.sh`, and the test suite. Evidence status is
tagged per finding: **[measured]** = real command output this session, **[observed]** = read in
code/config, **[inferred]** = reasoned from the above, **[unmeasured]** = explicitly not tested.

---

## Executive summary

On one `(S)`-scoped issue (#13, N=1, directional) the orchestrated pipeline consumed **3.42× the
weighted tokens of a warm single-context run and shipped less** (0 vs 2 tasks cleanly). The cost
splits into two layers:

- **~55% is fixable churn** — the `error_max_turns` cold-retry pathology (#14) and session-limit
  misclassification (#13). Pure waste, no upside.
- **~2.1× is an architectural floor** — cold subprocess per stage, each re-ingesting context.
  This confirms the experiment's pre-registered 1.5–3× prediction.

The pipeline's designed upside (unattended autonomy, parallel fan-out, quality gating) is **real
but unmeasured** here — the Arm-B proxy was itself autonomous, so human-attention cost was never
priced in. **Verdict: for interactive small-scope work it is a token-eating machine with no
measured offsetting benefit; the two worst causes are fixable bugs, not inherent design.**

Key measured figures:

| | Weighted tokens | Cost | Turns | Shipped |
|--|---------------:|-----:|------:|--------:|
| Pipeline (as-is, #13) | 759,482 | $13.96 | 166 | 0 clean |
| — of which discarded (`error_max_turns`) | 495,391 | $7.70 (55%) | 104 | — |
| Warm loop (ship scope) | 222,150 | ~low-$ | 54 | 2 (AC-verified) |
| Pipeline **one clean task** (task-1) | 202,887 | $5.69 | 59 | ≈ whole loop run |

---

## Findings & tickets

| # | Finding | Severity | Evidence | Ticket |
|---|---------|----------|----------|--------|
| 1 | max_turns exhaustion → escalate + **cold restart** (discards ~55%) | Critical | [measured] | **#14** (open) |
| 2 | session-limit 429 classed as task failure; poisons `status.json` | Critical | [observed] | **#13** (open, fix in flight) |
| 3 | No token/cost accounting in `metrics.json` | High | [measured] | **#15** |
| 4 | No budget ceiling / circuit breaker (runs must be killed by hand) | High | [measured] | **#16** |
| 5 | Unsafe git ops in the working repo (stash/branch collisions) | High | [measured] | **#17** |
| 6 | No dry-run / side-effect-free mode (comments on live issue at startup) | Medium | [observed] | **#18** |
| 7 | Cold-subprocess-per-stage + redundant review re-ingestion | Medium (design) | [measured/inferred] | see §Architecture |
| 8 | Not cleanly resumable after a hard kill | Medium | [observed] | partial via #13/#11 |
| 9 | 8000-line orchestrator, no stage isolation / test seams | Medium | [observed] | see §Maintainability |
| 10 | Fragile/slow test suite (`test-stage-runner` >5h, hangs; known-reds) | Medium | [measured] | partial via #11 (closed) |
| 11 | Value proposition (autonomy/quality) unproven | Strategic | [unmeasured] | experiment follow-up |

---

## Detail

### 1. max_turns cold-retry churn — #14 (Critical) [measured]
`(S)` implement tasks cap sonnet at 25 turns (`implement-issue-orchestrator.sh:1864`). A task
needing more (task-1 needed 59) hits `error_max_turns`, is treated as a **failure**, and is
**cold-restarted on a pricier model** rather than resumed. On #13: task-1 succeeded only on
attempt 3 ($1.20 + $1.44 discarded first); task-2 failed twice ($5.06, never shipped). **4 of 6
invocations were pure waste — $7.70 / 55%.** Fix: treat max_turns as "needs more budget → resume
/ raise cap", not "failure → cold restart".

### 2. session-limit 429 misclassification — #13 (Critical) [observed]
A session-limit 429 burns per-task retry budget on an unretryable error, then `full-batch-retry`
marks *other* tasks falsely `failed`, corrupting `status.json`. Fix is in flight on
`feature/issue-13` (detect `session_limit`, halt resumably).

### 3. No token/cost accounting — #15 (High) [measured]
`metrics.json` records `duration_seconds` and `model` per stage but **no tokens or cost**. Cost is
only recoverable by hand-parsing `stages/*.log` result envelopes (as this audit did). A tool whose
central risk is token spend is blind to its own spend.

### 4. No budget ceiling / circuit breaker — #16 (High) [measured]
The #13 run had to be **manually killed** as a runaway (budget 45%→76% on one incomplete issue).
Nothing caps cumulative cost/turns or halts on a per-issue blowout.

### 5. Unsafe git ops in the working repo — #17 (High) [measured]
The pipeline runs real commits/worktrees/stash in the working checkout. During this audit an agent's
`git stash` **accidentally popped an unrelated pre-existing issue-11 stash** (recovered intact).
Working-branch naming can also collide with existing branches (e.g. `feature/issue-13`). Stash/branch
operations must be namespaced/isolated so they can't touch unrelated user state.

### 6. No dry-run / side-effect-free mode — #18 (Medium) [observed]
`comment_issue` fires at startup (`:6960`) and many stages; the pipeline also pushes and opens PRs.
There is no flag to run without outward-facing effects, which blocks safe measurement/testing runs
(the reason the churn-free floor re-run was judged disproportionate — it would have posted to live
issue #13). Add `--dry-run`/`--no-comment` and a `--stop-after <stage>`.

### Architecture (Finding 7) [measured/inferred]
Each stage is a cold `claude -p` re-ingesting context (14.2M cache-read on one #13 run).
task-review + review + spec-review + code-review each re-read the same diff in separate
subprocesses — multiplying tokens and risking *correlated* blind spots (re-judging the same
context) rather than independent coverage. Floor cost ≈ **2.1×** the warm loop even churn-free.
This is a deliberate trade for autonomy/gating; not a "bug" but the dominant residual cost.

### Maintainability (Findings 9–10) [observed/measured]
`implement-issue-orchestrator.sh` is 8000+ lines with a deeply nested stage graph and **no
stop-after/only-stage/dry-run seams** — both critical bugs (#13, #14) live in this one file.
`test-stage-runner.bats` exceeds 5 hours (exiled to nightly), its watchdog/timeout tests hang, and
a standing known-reds set is carried — i.e. the safety-critical supervision code is the least
routinely tested. The Agent-SDK harness rewrite (#11, closed; `plugins/pipeline-core/sdk/`)
targets this; track completion.

### Strategic (Finding 11) [unmeasured]
The pipeline's justification — unattended autonomy, parallel fan-out, quality gating — was never
measured against its token cost. On small tasks it is pure overhead; scale/complexity payoff is
untested. **Recommended next step:** a human-driven `/epic-task-loop` run (log human turns) + a
blind escaped-defect review of both diffs, to price the two unmeasured axes.

---

## Recommended priority

1. **#14** (max_turns cold-retry) — biggest single cost win; ~halves as-is spend.
2. **#13** (session-limit) — in flight; land it.
3. **#15** (cost accounting) — you can't manage what you can't see; unblocks everything else.
4. **#16** (budget circuit-breaker) — stops runaways without a human watching.
5. **#17** (git safety) — prevents data-loss incidents like the stash pop.
6. **#18** (dry-run/stop-after) — unblocks safe measurement + the floor/quality follow-ups.
7. Architecture (review re-ingestion) and the strategic quality/human-cost measurement — after the
   bugs land, re-run the A/B to get the true post-fix floor.
