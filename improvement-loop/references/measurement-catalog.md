# Measurement catalog by domain

Consult this when proposing how to measure each metric in setup step 1. Recommend the
recipe that fits what already exists in the user's project — a working dashboard query
beats a new harness every time. Whatever is chosen, the exact commands/queries go into
plan.md as the connection recipe.

## Contents

- Web/API latency
- Error rates and availability
- Frontend page performance
- Build and CI time
- Cost
- LLM/agent quality
- Database query performance
- Generic fallback: the number-printing script

## Web/API latency

- **APM/dashboards (prefer if present):** Grafana/Prometheus
  (`histogram_quantile(0.95, ...)`), Datadog, Cloud Monitoring. Record the exact query
  and time window.
- **Direct sampling:** a loop of `curl -o /dev/null -s -w '%{time_total}\n' <url>` —
  20+ samples, take the median or p95. Crude but works anywhere.
- **Load test:** `k6 run` or `wrk` against staging when prod sampling is too noisy.

Report percentiles (p50, p95), not averages — averages hide the pain.

## Error rates and availability

- Log query (Cloud Logging, Loki, ELK): count of 5xx / total over a fixed window.
- APM error-rate panel query, recorded verbatim.
- Health-check probe history (uptime tools expose an API).

## Frontend page performance

- **Lighthouse CI** (`lhci autorun`) — repeatable LCP/CLS/TBT against a URL.
- **WebPageTest** API for real-device profiles.
- **Bundle size:** `du -sh dist/` or the bundler's size report; track total bytes.

## Build and CI time

- CI provider API (GitHub Actions `gh run list --json ...`, Buildkite API) — wall time
  of the pipeline, median of recent runs.
- Local builds: `hyperfine '<build command>'` or `time` over 3 runs, median.

## Cost

- Cloud billing export / cost API (GCP Cloud Billing, AWS CUR) — daily cost of the
  service, fixed window.
- Per-unit cost: cost driver (e.g. vCPU-seconds, tokens) × price; measure the driver
  per request and multiply.

## LLM/agent quality

- An existing eval harness: run it, record the headline score and the run ID.
- No harness: a fixed set of 20–50 representative prompts with a pass/fail rubric,
  judged the same way every time. Record the judge and rubric in plan.md — changing
  the judge mid-loop invalidates the deltas.

## Database query performance

- `pg_stat_statements`: mean_exec_time and calls for the target query, snapshot before
  and after (`SELECT ... FROM pg_stat_statements WHERE query LIKE ...`).
- `EXPLAIN (ANALYZE, BUFFERS)` on a clone or read replica, fixed dataset.
- App-level timing of the endpoint that runs the query.

## Generic fallback: the number-printing script

When nothing else fits, agree on a script with the user: it runs, prints one number,
exits. Rules that keep it honest:

- Same machine, same conditions each run.
- N runs (3–5), record the median.
- The script lives in the repo and its path is in the connection recipe.
