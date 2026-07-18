# A/B Experiment: Orchestrated Pipeline vs. `/epic-task-loop`

**Status:** Executed at **N=1 (issue #13), directional.** Arm A captured (§10.1–10.3); Arm B
run 2026-07-05 as an autonomous warm-context proxy. **Result (two layers): as-is the pipeline
used 3.42× the weighted tokens (759k vs 222k) and shipped less (0 vs 2 tasks); with the 55%
fixable session-limit/turn-cap churn removed, the architectural floor is ~2.1× — which confirms
the pre-registered 1.5–3× prediction (§8). Rock-solid measured sub-fact: one clean pipeline task
(203k) ≈ the whole warm-loop 2-task run (222k).** Floor's only estimated input is task-2's clean
cost. Full writeup + caveats (incl. Arm-B over-run reconciliation): `arm-b-runkit/RESULTS-issue-13.md`.
**Author:** drafted 2026-07-03 during issue #13 run (`issue-13-20260703-171225`);
Arm-A capture finalised 2026-07-05.
**Owning question:** *Does the implement-issue orchestrator consume materially more model
usage than doing the same work interactively with `/epic-task-loop` and basic skills?*

---

## 1. Hypothesis

> **H1 (primary).** For an equivalent unit of shipped work, the orchestrated pipeline
> consumes **more weighted tokens and more total model turns** than `/epic-task-loop`,
> because it re-contextualises the same work across many cold subprocesses and adds
> automated multi-reviewer gates.

> **H0 (null).** No material difference in weighted tokens per shipped task
> (within ±15%) once cache-read tiering is accounted for.

> **H2 (secondary, quality).** The pipeline's extra spend buys measurable quality or
> autonomy value (fewer escaped defects, zero human turns) that `/epic-task-loop` does not.

**Falsification:** H1 is rejected if the pipeline's weighted-token-per-shipped-task is
within ±15% of `/epic-task-loop` across the issue sample. H2 is rejected if defect-escape
and rework rates are statistically indistinguishable between arms.

---

## 2. Why this is worth measuring (grounding evidence)

This is not abstract. Issue **#13** exists precisely because the pipeline wastes usage on a
failure mode a human-in-the-loop would never hit:

- Run `issue-11-20260703-113032` began **over the session limit**. Every stage `claude -p`
  call returned `{"is_error":true,"api_error_status":429,"result":"You've hit your session
  limit…","num_turns":1,"output_tokens":0}`.
- The orchestrator classified this as a normal task failure, spent the per-task retry budget
  on an unretryable error, then `full-batch-retry` re-ran tasks 2–7 and marked them
  **falsely failed**, poisoning `status.json`.
- A `/epic-task-loop` operator hits the same 429 **once**, reads "resets 2pm", and stops.

So the pipeline demonstrably has usage-amplifying failure modes. The experiment quantifies
whether that heaviness holds in the *happy path* too, not just under fault.

### Observed baseline (happy path, issue #13, first 3 stages)

| Stage | Turns | Input | Cache-write | Cache-read | Output |
|-------|------:|------:|------:|----------:|------:|
| triage | 3 | 17.6k | 60.5k | 43.7k | 3.6k |
| implement-task-1 | 26 | 22.6k | 89.8k | 1.74M | 6.7k |
| implement-task-2 | 26 | 0.4k | 83.9k | 2.21M | 17.7k |
| **subtotal** | **55** | **40.6k** | **234k** | **3.99M** | **28.0k** |

93% of raw tokens are cache-read (cheapest tier). The honest cap-impact proxy is the
**weighted** figure (~303k so far), not the 4.3M raw total. The experiment must therefore
report *weighted* tokens, not raw.

> **This table is the partial mid-run view** (one row per stage, kept attempt only). The
> **complete** Arm-A capture — every attempt including the discarded `error_max_turns` retries
> on *both* tasks, with dollar cost — is in **§10.1–10.3**. Read those for the real Arm-A
> totals ($13.96 / 759k weighted / 166 turns, 55% discarded); this §2 snapshot understates the
> waste because it hides the retries.

---

## 3. The two arms

### Arm A — Orchestrated pipeline (`implement-issue-orchestrator.sh`)

**Execution model:** a bash orchestrator drives a fixed stage graph. **Each stage is a
separate, cold `claude -p` subprocess** with its own system prompt, its own context ingest,
and its own JSON-result envelope. Per-task stages run inside **isolated git worktrees**.

**Stage graph (per the implement-issue SKILL):**

| # | Stage | Agent | Re-reads context? |
|---|-------|-------|-------------------|
| 1 | parse-issue | default | issue body |
| 2 | validate-plan | default | referenced files |
| 3 | triage | default (Haiku) | issue + repo |
| 4 | implement | per-task | full repo (in worktree) |
| 5 | task-review | spec-reviewer | diff + task (re-read) |
| 6 | fix | per-task | diff + findings (re-read) |
| 7 | test | default | repo (re-read) |
| 8 | review | code-reviewer | diff (re-read) |
| 9 | pr | default | diff + issue (re-read) |
| 10 | spec-review | spec-reviewer | PR + issue (re-read) |
| 11 | code-review | code-reviewer | PR diff (re-read) |
| 12 | complete | default | summary |

For **T** tasks, stages 4–8 run per task, so invocation count ≈ `5·T + 7`. For this 2-task
run: ~17 cold subprocess invocations, each re-loading system prompt + relevant context.

**Cost drivers (structural):**
1. **Cold subprocess per stage** — system prompt re-cached ~17× instead of once.
2. **Redundant re-review** — task-review + review + spec-review + code-review each re-ingest
   the same diff to re-judge work already done.
3. **Worktree isolation** — each task re-explores the repo from a cold mental model.
4. **Fault amplification** — retry/escalation/full-batch-retry can multiply spend (see #13).

**What it buys:** unattended operation, parallel task fan-out, structured quality gates,
reproducible per-stage logs, machine-readable `status.json`.

### Arm B — `/epic-task-loop` (interactive, human-in-the-loop)

**Execution model:** a **single warm Claude Code session**. `/epic-task-loop` is the
*umbrella loop* that carries an epic from idea to shipped, ticket by ticket, sequencing
specialised skills inside one conversation:

- **ticket-analyser** → scope/plan the ticket
- **brainstorming** → refine design before code (only when non-mechanical)
- **implement-ticket** → Serena/Context7 exploration, code, unit + Playwright tests
- **push** / **handoff** → commit, push, release notes, ticket closeout

**Key structural differences from Arm A:**
1. **One warm context.** System prompt caches **once**; each ticket builds on an already-warm
   understanding of the repo rather than re-exploring cold.
2. **The human is the reviewer.** No automated task-review/spec-review/code-review
   subprocesses — the operator eyeballs the diff and steers. Review "cost" moves off the
   token bill onto human attention.
3. **No worktree reset.** Mental model of the codebase persists across tickets.
4. **Fault handling is human.** A 429 stops the operator once; no retry storm.
5. **Turn count amortises.** Later tickets in the epic are cheaper because context is shared.

**What it costs elsewhere:** human wall-clock and attention; no parallel fan-out; quality
gating depends on operator diligence rather than a fixed gate; less machine-readable audit
trail.

### Side-by-side

| Dimension | Arm A: Pipeline | Arm B: `/epic-task-loop` |
|-----------|-----------------|--------------------------|
| Context model | Cold subprocess per stage | One warm session |
| System-prompt loads | ~`5·T+7` per issue | 1 per session |
| Reviewers | 3–4 automated subprocesses | Human operator |
| Codebase model | Re-explored per worktree | Persists across tickets |
| Parallelism | Task fan-out | Serial |
| Human turns | ~0 (unattended) | Many (steering) |
| Fault on 429 | Retry storm (pre-#13) | Human stops once |
| Audit trail | Per-stage logs + status.json | Single transcript JSONL |
| Amortisation across tickets | None (each cold) | Strong (shared context) |

---

## 4. Metrics

Report **per shipped task** (normalise by work delivered, not per run):

**Primary (usage):**
- `weighted_tokens` = `input + cache_write + output` (excludes cache-read; best cap proxy).
- `raw_tokens` = `input + cache_write + cache_read + output` (reported for transparency).
- `cache_read_tokens` (reported separately — the cheap tier that inflates raw).
- `total_turns` (model turns / `num_turns` summed).

**Secondary (efficiency & quality):**
- `wall_clock_seconds` (arm A: orchestrator; arm B: session span).
- `human_turns` (arm A ≈ 0; arm B = operator messages) — the hidden cost of Arm B.
- `escaped_defects` — bugs found *after* the arm declared done (blind third-party review).
- `rework_turns` — turns spent on retries/fixes after first "done".
- `shipped` — did it produce a mergeable PR meeting the issue's acceptance criteria (0/1).

**Derived:**
- `weighted_tokens_per_shipped_task` — the headline number for H1.
- `usage_per_human_minute` — contextualises Arm B's human cost.

---

## 5. Design

### 5.1 Controls (hold constant across arms)

- **Same issues.** Draw from a fixed pool (see 5.2). Each issue is run by **both** arms.
- **Same model & effort.** Pin the model id and reasoning effort for both arms; record it.
- **Same repo baseline.** Both arms branch from the **same base commit** (fresh clone or
  clean worktree). No cross-contamination.
- **Same acceptance criteria.** Judge "shipped" against the issue's stated AC, not vibes.
- **Same reviewer for scoring.** A **third, blind** `claude -p` review pass scores
  `escaped_defects` on each arm's final diff, unaware of which arm produced it.

### 5.2 Sample

Pick **N = 3–5 closed-or-open issues of comparable, small scope** (the `(S)` sizing the
orchestrator already assigns — e.g. "2 files, surgical"). Issue #13's two tasks are a good
template: bounded, testable, single-subsystem. Avoid mixing a 2-file fix with a 30-file
refactor; scope variance will swamp the arm signal. Record each issue's task count `T`.

**Order-effect control:** randomise/counterbalance which arm runs an issue first, or run on
independent base clones so neither arm warms the cache for the other.

### 5.3 Procedure — Arm A (pipeline)

```bash
# fresh base, then:
implement-issue-orchestrator.sh --issue <N> --branch <base>
# token capture: stage logs already carry claude -p JSON result envelopes
bash docs/experiments/tally.sh   # or canary-measure.sh --logs-dir <logdir>
```

### 5.4 Procedure — Arm B (`/epic-task-loop`)

Run in an interactive Claude Code session **whose `cwd` is a dedicated per-issue directory**
(this is what makes token attribution work — see 5.5):

```
/epic-task-loop   # then drive ticket <N> to a mergeable PR, same AC as Arm A
```

Operator rules for fairness:
- Do **not** hand the model the pipeline's decomposed tasks; let `/epic-task-loop` do its own
  ticket-analyser decomposition (that work is part of Arm B's cost).
- Stop when a mergeable PR meets the same AC Arm A targeted.
- Log operator message count as `human_turns`.

### 5.5 Measurement mechanics (reuse existing harness)

| Arm | Token source | Tool |
|-----|-------------|------|
| A (pipeline) | per-stage `claude -p` JSON result lines in `logs/.../stages/*.log` | `tally.sh` (this dir) or `canary-measure.sh --logs-dir` |
| B (epic-loop) | interactive transcript JSONL in `~/.claude/projects/<proj>/` | `canary-measure.sh` — attributes a JSONL record to the issue when its `cwd` == the issue's working dir or a descendant |
| A vs B report | aggregate deltas | `ab-report.sh --control-log-dir … --treatment-log-dir …` (pipeline-shaped) **or** the custom reducer in §6 |

> **Attribution key:** `canary-measure.sh` matches transcript records to an issue by `cwd`.
> Arm B **must** therefore run from a unique per-issue directory, or its tokens can't be
> isolated from unrelated session activity. This is the single most important setup detail.

`ab-report.sh` is built to diff **two pipeline arms**; for pipeline-vs-epic-loop, prefer
`canary-measure.sh` on each arm (it reads transcripts directly) and combine with the reducer
in §6.

### 5.6 Weighted-token reducer (arm-agnostic)

Both arms ultimately emit usage records with the same four fields. Sum them uniformly:

```
weighted = Σ(input + cache_creation_input + output)      # cap-impact proxy
raw      = weighted + Σ(cache_read_input)
turns    = Σ(num_turns)   # arm A: per stage;  arm B: assistant turns in transcript
```

Report per arm, then `Δ = (A − B) / B` per metric.

---

## 6. Analysis & reporting

Produce one table per issue and one aggregate:

| Metric | Arm A | Arm B | Δ (A−B) | Δ% |
|--------|------:|------:|--------:|---:|
| weighted_tokens / shipped task | | | | |
| raw_tokens / shipped task | | | | |
| total_turns / shipped task | | | | |
| wall_clock / shipped task | | | | |
| human_turns / shipped task | | | | |
| escaped_defects | | | | |
| shipped (0/1) | | | | |

**Decision rule:**
- H1 **supported** if median `weighted_tokens/shipped` Δ% > +15% in A's direction across the
  sample.
- H2 **supported** if A's `escaped_defects` is materially lower **and** `human_turns` ≈ 0
  while B's is high — i.e. the extra spend bought autonomy/quality.

---

## 7. Threats to validity

1. **Scope variance dominates.** Mismatched issue sizes swamp the arm effect → enforce
   `(S)`-sized, comparable issues only.
2. **Cache-read tiering.** Comparing raw tokens is misleading; **weighted** is the honest
   metric. Report both but decide on weighted.
3. **Operator skill in Arm B.** A slow/verbose operator inflates B; a terse expert deflates
   it. Mitigate by fixing operator rules (5.4) and reporting `human_turns`.
4. **Model/version drift.** Pin and record model id + effort for both arms.
5. **Warm-cache leakage.** If both arms share a session/cwd, cache bleeds across → dedicated
   per-issue dirs and/or separate clones.
6. **Small N.** 3–5 issues is directional, not significant. State it as such; don't
   over-claim a precise multiplier.
7. **Quality is hard to score.** Use a blind third-arm reviewer for `escaped_defects`;
   acknowledge residual subjectivity.

---

## 8. Predicted outcome (from architecture, pre-registered)

Based on the structural differences, I expect:
- **Weighted tokens:** Arm A **1.5×–3× higher** per shipped task, driven by ~`5·T+7` cold
  subprocess loads and 3–4× review re-ingestion.
- **Turns:** Arm A higher (each review stage adds turns B folds into one human glance).
- **Raw tokens:** Arm A dramatically higher (cache-read multiplied by cold re-reads), but
  this over-states cap impact.
- **Human turns:** Arm A ≈ 0; Arm B many — **this is the real trade Arm A is buying.**
- **Escaped defects:** plausibly lower for A (more gates), but not guaranteed — the gates
  re-judge the same context, so correlated blind spots may persist.

Pre-registering these means the writeup can't be retrofitted to whatever we observe.

---

## 9. Execution checklist (run when budget resets)

- [ ] Freeze issue sample (N=3–5, `(S)`-scoped); record `T` per issue.
- [ ] Pin model id + reasoning effort; record in results header.
- [ ] Prepare per-issue clean base clones (one per arm per issue).
- [ ] Arm A: run orchestrator per issue; capture with `tally.sh` / `canary-measure.sh`.
- [ ] Arm B: run `/epic-task-loop` per issue from a **dedicated cwd**; log `human_turns`.
- [ ] Blind third-arm reviewer scores `escaped_defects` on both final diffs.
- [ ] Run reducer (§5.6); emit per-issue + aggregate tables (§6).
- [ ] Evaluate decision rule (§6); write conclusion vs pre-registered prediction (§8).

---

## 10. Appendix — live baseline

Partial Arm-A data captured mid-run from `issue-13-20260703-171225` is in §2. A reusable
tally script lives at `docs/experiments/tally.sh` (points at that run's stage logs; generalise
the `LD` path for future runs).

**The `issue-13` run was killed mid-implement** (session budget 45% → 76% on one incomplete
issue). Final captured Arm-A totals at kill: **weighted 795k / raw 15.6M / $13.96**, across
**6 `claude -p` invocations** (2 tasks + triage), and it had **not** reached any
review/test/PR stage.

> **Turn count, two definitions.** `tally.sh` reports **88** turns (it takes each stage log's
> *final* `num_turns`, i.e. the last/kept attempt only). Summed across **every** attempt
> including the discarded retries, it is **166** turns. §10.1/§10.2 use the summed figure
> because discarded turns are exactly the waste being measured.

**Cost concentration (the headline for H1's fault-path evidence):** of the $13.96 spent,
**$7.70 (55%) was discarded** — 4 of the 6 invocations ended in `error_max_turns` and were
thrown away (weighted 495k / 104 turns of pure waste). The pathology hit **both** tasks, not
just task-1 (§10.1); task-2 (§10.2) never recovered before the kill.

### 10.1 Field evidence — the escalate-and-cold-retry pathology (→ issue #14)

While tallying, we caught a concrete instance of the overhead H1 predicts. Task 1 (triage-sized
`(S)`, "2 files") was executed **three times**:

| Attempt | Model | Turns | Result | Weighted | Cache-read | Cost | Kept? |
|--------|-------|------:|--------|---------:|-----------:|-----:|:-----:|
| 1 | sonnet | 26 | `error_max_turns` (cap=25) | 118k | 1.65M | $1.20 | ❌ |
| 2 | opus | 26 | `error_max_turns` → 900s wall-timeout → "failed" | 132k | 1.95M | $1.44 | ❌ |
| 3 | opus (serial) | 59 | ✅ success | 203k | 6.26M | $5.69 | ✅ |
| **Total** | | **111** | | **453k** | **9.87M** | **$8.33** | |

**55% of task-1's spend (250k weighted / 3.60M cache-read, 52 turns, $2.64) was discarded.** Causes:
turn cap (25) miscalibrated for a task genuinely needing 59; `max_turns` exhaustion treated as
failure → **escalate model + cold restart** (not resume); 900s wall-timeout discarding
near-complete work → full serial batch re-run. Filed as **issue #14**.

**Implication for the experiment:** this is pure Arm-A tax with **no Arm-B analogue** — an
interactive `/epic-task-loop` operator neither caps a task at 25 turns nor restarts it cold on
a pricier model. So the measured multiplier (§8) will partly reflect *fixable* pipeline bugs
(#13, #14), not just inherent architecture. **When reporting, separate "architectural overhead"
from "current-bug overhead"** — re-run Arm A after #13/#14 land to get the floor, and report
both the as-is and post-fix multipliers.

### 10.2 Field evidence — task-2 never recovered (the pathology is not task-1-specific)

The same run executed task-2 (also `(S)`, "2 files") **twice, and it was killed before a third
attempt could succeed**. Unlike task-1, **no attempt was ever kept** — task-2 shipped nothing
on its own:

| Attempt | Model | Turns | Result | Weighted | Cache-read | Cost | Kept? |
|--------|-------|------:|--------|---------:|-----------:|-----:|:-----:|
| 1 | sonnet | 26 | `error_max_turns` (cap=25) | 96k | 2.10M | $3.46 | ❌ |
| 2 | (escalated) | 26 | `error_max_turns` | 149k | 2.20M | $1.60 | ❌ |
| **Total** | | **52** | | **245k** | **4.30M** | **$5.06** | ❌ |

**100% of task-2's $5.06 was discarded.** Every turn task-2 consumed produced zero kept output
before the operator killed the runaway. This matters for the experiment framing: the pipeline's
fault-path waste is **not** an isolated task-1 fluke — it reproduced on the second, independent
task in the *same* run. It also means the killed run's on-branch commits for task-2 did **not**
come from a clean pipeline success; they were recovered/committed outside the failed attempts.

### 10.3 Whole-run roll-up (both tasks + triage, all 6 invocations)

| | Kept (accepted) | Discarded (`error_max_turns`) | Total |
|--|---------------:|------------------------------:|------:|
| Invocations | 2 (task-1 att3, triage) | **4** | 6 |
| Weighted tokens | ~264k | **495k** | 759k* |
| Turns (summed) | 62 | **104** | 166 |
| Cost | $6.26 | **$7.70** | **$13.96** |

**55% of the run's dollar spend, and 63% of its turns, were thrown away on the turn-cap /
cold-restart pathology (§10.1, §10.2).** This is pure Arm-A tax with no Arm-B analogue — the
single strongest piece of grounding evidence for H1's fault-path component, now measured across
*both* tasks rather than extrapolated from one.

> \*Result-envelope weighted total is 759k; `tally.sh` reports 795k because it also sums the
> intermediate assistant-turn usage lines that precede each final result envelope. Both are
> internally consistent; the ~36k gap is streaming-progress accounting, not extra model work.
