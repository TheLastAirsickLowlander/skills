# Report 002 — Fix double_serialization

- Date: 2026-11-06
- Iteration: 2
- Plan: ../plan.md

## Summary
The change disabled the `double_serialization` flag in `config.json`. The p95
latency fell from 1215 ms to 1095 ms (−9.9 %). The change is kept.

## Baseline
p95 latency: 1215 ms. Measured at 2026-11-07 01:43 UTC, immediately before the
change. Source: `./measure.sh`, 3 runs, median. The script is deterministic.
All 3 runs agreed.

## Change
Set `double_serialization.enabled` to `false` in `config.json`. No other file
changed. Hypothesis: the service serializes each response twice. Removing the
second pass saves 120 ms and keeps the same response body.

## Result
| Metric | Before | After | Delta |
|---|---|---|---|
| p95 latency | 1215 ms | 1095 ms | −120 ms (−9.9 %) |

## Analysis
The delta matches the hypothesis exactly. Expected 120 ms, measured 120 ms. This
was pure waste. No feature was lost. Decision: keep. In the real service this maps
to a code change: serialize once in the handler and pass the bytes through. The
simulation models that restructure as a flag.

## Next step
Remove `redundant_auth_check` (backlog #3). Expected effect: −90 ms on p95. One
auth check per request is enough. No backlog changes.

## Stop-rule status
Rule: stop when p95 < 1000 ms, or after 2 consecutive iterations below 2 %
improvement. Consecutive sub-threshold count: 0 of 2. Loop continues.
