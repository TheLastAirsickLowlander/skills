# Report 001 — Enable dependency caching

- Date: 2026-10-30
- Iteration: 1
- Plan: ../plan.md

## Summary
The change enabled dependency caching in the CI pipeline. The wall time fell from 25 min to 16 min (−36 %). The change is kept.

## Baseline
CI wall time: 25 min. Measured at 2026-10-30 10:00 with `./ci_time.sh`.

## Change
Set `cache_deps: true` in `.ci/pipeline.yaml`. No other file changed.
Hypothesis: the dependency install repeats on every run. Caching saves about 9 min.

## Result
| Metric | Before | After | Delta |
|---|---|---|---|
| CI wall time | 25 min | 16 min | −9 min (−36 %) |

## Analysis
The delta matches the hypothesis. Decision: keep. The install step no longer dominates. Test execution is now the largest block.

## Next step
Try shallow clone (backlog #2). Expected effect: about −2 min.

## Stop-rule status
Rule: stop after 2 consecutive iterations below 5 % improvement. Consecutive sub-threshold count: 0 of 2. Loop continues.
