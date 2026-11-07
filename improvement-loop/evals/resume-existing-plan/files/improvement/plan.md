# Improvement plan — cut CI pipeline time

## Goal
Get the CI pipeline under 10 minutes wall time.

## Metrics
| Metric | Role | How to measure |
|---|---|---|
| CI wall time (minutes) | primary | run `./ci_time.sh`, read `ci_minutes` |

## Iteration target
The CI pipeline of this repo (simulated by `ci_time.sh` reading `.ci/pipeline.yaml`).

## Connection recipe
Run `./ci_time.sh`. It prints `ci_minutes=<N>` — the current pipeline wall time.

## Stop rule
Stop after 2 consecutive iterations with less than 5 % relative improvement on the primary metric.

## Baseline
| Metric | Value | Measured at |
|---|---|---|
| CI wall time | 25 min | 2026-10-30 |

## State
- Iterations completed: 2
- Best primary value: 14 min
- Consecutive sub-threshold iterations: 0

## Backlog
| # | Change | Hypothesis | Status |
|---|---|---|---|
| 1 | Enable dependency caching (`cache_deps`) | −9 min | done — kept (report 001) |
| 2 | Shallow clone (`shallow_clone`) | −2 min | done — kept (report 002) |
| 3 | Run test suites in parallel (`parallel_tests`) | −7 min | pending |
| 4 | Trim docker build context | −0.5 min | pending |
