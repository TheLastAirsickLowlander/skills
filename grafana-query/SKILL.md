---
name: grafana-query
description: Ad-hoc querying of Grafana datasources (Prometheus instant/range, Elasticsearch terms aggs) using the grafana-connector session — for checking real metric values, comparing entities or time windows, discovering labels and series, and verifying what a dashboard panel actually measures before trusting it. Use when the user asks what a metric's real value is, wants pods/hosts/services or windows compared, wants a panel's numbers verified against raw data, asks about call volumes or error distributions in logs, or says a dashboard "doesn't make sense". Dashboard create/edit/push mechanics belong to the grafana skill; readable-dashboard design is in this skill's reference/DASHBOARD-DESIGN.md.
---

# Skill: grafana-query

The `grafana` skill manages dashboards as JSON; this skill answers "what does the data actually say" —
ad-hoc queries against the same server, plus the design rules for making the answers readable.

**Prime directive: verify what a panel measures before trusting its shape.** A panel's title is a claim;
its query is the truth. Pull the dashboard (grafana skill), read the query, check which series or log
lines it actually selects. The most-watched line on a dashboard can be the exception path, a fallback
arm, or a subset of the traffic its title implies.

## Session

Queries reuse the `grafana` skill's SSO session at `~/.config/grafana-connector/session.json`
(fields: `cookieName`, `cookieValue`). Sessions **rotate frequently** — a `401 session.token.rotate`
means re-run `bun scripts/cli.ts login --url <grafana-url>` from the grafana skill dir and retry.
Build every retry loop to do this without asking.

## Core recipe — POST /api/ds/query

`scripts/dsquery.sh` / `scripts/esquery.sh` (bundled) wrap this; the raw contract:

```
POST <grafana-url>/api/ds/query   Cookie: <cookieName>=<cookieValue>
{
  "queries": [{ "refId": "A",
                "datasource": {"type": "prometheus", "uid": "<dsUid>"},
                "expr": "<promql>", "instant": true, "maxDataPoints": 1 }],
  "from": "<epochMs>", "to": "<epochMs>"        // window bounds; instant evaluates at `to`
}
```

- **Instant + range vector** (`increase(...[7h])` with the window as from/to) is the workhorse for
  "how much in this window". **Range mode** (`"instant": false, "intervalMs": 3600000`) gives per-step
  series for scans across a day.
- Response: `results.A.frames[]` — labels at `schema.fields[1].labels`, values at `data.values[1]`.
  A missing/empty frame means no data, not zero. **Handle both.**
- Datasource uids: `GET /api/datasources` and match by name/type. Elasticsearch targets take a lucene
  `query`, a `terms` bucketAgg on the field, `metrics: [{"type":"count"}]`, and the index's `timeField`.

## Discovery recipes

| need | how |
|---|---|
| values of a label | `count by (<label>)(<any series carrying it>)` via ds/query — more reliable than the label-values API |
| does a series exist | `count by (__name__)({__name__=~"<pattern>.*"})` |
| dashboards / folders | `GET /api/search?query=<name>` / `?type=dash-folder&limit=300` |
| log field distribution | ES terms agg on the field with a permissive lucene query (`field:*`) |

## Interpretation rules (hard-won, keep them)

1. **Same-window comparisons only.** Workloads drift by hour; never compare entity A's morning to
   entity B's afternoon. Pick one UTC window, state the timezone assumption, and reproduce the claimant's
   numbers before explaining them — if you can't reproduce, say so and analyze the window you have.
2. **Rate without its denominator is meaningless.** Pair every duration/latency with the work it moved
   (items, bytes, requests). Normalized forms (time per item, bytes per second of work-time) separate
   "slow" from "busy". Queue/backlog gauges — not duration — are the saturation signal.
3. **Know each counter's attribution before comparing two of them.** Per-event streaming counters and
   end-of-job summary counters diverge in shape by design; mixing them manufactures contradictions.
   Read the emitter code or docs before writing the query.
4. **Log-derived views see only what's logged with that field.** Absence of a line means absence of a
   matching log record, not absence of activity. Enumerate the actual field distribution (terms agg)
   before concluding any traffic class is absent.

## Reference

- `reference/DASHBOARD-DESIGN.md` — conventions for readable dashboards: normalization pairing,
  layout, per-entity grouping, variable filtering. Load when a query result becomes a panel.

## Bundled scripts

- `scripts/dsquery.sh "<promql>" [fromISO] [toISO]` — instant Prometheus query; `DSUID` env overrides the datasource.
- `scripts/esquery.sh "<lucene>" <termsField> [fromISO] [toISO]` — ES terms agg; `DSUID` env overrides.

Both read the session cookie themselves and fail loudly on 401 with the re-login command.
