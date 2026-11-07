# Report 004 — Disable prefetch_on_idle

- Date: 2026-11-06
- Iteration: 4
- Plan: ../plan.md

## Summary
The change disabled the `prefetch_on_idle` flag in `config.json`. The p95 latency
fell from 1005 ms to 980 ms (−2.5 %). The goal of under 1000 ms is reached.
The change is kept. The loop exits on the goal.

## Baseline
p95 latency: 1005 ms. Measured at 2026-11-07 01:44 UTC, immediately before the
change. Source: `./measure.sh`, 3 runs, median. The script is deterministic.
All 3 runs agreed.

## Change
Set `prefetch_on_idle.enabled` to `false` in `config.json`. No other file changed.
Hypothesis: the idle-time prefetch costs 25 ms on the request p95. Disabling it
crosses the 1000 ms goal while keeping verbose request logging.

## Result
| Metric | Before | After | Delta |
|---|---|---|---|
| p95 latency | 1005 ms | 980 ms | −25 ms (−2.5 %) |

## Analysis
The delta matches the hypothesis exactly. Expected 25 ms, measured 25 ms.
Decision: keep. The cost is a small UX optimization. Users on slow networks lose
the prefetch head start. This is a judgment call, not a measurement. Two facts
support it. The goal is met. Request-level debug logging, worth 180 ms, stays on.
Note the headroom is thin: 980 ms leaves 20 ms under the goal. If prod traffic
grows, backlog #5 is the next lever.

## Next step
None. The loop ends. Backlog #5 stays pending for future work: restructure
`verbose_request_logging` to sampled logging. Expected effect if needed: −180 ms,
landing at 800 ms. That costs observability, so it was not spent here.

## Stop-rule status
Rule: stop when p95 < 1000 ms, or after 2 consecutive iterations below 2 %
improvement. Goal reached at 980 ms. Loop ends.
