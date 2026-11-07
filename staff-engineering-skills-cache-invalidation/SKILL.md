---
name: staff-engineering-skills-cache-invalidation
description: Prevent stale data bugs caused by missing or incomplete cache invalidation. Use when adding caching layers (Redis, in-memory Map, CDN, HTTP cache headers), optimizing read performance, or reviewing code that caches query results, API responses, or computed values. Activates on patterns like cache.set without cache.delete on write paths, unbounded Map/object caches, TTL-only invalidation on security-sensitive data, Cache-Control headers on mutable content, or any caching where the write path doesn't invalidate the read cache.
---

# Cache Invalidation Trap

You added a cache for performance. Now users see stale data. Before caching anything, ask: **when the source data changes, how does every copy get updated or discarded?**

## The Fundamental Problem

A cache is a copy, and copies diverge from the source. Every cache creates a consistency obligation: when the source changes, you must update or discard the copy. If you can't answer "how does this cache learn that the source changed?", you don't have a caching strategy -- you have a stale data bug with a variable delay.

## The Cache Hierarchy

Data passes through multiple cache layers; invalidating one doesn't invalidate the others. Invalidate the application cache but not the CDN (or the CDN but not the browser), and the stale layer keeps serving old data.

| Layer | Control | Invalidation | Risk |
|-------|---------|-------------|------|
| **Browser cache** | Limited (Cache-Control headers) | Can't force purge from server | Stale until user refreshes |
| **CDN** | Purge API, surrogate keys | Propagation delay (seconds) | Millions served stale data |
| **Reverse proxy** | Full control | Direct purge | Stale responses after deploy |
| **Application cache** (Redis, in-memory) | Full control | Event-driven or TTL | Process-local caches diverge across instances |
| **ORM/query cache** | Framework config | Often implicit, hard to invalidate | Stale reads after direct DB writes |

## Detection: When You're Creating a Stale Cache

**Stop and fix if you see:**

1. **`cache.set()` in the read path but no `cache.delete()` in the write path** -- writes don't invalidate reads; the cache serves old data until TTL or restart.

2. **`new Map()` or `{}` used as a cache with no size limit** -- grows forever. Staleness bug AND memory leak. Use LRU with a max size.

3. **TTL-only invalidation on security-sensitive data** (permissions, access tokens, feature flags) -- a revoked admin keeps access for the entire TTL. Invalidate on change, not on timer.

4. **`Cache-Control: max-age=86400` on mutable data** -- the browser won't ask the server for 24 hours. Can't fix server-side; the only escape is changing the URL.

5. **Cache key that doesn't include all variables affecting the value** -- `product:${id}` when the response varies by locale, role, or currency. Users see each other's cached content.

6. **Caching at the application level while also serving through a CDN** -- two caches, probably one invalidation path. Invalidate Redis, the CDN still has the old version.

7. **Write path that bypasses cache invalidation** -- the API invalidates on update, but a background job or admin tool writes directly to the DB. The cache never learns.

## Patterns

### Content-addressed caching (best -- no invalidation needed)

The cache key IS the content hash, so when content changes the key changes and old entries evict naturally via LRU.

```typescript
function getAssetUrl(content: Buffer): string {
  const hash = crypto.createHash("sha256").update(content).digest("hex").slice(0, 16);
  return `/assets/${hash}.js`; // serve with: Cache-Control: public, max-age=31536000, immutable
}
```

This is why build tools hash filenames (`main.a1b2c3d4.js`) while serving the referencing HTML with `no-cache`. **Use whenever the cached value is derived deterministically from its inputs.**

### Cache-aside with event-driven invalidation

```typescript
const CACHE_TTL = 300; // safety net, not the primary mechanism

async function getProfile(userId: string): Promise<UserProfile> {
  const cached = await redis.get(`profile:${userId}`);
  if (cached) return JSON.parse(cached);

  const profile = await db.users.findUnique({ where: { id: userId } });
  await redis.setex(`profile:${userId}`, CACHE_TTL, JSON.stringify(profile));
  return profile;
}

async function updateProfile(userId: string, data: Partial<UserProfile>) {
  const updated = await db.users.update({ where: { id: userId }, data });
  // Write-through: set to the known-correct value from the write
  await redis.setex(`profile:${userId}`, CACHE_TTL, JSON.stringify(updated));
  // For other instances with local caches, publish invalidation
  await redis.publish("cache-invalidation", JSON.stringify({ type: "profile", id: userId }));
}
```

- **Write-through** (set to new value) beats **delete** (let next read repopulate): delete risks repopulation from a stale replica -- see the Consistency Models skill.
- The TTL is a **safety net** that catches writes bypassing the invalidation path (admin tools, migrations, background jobs).
- Multiple instances with local caches need a pub/sub invalidation channel.

### Bounded in-memory cache with LRU

Never use a plain `Map` as a cache. Always use an LRU (or similar) with a size limit and TTL. `allowStale: true` gives stale-while-revalidate: the caller gets the old value immediately while the fresh value loads in the background.

```typescript
import { LRUCache } from "lru-cache";

const profileCache = new LRUCache<string, UserProfile>({
  max: 10_000,
  ttl: 5 * 60 * 1000,
  allowStale: true,
  fetchMethod: async (userId) => db.users.findUnique({ where: { id: userId } }),
});

async function getProfile(userId: string): Promise<UserProfile> {
  return profileCache.fetch(userId);
}
```

### Cache stampede prevention (single-flight)

When a popular entry expires, hundreds of requests see a miss simultaneously and all hit the database. Coalesce them into one.

```typescript
const inFlight = new Map<string, Promise<any>>();

async function getCached<T>(key: string, fetcher: () => Promise<T>, ttlSeconds: number): Promise<T> {
  const cached = await redis.get(key);
  if (cached) return JSON.parse(cached);
  if (inFlight.has(key)) return inFlight.get(key) as Promise<T>; // already fetching, wait for it

  const promise = fetcher()
    .then(async (result) => {
      await redis.setex(key, ttlSeconds, JSON.stringify(result));
      inFlight.delete(key);
      return result;
    })
    .catch((err) => {
      inFlight.delete(key);
      throw err;
    });

  inFlight.set(key, promise);
  return promise;
}
```

This works within a single process only. For multi-instance stampede prevention, use a distributed lock or probabilistic early expiration (each request has a small random chance of refreshing before TTL).

### Cache key design

Every variable that affects the cached value must be in the key, or different contexts share data they shouldn't.

```typescript
const key = `product:${productId}`;                                  // BAD: ignores locale/currency
const key = `product:${productId}:locale:${locale}:currency:${currency}`;
const key = `dashboard:${userId}:${orgId}`;                          // user-specific data
const key = `orders:${userId}:page:${page}:size:${pageSize}:sort:${sortBy}`; // paginated data
```

## What to Cache Where

| Data | Invalidation strategy | TTL | Notes |
|------|----------------------|-----|-------|
| Static assets (JS, CSS, images) | Content-addressed URL | Immutable (1 year) | No invalidation -- URL changes |
| User profile (own) | Write-through on update | 5 min safety net | Must see own changes immediately |
| User profile (others) | TTL-only | 5-15 min | Eventual consistency is fine |
| Permissions / access control | Invalidate on change | 30 sec safety net | Never TTL-only for security data |
| Feature flags | Invalidate on change | 1 min safety net | Long TTL delays incident response |
| Product catalog | Event-driven + TTL | 15 min | Flash sales need faster invalidation |
| Search results | TTL-only | 1-5 min | Eventually consistent by nature |
| API rate limit counters | N/A (not a cache) | N/A | Use Redis atomic ops, not caching |

## Anti-Patterns

```typescript
// No invalidation: cache written, never cleared
function getUser(id) { /* sets cache */ }
function updateUser(id, data) { /* updates DB, doesn't touch cache */ }

// Unbounded: grows until OOM
const queryCache = new Map<string, any>();

// TTL on security data: revoked user keeps access for 15 minutes
const permCache = new Map();
const TTL = 15 * 60 * 1000;

// Delete-then-repopulate race: del, then another request reads a lagging replica and re-caches stale data
await redis.del(`user:${id}`);

// Cache key missing context: users see each other's locale-specific content
await redis.set(`product:${id}`, JSON.stringify(localizedProduct));
```

## Related Traps

- **Consistency Models** -- cache staleness is a consistency problem. Write-through caching avoids the race where delete-then-repopulate reads from a stale replica. See the Consistency Models skill for read-after-write patterns.
- **Memory Leaks** -- every unbounded cache is a memory leak. If it has no max size and no eviction policy, it grows until the process is killed.
- **Thundering Herd** -- cache stampede (popular key expires, all requests hit the database simultaneously) is the thundering herd problem applied to caching. Single-flight and stale-while-revalidate prevent this.
- **Denormalization** -- a cache is a form of denormalization. Every cached value is a copy that must be kept in sync with the source. The consistency obligation is the same.
