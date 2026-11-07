# Report 001 — Disable legacy_analytics

- Date: 2026-11-06
- Iteration: 1
- Plan: ../plan.md

## Summary
The change disabled the `legacy_analytics` feature flag in `config.json`. The p95
latency fell from 1515 ms to 1215 ms (−19.8 %). The change is kept.

## Baseline
p95 latency: 1515 ms. Measured at 2026-11-07 01:42 UTC. Source: `./measure.sh`,
3 runs, median. The script is deterministic. All 3 runs agreed.

## Change
Set `legacy_analytics.enabled` to `false` in `config.json`. No other file changed.
Hypothesis: the legacy analytics pipeline adds 300 ms per request. It is a legacy
feature, so the feature-loss risk is low.

## Result
| Metric | Before | After | Delta |
|---|---|---|---|
| p95 latency | 1515 ms | 1215 ms | −300 ms (−19.8 %) |

## Analysis
The delta matches the hypothesis exactly. Expected 300 ms, measured 300 ms. The
legacy analytics pipeline was the largest single feature cost in the config.
Decision: keep. Legacy analytics has a modern replacement in the real service, so
the feature-loss risk is accepted. This is a judgment call, not a measurement.

## Next step
Fix `double_serialization` (backlog #2). Expected effect: −120 ms on p95. This is
pure waste. Serializing the response once keeps the same behavior. No backlog
changes.

## Stop-rule status
Rule: stop when p95 < 1000 ms, or after 2 consecutive iterations below 2 %
improvement. Consecutive sub-threshold count: 0 of 2. Loop continues.
