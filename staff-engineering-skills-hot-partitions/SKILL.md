---
name: staff-engineering-skills-hot-partitions
description: Prevent disproportionate load on individual partitions, shards, or nodes. Use when choosing partition keys, designing sharded databases, writing to Kafka topics, using DynamoDB, partitioning tables by date, or working with any system where data is distributed across multiple nodes. Activates on patterns like partitioning by date for write-heavy data, low-cardinality partition keys (country, status), tenant-based sharding without hot-tenant handling, single global keys in DynamoDB, or any partition scheme without per-partition monitoring.
---

# Hot Partitions Trap

You distributed the data evenly. But traffic isn't even -- one partition is on fire. Before choosing a partition key, ask: **does this key distribute access patterns, not just data?**

## The Core Problem

Data distribution and access distribution are different things. Ten million users across 100 partitions is 100,000 users per partition. But if one user generates 50% of traffic, that user's partition handles 50% of total load. You've built a distributed system that behaves like a single node.

Real traffic follows power laws. A small number of entities generate most of the activity. Your partition scheme must account for this.

## Detection: When You're Creating a Hot Partition

**Stop and fix if you see:**

1. **Partitioning by date/timestamp for write-heavy data** -- today's partition receives ALL writes. Yesterday's is idle. This is the most common hot partition pattern for time-series, events, and logs.

2. **Partitioning by a low-cardinality key** -- country code (US gets 50%), status field (90% are "active"), boolean flags. Low cardinality means few partitions, and the most common value dominates.

3. **A single global key in DynamoDB** -- `pk = "global-leaderboard"` or `pk = "config"`. Every request for that item hits the same partition. DynamoDB partitions can handle ~3,000 RCU / ~1,000 WCU per second per partition key.

4. **Kafka topic keyed by something skewed** -- `key: user.countryCode` means one Kafka partition gets half the world's messages. One consumer handles that partition and falls behind while 31 others are idle. Adding consumers doesn't help (Kafka assigns one consumer per partition).

5. **Tenant-based sharding with no hot-tenant handling** -- `hash(tenantId) % numShards`. The enterprise tenant generating 40% of queries lands on one shard. That shard is permanently overloaded.

6. **No per-partition monitoring** -- without metrics per partition, you won't know one is hot until it causes an outage. Per-partition metrics are not optional.

## Patterns

### Write sharding with random suffix

Spread writes for a hot key across multiple physical partitions.

```typescript
const WRITE_SHARDS = 10;

async function writeEvent(date: string, event: Event) {
  const shard = Math.floor(Math.random() * WRITE_SHARDS);
  await dynamodb.put({
    TableName: "events",
    Item: { pk: `${date}#${shard}`, sk: event.eventId, ...event },
  });
}

// Reads scatter-gather across all shards
async function readEvents(date: string): Promise<Event[]> {
  const results = await Promise.all(
    Array.from({ length: WRITE_SHARDS }, (_, i) =>
      dynamodb.query({
        TableName: "events",
        KeyConditionExpression: "pk = :pk",
        ExpressionAttributeValues: { ":pk": `${date}#${i}` },
      })
    )
  );
  return results.flatMap((r) => r.Items as Event[]);
}
```

**Tradeoff:** Writes are perfectly distributed. Reads require scatter-gather (query all shards and merge), increasing latency and cost. Use when the workload is write-heavy or the hot key is known in advance.

### Composite partition keys

Add a second dimension to increase cardinality and spread load.

```typescript
// BAD: tenant alone is low-cardinality for hot tenants
const pk = tenantId; // "acme-corp" gets 40% of traffic

// GOOD: combine with entity type or time bucket
const pk = `${tenantId}#${entityType}`;
// "acme-corp#invoices", "acme-corp#users", "acme-corp#events"

// GOOD: combine with time bucket for write-heavy patterns
const hourBucket = new Date().toISOString().slice(0, 13); // "2024-01-15T14"
const pk = `${tenantId}#${hourBucket}`;
```

**Tradeoff:** Only helps if the secondary dimension has enough cardinality. If the hot tenant does one thing, compositing doesn't spread the load.

### Dedicated infrastructure for hot tenants

```typescript
const DEDICATED_TENANTS = new Map<string, Database>([
  ["acme-corp", acmeDatabase],
  ["megacorp", megacorpDatabase],
]);

function getDatabaseForTenant(tenantId: string): Database {
  const dedicated = DEDICATED_TENANTS.get(tenantId);
  if (dedicated) return dedicated; // Hot tenant gets their own infrastructure

  const shardIndex = hash(tenantId) % NUM_SHARED_SHARDS;
  return sharedShards[shardIndex];
}
```

**Tradeoff:** Operational complexity -- you manage per-tenant infrastructure. But it completely isolates hot tenant load from everyone else. This is the standard pattern for enterprise SaaS at scale.

### Cache layer for hot reads

When a key is read-hot (many reads, few writes), cache it aggressively.

```typescript
async function getLeaderboard(): Promise<LeaderboardEntry[]> {
  const cached = await cache.get("global-leaderboard");
  if (cached) return JSON.parse(cached);

  // Use stampede protection (see Thundering Herd skill)
  const data = await fetchWithCoalescing("global-leaderboard", () =>
    db.query("SELECT * FROM leaderboard ORDER BY score DESC LIMIT 100")
  );

  await cache.set("global-leaderboard", JSON.stringify(data), { EX: 10 });
  return data;
}
```

**Tradeoff:** Adds staleness (up to TTL seconds old). Doesn't help with write-hot partitions. Combine with stampede protection to avoid thundering herd when the cache expires.

### Higher-cardinality Kafka partition keys

```typescript
// BAD: country code has ~200 values, US dominates
await producer.send({
  topic: "user-events",
  messages: [{ key: user.countryCode, value: JSON.stringify(event) }],
});

// GOOD: user_id has millions of values, distributes evenly
await producer.send({
  topic: "user-events",
  messages: [{ key: user.id, value: JSON.stringify(event) }],
});

// GOOD: for a known hot key, add a random suffix
const key = isHotUser(user.id)
  ? `${user.id}-${Math.floor(Math.random() * 8)}` // Spread across 8 partitions
  : user.id;
```

**Tradeoff:** Changing the partition key changes message ordering guarantees. Messages for the same user may land on different partitions with the random suffix, losing per-user ordering. Only use the suffix for keys where ordering doesn't matter.

### Per-partition monitoring

```typescript
function recordPartitionAccess(partitionKey: string, operation: "read" | "write") {
  metrics.increment("partition.operations", { partition: partitionKey, operation });
}

// Alert when:
// - One partition exceeds 3x the average operations
// - Partition utilization exceeds 80% of its throughput limit
// - Consumer lag on one Kafka partition grows while others are stable
```

This is not optional. Without per-partition metrics, you won't know a partition is hot until users report errors or the system pages you.

## The Read/Write Tradeoff

Every hot partition fix has a read/write tradeoff:

| Technique | Writes | Reads | Best for |
|-----------|--------|-------|----------|
| Random suffix sharding | Distributed perfectly | Scatter-gather (slower, costlier) | Write-heavy hot keys |
| Caching | Unchanged | Absorbed by cache | Read-heavy hot keys |
| Dedicated infrastructure | Isolated | Isolated | Known hot tenants |
| Composite keys | Spread across dimensions | Must know the dimension to query | Mixed workloads |

There is no technique that makes both reads and writes better. You're always trading one for the other.

## Anti-Patterns

```typescript
// Date partition for writes: today gets ALL writes
const pk = new Date().toISOString().split("T")[0]; // "2024-01-15"

// Low-cardinality Kafka key: US gets 50% of messages
messages: [{ key: user.countryCode, value: event }]

// Single global DynamoDB key: one partition handles all reads
KeyConditionExpression: "pk = :pk", { ":pk": "global-config" }

// Naive tenant sharding: enterprise tenant overloads one shard
const shard = hash(tenantId) % NUM_SHARDS;

// No per-partition monitoring: blind to imbalance
// You find out when users report errors, not from metrics
```

## Related Traps

- **Cardinality** -- low cardinality in partition keys directly causes hot partitions. If your key has 5 distinct values, you have at most 5 partitions, and the most popular value dominates.
- **Thundering Herd** -- a thundering herd on a partitioned system concentrates the stampede on one partition. Cache expiry for a hot key creates both problems simultaneously.
- **Sharding** -- hot partitions are the failure mode of bad shard key selection. The Sharding skill covers shard key choice; this skill covers what happens when the choice is wrong.
