# Phase 1 — Explorer

**Input:** a codebase (any stack)
**Output:** `reqs/catalog/coverage.md` — an annotated file/directory checklist

The Explorer's job is intelligence-gathering, not extraction. You are mapping the territory so
Phase 2 knows exactly where to look. A good coverage.md makes Phase 2 fast and focused; a poor
one wastes extraction effort on generated code and saves nothing on the important business logic.

---

## Step 1 — Orient to the codebase

Before touching individual files, get the 10,000-foot view:

```bash
# root layout
ls -1 <repo-root>

# line counts by extension (reveals dominant language)
find . -type f | grep -v node_modules | grep -v .git | \
  sed 's/.*\.//' | sort | uniq -c | sort -rn | head -20

# config/manifest files (reveal stack + dependencies)
ls -1 *.json *.toml *.gemspec *.gradle Makefile Dockerfile* 2>/dev/null
```

From this, identify:
- **Languages/frameworks** (e.g., Rails, FastAPI, Spring, React, Next.js)
- **Data stores** (SQL, NoSQL, Redis, S3 — relevant for understanding where state lives)
- **External services** (queue systems, external APIs, auth providers)
- **Deployment model** (Docker, K8s, serverless — shapes what "infra" means)

Note this stack summary at the top of coverage.md. It frames every finding for anyone reading
the docs later.

---

## Step 2 — Map into layers

Almost every codebase, regardless of stack, has the same logical layers. Map the actual
directories onto these categories:

| Layer | What it encodes | Typical paths |
|---|---|---|
| **Data models** | Entities, relationships, validations, state machines, schema constraints | `app/models/`, `models/`, `entities/`, `domain/`, `db/schema.rb`, `*.prisma` |
| **Business logic** | Services, use cases, domain rules, calculators, orchestrators | `app/services/`, `services/`, `use_cases/`, `lib/`, `domain/` |
| **API / controllers** | Endpoints, auth guards, request/response contracts, rate limits | `app/controllers/`, `routes/`, `handlers/`, `resolvers/` |
| **UI / frontend** | Screens, components, user flows, role-based visibility, forms | `src/`, `app/`, `pages/`, `components/`, `views/` |
| **Config / infra** | External services, environment, compose, queue config | `config/`, `docker-compose*.yml`, `*.env.example`, `infra/` |
| **Tests** | Behavior specs (high-value), unit tests (usually skip) | `spec/`, `test/`, `__tests__/`, `tests/` |

---

## Step 3 — Assess file-by-file value

For each major directory, answer: **does this encode business rules, or is it plumbing?**

**High-value (review in Phase 2):**
- Domain model files with validations, callbacks, state machines, before/after hooks
- Service objects / use cases / business logic
- Auth, permissions, and policy files (Pundit policies, middleware, guards, ACLs)
- Route definitions (encode API surface and auth guards)
- Integration clients (adapters, webhooks, third-party API wrappers)
- Feature flag / plan / billing logic
- Scheduled job definitions (encode business-scheduled behavior)
- Config that encodes business constants (timeouts, limits, rate parameters)
- Test specs that document edge cases not obvious from implementation

**Skip / low-value:**
- Auto-generated files (migrations, compiled assets, `schema.rb` after the initial scan, Gemfile.lock, package-lock.json)
- Boilerplate (framework initializers that do nothing domain-specific)
- Pure utilities with no business semantics (string formatters, date helpers)
- Test doubles, factories, fixtures (unless they reveal domain shape)
- Views / templates for standard CRUD (unless they encode specific field visibility rules)

---

## Step 4 — Produce `reqs/catalog/coverage.md`

Use this structure:

```markdown
# Coverage Checklist

> Stack: <language>, <framework>, <primary data store>
> External dependencies: <list key integrations>

## Summary
| Layer | Total | ✅ Reviewed | ⏭️ Skipped | ❌ Not reviewed |
|---|---|---|---|---|
| Data models | N | 0 | 0 | N |
| Business logic | N | 0 | 0 | N |
| API / controllers | N | 0 | 0 | N |
| UI / frontend | N | 0 | 0 | N |
| Config / infra | N | 0 | 0 | N |
| Tests | N | 0 | 0 | N |

## Layer: Data models
### `<path/to/models/>`

| File | Status | What it encodes | Catalog target |
|---|---|---|---|
| `user.rb` | ❌ | User entity; auth, roles, MFA | catalog/backend.md |
| `schema.rb` | ⏭️ | Auto-generated | — |
```

Status legend:
- `✅ Reviewed` — extracted in Phase 2, findings in the catalog target doc
- `🔍 In Review` — currently being processed
- `⏭️ Skipped` — intentionally not reviewed (generated, boilerplate, low-value)
- `❌ Not Reviewed` — high-value, not yet reviewed

**"Catalog target"** is the doc under `catalog/` where findings from this file will land. Multiple
files can map to the same catalog doc. Decide the grouping now — it shapes Phase 2's output.

---

## Step 5 — Parallelization

For large codebases, spawn one Explore subagent per major directory concurrently. Each subagent
returns: directory name, stack notes, and a table of files with value assessment. Merge into one
coverage.md in the main conversation.

Example subagent prompt:
```
Read the files under `src/app/models/` in this repo.
For each file:
  - Note what domain entity or behavior it encodes
  - Assess: high-value for requirements extraction, or skip?
  - Suggest which catalog doc it should map to (e.g., "catalog/backend.md")
Return a markdown table: File | Value assessment | What it encodes | Catalog target
```

---

## Confirming with the user

Before moving to Phase 2, show the user:
1. The stack summary
2. The layer breakdown with file counts
3. Any surprising finds (e.g., business logic buried in a migration, or a config file full of plan limits)
4. Ask: "Does this look complete? Any directories I should add or skip?"

Phase 2 is only as good as Phase 1's coverage map.
