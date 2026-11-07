# Readable dashboard design

Mechanics (login/pull/diff/push) live in the `grafana` skill. This file is the design half: how to put
data on a dashboard so a reader reaches the right conclusion without a tour guide.

## The one rule

**Every "is it slow?" panel gets a sibling that says "how much work."** Rate, duration, and latency
panels are meaningless alone — pair each with its denominator (items, bytes, requests) and, where it
helps, the normalized form (duration per item, bytes per second of work-time). A reader should be able
to distinguish "slow" from "busy" in one glance at one row.

## Panel inventory pattern

A diagnostic dashboard answers, in order:

1. **Speed** — duration/latency, its work denominator, and the normalized ratio.
2. **Saturation** — concurrency in use, and the queue/backlog gauge (the only honest "drowning" signal).
3. **Mix** — breakdowns by the dimensions that change the story (mode, path, type). Mix humps explain
   speed humps.
4. **Transport** — the call/log shape that carried the bytes (so "no visible pulls" never gets confused
   with "no pulls").

## Layout

- Charts at `h: 12`, max **3 per row** (`w: 8`); headline/signal panels half-width (`w: 12`).
  Rows (`h: 1`) separate the sections above. Full-width only for wide log-derived panels.
- Legend: table mode, right side, `mean` + `lastNotNull` calcs.
- Header text panel with the reading rules; cross-links in `links`.

## Variables and grouping

- **Every panel filters the selector variable** (`entity=~"$var"`; lucene: `entity:($var)`).
- Fleet-wide panels group **by the selector dimension** (`sum by (pod)`), so narrowing the selector
  keeps every chart comparable.
- Mix panels group `by (<selector>, <mix-dim>)` — and **drop stacking**: stacking across entities piles
  them into one misleading heap. Stack only when the series are parts of one entity's total.
- Selectors from the datasource itself (`label_values(...)`), multi + includeAll, refresh on time change.

## Queries

- Ratio panels: fixed `[10m]` windows (steady). Rate panels: `[5m]`. Gauges: `avg by (<dim>)(...)`.
- State attribution caveats in the panel **description** ("this line is the fallback arm",
  "completion-attributed, lags in-flight work") — descriptions are the only docs that travel with the panel.

## File lifecycle (works with the grafana skill)

- Envelope `{folderUid, dashboard}` intact; **pin `dashboard.uid`** in the generator after first push —
  regenerating without it creates a duplicate dashboard or 404s the diff.
- Generate JSON with a script; diff before every push and read the paths — the diff should name only
  the fields you meant to change. Anything else = stop and reconcile.
- Match the server's `schemaVersion` (check any pulled dashboard).
