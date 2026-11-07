---
name: staff-engineering-skills-race-conditions
description: Detect and prevent race conditions in concurrent code. Use when writing code that reads then writes shared state, checks a condition then acts on it, creates records that should be unique, updates counters or balances, transitions status fields, or handles webhook/queue retries. Activates on patterns like check-then-act, read-modify-write, findUnique-then-create, or any shared state mutation without atomicity guarantees.
---

# Race Conditions Trap

Code that reads correctly line by line can corrupt data when two copies run at once. Before writing any code that reads shared state and then writes based on what it read, ask: **what happens if another process changes the state between my read and my write?**

## The Three Patterns

Almost every race condition is one of these:

### 1. Check-Then-Act (TOCTOU)

Read state, make a decision, act on it. Another process changes state between check and act.

```typescript
// RACE: two requests both find no user, both create one
const existing = await db.user.findUnique({ where: { email } });
if (!existing) return await db.user.create({ data: { email } });
```

### 2. Read-Modify-Write

Read a value, compute a new value, write it back. Another process reads the same old value.

```typescript
// RACE: two requests read inventory=1, both write inventory=0. Oversold by 1.
const product = await db.product.findUnique({ where: { id: productId } });
if (product.inventory <= 0) throw new Error("Out of stock");
await db.product.update({ where: { id: productId }, data: { inventory: product.inventory - 1 } });
```

### 3. Check-Act-With-Side-Effects

Read state, perform an irreversible action, update state. Another process reads the same state before update.

```typescript
// RACE: two processes both see status="paid", both ship the order
const order = await db.order.findUnique({ where: { id: orderId } });
if (order.status !== "paid") throw new Error("Order not paid");
await externalShippingApi.createShipment(order); // irreversible!
await db.order.update({ where: { id: orderId }, data: { status: "shipped" } });
```

## Detection: When You're Writing a Race Condition

Stop and fix if you see any of these:

1. **`findUnique`/`findFirst` then `create`** -- classic check-then-act; two processes pass the check before either creates. Use a unique constraint + upsert or create-catch-conflict.
2. **Read X, compute, write X back** (`X = X + 1`) -- use atomic ops (`{ increment: 1 }`, `UPDATE ... SET x = x + 1`).
3. **Status read then updated in separate ops** (`if (status === "A") update("B")`) -- use conditional WHERE `... SET status='B' WHERE status='A'` and check affected rows.
4. **Any read-then-write to the same row without a transaction or atomic constraint** -- the gap between them is the race window.
5. **Retry logic on non-idempotent operations** -- the first attempt may have succeeded with a lost response; the retry races the completed first attempt.
6. **`if (!fs.existsSync(path)) fs.writeFileSync(path, data)`** -- filesystem TOCTOU; use `O_CREAT | O_EXCL`.

## Fix: Let the Database Be the Arbiter

The database is the source of truth and the concurrency enforcer. Push race-prevention into the database layer, not application code.

### Unique constraints (for check-then-act)

```typescript
// SAFE: unique index on email. Only one create succeeds; loser falls back to find.
async function getOrCreateUser(email: string) {
  try {
    return await db.user.create({ data: { email } });
  } catch (error) {
    if (isPrismaUniqueConstraintError(error)) {
      return await db.user.findUnique({ where: { email } });
    }
    throw error;
  }
}

// Or, if your ORM upserts atomically:
const user = await db.user.upsert({ where: { email }, create: { email, name }, update: {} });
```

### Atomic update with conditional WHERE (for read-modify-write)

```typescript
// SAFE: decrement-and-check in one atomic statement (UPDATE ... SET inv = inv - 1 WHERE id = ? AND inv > 0)
async function decrementInventory(productId: string) {
  const result = await db.product.updateMany({
    where: { id: productId, inventory: { gt: 0 } },
    data: { inventory: { decrement: 1 } },
  });
  if (result.count === 0) throw new Error("Out of stock");
}
```

### Conditional status transition (for state machines)

```typescript
// SAFE: claim the transition atomically (UPDATE ... SET status='shipping' WHERE id=? AND status='paid') before any side effect
async function shipOrder(orderId: string) {
  const result = await db.order.updateMany({
    where: { id: orderId, status: "paid" },
    data: { status: "shipping" }, // claim it first
  });
  if (result.count === 0) throw new Error("Order not in paid state");

  await externalShippingApi.createShipment(orderId); // now safe -- we own this transition
  await db.order.update({ where: { id: orderId }, data: { status: "shipped" } });
}
```

### Optimistic locking with version column

```typescript
// SAFE: detects concurrent modification via version mismatch
async function updateDocument(docId: string, changes: Partial<Doc>) {
  const doc = await db.document.findUnique({ where: { id: docId } });
  const result = await db.document.updateMany({
    where: { id: docId, version: doc.version },
    data: { ...changes, version: doc.version + 1 },
  });
  if (result.count === 0) throw new ConflictError("Document was modified by another process");
}
```

### Pessimistic locking (when you must hold state across external calls)

```typescript
// SAFE: FOR UPDATE locks the row, serializing concurrent access
async function processPayment(orderId: string) {
  await db.$transaction(async (tx) => {
    const order = await tx.$queryRaw`SELECT * FROM orders WHERE id = ${orderId} FOR UPDATE`;
    if (order.status !== "pending") throw new Error("Already processed");

    const charge = await stripe.charges.create({ amount: order.total });
    await tx.order.update({
      where: { id: orderId },
      data: { status: "paid", stripeChargeId: charge.id },
    });
  });
}
```

Use `SELECT FOR UPDATE` when you must read state, do external work (API calls), then write. Tradeoff: same-row operations serialize, reducing throughput.

## Redis Atomic Operations

Redis commands are single-threaded and atomic. Use them for fast, atomic operations on shared counters, flags, or sets that don't need database durability.

### Atomic counter

```typescript
// SAFE: DECR is atomic; incr to undo if we went negative
async function decrementInventory(productId: string) {
  const remaining = await redis.decr(`inventory:${productId}`);
  if (remaining < 0) {
    await redis.incr(`inventory:${productId}`);
    throw new Error("Out of stock");
  }
}
```

### Lua scripts for multi-step atomic operations

```typescript
// SAFE: the whole script executes atomically in Redis
const CLAIM_COUPON = `
  local used = redis.call('SISMEMBER', KEYS[1], ARGV[1])
  if used == 1 then return 0 end
  redis.call('SADD', KEYS[1], ARGV[1])
  return 1
`;

async function claimCoupon(couponId: string, userId: string): Promise<boolean> {
  const result = await redis.eval(CLAIM_COUPON, 1, `coupon:${couponId}:used`, userId);
  return result === 1;
}
```

### SET NX for simple locks

```typescript
// SAFE: atomic set-if-not-exists with auto-expiry to prevent deadlocks
async function acquireLock(resource: string, ttlMs: number): Promise<string | null> {
  const token = crypto.randomUUID();
  const acquired = await redis.set(`lock:${resource}`, token, "PX", ttlMs, "NX");
  return acquired === "OK" ? token : null;
}

// Release with Lua so you only release YOUR lock
const RELEASE_LOCK = `
  if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
  end
  return 0
`;

async function releaseLock(resource: string, token: string) {
  await redis.eval(RELEASE_LOCK, 1, `lock:${resource}`, token);
}
```

## Distributed Locks and Redlock

When you need mutual exclusion across processes or servers and `SELECT FOR UPDATE` won't work (e.g., the critical section touches non-database resources), you may need a distributed lock.

**Single-instance Redis (usually sufficient):** `SET NX PX` (above) is good enough for most apps. Failure mode is well-understood: if Redis dies the lock is lost and two processes may enter the critical section. Acceptable when the lock is a best-effort guard, not a safety-critical mutex.

**Redlock (when single-instance isn't enough):** uses N independent Redis instances (typically 5); a client holds the lock if it acquires a majority (N/2 + 1) within a time bound.

```typescript
import { Redlock } from "redlock";

const redlock = new Redlock([redis1, redis2, redis3, redis4, redis5], { retryCount: 3, retryDelay: 200 });

async function processExclusively(resourceId: string) {
  const lock = await redlock.acquire([`lock:${resourceId}`], 30_000);
  try {
    await doExclusiveWork(resourceId);
  } finally {
    await lock.release();
  }
}
```

### When to use what

| Approach | Use when | Tradeoff |
|----------|----------|----------|
| Database `SELECT FOR UPDATE` | Critical section is database operations | Serializes access, holds DB connection |
| Single Redis `SET NX PX` | Best-effort mutual exclusion, single Redis | Lost on Redis failure |
| Redlock (N Redis instances) | Need lock to survive single-node failure | Complex, clock-dependent, controversial |
| Idempotency key | Operations can be safely retried | Doesn't prevent concurrent execution, just duplicate effects |

**Redlock caveats:**
- Depends on synchronized clocks; clock skew can let two processes both believe they hold the lock.
- Kleppmann's "How to do distributed locking" argues it's unsafe for correctness-critical use. Add **fencing tokens** (monotonically increasing values downstream services validate) as a safety layer.
- If the protected operation has side effects (API calls, charges), the lock alone isn't enough -- combine with idempotency keys.
- Reach for Redlock only when you have a specific reason single-instance Redis isn't enough; otherwise a DB constraint or single Redis lock is simpler.

## The Priority Order

When fixing a race, prefer solutions in this order -- higher numbers mean more code, complexity, and failure modes:

1. **Unique constraint** -- DB rejects duplicates, zero app code.
2. **Atomic update** -- `SET x = x + 1 WHERE condition`, inherently atomic.
3. **Upsert** -- `INSERT ... ON CONFLICT UPDATE`, atomic create-or-update.
4. **Redis atomic ops** -- `DECR`, `SETNX`, Lua, for fast in-memory coordination.
5. **Optimistic locking** -- version column in WHERE, retries on conflict.
6. **Pessimistic locking** -- `SELECT FOR UPDATE`, blocks concurrent access.
7. **Distributed lock (Redis/Redlock)** -- cross-process mutual exclusion, last resort.

## Anti-Patterns

- **Check-then-act (TOCTOU)** -- `findUnique` then `create`, or "check it doesn't exist, then insert." Two requests both pass the check and both write. Fix with a unique constraint.
- **Read-modify-write in app code** -- read a counter or balance, compute the new value, write it back. Concurrent writers overwrite each other's increments. Fix with atomic `UPDATE ... SET x = x + n` or a version column.
- **Acting on a stale status** -- read `status === "pending"`, then charge/ship/send. A retry reads the same status and acts twice. Gate the side effect on a conditional transition (`UPDATE ... WHERE status = 'pending'`) and check rows affected.
- **Holding a distributed lock across an external call without a fence** -- the lock can expire mid-operation while a second worker acquires it. Carry a fencing token so stale holders are rejected.

## Related Traps

- **Idempotency** -- many races manifest as duplicate operations. If every operation is idempotent, races cause no harm. Idempotency keys are the primary defense against webhook and queue retry races.
- **Consistency Models** -- replica lag creates races even in single-process code: you write to the primary, read from a replica, data isn't there yet. Read-after-write must hit the primary.
- **Object Store as Database** -- S3 GET-modify-PUT without `If-Match` is a read-modify-write race. Use conditional writes for optimistic concurrency on object storage.
