# skills

Personal agent-skill library. Each folder is an [Agent Skill](https://agentskills.io) with a `SKILL.md`.

Curated from [`KaseyaStrategicEngineering/skill-matt`](https://github.com/KaseyaStrategicEngineering/skill-matt):
kept the general-purpose workflow skills and the distributed-systems guardrails, dropped
the PostgreSQL/Cloud SQL performance set and the eval harness.

## Install with the Skills CLI

List the skills without installing them:

```sh
npx skills add TheLastAirsickLowlander/skills --list
```

Install all skills for every supported agent in the current project:

```sh
npx skills add TheLastAirsickLowlander/skills --all
```

Install one skill for OpenCode in the current project:

```sh
npx skills add TheLastAirsickLowlander/skills \
  --skill gh-review \
  --agent opencode \
  --copy \
  -y
```

Install globally with `--global`. Check and refresh via `npx skills list` / `npx skills update`.
Set `DISABLE_TELEMETRY=1` when anonymous CLI installation telemetry is not desired.

## Install from a local checkout

```sh
./install.sh
```

Copies every skill into `~/.agents/skills/`, **overwriting** existing copies.
Pass an extra path to install elsewhere: `./install.sh /path/to/other/skills`.

## Skills included (23)

### Workflow / general-purpose

| Skill | Purpose |
|---|---|
| find-skills | Discover installable skills when the user asks "how do I X" |
| gh-review | Handle GitHub PR review comments end-to-end (fix, reply, push, loop till green) |
| improvement-loop | Goal → agreed metrics → one-change-at-a-time measured loop, stop at diminishing returns |
| report | Turn a finished analysis into a self-contained STE-inspired HTML document with inline diagrams |
| grafana-query | Ad-hoc Grafana datasource queries and readable-dashboard design |
| reqs-reverse-engineer | Reverse-engineer requirements from a codebase (catalog + narrative spec) |
| unslop | Cut AI tells from any writing |

### Distributed-systems guardrails (`staff-engineering-skills-*`)

| Skill | Guards against |
|---|---|
| backpressure | Unbounded growth when producers outpace consumers |
| cache-invalidation | Stale data from missing/incomplete invalidation |
| cardinality | Unbounded iteration / per-entity resource fan-out |
| clock-skew | Assuming synchronized or monotonic clocks |
| consistency-models | Stale reads from replica lag, cache staleness, index delay |
| denormalization | Duplicated-data traps in data models |
| distributed-system-fallacies | Treating network calls like function calls |
| hot-partitions | Skewed load on individual partitions/shards/nodes |
| idempotency | Unsafe retries of mutating operations |
| memory-leaks | Leaks in GC'd languages (caches, listeners, timers, goroutines) |
| object-store-as-database | Misusing S3/GCS/Blob as a database layer |
| race-conditions | Check-then-act / read-modify-write on shared state |
| retry-storms | Retries amplifying failures into cascading outages |
| sharding | Wrong sharding calls — when, what breaks, key choice |
| streams-vs-batch | Wrong processing model for pipelines/queues/webhooks |
| thundering-herd | Synchronized demand spikes (TTL stampedes, cron alignment, reconnect storms) |
