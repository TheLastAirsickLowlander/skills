---
name: staff-engineering-skills-sharding
description: Make correct decisions about database sharding -- when to shard, when not to, and what breaks when you do. Use when designing database architecture, choosing scaling strategies, writing queries that assume a single database, selecting shard keys, or when someone says "we need to shard." Activates on patterns like cross-table JOINs in potentially sharded systems, global unique constraints, multi-entity transactions, or premature scaling discussions.
---

# Sharding Trap

Sharding is nearly impossible to undo and fundamentally changes what your code can do. Before sharding, ask: **have you exhausted every simpler alternative?**

## Do You Actually Need to Shard?

Almost certainly not. Work through this checklist first:

| Step | Solution | Handles |
|------|----------|---------|
| 1 | **Indexes** -- run `EXPLAIN ANALYZE` on slow queries | Missing indexes cause 90% of "database is slow" |
| 2 | **Query optimization** -- fix N+1 queries, unnecessary JOINs, full scans | Bad queries, not database limits |
| 3 | **Connection pooling** -- PgBouncer or built-in pooling | Connection exhaustion |
| 4 | **Caching** -- Redis for hot data, query result caches | Read throughput |
| 5 | **Read replicas** -- route reads to replicas | Read scaling |
| 6 | **Table partitioning** -- partition by date range within one database | Large table performance, transparent to app code |
| 7 | **Vertical scaling** -- bigger machine (64-core, 256GB RAM) | Everything, up to a point |

**Only if ALL of these are insufficient should you consider sharding.** A single PostgreSQL instance with proper indexing and read replicas handles far more than most people expect. If you have less than 1TB of data or fewer than 10,000 writes per second, you almost certainly don't need to shard.

## What Sharding Breaks

Once data is distributed across shards, these operations become expensive or impossible:

| Before sharding (trivial) | After sharding (painful) |
|--------------------------|-------------------------|
| `JOIN users ON orders.user_id = users.id` | Cross-shard join: fetch from both shards, join in memory |
| `BEGIN; UPDATE orders; UPDATE inventory; COMMIT;` | Cross-shard transaction: 2PC or saga pattern |
| `SELECT COUNT(*) FROM orders` | Scatter to all shards, aggregate results |
| `CREATE UNIQUE INDEX ON users(email)` | Cross-shard uniqueness: separate lookup table |
| `SELECT * FROM orders ORDER BY created_at LIMIT 20` | Fetch 20 from each shard, merge-sort |

**Every feature you build must now answer: "which shard is this data on?"**

## Detection: Sharding-Unsafe Code

If the system is sharded or may be sharded, **stop and reassess if you see:**

1. **JOINs across entity types** -- `orders JOIN products JOIN users`. These tables may be on different shards. Each join may need to become a separate query + application-level join.

2. **Multi-entity transactions** -- `BEGIN; update order; update inventory; update user; COMMIT;`. If these entities are on different shards, this transaction cannot work.

3. **Global unique constraints** -- `UNIQUE(email)` only works within a single database. Cross-shard uniqueness requires a coordination layer.

4. **Unscoped aggregations** -- `SELECT COUNT(*) FROM orders`. Without a shard key in the WHERE clause, this hits every shard.

5. **`ORDER BY ... LIMIT` without shard key** -- requires fetching from all shards and merge-sorting.

## Shard Key Selection

The shard key determines everything. Get it wrong and sharding makes things worse.

**The shard key must be in your most common query's WHERE clause.** If 80% of queries are scoped to a tenant, shard by tenant. If 80% are scoped to a user, shard by user.

| Shard key choice | Good when | Bad when |
|-----------------|-----------|----------|
| **Tenant/org ID** | Multi-tenant SaaS, queries scoped to tenant | One tenant is 1000x bigger than others (hot shard) |
| **User ID** | User-scoped apps (social, messaging) | Queries need cross-user views (analytics, search) |
| **Hash of primary key** | Even distribution needed | Range queries on the key (date ranges, alphabetical) |
| **Geographic region** | Latency-sensitive, data residency requirements | Uneven population distribution |

**Red flags in shard key selection:**
- Low cardinality (country code: US gets 50% of traffic)
- Skewed distribution (first letter of name: "S" has 4x more than "Q")
- Doesn't appear in the most frequent query's WHERE clause
- Changes over time (user can move between tenants)

## Patterns

### Tenant-based sharding (most common for SaaS)

```typescript
function getShardForTenant(tenantId: string): DatabaseConnection {
  const shardIndex = consistentHash(tenantId, shardCount);
  return shardConnections[shardIndex];
}

async function getOrders(tenantId: string, filters: OrderFilters) {
  const shard = getShardForTenant(tenantId);
  // Single-shard query -- no scatter-gather
  return shard.query(
    `SELECT * FROM orders WHERE tenant_id = $1 AND status = $2
     ORDER BY created_at DESC LIMIT $3`,
    [tenantId, filters.status, filters.limit]
  );
}
```

Works because almost all SaaS operations are scoped to one tenant. Cross-tenant analytics go to a separate data warehouse fed by event streaming.

### Handling cross-shard queries with a read store

```typescript
// Writes go to the shard
async function createOrder(tenantId: string, data: OrderInput) {
  const shard = getShardForTenant(tenantId);
  const order = await shard.insert("orders", { tenantId, ...data });

  // Async: replicate to a global read store for cross-shard queries
  await eventBus.publish("order.created", { orderId: order.id, tenantId, ...data });
  return order;
}

// Cross-shard queries hit the read store (eventually consistent)
async function globalOrderStats() {
  return analyticsDb.query(`
    SELECT DATE_TRUNC('day', created_at) as day, COUNT(*), SUM(amount)
    FROM orders_read_model GROUP BY day ORDER BY day DESC
  `);
}
```

Accept that cross-shard queries need a different store. The read store is eventually consistent but avoids scatter-gather.

### Hot tenant isolation

```typescript
const DEDICATED_TENANTS = new Map([
  ["acme-corp", dedicatedShardConnection],
  ["megacorp", dedicatedShardConnection2],
]);

function getShardForTenant(tenantId: string): DatabaseConnection {
  // Large tenants get their own shard
  const dedicated = DEDICATED_TENANTS.get(tenantId);
  if (dedicated) return dedicated;

  // Everyone else shares the pool
  const shardIndex = consistentHash(tenantId, sharedShardCount);
  return sharedShardConnections[shardIndex];
}
```

When one tenant generates 40% of traffic, hash-based distribution doesn't help. Move them to dedicated infrastructure.

## Anti-Patterns

```typescript
// Premature: "We might have millions of users someday"
// You have 50,000 users and 5GB of data. A single PostgreSQL instance
// on a $600/month machine handles 100x this. Sharding infrastructure
// will cost more in engineering time than 5 years of vertical scaling.

// Wrong shard key: sharded by user_id but dashboard queries by org_id
// Every dashboard query must scatter to ALL shards and aggregate
const results = await Promise.all(
  shards.map(shard =>
    shard.query(`SELECT count(*), sum(amount) FROM orders WHERE org_id = $1`, [orgId])
  )
);
// If the primary access pattern is per-org, shard by org, not user.

// Assumes single database: JOIN across entity types
const orderDetails = await db.query(`
  SELECT o.*, p.name, u.email
  FROM orders o
  JOIN products p ON o.product_id = p.id
  JOIN users u ON o.user_id = u.id
  WHERE o.id = $1
`, [orderId]);
// If orders, products, and users are on different shards, this doesn't work.
```

## Related Traps

- **Race Conditions** -- `SELECT FOR UPDATE` doesn't work across shards. Distributed locking adds latency and failure modes. Cross-shard operations need saga patterns or optimistic concurrency.
- **Idempotency** -- the idempotency key and the data it protects must be on the same shard. Otherwise you can't atomically check for duplicates and perform the operation.
- **Hot Partitions** -- even with sharding, one shard can receive disproportionate traffic. Shard key distribution determines whether you've solved the problem or just renamed it.
- **Consistency Models** -- within a shard: strong consistency. Across shards: eventual consistency at best. Cross-shard queries see data at different points in time.
- **Denormalization** -- cross-shard queries often require maintaining denormalized read stores. This creates consistency obligations (see denormalization trap).
