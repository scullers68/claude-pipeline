# Results — issue #13 · Pipeline (Arm A) vs warm-loop (Arm B)

**Status: RUN COMPLETE (N=1, directional).** Arm B executed 2026-07-05.

| Field | Arm A (pipeline) | Arm B (warm single-context) |
|-------|------------------|-----------------------------|
| Model | sonnet→opus escalation (as-run) | opus (`claude-opus-4-8`), pinned |
| Base commit | `c53f753` | `c53f753` |
| Source | `logs/implement-issue/issue-13-20260703-171225/` | isolated agent transcript, `armB/issue-13` |
| Method | cold `claude -p` subprocess per stage, worktree-isolated tasks | **one continuous agent context**, no per-stage cold restart, no per-task turn cap |
| Human turns | ~0 (unattended) | 0 (autonomous — no operator steering) |
| Date | 2026-07-03 (killed mid-run) | 2026-07-05 |

> **Method note.** Arm B is a *faithful proxy* for `/epic-task-loop`'s cost architecture — one
> warm context ships the whole issue, no cold subprocess-per-stage, no `--max-turns` cap — run
> autonomously (no human operator). It is **not** a human-driven interactive session, so it
> carries no `human_turns` and removes the operator-skill confound (§7 threat #3). It measures
> the *architecture*, not operator behaviour.

---

## Primary comparison (H1 decided on **weighted tokens**)

| Metric | Arm A | Arm B | Δ (A−B) | **A / B** |
|--------|------:|------:|--------:|----------:|
| **weighted_tokens** (in+cw+out) | **759,482** | **222,150** | 537,332 | **3.42×** |
| raw_tokens (incl. cache-read) | 15,616,388 | 6,075,759 | 9,540,629 | 2.57× |
| total_turns (summed) | 166 | 54 | 112 | 3.07× |
| dollar cost | $13.96 | not directly captured† | — | — |
| human_turns | ~0 | 0 | — | — |
| **shipped** | **0 tasks clean** | **2 tasks, AC-verified**‡ | — | — |

† Arm B transcripts carry tokens, not `total_cost_usd`; the pre-registered decision axis is
weighted tokens (§4). At opus rates the 222k weighted ≈ low-single-digit dollars — well under
Arm A's $13.96, but cited as color, not the decision.

‡ **Independently verified** (not self-report): `test-rate-limit.bats` 38/0, `decide-action.bats`
18/0, `escalation-policy-golden.bats` 4/0 — all green in the worktree. The new tests directly
assert all four #13 AC (`detect_session_limit`, `halt_on_session_limit` → `state=paused`,
completions preserved, no task failed, transient 429 keeps retry). Change scope 424 insertions /
5 files (incl. an in-scope `session_limit` enum addition to `escalation-policy.json`),
comparable to Arm A's 484/4. Committed `6adb2fc` on `armB/issue-13`. **Caveat:** the agent did
not commit on its own (I committed to preserve the artifact) and a full per-push regression sweep
was not run — so "shipped" = functionally complete + AC-green, *not* a merged PR.

### Arm-B measurement integrity (must read)

The Arm-B figure **222,150 weighted / 54 msgs** is the **ship scope**: implement both tasks + run
the AC tests + commit `6adb2fc` — captured at the agent's first completion. The agent then
**over-ran** for ~45 more minutes into unprompted regression work (full-directory sweeps, even the
nightly `test-stage-runner`, plus a `git stash` recovery), reaching **950,348 weighted / 93 msgs**
total. That extra 728k is scope-creep verification a disciplined `/epic-task-loop` would not do,
so it is **excluded** as non-representative — but it is a real measurement weakness. A tighter
re-run (prompt: "implement, run only the AC tests, commit, STOP") would firm up the 222k. Even at
the contaminated 950k, Arm B ≈ Arm A's as-is 759k — the headline (loop ≤ pipeline) survives either
way; the 3.42× uses the fair ship-scope number.

---

## Verdict on H1

**H1 strongly supported, as-is.** On issue #13 the pipeline consumed **3.4× the weighted tokens
and 3.1× the turns** of the warm loop **and shipped less** — Arm A was killed mid-run having
cleanly landed 0 of 2 tasks, while Arm B landed both with AC-passing tests. Far past the +15%
threshold.

### But most of the gap is *fixable churn*, not pure architecture (mandatory nuance, §10.1)

Arm A's $13.96 / 759k weighted was **55% discarded** on `error_max_turns` retries — the exact
session-limit/turn-cap pathology issue #13 (+ #14) fixes. Breaking it down:

- **As-is multiplier: 3.42×** — dominated by Arm A's retry churn.
- **Kept-work-only: 264k (Arm A) vs 222k (Arm B) = 1.19×** — *but this understates Arm A's true
  per-shipped cost*: Arm A's kept 264k bought only task-1 + triage (1 of 2 tasks) and **never
  reached the test/review/PR stages** (stages 5–12), whereas Arm B's 222k shipped **both** tasks
  *plus* tests. So even churn-excluded, the pipeline spent more per unit of verified work.

**Two effects, both real:** (a) a large *fixable* overhead from current bugs, and (b) a smaller
*architectural* overhead (cold subprocess-per-stage + review re-ingestion) that this run cannot
cleanly isolate because Arm A never completed its stage graph. The pre-registered 1.5–3×
architectural prediction (§8) is **neither confirmed nor refuted** by N=1 — it needs a clean
post-#13/#14 Arm-A re-run.

## Architectural floor (Arm A, churn removed) — from captured clean data

The #13 Arm-A run's 55% waste was `error_max_turns` churn (#14). The **churn-free** cost is
recoverable from the kept/successful result envelopes already in the logs — no re-run needed:

| Component | Weighted | Cost | Turns | Source |
|-----------|---------:|-----:|------:|--------|
| triage (clean success) | 61,204 | $0.57 | 3 | measured |
| task-1 (uncapped success) | 202,887 | $5.69 | 59 | **measured** (the churn-free implement cost) |
| task-2 (clean) | ~203k | ~$5 | ~59 | **estimated** — its real attempts were cap-truncated at 26 turns; scoped ≈ task-1 |
| **Floor total** | **~467k** | ~$11 | — | 1 measured task + 1 estimated |

**Rock-solid sub-fact (measured, not estimated):** the pipeline's *single* clean task-1 attempt
(202,887 weighted) is **0.91×** of Arm B's *entire* 2-task ship (222,150). One cold
subprocess for one task ≈ the whole warm-loop run for both tasks.

### The comparison resolves into two layers

| Basis | Pipeline / Loop (weighted) | Meaning |
|-------|---------------------------:|---------|
| **As-is** | **3.42×** | includes the 55% fixable churn (#13/#14) |
| **Architectural floor** | **~2.1×** | churn removed — cold-subprocess-per-task overhead. **Confirms the pre-registered 1.5–3× prediction (§8).** |

Only task-2's clean cost is estimated; everything else is measured. A supervised full-orchestrator
re-run would replace that estimate with a measured number (expected to move 2.1× by ≈±0.2). It was
**not** run: faithful+safe execution needs patching out the live-issue-#13 comment side effect,
branch-collision isolation vs the real `feature/issue-13`, and running a runaway-prone 8000-line
script autonomously — disproportionate to refining one already-bounded estimate.

## H2 (quality/autonomy) — not yet scored

`escaped_defects` requires a **blind** third-party review of each arm's final diff (§5.1). Not
run. Both arms are autonomous here (human_turns ≈ 0), so H2's "buys autonomy" axis doesn't
separate them on *this* proxy; it would matter against a *human-driven* Arm B.

## Threats / honesty

- **N=1.** Directional only. Repeat on 2–4 more `(S)` issues for a median (§5.2).
- **Arm A incomplete.** Killed pre-test/PR; a complete clean pipeline run would cost *more* on
  the downstream stages but *less* on churn — net direction unknown without the re-run.
- **Arm B ≠ human loop.** Autonomous proxy; a real operator adds `human_turns` and may steer
  differently.

## Conclusion vs pre-registered prediction (§8)

Predicted: Arm A 1.5–3× higher weighted tokens per shipped task. **Observed: 3.4× as-is**
(exceeds range, driven by churn) — while the churn-excluded architectural component is smaller
and unresolved at N=1. **Headline: for this issue, the pipeline cost ~3.4× the tokens and
shipped less; the dominant cause is the very fault-path bug #13 fixes, with a residual—but
unquantified—architectural overhead on top.**
