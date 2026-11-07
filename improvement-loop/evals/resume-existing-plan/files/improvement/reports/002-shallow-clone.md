# Report 002 — Shallow clone

- Date: 2026-10-31
- Iteration: 2
- Plan: ../plan.md

## Summary
The change enabled shallow clone in the CI pipeline. The wall time fell from 16 min to 14 min (−12.5 %). The change is kept.

## Baseline
CI wall time: 16 min. Measured at 2026-10-31 09:40 with `./ci_time.sh`.

## Change
Set `shallow_clone: true` in `.ci/pipeline.yaml`. No other file changed.
Hypothesis: the full git history is not needed for CI. A shallow clone saves about 2 min.

## Result
| Metric | Before | After | Delta |
|---|---|---|---|
| CI wall time | 16 min | 14 min | −2 min (−12.5 %) |

## Analysis
The delta matches the hypothesis. Decision: keep. Test execution is still the largest block at about 7 min.

## Next step
Run the test suites in parallel (backlog #3). Expected effect: about −7 min. This reaches the goal of 10 min if the hypothesis holds.

## Stop-rule status
Rule: stop after 2 consecutive iterations below 5 % improvement. Consecutive sub-threshold count: 0 of 2. Loop continues.
