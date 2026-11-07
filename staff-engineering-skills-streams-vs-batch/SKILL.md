---
name: staff-engineering-skills-streams-vs-batch
description: Choose the right processing model before writing code. Use when building data pipelines, processing queues, handling webhooks, sending notifications, aggregating metrics, or any system that processes a collection of items over time. Activates on patterns like cron jobs processing "new" items, polling for unprocessed rows, setInterval-based processing, or collecting items into arrays before processing.
---

# Streams vs Batch Trap

Batch-to-stream is a rewrite, not a refactor. Before writing a processing pipeline, ask: **what's the latency requirement, and will it change?**

## Decision Framework

Ask these questions before writing the first line of processing code:

| Question | Batch | Stream |
|----------|-------|--------|
| Acceptable latency? | Minutes to hours | Seconds or less |
| Throughput trajectory? | Stable or slow-growing | Growing fast or unpredictable |
| Failure isolation? | Whole batch can retry | Must handle per-item failure |
| Ordering matters? | No, or within batch is fine | Yes, across items |
| "Real-time" ever mentioned? | No | Yes -- build for it now |

**If the answer to ANY row points to stream, build for streaming from the start.** You cannot cheaply add streaming later.

## The Rule

Reducing a batch interval is not a scaling strategy. A 10-second batch interval is a bad stream processor -- it has all the complexity of streaming with none of the benefits (no ordering, no backpressure, no offset tracking, overlap risk).

## Detection: Batch Patterns That Will Need Streaming

**Stop and reassess if you see:**

1. **A cron job processing "new" or "unprocessed" items** -- `SELECT * FROM events WHERE processed = false`. What's the latency requirement? If "as fast as possible," this is the wrong model.

2. **`setInterval` or `setTimeout` for processing** -- what happens when processing takes longer than the interval? Overlapping batches cause duplicate processing and resource contention.

3. **Shrinking batch intervals over time** -- started at 5 minutes, now at 10 seconds. This is the symptom. The disease is: you need streaming.

4. **Items collected into an array before processing** -- what bounds the array? If it's time-based ("all items in the last 5 minutes"), memory grows with throughput.

5. **"We'll add real-time later"** -- flag this immediately. This is not an incremental change. The data flow, error handling, and ordering assumptions are fundamentally different.

## When Batch Is Correct

Batch is the right choice when:
- Latency requirements are hours or days (daily reports, nightly ETL, weekly digests)
- The processing needs a complete view of a time window (aggregations, reconciliation)
- Throughput is stable and predictable
- The workload is compute-heavy and benefits from bulk operations (ML training, data export)

```typescript
// Batch is correct here: daily revenue report. Nobody needs this in real-time.
async function generateDailyReport() {
  const revenue = await db.$queryRaw`
    SELECT DATE_TRUNC('hour', created_at) as hour, SUM(amount) as total
    FROM orders
    WHERE created_at >= ${startOfDay} AND created_at < ${endOfDay}
    GROUP BY DATE_TRUNC('hour', created_at)
  `;
  await saveReport({ date: today, hourlyRevenue: revenue });
}
```

## When You Need Event-Driven Processing

For most applications, you don't need Kafka. You need event-driven task processing with proper failure handling.

```typescript
// Process each item as it arrives. Failure isolated per item.
// Latency is seconds, not minutes. Scales by adding workers.
import { task } from "@trigger.dev/sdk";

export const processSignup = task({
  id: "process-signup",
  retry: { maxAttempts: 3 },
  run: async (payload: { userId: string }) => {
    const user = await db.user.findUnique({ where: { id: payload.userId } });
    await sendWelcomeEmail(user);
    await createDefaultWorkspace(user);
    await trackSignupAnalytics(user);
  },
});

// In the signup handler -- trigger immediately, don't batch
async function handleSignup(data: SignupInput) {
  const user = await db.user.create({ data });
  await processSignup.trigger({ userId: user.id });
  return user;
}
```

## Micro-Batching: The Middle Ground

When per-item overhead is too high but you need low latency, use small frequent batches with per-item failure handling.

```typescript
import { task } from "@trigger.dev/sdk";

export const processEventBatch = task({
  id: "process-event-batch",
  queue: { concurrencyLimit: 5 },
  run: async (payload: { eventIds: string[] }) => {
    const events = await db.event.findMany({
      where: { id: { in: payload.eventIds } },
    });

    // Process individually within the batch -- failure isolation
    const results = await Promise.allSettled(
      events.map(event => processEvent(event))
    );

    // Retry only failures, not the whole batch
    const failures = results
      .map((r, i) => r.status === "rejected" ? events[i] : null)
      .filter(Boolean);
    if (failures.length > 0) await enqueueRetry(failures);
  },
});
```

## Anti-Patterns

```typescript
// Dangerous: polling for unprocessed rows on a timer
// Race conditions with multiple instances, no failure isolation,
// duplicate emails if process crashes between send and flag update
const job = cron("*/5 * * * *", async () => {
  const users = await db.user.findMany({ where: { welcomeEmailSent: false } });
  for (const user of users) {
    await sendWelcomeEmail(user);
    await db.user.update({ where: { id: user.id }, data: { welcomeEmailSent: true } });
  }
});

// Dangerous: shrinking interval as scaling strategy
// Started at 5min, now 10sec. What if processing takes 15sec? Overlap.
setInterval(async () => {
  const events = await db.event.findMany({
    where: { processedAt: null }, take: 1000,
  });
  await processEvents(events); // takes longer than interval under load
}, 10_000);

// Dangerous: one bad item kills the whole batch
const orders = await db.order.findMany({ where: { date: today } });
const report = orders.map(order => ({
  revenue: calculateRevenue(order),  // throws on malformed data
  tax: calculateTax(order),          // throws on missing region
}));
// Order #5,000 throws. All 50,000 orders lost. Retry all or skip?
```

## Related Traps

- **Cardinality** -- high-cardinality data growing over time is the forcing function that breaks batch. When batch size grows because data volume grows, you need streaming, not a shorter interval.
- **Backpressure** -- stream processors handle backpressure naturally (consumer pulls at its own pace). Batch processors don't -- if the batch is bigger than the system can handle, it fails.
- **Idempotency** -- stream/event processing requires idempotent handlers because messages can be delivered more than once. Batch systems often skip this and break when they retry.
- **Race Conditions** -- polling-based batch processing is inherently racy. Two instances polling for `WHERE processed = false` at the same time pick up the same rows.
