---
name: staff-engineering-skills-clock-skew
description: Prevent bugs caused by assuming clocks are synchronized or monotonic. Use when writing code that compares timestamps across machines, measures durations, sets lock expiry, orders distributed events, deduplicates by time window, or uses Date.now() for anything other than logging or display. Activates on patterns like Date.now() used for duration measurement, absolute timestamp expiry shared across machines, wall clock timestamps for event ordering, last-write-wins conflict resolution with timestamps, or timeout calculations using wall clock time.
---

# Clock Skew Trap

You used timestamps for ordering. Time disagreed. Before using `Date.now()` for anything other than logging or display, ask: **does correctness depend on this timestamp being accurate relative to another machine's clock, or relative to a previous reading on this machine?**

## Two Kinds of Time

| | Wall clock | Monotonic clock |
|---|-----------|----------------|
| **What it is** | Current time of day (NTP-synchronized) | Counter that only moves forward |
| **Can go backward?** | Yes (NTP corrections, clock steps) | No, by definition |
| **Comparable across machines?** | Only within clock skew margin (typically 1-100ms) | No -- only meaningful within one process |
| **Use for** | Logging, display, human-readable timestamps | Durations, timeouts, elapsed time measurement |
| **API** | `Date.now()`, `time.time()`, `System.currentTimeMillis()` | `process.hrtime.bigint()`, `time.monotonic()`, `time.Since()` |

**The rule:** Use wall clock for humans. Use monotonic clock for measurement. Use logical clocks for distributed ordering.

## Detection: When You're Misusing Time

**Stop and fix if you see:**

1. **`Date.now()` to measure a duration** -- `end - start` can go negative if NTP adjusts the clock between the two calls. Use a monotonic clock.
2. **Timestamps compared across machines for ordering** -- "A happened before B" from different servers' `Date.now()`. If skew is 50ms and events are 30ms apart, you can't know the order. Use logical clocks or a centralized sequence.
3. **Absolute timestamp expiry shared across machines** -- `{ expiresAt: Date.now() + 60000 }` written by Machine A, checked by Machine B. If B's clock is ahead, data expires early. Use relative TTLs.
4. **Last-write-wins using wall clock timestamps** -- two writes within the skew window have undefined ordering. The "winner" is whichever machine's clock runs fast, not which write actually happened last.
5. **Distributed lock expiry using wall clock** -- `if (Date.now() > lockExpiresAt)` checked on a different machine than acquired it. Skew makes the lock appear expired early (two holders) or late (delayed release).
6. **Deduplication by timestamp proximity** -- "ignore events within 100ms." 150ms of skew makes simultaneous events look 150ms apart (not deduped) or 150ms-apart events look simultaneous (wrongly deduped). Dedupe by unique ID.

## When Wall Clock Is Fine

```typescript
// Logging, display, analytics: humans read it; cross-machine order/sub-second accuracy isn't critical
logger.info("Request completed", { timestamp: new Date().toISOString() });
await analytics.track("page_view", { timestamp: Date.now() }); // events/hour survives 100ms skew

// Single-machine record, not used for distributed ordering
const createdAt = new Date();
```

Wall clock is fine when correctness doesn't depend on cross-machine comparison or exact duration measurement.

## Patterns

### Monotonic clock for durations

```typescript
// Node.js -- always non-negative, even if NTP adjusts the wall clock mid-operation
const start = process.hrtime.bigint();
await doExpensiveOperation();
const elapsedMs = Number(process.hrtime.bigint() - start) / 1_000_000;
```

Equivalents: Python `time.monotonic()` (diff is always non-negative); Go `time.Since(time.Now())` (uses the monotonic component automatically).

Use monotonic clocks for: timeouts, latency measurement, rate-limiting windows, any `end - start`. They're only valid within a single process -- never compare across machines.

### Relative TTLs instead of absolute expiry

```typescript
// BAD: absolute expiry shared across machines -- B may disagree on when "now" is
await redis.pexpireat("session", Date.now() + 3600_000); // Machine A's "1 hour from now"

// GOOD: pass durations; let each system compute expiry from its own clock
await redis.expire("session", 3600);             // Redis's own clock
await redis.setex(key, ttlSeconds, payload);     // same system sets and checks the timer
```

The principle: pass durations (seconds, ms) between systems, not absolute timestamps.

### Logical clocks for distributed ordering

To order events across machines, use a logical clock that guarantees causal ordering, not wall clock.

```typescript
class LamportClock {
  private counter = 0;
  tick(): number { return ++this.counter; }
  receive(senderClock: number): number {
    this.counter = Math.max(this.counter, senderClock) + 1;
    return this.counter;
  }
}

const event = {
  type: "order.created",
  logicalTime: clock.tick(),           // ordering: monotonic, causally consistent
  wallClock: new Date().toISOString(), // humans: display/debug only
};
```

Lamport clocks guarantee: if A causally precedes B, then A's logical time < B's. They don't identify concurrent events (use vector clocks for that). For most apps, a centralized sequence generator (DB auto-increment, Redis `INCR`) is simpler and gives a total order.

### Hybrid logical clocks (HLC)

Combines wall clock (rough real-time correspondence) with a logical counter (causal ordering); used by CockroachDB. HLC timestamps sort first by wall time, then by logical counter -- so they roughly track real time while keeping causally related events ordered even when wall clocks collide.

```typescript
class HybridLogicalClock {
  private physicalTime = 0;
  private logical = 0;

  now(): { wallMs: number; logical: number } {
    const pt = Date.now();
    if (pt > this.physicalTime) { this.physicalTime = pt; this.logical = 0; }
    else { this.logical++; }
    return { wallMs: this.physicalTime, logical: this.logical };
  }

  receive(remote: { wallMs: number; logical: number }): { wallMs: number; logical: number } {
    const maxPt = Math.max(Date.now(), this.physicalTime, remote.wallMs);
    if (maxPt === this.physicalTime && maxPt === remote.wallMs) {
      this.logical = Math.max(this.logical, remote.logical) + 1;
    } else if (maxPt === this.physicalTime) {
      this.logical++;
    } else if (maxPt === remote.wallMs) {
      this.logical = remote.logical + 1;
    } else {
      this.logical = 0;
    }
    this.physicalTime = maxPt;
    return { wallMs: this.physicalTime, logical: this.logical };
  }
}
```

### Fencing tokens for distributed locks

Don't rely on clock-based expiry alone. Hand out a monotonically increasing token at acquisition; the protected resource rejects stale ones.

```typescript
const { token } = await acquireLockWithToken("resource-123"); // token monotonically increases
await protectedService.write({ data: newData, fencingToken: token });

// The protected service is the final arbiter, not the clock
async function write(req: { data: Data; fencingToken: number }) {
  if (req.fencingToken <= this.lastSeenToken) {
    throw new Error("Stale fencing token -- lock was superseded");
  }
  this.lastSeenToken = req.fencingToken;
  await db.save(req.data);
}
```

Even if skew makes two processes believe they hold the lock, only the highest token can write.

## Anti-Patterns

```typescript
// Duration with wall clock: can be negative
const elapsed = Date.now() - start; // Use process.hrtime.bigint() instead

// Cross-machine ordering with wall clock: undefined within skew window
events.sort((a, b) => a.timestamp - b.timestamp); // Timestamps from different machines

// Absolute expiry across machines: skew causes early/late expiry
await cache.set(key, { expiresAt: Date.now() + 60000 }); // Pass ttlSeconds instead

// Last-write-wins with wall clock: "last" is undefined
const winner = writes.reduce((a, b) => a.timestamp > b.timestamp ? a : b);

// Lock expiry with wall clock: two holders possible
if (Date.now() > lockExpiresAt) acquireLock(); // Different machine's clock
```

## Related Traps

- **Race Conditions** -- clock skew can create race conditions in distributed locks. Two processes both believe they hold an "exclusive" lock because their clocks disagree on whether the TTL has expired. Fencing tokens prevent the downstream corruption even when the lock fails.
- **Retry Storms** -- timeout calculations using wall clock can fire early (clock jumps forward) or never fire (clock jumps backward). Use monotonic clocks for all timeout logic.
- **Hot Partitions** -- time-based partition keys interact with clock skew at boundaries. Near midnight, machines with different clocks write to different date partitions, creating inconsistency.
- **Idempotency** -- deduplication windows based on timestamps are unreliable when events come from machines with different clocks. Use unique IDs for deduplication, not timestamp proximity.
