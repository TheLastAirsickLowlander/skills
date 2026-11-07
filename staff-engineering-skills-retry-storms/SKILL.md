---
name: staff-engineering-skills-retry-storms
description: Prevent retry logic from amplifying failures into cascading outages. Use when adding retry logic to network calls, configuring HTTP clients, building service-to-service communication, handling timeouts, or working with multi-layer architectures where retries exist at multiple levels. Activates on patterns like retry loops without backoff or jitter, retrying all HTTP errors including 4xx, retry logic at multiple layers of a call chain, retries without circuit breakers, or timeouts that don't account for remaining deadline budget.
---

# Retry Storms Trap

The service is slow. Your retries made it slower. Before adding retry logic, ask: **what happens when every client retries at the same time against an already-struggling service?**

## The Feedback Loop

Retry storms are a positive feedback loop: worse performance draws more retries, which worsens performance, which draws more retries. The only stable states are "working fine" and "completely dead."

```
Service slow → clients time out → retry → 2x load → slower
  → more timeouts → more retries → 4x load → collapse
```

The system can't recover under load because retries prevent the load from decreasing.

## The Layer Multiplication Problem

Three layers of 3 retries = 27 backend calls for one user request.

```
User request
  → Gateway 3x → Service A 3x → Service B 3x → Database
        = 3 × 3 × 3 = 27 database queries
```

Each layer multiplies independently. An agent adding "just 3 retries" to Service A doesn't know Service B already has 3. Nobody calculated the total.

**Before adding retries, count the total retry multiplication across the full call chain.**

## Detection: When You're Building a Retry Storm

**Stop and fix if you see:**

1. **Retry logic at multiple layers** -- calculate worst-case total. More than ~10 for one user request is too many. Retry at ONE layer, ideally the outermost.

2. **Retrying all errors, including 4xx** -- 400/401/409 will never succeed on retry. Only retry 5xx, 429, 408, and network errors.

3. **Fixed-interval retries or no backoff** -- `sleep(1000)` makes all clients retry the same second. Use exponential backoff with jitter.

4. **Retries without a circuit breaker** -- retries into a dead service generate load that prevents recovery. A breaker stops sending after repeated failures, giving the service time to recover.

5. **Timeout × retry count exceeds the user's patience** -- 30s × 3 = 120s worst case; is the user still waiting? Each retry should use the remaining deadline, not a fresh timeout.

6. **Retry logic in both the HTTP client library and application code** -- Axios, AWS SDK, gRPC retry by default. App-level retries on top multiply silently. Check your client's default retry config.

## Patterns

### Only retry retriable errors

```typescript
function isRetriable(error: unknown): boolean {
  if (error instanceof HttpError) {
    return error.status >= 500 || error.status === 429 || error.status === 408;
  }
  // Network errors (connection refused, DNS failure, TCP reset)
  if (error instanceof TypeError && error.message.includes("fetch")) return true;
  return false;
}
```

| Status | Retry? | Why |
|--------|--------|-----|
| 400 / 422 | No | Input/validation wrong, won't change |
| 401 / 403 | No | Credentials wrong / permission denied |
| 404 | No | Resource doesn't exist |
| 409 Conflict | No | Operation already happened or state conflict |
| 429 Too Many Requests | Yes | Rate limited, back off and retry |
| 408 Request Timeout | Yes | Server timed out, may work on retry |
| 500+ Server Error | Yes | Transient server issue |
| Network error | Yes | Connection failed, may work on retry |

### Exponential backoff with full jitter

```typescript
async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  options: { maxRetries?: number; baseDelayMs?: number } = {},
): Promise<T> {
  const { maxRetries = 3, baseDelayMs = 200 } = options;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      if (attempt === maxRetries || !isRetriable(error)) throw error;
      // Full jitter: random point in the exponential window
      const delay = Math.random() * (baseDelayMs * 2 ** attempt);
      await new Promise((r) => setTimeout(r, delay));
    }
  }
  throw new Error("unreachable");
}
```

Full jitter (`random * maxDelay`) spreads retries across the entire backoff window. Without jitter, all clients that failed together retry together -- a thundering herd of retries.

### Circuit breaker (stop retrying into a dead service)

```typescript
class CircuitBreaker {
  private failures = 0;
  private lastFailure = 0;
  private state: "closed" | "open" | "half-open" = "closed";

  constructor(private threshold = 5, private resetMs = 30_000) {}

  async call<T>(fn: () => Promise<T>): Promise<T> {
    if (this.state === "open") {
      if (Date.now() - this.lastFailure > this.resetMs) this.state = "half-open"; // allow one test
      else throw new CircuitBreakerOpenError(); // fail fast
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

When open, requests fail immediately instead of waiting for a timeout, giving the downstream service time to recover. After `resetMs`, one test request is allowed through; if it succeeds the circuit closes and traffic resumes.

### Retry budget (system-level protection)

Limit retries as a percentage of total traffic, not per-request.

```typescript
class RetryBudget {
  private requests = 0;
  private retries = 0;

  constructor(private maxRetryRatio = 0.1, private minRetriesPerWindow = 10) {
    setInterval(() => { this.requests = 0; this.retries = 0; }, 1000); // sliding window
  }

  recordRequest() { this.requests++; }
  recordRetry() { this.retries++; }

  shouldRetry(): boolean {
    if (this.retries < this.minRetriesPerWindow) return true; // always allow some
    return this.retries / Math.max(this.requests, 1) < this.maxRetryRatio;
  }
}
```

With a 10% budget at 1,000 req/s, at most 100 are retries -- the system can never generate more than 1.1x its normal load from retries. This is the approach used by Google's gRPC and the Google SRE book.

### Deadline propagation

Pass the remaining time budget through the call chain; don't give each retry a fresh timeout.

```typescript
async function handleRequest(req: Request) {
  const deadline = Date.now() + 10_000; // 10s total budget
  const resultA = await callWithDeadline(serviceA.fetch, deadline);
  const resultB = await callWithDeadline(serviceB.fetch, deadline); // if A took 8s, B gets 2s
  return combine(resultA, resultB);
}

async function callWithDeadline<T>(
  fn: (timeoutMs: number) => Promise<T>,
  deadline: number,
): Promise<T> {
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw new DeadlineExceededError();
  return fn(remaining);
}
```

Without propagation, a retry starting 8s into a 10s budget gets a fresh 10s timeout and the user waits 18s total. With it, the retry gets 2s and fails fast.

### Load shedding (server-side protection)

The server rejects requests when overloaded instead of accepting them and being slow.

```typescript
class LoadShedder {
  private active = 0;
  constructor(private maxConcurrent: number) {}

  async handle<T>(fn: () => Promise<T>): Promise<T> {
    if (this.active >= this.maxConcurrent) throw new HttpError(503, "Service overloaded");
    this.active++;
    try { return await fn(); }
    finally { this.active--; }
  }
}
```

A fast 503 tells the client "try again later" or "try another instance" instead of tying up its resources while it waits. Load shedding keeps accepted requests fast and healthy.

## Anti-Patterns

```typescript
// Retries all errors including 4xx; fixed interval, no jitter
for (let i = 0; i < 3; i++) {
  try { return await fetch(url); }
  catch { await sleep(1000); }
}

// Layer multiplication: 3 × 3 × 3 = 27 backend calls
gateway: retry(3, () => serviceA())
serviceA: retry(3, () => serviceB())
serviceB: retry(3, () => database())

// Fresh timeout per retry: 30s × 4 attempts = 120s user wait
for (let i = 0; i < 3; i++) {
  try { return await callWithTimeout(service, 30_000); }
  catch { continue; }
}

// Library retries + app retries = silent multiplication
const axios = create({ retries: 3 });
async function call() { return retry(3, () => axios.get(url)); } // 9 total
```

## Related Traps

- **Thundering Herd** -- retries without jitter create thundering herds: all clients that failed together retry together. Exponential backoff with jitter is the same fix for both.
- **Idempotency** -- every operation you retry MUST be idempotent. Retrying a payment without an idempotency key charges the customer multiple times. Retries and idempotency are inseparable.
- **Distributed System Fallacies** -- fallacy #1 (the network is reliable) leads to both "no retries" and "too many retries." The correct middle ground is limited, budgeted retries with circuit breakers.
- **Backpressure** -- retries without budgets are a backpressure violation. Each retry adds work to an overwhelmed system instead of slowing down.
