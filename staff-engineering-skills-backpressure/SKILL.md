---
name: staff-engineering-skills-backpressure
description: Prevent unbounded resource growth when producers outpace consumers. Use when writing producer-consumer code, queue processing, batch operations, fan-out patterns, streaming pipelines, or any code where work is generated faster than it can be processed. Activates on patterns like Promise.all on dynamic-sized arrays, unbounded in-memory queues, producer loops without depth checks, fire-and-forget async calls in loops, or any buffer between a producer and consumer without a size limit.
---

# Backpressure Trap

The producer is faster than the consumer. The buffer between them grows until something breaks. Before connecting a producer to a consumer, ask: **what happens when the consumer is 10x slower than the producer?**

## The Core Problem

Backpressure is not a problem to solve -- it's a signal to propagate. When a consumer can't keep up, you have three options:

| Strategy | What happens | When to use |
|----------|-------------|-------------|
| **Slow down the producer** | Producer blocks or is throttled until consumer catches up | When all work must be processed (financial transactions, critical events) |
| **Reject at the entry point** | Return 503/429 immediately, caller retries with backoff | When it's better to fail fast than queue indefinitely |
| **Drop excess work** | Newest or oldest items are discarded | When stale data is worthless (metrics, real-time telemetry, live video frames) |

What you must NOT do: add a bigger unbounded buffer. A bigger buffer just delays the failure and makes the OOM worse.

## Detection: When Backpressure Is Missing

**Stop and fix if you see:**

1. **`Promise.all(items.map(fn))` where `items` is dynamic-sized** -- if `items` has 500,000 entries, this creates 500,000 concurrent operations. Connection pools saturate, memory spikes, downstream services are overwhelmed. Always use a concurrency limiter.

2. **An array, queue, or channel that gets `.push()`/`enqueue()` but never has its size checked** -- what bounds the growth? If the answer is "nothing," it grows until OOM.

3. **A producer loop that writes to a queue without checking queue depth** -- the producer runs at full speed regardless of whether the consumer is keeping up. The queue grows linearly with the rate difference.

4. **Fire-and-forget async calls in a loop** -- `for (item of items) { db.insert(item).catch(log) }` launches all inserts as fast as possible with no await. The event loop fills with pending operations, the connection pool is exhausted, and nothing completes.

5. **A database table used as a queue with no depth management** -- INSERT in the producer, SELECT+DELETE in the consumer. Under load, the table grows to millions of rows. SELECT ... ORDER BY ... LIMIT 1 slows down as the table bloats. The consumer gets slower, which makes the queue grow faster -- a positive feedback loop.

6. **No monitoring or alerting on queue/buffer depth** -- you won't know the buffer is filling up until it's too late. Queue depth is the single most important metric for any producer-consumer system.

## Patterns

### Bounded queue with rejection

```typescript
class BoundedQueue<T> {
  private items: T[] = [];

  constructor(private maxSize: number) {}

  enqueue(item: T): boolean {
    if (this.items.length >= this.maxSize) return false; // Backpressure signal
    this.items.push(item);
    return true;
  }

  dequeue(): T | undefined {
    return this.items.shift();
  }

  get depth(): number {
    return this.items.length;
  }
}

// Producer respects backpressure
function handleRequest(req: Request, res: Response) {
  if (!taskQueue.enqueue(createTask(req))) {
    // Tell the caller immediately instead of buffering forever
    res.status(503).json({ error: "System busy. Try again later." });
    return;
  }
  res.status(202).json({ status: "accepted" });
}
```

A 503 in 5ms is better than a timeout after 60 seconds. The caller knows immediately and can retry with backoff. The system stays healthy.

### Concurrency-limited parallel processing

```typescript
import pLimit from "p-limit";

const limit = pLimit(20); // Max 20 concurrent operations

async function processAllUsers(userIds: string[]) {
  return Promise.all(
    userIds.map((id) => limit(() => fetchAndProcessUser(id)))
  );
}
```

Without the limiter, 500,000 users = 500,000 concurrent requests. With it, at most 20 run at a time. The rest wait their turn.

Manual implementation without a library:

```typescript
async function processWithConcurrency<T, R>(
  items: T[],
  fn: (item: T) => Promise<R>,
  concurrency: number,
): Promise<R[]> {
  const results: R[] = [];
  const executing = new Set<Promise<void>>();

  for (const item of items) {
    const promise = fn(item).then((result) => {
      results.push(result);
      executing.delete(promise);
    });
    executing.add(promise);

    if (executing.size >= concurrency) {
      await Promise.race(executing); // Wait for one to finish before starting next
    }
  }

  await Promise.all(executing);
  return results;
}
```

### Pull-based consumption

```typescript
// Consumer pulls work when ready -- natural backpressure
async function consumeQueue(queue: MessageQueue) {
  while (true) {
    // Consumer asks for work only when it's ready for more
    const message = await queue.receive({ waitTimeout: 5000 });
    if (!message) continue;

    try {
      await processMessage(message);
      await queue.ack(message.id);
    } catch (err) {
      await queue.nack(message.id); // Return to queue for retry
    }
  }
}
```

Pull-based has slightly higher latency than push-based (polling vs notification), but the consumer never takes more than it can handle. This is the standard pattern for SQS, RabbitMQ, and most message queues.

### Node.js streams (backpressure built in)

```typescript
import { pipeline, Transform } from "node:stream";
import { createReadStream, createWriteStream } from "node:fs";

const transform = new Transform({
  highWaterMark: 16 * 1024, // 16KB buffer max
  transform(chunk, encoding, callback) {
    const processed = processChunk(chunk);
    callback(null, processed);
    // If the writable side is full, the readable side automatically pauses.
    // Backpressure is handled by the stream machinery -- no manual management.
  },
});

pipeline(
  createReadStream("input.csv"),
  transform,
  createWriteStream("output.csv"),
  (err) => { if (err) console.error("Pipeline failed:", err); }
);
```

`pipeline` handles backpressure automatically. If the writer can't keep up, the transform pauses, which pauses the reader. Use `pipeline` instead of manually piping `.pipe()` -- it also handles cleanup on error.

### Producer that checks consumer health

```typescript
async function ingestEvents(stream: EventStream, queue: BoundedQueue<Event>) {
  for await (const event of stream) {
    // Check queue depth before producing
    while (!queue.enqueue(event)) {
      // Queue is full -- slow down instead of dropping or buffering in memory
      await new Promise((r) => setTimeout(r, 100));

      // Or: if events are time-sensitive and stale ones are worthless, drop
      // logger.warn("Queue full, dropping event", { eventId: event.id });
      // break;
    }
  }
}
```

## The Cascading Failure Connection

Missing backpressure is how one slow service takes down an entire system:

1. Service B gets slow (database issue, GC pause, whatever)
2. Service A calls Service B. Requests pile up in A's outbound connection pool.
3. Service A's connection pool fills. A can't make any new connections -- to B or anyone else.
4. Service A becomes slow for ALL callers, not just the ones that need B.
5. Services C, D, E that call A now have the same problem.
6. The entire system is down because one database query got slow.

**Circuit breakers** (see Distributed System Fallacies skill) cut the cascade by failing fast. **Backpressure** prevents the buffer accumulation that leads to the cascade in the first place.

## Anti-Patterns

```typescript
// Unbounded queue: grows until OOM
const queue: Task[] = [];
function enqueue(task: Task) { queue.push(task); } // No size check

// Promise.all on dynamic array: 500k concurrent operations
await Promise.all(userIds.map(id => processUser(id)));

// Fire-and-forget in a loop: saturates connection pool
for (const row of rows) { db.insert(row).catch(console.error); }

// Producer ignores consumer: pushes to Redis queue without checking depth
for await (const event of stream) { await redis.lpush("queue", JSON.stringify(event)); }

// Database as unbounded queue: table bloat causes positive feedback loop
// INSERT ... (fast) vs SELECT ... ORDER BY created_at LIMIT 1 (slow on 10M rows)
```

## Related Traps

- **Memory Leaks** -- an unbounded buffer is a memory leak. Backpressure and memory leaks are two views of the same problem: data accumulating without bound.
- **Distributed System Fallacies** -- fallacy #3 (bandwidth is infinite) is a backpressure problem. Circuit breakers complement backpressure by failing fast when a dependency is overwhelmed.
- **Thundering Herd** -- when a backed-up queue finally drains (consumer recovers or scales up), the burst of processing can overwhelm downstream services.
- **Retry Storms** -- retries without backoff are a backpressure violation. Each retry adds more work to an already-overwhelmed system.
