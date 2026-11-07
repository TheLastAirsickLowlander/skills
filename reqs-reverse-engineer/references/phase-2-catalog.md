# Phase 2 — Catalog

**Input:** `reqs/catalog/coverage.md` + the codebase
**Output:** `reqs/catalog/*.md` — per-domain requirement docs + updated `coverage.md`

The catalog's job is extraction and classification. For every high-value file in coverage.md,
pull out the behaviors that are genuinely requirements — business rules, constraints, access
controls, state machines, integration contracts — and distinguish them from implementation choices.
The output is the source of truth that Phase 3 will re-organize into a readable spec.

---

## What IS a requirement vs what ISN'T

This distinction is the hardest judgment call in the whole workflow, and the most important.

**IS a requirement** (record it):
- A business rule enforced in code: "max 20 active shared links per password"
- A deterministic algorithm with business consequence: "coupons applied in order: %-off first, then flat discount, then compound"
- An access rule: "MyGlue users cannot see IT Glue passwords"
- A state machine: "API key can be active / paused / inactive; only paused keys can reactivate"
- An integration contract: "on PSA persistence failure return HTTP 202, not 500"
- A limit/threshold with a business meaning: "90-minute timeout on PDF conversion"
- A behavioral surprise: anything that would cause a bug if a new dev didn't know it

**ISN'T a requirement** (skip or note as tech decision):
- Storage medium: "uses PostgreSQL" / "data stored in Redis"
- Data structure: "stored as a JSON hash" / "uses an array for ordering"
- Framework choice: "uses Sidekiq for background jobs" / "uses Pundit for authorization"
- Boilerplate patterns: standard Rails callback, typical REST shape

When in doubt: **would a product manager or QA engineer care about this rule?** If yes, it's a
requirement. If only a backend engineer building the storage layer cares, it's a tech decision.

**Special case — tech decisions that encode a business rule.** Sometimes the implementation
reveals a constraint that matters: "uses PBKDF2 with 600,000 iterations" looks like a tech
choice but encodes a security posture. "Stores `closed_at` as 15 days before the effective date"
is a storage trick that encodes a grace-period business rule. Extract these; just be precise about
what the rule actually is.

---

## Confidence levels

Tag every finding with one of:

| Tag | Meaning | When to use |
|---|---|---|
| `CERTAIN` | Explicit in code — a constant, a validator, an enforced rule | You read the code and it's unambiguous |
| `PROBABLE` | Strong inference — the pattern clearly encodes a business rule | The intent is clear but the code is indirect (e.g., a comment-free service method that always behaves a certain way) |
| `SPECULATIVE` | Indirect evidence — might be a business rule, might be incidental | You're inferring from naming, tests, or context |

When uncertain, prefer PROBABLE or SPECULATIVE over asserting CERTAIN. The confidence tag is what
makes the catalog honest and useful for a rewrite.

---

## Capturing "odd" rules

The highest-value findings are the surprising ones — the rules that would cause a production bug
if a developer didn't know them. Prioritize:

- Side effects on save/update/delete (e.g., "updating account name cascades to primary org")
- Hardcoded limits with no obvious source (e.g., "max 5 attachments, 5 MB each")
- Asymmetric behavior (e.g., "synced children promoted, non-synced destroyed — different outcome based on a flag")
- State machines with non-obvious transitions
- Date/time offsets that are intentional (e.g., "stored 15 days before effective date")
- Forbidden actions (e.g., "Account#destroy raises an exception by design")
- Order-dependent logic (e.g., "coupons must apply in A → B → C sequence")

Describe each odd rule precisely: what it does, and why it matters (the business consequence of
getting it wrong).

---

## Catalog doc structure

Group findings by **domain** (not by file — multiple files feed one doc). A domain is a
coherent business area: credentials, documents, account lifecycle, integrations, access control, etc.

Name and organize docs to match the logical areas, not the file tree:

```
catalog/
  index.md        TOC + "how to read this catalog"
  backend.md      Core models, entities, auth, billing (if a monolith backend)
  api.md          API surface: routes, auth methods, rate limits, contracts
  ui.md           Frontend: screens, flows, role-based visibility
  infra.md        Infrastructure: services, pipelines, conversion, queues
  <domain>.md     Add more as the codebase warrants
```

For each finding in a catalog doc:

```markdown
## <Section title>

<One or two sentences describing the behavior or rule.> `CERTAIN`

- Specific detail. `PROBABLE`
- Another rule: **<highlight the exact constraint>**. `CERTAIN`
  → [`src/path/to/file.ext`](../../src/path/to/file.ext)

### Odd rules
- **Rule name** — precise description of what it does and why the business consequence matters.
  `CERTAIN` → [`src/path/to/file.ext#L42`](../../src/path/to/file.ext)
```

**Source link format:** the relative path from the catalog doc to the source file. If `catalog/`
is at `reqs/catalog/` and source is at `src/`, the prefix is `../../src/`.
Calculate this from the actual repo layout — don't assume a fixed depth.

---

## Parallelization strategy

Group coverage.md entries by catalog target doc. For each target doc, spawn one Explore subagent
with a prompt like:

```
Read these files from coverage.md that map to catalog/backend.md:
  - src/app/models/account.rb
  - src/app/models/user.rb
  - src/app/services/billing_service.rb
  [...]

For each file:
1. Extract behaviors that are business requirements (not tech decisions).
2. Tag each with CERTAIN / PROBABLE / SPECULATIVE.
3. Link each finding to the source file (relative from reqs/catalog/).
4. Highlight any "odd" or surprising rules explicitly.
5. Note what tech decisions you explicitly excluded and why.

Return findings organized by business domain (not by file),
using the catalog doc format from the skill.
```

Merge subagent outputs into the catalog docs. Synthesize — don't just concatenate. If two
subagents found the same rule from different files, state it once and link both sources.

---

## Updating coverage.md

As each file is processed, update its status in coverage.md:
- `✅ Reviewed` — findings extracted to the named catalog doc
- `⏭️ Skipped` — intentionally skipped with a brief note

Keep the summary table current. This is the artifact the user sees to judge completeness.

---

## Confirming with the user

Before proceeding to Phase 3, ask:

1. Are there any domains missing from the catalog? (Did the coverage.md miss anything important?)
2. Are there specific areas where the findings seem thin or surprising?
3. Is the catalog doc structure reasonable for the codebase shape?

Phase 3 is re-organizing the catalog — if the catalog is wrong, the narrative will be wrong.
