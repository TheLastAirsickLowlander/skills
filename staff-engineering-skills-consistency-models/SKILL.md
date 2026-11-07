---
name: staff-engineering-skills-consistency-models
description: Prevent stale read bugs caused by replica lag, cache staleness, and index delay. Use when writing code that reads data after writing it, uses read replicas, caches query results, reads from search indexes, or builds event-driven read models. Activates on patterns like create-then-redirect, update-then-read, cache-aside with TTL, search-after-create, or any write followed by a read that might hit a different data source.
---

# Consistency Models Trap

You wrote data. You read it back. You got the old value. Before writing any code that reads after writing, ask: **could the read hit a different instance than the write?**

## The Three Consistency Gaps

Almost every consistency bug has the same shape: data written to system A, read from system B, and B hasn't caught up.

| Gap | What happens | Typical delay |
|-----|-------------|---------------|
| **Replica lag** | Write to primary, read hits replica | 10-500ms (async replication) |
| **Cache staleness** | Write to database, read hits cache | Seconds to minutes (TTL-based) |
| **Index delay** | Write to database, search reads index | 1-30s (Elasticsearch, Algolia) |

## Detection: Write-Then-Read Patterns

**Stop and check consistency if you see:**

1. **Create/update then redirect to a page that reads the same data** -- the page load may hit a replica; user sees old data and thinks the save failed.
2. **Database write then cache read on the next request** -- cache still has the old value. Worse if the cache was populated from a replica.
3. **Database write then search** -- "I just created this, where is it?" The index hasn't indexed it yet.
4. **Event published then read model queried** -- consumer hasn't processed it. "Order not found" on the confirmation page.
5. **Database write then `findMany` that should include the new record** -- if `findMany` hits a replica, the new record may be missing.
6. **Any UI flow: mutate → navigate → display** -- if display reads from a different source than the mutate, there's a gap.

## Not Everything Needs Strong Consistency

The fix is NOT "make everything strongly consistent" -- that's expensive and usually unnecessary. **Route reads to the appropriate backend based on freshness requirements.**

| Read type | Consistency needed | Source |
|-----------|-------------------|--------|
| User viewing own data after editing | Strong (read-after-write) | Primary, or return written data |
| Browsing other users' content | Eventual | Read replica, cache |
| Full-text search results | Eventual | Search index |
| Dashboard analytics | Eventual | Read replica, materialized view |
| Account balance after transfer | Strong | Primary, write-through cache |
| "My recent orders" after placing one | Strong (read-after-write) | Primary or optimistic UI |

## Patterns

### Return the written data (simplest, best)

```typescript
app.post("/api/profile", async (req, res) => {
  const updated = await db.user.update({
    where: { id: req.user.id },
    data: { name: req.body.name, bio: req.body.bio },
  });
  res.json(updated); // Return what we wrote. No second read needed.
});
```

No read-after-write means no consistency problem. Best pattern whenever the API can return the mutated entity.

### Optimistic UI (client-side)

```typescript
async function updateProfile(data: ProfileUpdate) {
  setLocalProfile(prev => ({ ...prev, ...data })); // Show immediately

  const response = await fetch("/api/profile", {
    method: "PUT",
    body: JSON.stringify(data),
  });

  if (!response.ok) {
    setLocalProfile(previousProfile); // Revert on failure
    showError("Failed to save");
  }
  // Don't re-fetch. Trust local state. Others see it when read models catch up.
}
```

The writer sees the change immediately -- no round-trip, no gap. Standard for modern SPAs.

### Read from primary after write

```typescript
app.post("/api/profile", async (req, res) => {
  await db.user.update({ where: { id: req.user.id }, data: req.body });
  res.cookie("_read_primary", "1", { maxAge: 5000 }); // tell read path to use primary
  res.redirect(`/profile/${req.user.id}`);
});

app.get("/profile/:id", async (req, res) => {
  const forcePrimary = req.cookies._read_primary === "1";
  const user = await db.user.findUnique({
    where: { id: req.params.id },
    ...(forcePrimary && { replicaRead: false }), // framework-specific
  });
  res.render("profile", { user });
});
```

Only the user who wrote gets the primary read; once the cookie expires, reads return to replicas. Everyone else stays on replicas throughout.

### Write-through cache

```typescript
async function updateUser(userId: string, data: Partial<User>) {
  const updated = await db.user.update({ where: { id: userId }, data });
  // Set cache to the known-correct value, don't just delete it.
  await redis.set(`user:${userId}`, JSON.stringify(updated), "EX", 300);
  return updated;
}
```

Write-through beats delete-then-repopulate: if you delete the key, the next request can read from a stale replica and repopulate with old data.

### Separate "my stuff" from "browse/search"

```typescript
app.get("/api/documents", async (req, res) => {
  if (req.query.q) {
    // Search: index (eventual, expected for search)
    res.json(await searchIndex.search("documents", req.query.q));
  } else if (req.query.mine) {
    // My documents: primary (strong for own data)
    res.json(await db.document.findMany({
      where: { authorId: req.user.id }, orderBy: { createdAt: "desc" },
    }));
  } else {
    // Browse all: replica (eventual, fine for discovery)
    res.json(await readReplica.document.findMany({
      orderBy: { createdAt: "desc" }, take: 50,
    }));
  }
});
```

Different reads, different consistency requirements, different backends.

## Know Your Database's Consistency Model

Every database has a default consistency model. Assume stronger guarantees than you have and you'll write stale-read bugs. Defaults and the trap for each:

- **PostgreSQL** -- Strong on a single instance. Streaming (async) replication is the standard HA setup, with 10-500ms replica lag; synchronous replication removes lag but adds write latency. *Trap:* Prisma/Rails/Django can transparently route reads to replicas -- your ORM may read a replica without you knowing.
- **MySQL / Aurora MySQL** -- Strong on single instance. Aurora replicas lag ~10-20ms (shared storage); standard async replicas lag seconds-to-minutes under load. Aurora reader-endpoint affinity can route post-write reads to the writer. *Trap:* cluster endpoint (writes) vs reader endpoint (replicas) -- a reader connection string means you're reading replicas.
- **Redis** -- Eventual with async replication; no guarantee a replica has the latest write. *Trap:* stale cache reads from replicas are by design; for coordination (locks, rate limiting) always read/write the primary.
- **ClickHouse** -- Eventual; built for analytics where slight staleness is fine. Inserts are async by default (local buffer, async replication), so a query right after insert may miss the data. `insert_quorum` forces synchronous writes to N replicas; `select_sequential_consistency=1` forces reads to wait for latest -- both expensive. ReplicatedMergeTree still replicates async. MergeTree merges run in the background, so queries can see duplicate rows until merge completes unless you use `ReplacingMergeTree` with `FINAL` (or `OPTIMIZE TABLE ... FINAL`, expensive). *Trap:* write-then-immediately-query works single-node in dev, fails with distributed tables in prod -- assume reads are stale unless quorum writes are configured.
- **MongoDB** -- Eventual with replica sets; secondaries may be stale. Read concern: `"local"` (default, may be stale), `"majority"`, `"linearizable"` (strongest, slowest). *Trap:* default `"local"` read + default `w:1` write means you can lose acknowledged writes if the primary fails before replication.
- **DynamoDB** -- Eventual reads by default; `GetItem`/`Query` need `ConsistentRead: true` (2x read cost) to see the latest. Global tables resolve cross-region conflicts last-writer-wins. *Trap:* SDK defaults give eventual consistency silently -- a `GetItem` that must see a prior `PutItem` needs `ConsistentRead: true`.
- **Elasticsearch / OpenSearch** -- Near-real-time (eventual): an indexed doc isn't searchable until the next refresh (default 1s; bulk slower). `refresh=wait_for` forces a refresh before returning, at a latency cost. *Trap:* "just indexed, can't find it" -- the index hasn't refreshed; consistency is traded for search throughput.
- **S3** -- Strong read-after-write since 2020: a GET after a successful PUT returns the latest. *Trap:* LIST can still lag -- a newly PUT object may not appear in a LIST immediately. See the Object Store as Database skill for conditional writes.

## Anti-Patterns

```typescript
// Dangerous: create then redirect. /orders/:id reads a replica; order may not be there yet.
app.post("/api/orders", async (req, res) => {
  const order = await db.order.create({ data: req.body });
  res.redirect(`/orders/${order.id}`);
});

// Dangerous: update database, read from cache on next request (stale until TTL expires)
await db.user.update({ where: { id }, data: { name: "New Name" } });
const cached = await redis.get(`user:${id}`); // still "Old Name"

// Dangerous: create in database, immediately search for it (index hasn't refreshed)
await db.document.create({ data: { title: "Q4 Report", content: "..." } });
await searchIndex.index("documents", doc.id, doc);
// User searches "Q4 Report" -- not found

// Dangerous: publish event, query read model on next page (consumer hasn't run)
await eventBus.publish("order.created", order);
res.redirect("/orders");
```

## Related Traps

- **Race Conditions** -- replica lag is a race condition: write to primary, read from replica, decide on stale data. Same fix: read from primary when freshness matters.
- **Idempotency** -- consistency gaps make users retry ("my save didn't work, click again"), creating duplicates. Idempotency prevents the duplicate from causing harm.
- **Cache Invalidation** -- cache staleness is a consistency problem. Write-through is the consistency-aware pattern; delete-and-repopulate races with a stale-replica refill.
- **Denormalization** -- every denormalized copy is an eventually consistent read model; the gap is the window between source write and copy update.
