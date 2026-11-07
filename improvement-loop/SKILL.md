---
name: improvement-loop
description: 'Measurement-driven improvement loop for any goal that has a number: break the goal into measurable metrics, agree with the user how to measure each one against a target (e.g. production), then repeat a disciplined loop — make ONE change, measure the delta, write a short ASD-STE100-inspired report, and stop at an agreed diminishing-returns threshold. Use this skill whenever the user wants to iteratively improve, optimize, tune, reduce, or raise something measurable — latency, error rate, cost, build time, bundle size, eval score, conversion — especially when they mention one change at a time, measuring the impact of each change, iterating against prod, or stopping at diminishing returns. Trigger on: "improvement loop", "iterate on", "keep improving until", "optimize this", "measure each change", "one change at a time", "until diminishing returns", "tune this until", "get X under Y", "iteratively improve", "shrink this step by step".'
---

# Improvement Loop

A controlled loop for improving a measurable goal. The loop exists because intuition is a
bad judge of what helps: small changes, measured one at a time against the real target,
beat large unmeasured rewrites. The user gets an auditable trail of what changed, what it
did, and why the loop stopped.

## The one rule that makes the loop work

**One change per iteration.** If two things change and the metric moves, you cannot know
which one did it. If a change turns out to contain several edits, that is fine — but the
*experiment* must be a single hypothesis: "changing X will improve metric M because …".

Two supporting disciplines:

- **Baseline before change.** Always measure immediately before applying the change.
  Targets drift (traffic, caches, other deploys), so a baseline from yesterday is not a
  baseline.
- **Never fabricate a measurement.** If a measurement fails or the connection recipe no
  longer works, stop and tell the user. A guessed number poisons every later decision.

## Project state

All state lives in the project being improved, so any later session can resume:

```
improvement/
  plan.md               # goal, metrics, measurement recipes, target, stop rule, backlog, state
  reports/
    001-<slug>.md       # one report per iteration
    002-<slug>.md
```

**Resume check — do this first.** If `improvement/plan.md` exists in the working project,
read it and skip to the loop. Setup already happened; do not re-ask the setup questions.
Summarize the state to the user (best value so far, iterations done, next candidate) and
confirm before continuing.

## Phase 1 — Setup (only when no plan.md exists)

Work through these steps with the user. Propose, recommend, then let the user decide —
the user owns the goal; you bring the measurement expertise.

### 1. Break the goal into measurable items

Restate the user's goal, then decompose it into candidate metrics. For each candidate,
recommend a concrete way to measure it given the context you can see (repo, scripts,
dashboards, CLIs). [`references/measurement-catalog.md`](references/measurement-catalog.md)
lists proven measurement recipes by domain — consult it before inventing your own.

Ask the user to confirm which metrics to track — this is a **multi-select**: they may
take several or all of them. Offer your recommendations as the default selection.
Distinguish:

- **Primary metric** — the one number the loop optimizes. Exactly one.
- **Guardrail metrics** — numbers that must not get worse (e.g. optimize latency but
  watch error rate). Any regression on a guardrail reverts the change.

### 2. Fix the iteration target and the connection recipe

The target is the environment measured each iteration — often production, but also
staging, a benchmark suite, an eval set, or a local script. Ask the user how to connect
to it and measure: which dashboard query, which CLI, which endpoint, which script.

Record their answer **verbatim** in plan.md as the *connection recipe* — exact commands,
queries, URLs, credentials location. Future sessions re-measure from this recipe alone.

Then **verify the recipe**: run it once and take a real baseline reading before writing
plan.md. If you cannot get a number now, you will not get one mid-loop.

### 3. Agree the stop rule

The loop ends on diminishing returns, decided by data, not vibes. Propose a rule and let
the user adjust it. Good default:

> Stop when the primary metric improves by less than **2%** (relative) in **2**
> consecutive iterations.

Absolute thresholds ("< 5 ms", "< 0.5 points") often fit better than relative ones —
pick whatever matches the metric. Record the exact rule in plan.md.

### 4. Build the initial backlog

Brainstorm candidate changes with the user. Each backlog item is one hypothesis:
*change, expected effect, rough cost*. Order by expected value per effort. The backlog
is a living list — every iteration's analysis may add, reprioritize, or kill items.

### 5. Write plan.md

Use this template:

```markdown
# Improvement plan — <goal>

## Goal
<one sentence, with the target number if there is one>

## Metrics
| Metric | Role | How to measure |
|---|---|---|
| <name> | primary | <recipe> |
| <name> | guardrail | <recipe> |

## Iteration target
<environment being measured>

## Connection recipe
<verbatim commands/queries/steps to measure, exactly as agreed>

## Stop rule
<e.g. "Stop after 2 consecutive iterations with primary-metric improvement < 2%.">

## Baseline
| Metric | Value | Measured at |
|---|---|---|

## State
- Iterations completed: 0
- Best primary value: <baseline>
- Consecutive sub-threshold iterations: 0

## Backlog
| # | Change | Hypothesis | Status |
|---|---|---|---|
| 1 | <change> | <expected effect> | pending |
```

## Phase 2 — The loop

Repeat until the goal number is reached, the stop rule fires, or the user says stop.
Reaching the goal is the happy exit — write the final summary the same way as a
stop-rule exit. Each iteration:

1. **Pick one change** from the backlog (highest expected value per effort). State the
   hypothesis out loud: "changing X should improve M because …".
2. **Measure the baseline** using the connection recipe. Record it.
3. **Make the one change.** Nothing else. If the target is a live environment, prefer
   reversible changes and tell the user before doing anything risky.
4. **Measure again.** Compute the delta on the primary metric and check guardrails.
5. **Decide:** improved → keep. Guardrail regressed or primary clearly worse → revert
   and record the rejection. Roughly neutral → judgment call, explained in the report.
6. **Analyze.** Why did the delta look like this? What does it suggest trying next?
   Update the backlog and the State section of plan.md (iterations, best value,
   consecutive sub-threshold count).
7. **Write the report** to `improvement/reports/NNN-<slug>.md` using
   [`references/report-template.md`](references/report-template.md). Reports follow
   ASD-STE100-inspired style: short sentences, one idea per sentence, plain words, no
   hedging — state what the data shows.
8. **Check the stop rule.** Fired → write a final summary in plan.md (total improvement,
   best configuration, what was tried) and stop. Not fired → next iteration.

Show the user the delta and report path at the end of every iteration. The loop runs
autonomously between those checkpoints; a user "stop" always wins over the stop rule.
