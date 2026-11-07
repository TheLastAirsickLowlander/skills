---
name: staff-engineering-skills-idempotency
description: Ensure operations are safe to retry and execute multiple times. Use when writing API endpoints that mutate state, webhook handlers, queue consumers, payment processing, retry logic, or any code that creates records, sends emails, charges cards, or increments counters. Activates on patterns like POST handlers without deduplication, retry wrappers around non-idempotent calls, webhook processors, or queue message handlers.
---

# Idempotency Trap

The request was sent twice. The customer was charged twice. Before writing any operation that mutates state, ask: **what happens if this runs again with the same input?**

## The Three Sources of Duplicates

Every system faces these as normal operation, not edge cases. You cannot prevent them -- only make operations safe when they happen.

1. **User retries** -- double-click, refresh, back-button-and-resubmit. Client sends the same request twice intentionally.
2. **Network retries** -- the operation succeeded but the response was lost (timeout, TCP reset, LB cut). Client retries, not knowing the first attempt worked.
3. **Infrastructure redelivery** -- webhook providers retry on timeout, message queues deliver "at least once," cron jobs overlap. Infrastructure sends the same work twice.

## Naturally Idempotent vs Not

| Naturally idempotent (safe to repeat) | NOT idempotent (dangerous to repeat) |
|---------------------------------------|--------------------------------------|
| `SET x = 5` | `SET x = x + 1` |
| `UPDATE status = 'paid' WHERE id = ?` | `INSERT INTO orders (...)` |
| `DELETE WHERE id = ?` | `balance += amount` |
| `PUT /users/123 {full body}` | `POST /orders {new order}` |
| Upsert (INSERT ... ON CONFLICT UPDATE) | `sendEmail(user, template)` |
| | `stripe.charges.create(...)` |

**Design for natural idempotency first.** If you can express the operation as "set to this state" rather than "apply this change," it's inherently safe.

## Detection: Non-Idempotent Code

**Stop and add idempotency protection if you see:**

1. **A POST handler that creates a record without an idempotency key** -- double-submit creates duplicates.
2. **Retry logic wrapping a non-idempotent call** -- retrying `stripe.charges.create()` without an idempotency key double-charges; retrying `POST /orders` creates duplicates.
3. **A webhook handler that doesn't record processed event IDs** -- Stripe, GitHub, Twilio all document that they may resend the same event.
4. **A queue consumer that uses `INCREMENT` or `INSERT` without deduplication** -- SQS, RabbitMQ, Kafka (at-least-once) can all deliver the same message twice.
5. **`sendEmail()`, `sendSMS()`, or any notification call without a dedup check** -- the user gets two of everything.
6. **Multi-step operations where early steps have side effects** -- if step 3 fails and the client retries, steps 1 and 2 run again. Are they safe to repeat?

## Patterns

### Idempotency key (for API endpoints)

The client generates a unique key (UUID) and sends it with the request; the server detects retries by the key.

```typescript
app.post("/api/orders", async (req, res) => {
  const idempotencyKey = req.headers["idempotency-key"];
  if (!idempotencyKey) {
    return res.status(400).json({ error: "Idempotency-Key header required" });
  }

  // Return stored response if already processed
  const existing = await db.idempotencyRecord.findUnique({ where: { key: idempotencyKey } });
  if (existing?.status === "complete") {
    return res.status(existing.statusCode).json(existing.responseBody);
  }

  // Claim key + create business data in ONE transaction (unique constraint loses the race for one of two retries)
  const order = await db.$transaction(async (tx) => {
    await tx.idempotencyRecord.create({ data: { key: idempotencyKey, status: "processing" } });
    return tx.order.create({
      data: { userId: req.user.id, items: req.body.items, total: req.body.total },
    });
  });

  // External side effects get THEIR OWN key derived from the original
  await stripe.paymentIntents.create(
    { customer: req.user.id, amount: order.total, currency: "usd" },
    { idempotencyKey: `charge-${idempotencyKey}` }
  );

  // Store response so duplicates get the SAME response as the original
  await db.idempotencyRecord.update({
    where: { key: idempotencyKey },
    data: { status: "complete", statusCode: 201, responseBody: order },
  });

  res.status(201).json(order);
});
```

The three load-bearing details: the idempotency record is created in the **same transaction** as the business data; external APIs get **their own** keys derived from the original; the stored response is replayed on duplicates.

### Webhook deduplication (for incoming webhooks)

Webhook providers include a unique event ID. Record it and skip duplicates. The unique constraint on `eventId` also catches races between two simultaneous deliveries. Non-transactional side effects (emails) go **after** the dedup gate.

```typescript
app.post("/webhooks/stripe", async (req, res) => {
  const event = req.body;

  try {
    await db.$transaction(async (tx) => {
      await tx.processedWebhookEvent.create({ data: { eventId: event.id, processedAt: new Date() } });
      if (event.type === "payment_intent.succeeded") {
        await tx.order.update({
          where: { paymentIntentId: event.data.object.id },
          data: { status: "paid" },
        });
      }
    });
  } catch (error) {
    if (isPrismaUniqueConstraintError(error)) {
      return res.json({ received: true }); // Already processed, skip
    }
    throw error;
  }

  if (event.type === "payment_intent.succeeded") {
    await sendConfirmationEmail(event.data.object.metadata.userId);
  }
  res.json({ received: true });
});
```

### Queue consumer deduplication

The producer includes a unique transaction/message ID; the consumer records it in the same transaction as the work. On a real error, **don't ack** -- let the queue redeliver.

```typescript
worker.on("message", async (msg) => {
  const { transactionId, userId, amount } = JSON.parse(msg.body);

  try {
    await db.$transaction(async (tx) => {
      // Unique constraint on transactionId prevents duplicates
      await tx.processedTransaction.create({ data: { id: transactionId, processedAt: new Date() } });
      await tx.account.update({ where: { userId }, data: { balance: { increment: amount } } });
    });
  } catch (error) {
    if (isPrismaUniqueConstraintError(error)) {
      await msg.ack(); // Already processed -- ack and move on
      return;
    }
    throw error; // Real error -- don't ack, let queue redeliver
  }

  await msg.ack();
});
```

### Natural idempotency via upsert

When possible, design the operation so repeating it converges on the same state -- upsert, or SET rather than INCREMENT.

```typescript
// Same result whether it runs once or five times
async function setUserPreference(userId: string, key: string, value: string) {
  await db.userPreference.upsert({
    where: { userId_key: { userId, key } },
    create: { userId, key, value },
    update: { value },
  });
}
```

### Making external API calls idempotent

Most payment/communication APIs support idempotency keys -- always pass them.

```typescript
await stripe.paymentIntents.create(
  { customer: customerId, amount, currency: "usd" },
  { idempotencyKey: `order-${orderId}-charge` }
);
// Twilio: unique message SID or your own dedup. SendGrid: custom unique args. AWS SES: MessageDeduplicationId (FIFO).
```

If the API has no idempotency-key support, track the call yourself:

```typescript
async function sendWelcomeEmail(userId: string) {
  const sent = await db.sentEmail.findUnique({
    where: { userId_template: { userId, template: "welcome" } },
  });
  if (sent) return; // Already sent

  await emailService.send({ to: userId, template: "welcome" });
  await db.sentEmail.create({ data: { userId, template: "welcome", sentAt: new Date() } });
}
```

## Anti-Patterns

```typescript
// Dangerous: retry wrapping a non-idempotent call
await retry(() => stripe.paymentIntents.create({ amount, customer }), { retries: 3 });
// First call succeeds, response lost, retry creates a SECOND charge. Fix: pass idempotencyKey to Stripe.

// Dangerous: POST handler with no dedup -- double-click = two orders, two charges
app.post("/api/orders", async (req, res) => {
  const order = await db.order.create({ data: req.body });
  await chargeCustomer(order.total);
  res.status(201).json(order);
});
// Fix: require and check Idempotency-Key header.

// Dangerous: queue consumer with INCREMENT -- SQS delivers twice = balance incremented twice
worker.on("message", async (msg) => {
  const { userId, amount } = JSON.parse(msg.body);
  await db.account.update({ where: { userId }, data: { balance: { increment: amount } } });
  await msg.ack();
});
// Fix: dedup on transactionId in a single transaction.
```

## Related Traps

- **Race Conditions** -- idempotency checks are themselves vulnerable to races. Two retries arriving simultaneously can both pass the "already processed?" check. The dedup record must be created atomically with the business operation (same transaction, unique constraint).
- **Consistency Models** -- if your dedup check reads from a replica but the dedup record was written to the primary, replica lag can cause the check to miss the duplicate. Dedup checks must read from the primary.
- **Retry Storms** -- retrying non-idempotent operations doesn't just create duplicates -- it amplifies load. Idempotency + retry storms = data corruption at scale.
