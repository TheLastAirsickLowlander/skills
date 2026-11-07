---
name: staff-engineering-skills-cardinality
description: Detect and prevent cardinality traps in systems code. Use when writing code that iterates over collections, stores items in memory, creates per-entity resources, or fans out operations across a set of items. Activates on patterns like loops over query results, in-memory Maps/Sets populated from databases, or "one X per Y" resource allocation.
---

# Cardinality Trap

Code that works for 10 items becomes a production incident at 10 million. Before writing any code that operates on a collection, ask: **how many items can this collection contain, and what controls that number?**

## The Cardinality Levels

Classify every collection you touch:

| Level | Controlled by | Examples | Safe to load in memory? |
|-------|--------------|----------|------------------------|
| **L1** | Code (deploy to change) | Enums, feature flags, status codes | Yes |
| **L2** | Real-world constraints | Countries, US states, time zones | Yes, but verify count |
| **L3** | User action + limits | Team members (capped at 50), projects per workspace | With caution. Limits change. |
| **L4** | User action, no limits | Documents, messages, spreadsheet rows | No. Paginate always. |
| **L5** | API/automation + time | API requests, log entries, webhook events, metrics | No. Assume millions. Stream or batch. |

**The 2nd Degree Rule:** Treat L4 as L5. User-driven collections almost always gain API access later. "Documents in a drive" becomes "documents created by an integration every 5 minutes."

## Detection: When You're About to Write Cardinality-Sensitive Code

**Stop and assess cardinality if you're about to write any of these:**

1. **`for (const x of collection)` / `.map()` / `.forEach()`** on a query result -- what bounds `collection`? If it's user-controlled or time-accumulating, it's L4/L5.

2. **`new Map()` or `new Set()` populated from a database** -- what bounds its size? If the answer is "number of users/documents/events," it will grow without limit.

3. **"One X per Y"** -- one queue per customer, one timer per session, one connection per tenant. What's the cardinality of Y?

4. **`SELECT * FROM table` without LIMIT** -- what's the row count trajectory? Tables that accumulate over time are unbounded.

5. **`Promise.all(items.map(...))` for fan-out** -- what's the max length of `items`? Unbounded fan-out exhausts connection pools and memory.

6. **Per-entity time series** -- metrics per org, events per user. The cross product (entities x time intervals) is multiplicative cardinality.

## Decision Checklist

Before writing code that touches a collection, answer these:

- [ ] What is the cardinality level (L1-L5)?
- [ ] What is the current count? What will it be in 1 year?
- [ ] Is the entire collection loaded into memory at any point?
- [ ] Is there a resource created per item (timer, connection, goroutine, queue)?
- [ ] What happens if the collection is 1000x larger than today?
- [ ] Could this collection ever be populated by an API? (If yes, treat as L5)

## Patterns

### L1-L2: Direct iteration is fine

```typescript
// Safe: status is an enum (L1), countries are bounded (L2)
const results = statusValues.map(s => getCountByStatus(s));
```

### L3+: Paginate and bound

```typescript
// Dangerous
const orgs = await db.organization.findMany({ where: { status: "active" } });
orgs.forEach(org => process(org));

// Safe: cursor-based pagination with bounded batches
let cursor: string | undefined;
do {
  const batch = await db.organization.findMany({
    where: { status: "active" },
    take: 100,
    cursor: cursor ? { id: cursor } : undefined,
    orderBy: { id: "asc" },
  });
  for (const org of batch) await process(org);
  cursor = batch.length === 100 ? batch[batch.length - 1].id : undefined;
} while (cursor);
```

### Aggregate in the database, not in memory

```typescript
// Dangerous: loads all events into memory to count them
const events = await getAllEvents(orgId);
const counts = new Map<string, number>();
for (const e of events) counts.set(e.type, (counts.get(e.type) || 0) + 1);

// Safe: push aggregation to the database
const counts = await db.$queryRaw`
  SELECT event_type, COUNT(*) as count
  FROM events WHERE org_id = ${orgId}
  GROUP BY event_type
`;
```

### Bound fan-out with queuing

```typescript
// Dangerous: unbounded concurrent fan-out
const members = await getTeamMembers(teamId);
await Promise.all(members.map(m => sendNotification(m.id, message)));

// Safe: check cardinality, branch strategy
const count = await getTeamMemberCount(teamId);
if (count > DIRECT_THRESHOLD) {
  await enqueueJob("notify-team", { teamId, message }); // batched in background
} else {
  const members = await getTeamMembers(teamId);
  await Promise.all(members.map(m => sendNotification(m.id, message)));
}
```

### Never create unbounded per-entity resources

```typescript
// Dangerous: one timer per session, never cleaned up
for (const session of sessions) {
  setInterval(() => pingSession(session.id), 30_000);
}

// Safe: single timer that iterates, or use a bounded pool
const sessionPinger = setInterval(async () => {
  const activeSessions = await getActiveSessions({ limit: 1000 });
  for (const session of activeSessions) await pingSession(session.id);
}, 30_000);
```

### Metrics and time series: multiplicative cardinality

Metric labels and time series are the most common hidden cardinality trap. The total series count is the cross product of every label value combination, and it grows multiplicatively.

```typescript
// Dangerous: per-tenant metric label. 50,000 tenants x 20 metrics = 1M series.
// Prometheus/Victoria/Datadog all choke on high-cardinality labels.
metrics.increment("api.requests", { tenant: tenantId, endpoint, method, status });
// If tenantId has 50K values, endpoint has 200, method has 5, status has 5:
// 50,000 x 200 x 5 x 5 = 250,000,000 unique series. Your monitoring is dead.

// Safe: use bounded labels only. Aggregate per-tenant metrics separately.
metrics.increment("api.requests", { endpoint, method, status }); // L1 labels only
// Per-tenant data goes to a dedicated analytics pipeline (ClickHouse, BigQuery)
// that's designed for high-cardinality dimensional queries.
```

**The rule:** Every metric label must be L1 or L2. If you need per-tenant, per-user, or per-entity metrics, that's an analytics query, not a metric. Route it to a system designed for high-cardinality queries (ClickHouse, BigQuery, Tinybird) rather than a monitoring system (Prometheus, Datadog, Grafana Cloud) that charges per series or collapses under high cardinality.

## Anti-Patterns

- **Loading an unbounded collection into memory** -- `findMany()` with no `take`, then filtering or mapping in app code. Filter and bound in the query; paginate L4/L5 sets.
- **One resource per entity** -- a `setInterval`, connection, queue, or goroutine created per item in a loop. Use a single iterating worker or a bounded pool.
- **Aggregating in memory** -- pulling every row to count/sum/group in app code. Push the aggregation into the database (`GROUP BY`).
- **Unbounded fan-out** -- `Promise.all(items.map(...))` over a user- or API-sized array. Check the count and branch to a queue past a threshold.
- **High-cardinality metric labels** -- per-tenant/user/entity labels on a monitoring metric. Keep labels L1/L2; route per-entity analytics to a columnar store.

## Related Traps

- **Denormalization** -- denormalizing into a high-cardinality set creates write amplification proportional to the set size.
- **Backpressure** -- unbounded fan-out without backpressure collapses under high cardinality.
- **Memory Leaks** -- unbounded `Map`/`Set` at module scope is both a cardinality trap and a memory leak.
- **Streams vs Batch** -- high cardinality is the forcing function that moves you from batch to streaming.
