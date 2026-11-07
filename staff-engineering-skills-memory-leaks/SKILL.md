---
name: staff-engineering-skills-memory-leaks
description: Prevent memory leaks in garbage-collected languages (Node.js, Go). Use when writing code that accumulates state over time -- in-memory caches, event listeners, timers, closures, goroutines, or any data structure that grows as requests are processed. Activates on patterns like module-level Map/Set/Array that grows without eviction, addEventListener or .on() without corresponding removal, setInterval without clearInterval, closures capturing large objects, Go goroutines without cancellation, or defer inside loops.
---

# Memory Leaks Trap

It works fine in testing. After a week in production, the OOM killer visits. Before writing any code that accumulates state, ask: **what removes entries from this, and what limits its size?**

## How Memory Leaks Happen in GC Languages

In JavaScript and Go, leaks aren't about forgetting `free()`. They're about holding references you no longer need. The GC only reclaims **unreachable** memory; a reference held through a Map, closure, listener, or goroutine pins that memory forever.

The danger is the time dimension. A 200-byte-per-request leak is invisible in a 100-request test. At 1,000 req/s, it's 17GB per day.

## The Five Leak Patterns

| Pattern | What happens | How to spot it |
|---------|-------------|----------------|
| **Unbounded accumulator** | Map/Set/Array grows without eviction | Module-level collection with `.set()`/`.push()` but no `.delete()`/`.pop()` |
| **Event listener leak** | New listener per request, never removed | `.on()`/`addEventListener` without matching `.off()`/`removeEventListener` |
| **Closure capture** | Callback pins a large object in scope | Closure on a long-lived callback referencing outer-scope variables |
| **Timer leak** | `setInterval` runs forever | No `clearInterval` on shutdown or when the resource is gone |
| **Goroutine leak** (Go) | Goroutine blocks on channel/lock forever | `go func()` without context cancellation or channel close |

## Detection: When You're Writing a Leak

**Stop and fix if you see:**

1. **`new Map()`/`new Set()`/`[]` at module scope with `.set()`/`.push()` but no removal** -- if nothing limits its size or evicts old entries, it grows until OOM.

2. **`.on("event", handler)` or `addEventListener` without matching `.off()`/`removeEventListener`** -- every call adds a listener; per-request or per-connection, they accumulate. Node warns with `MaxListenersExceededWarning` -- never suppress it.

3. **`setInterval` without `clearInterval`** -- the timer runs forever and pins any objects its callback references. Clear it when the owning resource is destroyed.

4. **A closure passed to a long-lived callback (scheduler, event bus, queue)** -- check what it captures. It may pin the entire request context or a large dataset even if it uses one field.

5. **`go func()` reading a channel or waiting on a lock without a context/done channel** -- if the channel never closes and the context never cancels, it blocks forever. Each leaked goroutine holds 8KB+ of stack plus referenced data.

6. **`defer` inside a loop** (Go) -- defer runs when the **function** returns, not the iteration. In a 100,000-item loop, all deferred calls accumulate until the function exits.

## Patterns

### Bounded cache with LRU eviction

Never use a plain `Map` as a cache. Always use LRU (or similar) with a `max` size and `ttl` so the memory ceiling is predictable.

```typescript
import { LRUCache } from "lru-cache";

const userCache = new LRUCache<string, User>({ max: 10_000, ttl: 5 * 60 * 1000 });

export async function getUser(id: string): Promise<User> {
  const cached = userCache.get(id);
  if (cached) return cached;
  const user = await db.users.findUnique({ where: { id } });
  userCache.set(id, user);
  return user;
}
```

### Event listener cleanup

Every `.on()` needs a corresponding `.off()` tied to the lifecycle of the resource that owns the listener. With modern APIs, an `AbortController` `signal` removes all listeners tied to it on `abort()`:

```typescript
export function handleWebSocket(ws: WebSocket, userId: string) {
  const ac = new AbortController();
  eventBus.on("notification", (event) => {
    if (event.userId === userId) ws.send(JSON.stringify(event));
  }, { signal: ac.signal });
  ws.on("close", () => ac.abort()); // removes the listener
}
```

### Closures that don't capture more than they need

```typescript
// BAD: closure captures largeDataset (500MB) even though it only uses summary
async function processReport(reportId: string) {
  const largeDataset = await fetchDataset(reportId);
  const summary = summarize(largeDataset);
  scheduler.onComplete(reportId, () => notifyUser(`Report ${reportId}: ${summary}`));
  // largeDataset is pinned by the closure's scope -- can't be GC'd
}

// GOOD: extract needed values before creating the closure
async function processReport(reportId: string) {
  const largeDataset = await fetchDataset(reportId);
  const message = `Report ${reportId}: ${summarize(largeDataset)}`;
  scheduler.onComplete(reportId, () => notifyUser(message));
  // largeDataset is now eligible for GC
}
```

### WeakMap for metadata on transient objects

Use `WeakMap` to attach metadata to objects whose lifecycle you don't control. Unlike `Map`, it doesn't prevent GC of its keys, so entries vanish automatically with no manual cleanup.

```typescript
const requestMetadata = new WeakMap<Request, { startTime: number; traceId: string }>();

export function trackRequest(req: Request) {
  requestMetadata.set(req, { startTime: Date.now(), traceId: crypto.randomUUID() });
}
// Entry removed automatically when the Request is GC'd after the response.
```

### Timer cleanup

```typescript
export function startHeartbeat(connection: Connection) {
  const timer = setInterval(() => connection.ping(), 30_000);
  connection.on("close", () => clearInterval(timer));
  process.on("SIGTERM", () => clearInterval(timer)); // also clear on shutdown
}
```

### Go: goroutine lifecycle with context

Every goroutine needs an exit path -- channel closed, context cancelled, or both. Without one, it's a leak.

```go
func watchForUpdates(ctx context.Context, ch <-chan Update, handler func(Update)) {
    go func() {
        for {
            select {
            case update, ok := <-ch:
                if !ok { return } // channel closed
                handler(update)
            case <-ctx.Done():
                return // context cancelled
            }
        }
    }()
}
```

### Go: defer in loops -- extract to a function

```go
// BAD: all file handles stay open until processFiles returns
func processFiles(paths []string) error {
    for _, path := range paths {
        f, _ := os.Open(path)
        defer f.Close() // accumulates!
    }
    return nil
}

// GOOD: defer runs per-iteration because it lives in its own function scope
func processFiles(paths []string) error {
    for _, path := range paths {
        if err := processFile(path); err != nil { return err }
    }
    return nil
}

func processFile(path string) error {
    f, err := os.Open(path)
    if err != nil { return err }
    defer f.Close()
    return nil
}
```

## The Container Restart Mask

Containers mask leaks. A 20MB/hour leak in a 512MB pod OOM-restarts every ~24 hours -- teams see one restart a day and call it "container flakiness." It persists for months until a traffic increase makes it OOM every 6 hours and someone investigates.

**Periodic restarts at a regular interval = suspect a memory leak.** Plot memory over time -- a linear upward trend is the signature.

## Anti-Patterns

```typescript
// Unbounded Map: grows until OOM
const cache = new Map<string, any>();
function getItem(key) { if (!cache.has(key)) cache.set(key, fetchItem(key)); }

// Listener leak: new listener per connection, never removed
eventBus.on("event", (data) => ws.send(data)); // in a per-connection handler

// Timer leak: no clearInterval anywhere
setInterval(() => refreshData(), 60_000);

// Closure capture: pins 500MB dataset via scope
const data = await fetchLargeDataset();
const summary = summarize(data);
scheduler.later(() => log(`Done: ${summary}`)); // data is pinned
```

## Related Traps

- **Cache Invalidation** -- unbounded caches are the most common source of memory leaks. Every cache needs a max size and eviction policy. See the Cache Invalidation skill.
- **Backpressure** -- unbounded buffers (queues, arrays) that grow because the consumer can't keep up are both a backpressure failure and a memory leak. Apply backpressure before the buffer exhausts memory.
- **Thundering Herd** -- when an OOM-killed process restarts with cold caches, the sudden spike in cache misses can cause a thundering herd on the database.
