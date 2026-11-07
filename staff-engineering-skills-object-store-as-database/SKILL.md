---
name: staff-engineering-skills-object-store-as-database
description: Use object storage (S3, GCS, Azure Blob) correctly as a database layer. Use when writing code that stores state in object storage, builds transaction logs on S3, implements coordination primitives on object stores, or designs data systems with S3 as primary storage. Activates on patterns like writing metadata or state to S3, concurrent writers to the same S3 key, append-only logs in object storage, or any system using S3 as more than a simple blob store.
---

# Object Store as Database

S3 is no longer just a blob store. With strong read-after-write consistency (2020) and conditional writes (2024), S3 is a **linearizable key-value store** for single-key operations. The trap is not "don't use S3 as a database" -- it's using S3 as a database **without using conditional writes for correctness**.

## What Changed

| Year | Change | Impact |
|------|--------|--------|
| 2020 | Strong read-after-write consistency | Read after write returns latest; LIST reflects current state. |
| Aug 2024 | `If-None-Match: *` (put-if-absent) | Atomic create-if-not-exists. Enables append-only logs, idempotent writes. |
| Nov 2024 | `If-Match: <etag>` (compare-and-swap) | True CAS on objects. Enables optimistic concurrency, leader election, metadata catalogs. |

Together these give **linearizable single-key operations**: read an object (get its ETag), compute a new value, write it back with `If-Match`. This is the building block under Delta Lake, Iceberg, SlateDB, WarpStream, Chroma, and dozens of others.

## The Fundamental Pattern

Almost every system using S3 as a database follows the same architecture:

1. **Write immutable data files** to S3 (Parquet, JSON, binary blobs).
2. **Maintain a mutable metadata pointer** using conditional writes for atomic commits.
3. **Readers follow the pointer** to find the current set of data files.

This is how Delta Lake's transaction log, Iceberg's catalog, SlateDB's manifest, and Chroma's wal3 all work.

## The Conditional Write Primitives

### Put-If-Absent: `If-None-Match: *`

Write succeeds only if no object with this key exists; returns `412 Precondition Failed` if it does. Use for: transaction log entries, idempotent event writes, one-time initialization, append-only streams.

```typescript
// Claim the next sequence number atomically
try {
  await s3.putObject({
    Bucket: "my-log",
    Key: `_log/${String(nextSeqNum).padStart(10, "0")}.json`,
    Body: JSON.stringify(commitEntry),
    IfNoneMatch: "*", // Fails if another writer already claimed this key
  });
} catch (err) {
  if (err.$metadata?.httpStatusCode === 412) {
    // Another writer got there first. Re-read state and retry.
    throw new ConflictError("Sequence number already claimed");
  }
  throw err;
}
```

### Compare-and-Swap: `If-Match: <etag>`

Write succeeds only if the object's current ETag matches; returns `412` if another writer changed it. Use for: metadata pointers, shared configuration, counters, leader election, any mutable state.

```typescript
// Read-modify-write with optimistic concurrency
async function updateState<T>(
  bucket: string,
  key: string,
  modify: (current: T) => T,
  maxRetries = 5
): Promise<T> {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    const response = await s3.getObject({ Bucket: bucket, Key: key });
    const etag = response.ETag;
    const current = JSON.parse(await response.Body.transformToString()) as T;
    const next = modify(current);
    try {
      await s3.putObject({
        Bucket: bucket,
        Key: key,
        Body: JSON.stringify(next),
        IfMatch: etag, // Fails if someone wrote between our read and write
      });
      return next;
    } catch (err) {
      if (err.$metadata?.httpStatusCode === 412) continue; // Conflict -- retry with fresh read
      throw err;
    }
  }
  throw new Error(`CAS failed after ${maxRetries} retries`);
}
```

## Detection: When You're Using S3 as a Database

**Stop and assess if you see:**

1. **GET → modify → PUT without `If-Match`** -- a race condition. Two concurrent writers silently clobber each other. Always use conditional writes for mutable state.
2. **Sequential log entries without `If-None-Match`** -- two writers can claim the same sequence number. Use put-if-absent to atomically claim entries.
3. **S3 LIST as a query mechanism** -- LIST returns 1,000 objects per page and is not a query. To find objects by field values, store metadata in a database or use a table format (Iceberg, Delta Lake) with a catalog.
4. **Mutable state without a retry loop** -- conditional writes are optimistic and can fail with `412`. You must read, modify, write, and retry on conflict.
5. **Missing the 412 handler** -- a PutObject that doesn't handle `412 Precondition Failed` makes the conditional write useless; the whole point is detecting conflicts.

## Patterns in the Wild

### Transaction log (Delta Lake pattern)

```
_delta_log/0000000001.json   ← each commit claims the next seq number with If-None-Match: *
data/part-00001.parquet      ← immutable data files referenced by commits
```

Readers find the latest commit number, read that commit's JSON to learn which data files are current.

### Metadata pointer (Iceberg pattern)

```
metadata/v3-uuid.metadata.json   ← immutable metadata snapshots
metadata/current.json            ← mutable pointer, updated with If-Match
data/data-00001.parquet          ← immutable data files
```

Writers create a new immutable metadata file, then CAS `current.json` from the old metadata to the new. On conflict, re-read the pointer, check for data conflicts, and retry.

### Leader election / append-only event store

Both are put-if-absent: claim an epoch-numbered lock or a version-numbered event key with `If-None-Match: *`; a `412` means someone else claimed it.

```typescript
// Append an immutable, version-numbered event; 412 = version already exists
async function appendEvent(streamId: string, expectedVersion: number, event: Event) {
  const key = `streams/${streamId}/${String(expectedVersion + 1).padStart(10, "0")}.json`;
  try {
    await s3.putObject({
      Bucket: "event-store",
      Key: key,
      Body: JSON.stringify({ ...event, version: expectedVersion + 1, timestamp: new Date() }),
      IfNoneMatch: "*",
    });
  } catch (err) {
    if (err.$metadata?.httpStatusCode === 412) {
      throw new ConcurrencyError(`Version ${expectedVersion + 1} already exists`);
    }
    throw err;
  }
}
```

## Performance and Cost Reality

| | S3 Standard | S3 Express One Zone | PostgreSQL (RDS) |
|---|---|---|---|
| CAS latency | 50-70ms | 14-26ms | <1ms |
| CAS throughput (per key) | ~15 op/s | ~75 op/s | thousands op/s |
| Storage | $0.023/GB/mo | $0.16/GB/mo | ~$0.10/GB/mo (EBS) |
| Durability | 11 nines, multi-AZ | Single AZ | Manual replication |
| Operational overhead | Zero | Zero | Backups, patching, failover |
| Capacity limit | Unlimited | Unlimited | Requires resharding |

**S3-as-database fits when:** 20-200ms write latency is acceptable, data is large (TB+), reads are sequential scans (not point lookups), durability matters more than latency, or you want zero ops overhead.

**Use a traditional database when:** you need sub-ms latency, high-frequency point reads/writes on one key, complex indexed queries, or CAS throughput above ~75 op/s per key.

## Anti-Patterns

```typescript
// Dangerous: read-modify-write WITHOUT IfMatch -- concurrent writers clobber each other
const data = await s3.getObject({ Bucket: "state", Key: "config.json" });
const config = JSON.parse(await data.Body.transformToString());
config.setting = "new-value";
await s3.putObject({ Bucket: "state", Key: "config.json", Body: JSON.stringify(config) });

// Dangerous: log append WITHOUT IfNoneMatch -- two writers claim the same sequence number
await s3.putObject({ Bucket: "log", Key: `_log/0000000005.json`, Body: JSON.stringify(entry) });

// Dangerous: conditional write WITHOUT retry -- throwing on 412 is not handling it; re-read and retry
try {
  await s3.putObject({ Bucket: "state", Key: "config.json", Body: newConfig, IfMatch: etag });
} catch (err) {
  if (err.$metadata?.httpStatusCode === 412) throw err; // wrong: must re-read and retry
}
```

## Related Traps

- **Race Conditions** -- S3 without conditional writes is a race condition factory. With `If-Match` and `If-None-Match`, S3 provides the same optimistic concurrency as database version columns.
- **Idempotency** -- `If-None-Match: *` is a natural idempotency primitive. Writing an event with a deterministic key and put-if-absent guarantees exactly-once creation.
- **Consistency Models** -- S3 is strongly consistent for reads-after-writes, but LIST can lag. To "read your writes" immediately after a PUT, use GET (strongly consistent), not LIST.
- **Cardinality** -- S3 LIST is still O(n) on the prefix. For high-cardinality key spaces, maintain a metadata index rather than listing objects.
