---
name: staff-engineering-skills-thundering-herd
description: Prevent synchronized demand spikes that overwhelm backends. Use when implementing caching with TTL expiry, scheduling cron jobs, handling reconnection after failures, warming caches on startup, or invalidating cache entries. Activates on patterns like check-cache-miss-fetch-store without locking, fixed TTLs on popular keys, cron expressions at round times like :00 or :30, cache.clear() or cache.delete() on hot keys, or reconnection logic without jitter.
---

# Thundering Herd Trap

The cache expired. Ten thousand requests hit the database at once. Before writing any cache-miss handler, cron schedule, or reconnection logic, ask: **what happens when every client does this at the same time?**

## The Four Triggers

| Trigger | What happens | Example |
|---------|-------------|---------|
| **Cache expiry** | Popular key expires, all concurrent requests miss and fetch simultaneously | Homepage feed cached for 5 min; on expiry, 10,000 requests hit the DB at once |
| **Service recovery** | Service comes back up, all queued retries hit it simultaneously | Downstream API recovers from outage, backlogged clients all retry at once |
| **Synchronized scheduling** | Every instance fires at the same second | Cron at `0 * * * *` on 50 instances = 50 identical queries at :00 |
| **Connection storm** | All clients reconnect simultaneously after a failure | Database failover: 500 app servers all connect to the new primary at once |

## Detection: When You're Creating a Thundering Herd

**Stop and fix if you see:**

1. **"Check cache, miss, fetch, store" with no coalescing** -- the textbook pattern. When 1,000 requests hit the miss simultaneously, 1,000 identical queries hit the database. Only one fetch is needed; the other 999 should wait for its result.

2. **A fixed TTL on a popular cache key** -- `cache.set(key, data, { ttl: 300 })`. All keys set at similar times expire at similar times. Especially dangerous after a deployment or cache restart that repopulates everything at once.

3. **Cron at round times** -- `0 * * * *`, `*/30 * * * *`, `0 0 * * *`. Every instance fires at the same second. Every other system in the world also chose these times. Add jitter.

4. **`cache.delete(key)` or `cache.clear()` on a hot path** -- invalidating a popular key causes an immediate stampede. Use write-through (set the new value) instead of delete, or use stale-while-revalidate.

5. **Reconnection logic without jitter** -- `on("error", () => connect())`. Every client detects the failure at the same time and reconnects at the same time. The new server gets overwhelmed before it can serve anyone.

6. **Cache warming on startup with no stagger** -- 50 pods restart during a deploy, each makes 50 warmup queries. That's 2,500 queries in seconds on top of normal load.

## Patterns

### Request coalescing (single-flight)

Only one request fetches on a miss. Everyone else waits for that result.

```typescript
const inflight = new Map<string, Promise<any>>();

async function getWithCoalescing<T>(key: string, fetcher: () => Promise<T>, ttlSeconds: number): Promise<T> {
  const cached = await cache.get(key);
  if (cached) return JSON.parse(cached);

  // If someone is already fetching this key, wait for their result
  if (inflight.has(key)) return inflight.get(key) as Promise<T>;

  const promise = fetcher()
    .then(async (data) => {
      await cache.set(key, JSON.stringify(data), { EX: ttlSeconds + jitter(ttlSeconds) });
      inflight.delete(key);
      return data;
    })
    .catch((err) => {
      inflight.delete(key);
      throw err;
    });

  inflight.set(key, promise);
  return promise;
}

function jitter(baseTtl: number): number {
  return Math.floor(Math.random() * baseTtl * 0.2); // 0-20% jitter
}
```

This is in-process only -- works for single-instance services. For multi-instance, use a distributed lock (Redis `SET NX PX`) so only one instance across the fleet fetches.

### Stale-while-revalidate

Serve stale data immediately, refresh in the background. The cache never has a true miss.

```typescript
const refreshing = new Set<string>();

async function getWithSWR<T>(key: string, fetcher: () => Promise<T>, ttlSeconds: number): Promise<T> {
  const entry = await cache.getWithTTL(key); // Returns { data, remainingTtl }

  if (entry && entry.remainingTtl > 0) {
    return entry.data; // Fresh
  }

  if (entry) {
    // Stale but exists -- serve it, refresh in background
    if (!refreshing.has(key)) {
      refreshing.add(key);
      fetcher()
        .then((data) => cache.set(key, data, { EX: ttlSeconds + jitter(ttlSeconds) }))
        .finally(() => refreshing.delete(key));
    }
    return entry.data; // Return stale immediately
  }

  // No data at all -- must fetch synchronously (with coalescing)
  return fetchAndCache(key, fetcher, ttlSeconds);
}
```

The user gets a response in milliseconds (from stale cache) while the fresh data is fetched in the background. No stampede because there's never a moment where the cache is empty.

**Tradeoff:** Users may briefly see stale data. Fine for most content. Not acceptable for financial data or security-critical reads.

### Jittered TTLs

Prevent mass expiry by spreading expirations across a time window.

```typescript
function setWithJitter(key: string, data: any, baseTtlSeconds: number) {
  // Add 0-20% random jitter
  const ttl = baseTtlSeconds + Math.floor(Math.random() * baseTtlSeconds * 0.2);
  return cache.set(key, JSON.stringify(data), { EX: ttl });
}
```

This doesn't prevent a stampede on a single hot key (all requests still miss at the same moment). But it prevents mass expiry -- 10,000 keys populated at the same time won't all expire in the same second.

### Jittered cron scheduling

```typescript
// BAD: all instances fire at exactly :00
cron.schedule("0 * * * *", generateReport);

// GOOD: each instance starts at a random offset within the first minute
const jitterMs = Math.floor(Math.random() * 60_000);
setTimeout(() => {
  cron.schedule("0 * * * *", generateReport);
}, jitterMs);
```

### Jittered reconnection

```typescript
// BAD: reconnect immediately on failure
db.on("error", () => db.connect());

// GOOD: exponential backoff with jitter
db.on("error", () => {
  const baseDelay = 1000;
  const attempt = reconnectAttempts++;
  const delay = baseDelay * 2 ** Math.min(attempt, 6) + Math.random() * 1000;
  setTimeout(() => db.connect(), delay);
});
```

Without jitter, all clients reconnect at the same time after the same backoff duration. Jitter spreads them across a window so the server isn't overwhelmed.

### Write-through instead of delete on invalidation

```typescript
// BAD: delete causes a stampede on the next read
async function updateConfig(newConfig: Config) {
  await db.save(newConfig);
  await cache.delete("config"); // Every next request stampedes
}

// GOOD: write the new value directly -- no miss, no stampede
async function updateConfig(newConfig: Config) {
  await db.save(newConfig);
  await cache.set("config", JSON.stringify(newConfig), { EX: 300 });
  // Cache goes from old value → new value with no gap
}
```

## Anti-Patterns

```typescript
// Naive cache-aside: 1,000 concurrent misses = 1,000 identical DB queries
const cached = await cache.get(key);
if (!cached) { data = await db.query(key); await cache.set(key, data, { ttl: 300 }); }

// Fixed TTL, no jitter: all keys populated at deploy expire at the same time
cache.set(key, data, { ttl: 300 }); // Every key gets exactly 300s

// Cron at round time: 50 instances all fire at :00
cron.schedule("0 * * * *", expensiveJob);

// Cache clear in hot path: nuclear stampede
await cache.clear(); // Everything stampedes at once

// Reconnect without backoff: connection storm
db.on("error", () => db.connect());
```

## Related Traps

- **Cache Invalidation** -- cache stampede is the thundering herd problem applied to caching. Stale-while-revalidate and write-through invalidation prevent the gap where the cache is empty.
- **Retry Storms** -- retries are a specific form of thundering herd. When a service is slow and clients retry, the retries themselves create a herd on the struggling service. Exponential backoff with jitter is the same fix in both contexts.
- **Hot Partitions** -- a thundering herd on a partitioned system overwhelms whichever partition holds the hot key. The two traps compound.
- **Backpressure** -- a cache stampede is a sudden loss of backpressure. The cache was absorbing load; when it expires, the full load hits the backend with no buffering.
