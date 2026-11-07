---
name: staff-engineering-skills-denormalization
description: Detect and prevent denormalization traps when designing data models. Use when writing code that copies fields between tables, embeds related data in documents, caches composed objects, or adds redundant columns to avoid joins. Activates on patterns like storing derived/copied data, syncing fields across tables, or embedding nested objects in document stores.
---

# Denormalization Trap

Every copy of data is a consistency obligation. Before duplicating a field to avoid a join, ask: **who updates this copy, what happens when the update fails, and how do you detect drift?**

## Snapshot vs Reference

The first question when copying data: is this a **snapshot** or a **reference**?

- **Snapshot:** The value at a point in time. Correct to copy. Example: the price on an order line item at time of purchase. The product price may change later, but the order price should not.
- **Reference:** The current value of something. Dangerous to copy. Example: a user's plan name stored on their profile. When the plan changes, every copy is wrong until updated.

If you're copying a reference, you've taken on a consistency obligation. If you can't answer all four questions in the checklist below, don't denormalize.

## Consistency Obligation Checklist

For **every** denormalized field, document:

- [ ] **Source of truth** -- which table/record is canonical?
- [ ] **Update trigger** -- what code updates the copies when the source changes?
- [ ] **Failure mode** -- what happens if the update fails halfway? How stale can it get?
- [ ] **Repair mechanism** -- how do you detect and fix drift? Is there a reconciliation job?

If you can't fill this out, use a join instead.

## Detection: When You're About to Denormalize

**Stop and assess if you're about to write any of these:**

1. **Copying a field from one table into another at write time** -- `order.customerName = customer.name`. What happens when the customer changes their name?

2. **Embedding related objects in a document** -- `{ user: { org: { plan: { name: "Pro" } } } }`. Each nesting level is a copy that needs an update path.

3. **Adding a column to avoid a join** -- storing `planName` on the user table so you don't have to join through organization. Who updates it when the org changes plans?

4. **Building a cache blob from multiple tables** -- `buildFullProfile(userId)` that joins user + org + plan + settings into one cached object. What invalidates every field in that blob?

5. **A background job that "syncs" data between tables** -- if this exists, you already have the trap. Is it idempotent? Does it handle partial failures?

6. **`ON UPDATE CASCADE` or database triggers** -- these hide write amplification inside the database where application code can't see it.

## The Default: Join at Read Time

```typescript
// Prefer this. Single source of truth, always consistent.
async function getUserProfile(userId: string) {
  return db.user.findUnique({
    where: { id: userId },
    include: {
      organization: {
        include: { plan: true },
      },
    },
  });
}
```

Joins are not inherently slow. A join on indexed foreign keys is fast. Measure before assuming you need to denormalize.

## When Denormalization Is Justified

Denormalize only when ALL of these are true:

1. The join is a measured performance bottleneck (not a hypothetical one)
2. The source data changes infrequently relative to reads
3. You have an update path for every copy
4. You have a repair mechanism for drift
5. The acceptable staleness window is defined and documented

## Patterns (When You Must Denormalize)

### Materialized view (database-managed)

```typescript
// The database owns the denormalization logic. Refresh is atomic.
await db.$executeRaw`
  CREATE MATERIALIZED VIEW user_profiles AS
  SELECT u.id, u.name, o.name as org_name, p.name as plan_name
  FROM users u
  JOIN organizations o ON u.org_id = o.id
  JOIN plans p ON o.plan_id = p.id
`;
// Refresh on schedule or after writes
await db.$executeRaw`REFRESH MATERIALIZED VIEW CONCURRENTLY user_profiles`;
```

Stale between refreshes. But the logic is declarative, refresh is atomic, and you can't "forget" to update a copy.

### Event-driven sync with repair job

```typescript
// Update copies when the source changes
async function handleOrgPlanChanged(event: OrgPlanChangedEvent) {
  const plan = await db.plan.findUnique({ where: { id: event.newPlanId } });
  // Batch update to avoid cardinality trap
  let cursor: string | undefined;
  do {
    const users = await db.user.findMany({
      where: { orgId: event.orgId }, take: 100,
      cursor: cursor ? { id: cursor } : undefined,
      orderBy: { id: "asc" },
    });
    for (const user of users) {
      await db.user.update({
        where: { id: user.id },
        data: { cachedPlanName: plan.name },
      });
    }
    cursor = users.length === 100 ? users[users.length - 1].id : undefined;
  } while (cursor);
}

// REPAIR: nightly job that detects and fixes drift
async function repairDenormalizedPlanNames() {
  const drifted = await db.$queryRaw`
    SELECT u.id, u.cached_plan_name, p.name as actual
    FROM users u
    JOIN organizations o ON u.org_id = o.id
    JOIN plans p ON o.plan_id = p.id
    WHERE u.cached_plan_name != p.name
  `;
  for (const row of drifted) {
    await db.user.update({
      where: { id: row.id },
      data: { cachedPlanName: row.actual },
    });
    logger.warn("Repaired drifted plan name", { userId: row.id });
  }
}
```

More infrastructure. But failures are recoverable, drift is detectable, and the system self-heals.

## Anti-Patterns

```typescript
// Dangerous: copies org and plan data into every user record.
// Who updates orgName and planName when they change?
return db.user.create({
  data: {
    name: data.name, email: data.email, orgId: data.orgId,
    orgName: org.name,        // copy -- consistency obligation
    planName: plan.name,      // copy -- consistency obligation
    planFeatures: plan.features, // copy -- consistency obligation
  },
});

// Dangerous: updates N tables with no failure handling.
// What if updateMany times out? What if it partially succeeds?
async function updateOrgName(orgId: string, newName: string) {
  await db.organization.update({ where: { id: orgId }, data: { name: newName } });
  await db.user.updateMany({ where: { orgId }, data: { orgName: newName } });
  await db.invoice.updateMany({ where: { orgId }, data: { orgName: newName } });
  await db.auditLog.updateMany({ where: { orgId }, data: { orgName: newName } });
}
```

## Related Traps

- **Cardinality** -- denormalization cost scales with the cardinality of the target collection. Denormalizing into an L4/L5 set means write amplification proportional to its size.
- **Cache Invalidation** -- caching a denormalized blob is double denormalization. The cache is a copy of a copy.
- **Consistency Models** -- denormalized data is eventually consistent by nature. If your feature needs strong consistency, denormalization is the wrong tool.
- **Idempotency** -- sync jobs that update denormalized copies must be idempotent, or partial failures leave data in an inconsistent state.
