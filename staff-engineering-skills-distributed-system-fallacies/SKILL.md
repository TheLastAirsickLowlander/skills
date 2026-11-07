---
name: staff-engineering-skills-distributed-system-fallacies
description: Prevent failures caused by treating network calls like function calls. Use when writing code that calls external services, splits a monolith into microservices, chains multiple API calls, orchestrates distributed workflows, or handles requests that depend on other services. Activates on patterns like sequential service calls without timeouts, fetch/axios calls without error handling, multi-service writes without compensation, hardcoded service URLs, or any code that assumes the network is reliable, fast, or free.
---

# Distributed System Fallacies Trap

Code that works locally will fail in production because the network is not a function call. Before writing any code that crosses a network boundary, ask: **what happens when this call is slow, fails, or returns stale data?**

## The Eight Fallacies

Every network call violates at least one of these. Your code must not depend on any.

| # | False assumption | Reality | What breaks |
|---|---|---|---|
| 1 | Network is reliable | Packets drop, connections reset, services crash | Unhandled errors, partial state |
| 2 | Latency is zero | Each call adds 1-500ms; tails spike 10x | Sequential chains become seconds long |
| 3 | Bandwidth is infinite | Full object graphs saturate links at scale | Large payloads slow everything |
| 4 | Network is secure | Internal traffic can be sniffed, spoofed, replayed | Data leaks between services |
| 5 | Topology is static | Services move, scale, failover, redeploy | Hardcoded addresses break |
| 6 | One administrator | Network/cloud/security teams all have control | Can't unilaterally change config |
| 7 | Transport cost is zero | Ser/deser costs CPU at scale | JSON/protobuf encoding overhead |
| 8 | Network is homogeneous | Cross-region != same-rack; WiFi != fiber | Latency varies wildly by path |

## Detection: When You're Writing a Fallacy

**Stop and fix if you see:**

1. **A network call without a timeout** -- `fetch(url)` with no `AbortController`/`signal`/timeout. This can hang forever. Every network call needs an explicit timeout.

2. **Sequential calls where each depends on the previous** -- A, then B, then C. If C fails after A and B succeeded, what state are you in? Think about partial failure before chaining.

3. **`try/catch` that just logs and rethrows** -- handling that doesn't handle anything. What should the system *do* on failure? Return cached data? Degrade? Fail the whole request?

4. **`Promise.all` for calls that can fail independently** -- one rejection kills all. Use `Promise.allSettled` when partial results are acceptable.

5. **A service URL hardcoded or in static config** -- when the service moves (it will), every caller breaks. Use service discovery or DNS with reasonable TTLs.

6. **No circuit breaker on a critical dependency** -- a slow downstream makes your service slow (cascading failure). Without a breaker, you wait for timeouts instead of failing fast.

7. **Multi-service writes without compensation** -- debit A, then credit B. If the credit fails, the debit already happened and money vanished. Distributed writes need saga/compensation.

8. **Fetching full objects when you need two fields** -- `GET /users/123` returns the whole graph when you need `name` and `email`. At scale this wastes bandwidth and serialization time.

## The Core Defensive Patterns

### Every network call gets a timeout

```typescript
async function callService(url: string, timeoutMs: number = 3000) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) throw new Error(`${response.status}: ${response.statusText}`);
    return await response.json();
  } finally {
    clearTimeout(timeout);
  }
}
```

No exceptions, even internal services. A service that "should respond in 10ms" eventually takes 30 seconds, and without a timeout your thread/connection is stuck the whole time.

### Parallel calls with partial failure tolerance

```typescript
async function getUserProfile(userId: string) {
  const [userResult, prefsResult, historyResult] = await Promise.allSettled([
    callService(`${USER_SERVICE}/users/${userId}`, 2000),
    callService(`${PREFS_SERVICE}/preferences/${userId}`, 2000),
    callService(`${HISTORY_SERVICE}/history/${userId}`, 2000),
  ]);
  return {
    user: userResult.status === "fulfilled" ? userResult.value : null,
    preferences: prefsResult.status === "fulfilled" ? prefsResult.value : DEFAULT_PREFS,
    history: historyResult.status === "fulfilled" ? historyResult.value : [],
  };
}
```

Three decisions: (1) parallel, not sequential -- wall-clock is max(latencies), not sum. (2) `allSettled`, not `all` -- one failure doesn't kill the page. (3) defaults for failed calls -- render degraded rather than error.

### Circuit breaker

When a dependency is down, stop calling it. Fail fast instead of waiting for timeouts.

```typescript
class CircuitBreaker {
  private failures = 0;
  private lastFailure = 0;
  private state: "closed" | "open" | "half-open" = "closed";

  constructor(private threshold: number = 5, private resetMs: number = 30_000) {}

  async call<T>(fn: () => Promise<T>): Promise<T> {
    if (this.state === "open") {
      if (Date.now() - this.lastFailure > this.resetMs) this.state = "half-open";
      else throw new Error("Circuit breaker open");
    }
    try {
      const result = await fn();
      this.failures = 0;
      this.state = "closed";
      return result;
    } catch (err) {
      this.failures++;
      this.lastFailure = Date.now();
      if (this.failures >= this.threshold) this.state = "open";
      throw err;
    }
  }
}
```

States: **closed** (calls pass through), **open** (dependency down, reject immediately), **half-open** (try one call to test recovery). Prevents cascading failure -- without it your service burns all its resources waiting on a dead dependency.

### Saga pattern for distributed writes

You cannot have ACID transactions across services. Use reservations and compensations instead.

```typescript
async function transferMoney(from: string, to: string, amount: number) {
  const sagaId = crypto.randomUUID();
  const reservation = await accountsService.reserve(from, amount, sagaId); // hold, don't transfer
  try {
    await accountsService.credit(to, amount, sagaId);
    await accountsService.confirm(reservation.id); // makes the debit permanent
  } catch (err) {
    await accountsService.release(reservation.id); // compensation: release held funds
    throw err;
  }
}
```

Every side-effecting step must be reversible until the final commit; on failure, run compensating actions for all completed steps. This is eventual consistency with explicit rollback, not ACID.

### Retry with backoff (but not blindly)

```typescript
async function callWithRetry<T>(
  fn: () => Promise<T>,
  options: { retries?: number; baseDelayMs?: number; retryableStatuses?: number[] } = {},
): Promise<T> {
  const { retries = 3, baseDelayMs = 200, retryableStatuses = [429, 502, 503, 504] } = options;
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      const isLast = attempt === retries;
      const isRetryable =
        err instanceof Response
          ? retryableStatuses.includes(err.status)
          : err.name !== "AbortError"; // don't retry timeouts by default
      if (isLast || !isRetryable) throw err;
      const delay = baseDelayMs * 2 ** attempt + Math.random() * baseDelayMs; // backoff + jitter
      await new Promise((r) => setTimeout(r, delay));
    }
  }
  throw new Error("unreachable");
}
```

Only retry **retryable** errors (5xx, rate limits); never 4xx (a bad request won't become good). Always backoff with jitter to avoid thundering herd. The retried operation **must be idempotent** -- see the Idempotency skill.

## The Latency Multiplication Problem

Every network hop multiplies latency risk. This is why "split the monolith into microservices" is dangerous advice without understanding the tradeoffs.

| Architecture | Hops | p50 | p99 |
|---|---|---|---|
| Monolith | 0 (in-process) | <1ms | <5ms |
| 2 services | 1 | 5ms | 50ms |
| 5 services in chain | 4 | 20ms | 400ms |
| 10 services in chain | 9 | 50ms | 1-2s |

At p99 each hop can spike 10-50x its median, so with 5 sequential hops one spike anywhere makes the whole request slow. Therefore: **parallelize** independent calls, **don't distribute** what doesn't need it, **set aggressive timeouts** so one slow hop can't hold everything.

## Anti-Patterns

```typescript
// No timeout: hangs forever if the service is slow
const data = await fetch("http://internal-service/api/data");

// Sequential when independent -- fix: Promise.allSettled([getUsers(), getOrders(), getProducts()])
const users = await userService.getUsers();
const orders = await orderService.getOrders();
const products = await productService.getProducts();

// Promise.all when partial failure is acceptable: if history fails, users+orders are discarded too
const [users, orders, history] = await Promise.all([getUsers(), getOrders(), getHistory()]);
// Fix: Promise.allSettled if any can degrade gracefully

// Distributed write without compensation: credit fails, money is gone
await serviceA.debit(account, amount);
await serviceB.credit(target, amount);
// Fix: reserve → credit → confirm, with compensation on failure

// Hardcoded service address: breaks when the IP changes (it will)
const SERVICE_URL = "http://10.0.1.45:3000";
```

## Related Traps

- **Retry Storms** -- retries are essential but dangerous. Retrying without backoff and jitter amplifies load on a struggling service. Retrying non-idempotent operations creates duplicates.
- **Thundering Herd** -- when a service recovers, all the clients that were retrying hit it at once. Circuit breakers with jittered half-open help prevent this.
- **Backpressure** -- the correct response to a slow downstream service is to slow down your own intake, not buffer infinitely until you OOM.
- **Consistency Models** -- across services, you get eventual consistency at best. CAP theorem says during a partition, choose consistency or availability. PACELC says even without partitions, there's a latency/consistency tradeoff.
- **Idempotency** -- every operation you retry must be idempotent. Without idempotency keys, retries create duplicates.
