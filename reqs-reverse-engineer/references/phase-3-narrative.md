# Phase 3 — Narrative

**Input:** `reqs/catalog/` (populated from Phase 2)
**Output:** `reqs/narrative/` — persona-driven requirements spec

The narrative re-organizes the same facts from the catalog through a different lens: not "what does
this file do?" but "what does this system do, for whom, and why?" The result is the document you'd
hand to a new engineer, a product manager, or a team planning a rewrite — something readable from
top to bottom, with precise, traceable requirements underneath the prose.

---

## Step 1 — Identify personas from the catalog

A persona is a distinct actor with meaningfully different capabilities, constraints, or goals.
Read the catalog with these questions:

**Who uses the system?**
- Is there a role/permission hierarchy? (e.g., Admin > Manager > Editor > Read-Only)
- Are there multiple distinct user populations? (e.g., internal staff vs. external customers)
- Are there cross-account or federated users with special rules?

**What non-human actors operate on the system?**
- Integration/sync engines (adapters, webhooks, cron jobs)
- AI subsystems
- External platforms calling back in (webhook receivers)
- Offline or mobile clients

**How many personas is right?**
- Aim for 4–8. Too few loses meaningful distinctions; too many loses coherence.
- If two actors have identical capabilities and constraints, merge them.
- If one actor has a dramatically different access surface or set of rules, split it out.

**Name personas by role, not by tech** — "MSP Administrator", "External Customer", "API Consumer",
"Sync Engine" — not "admin_user" or "ApiKeyHolder".

---

## Step 2 — Identify capability domains and define REQ codes

Capability domains are the major *things the system does* — independent of who does them.
Read the catalog and group requirements by business area:

```
Credentials / vault
Documents & runbooks
Asset / configuration inventory
Network discovery
Integrations / adapters / sync
AI assist
Account lifecycle & billing
Access control / auth / permissions
Notifications
Offline mode
API platform behavior
Audit / compliance
```

Assign a short code to each domain (2–5 uppercase letters). These form the REQ-ID namespace.
Example: `CRD` for credentials, `DOC` for documents, `AUTH` for access control.

**Key design rule:** REQ IDs are capability-namespaced, not persona-namespaced. A requirement has
one stable definition regardless of how many personas exercise it. This prevents the same rule from
being stated multiple times in different chapters with subtle differences.

Example: if "passwords are encrypted at rest with AES-256" is `REQ-CRD-001`, then:
- The Technician chapter *defines* REQ-CRD-001 (it's in their home domain)
- The Admin chapter *cites* REQ-CRD-001 and notes any admin-specific delta
- The API Consumer chapter *cites* REQ-CRD-001 and notes API-specific access rules

---

## Step 3 — Build the file structure

Create the following files (in this order — each one informs the next):

```
reqs/narrative/
  README.md          # write in full (Step 4)
  01-personas.md     # write in full (Step 5)
  glossary.md        # write in full (Step 6)
  <NN>-<name>.md     # one per persona (Step 7)
  traceability.md    # build last (Step 8)
```

Number persona files with a two-digit prefix for ordered navigation:
- `10`, `11`, `12`, `13` — internal staff (ordered by descending privilege)
- `20`, `21` — external users / customers
- `30` — API / integration consumers
- `40` — system / automation actors

---

## Step 4 — Write `narrative/README.md`

This is the spec's cover page. Include:

1. **What the system is** — a 2–4 sentence description derived from the catalog. What it does,
   who it serves, the major capability clusters.
2. **The actor landscape** — a brief ASCII tree showing all personas and their grouping.
3. **How to read this spec** — the REQ-ID scheme, the trace convention (`→ ../catalog/<doc>`),
   confidence levels, and the dedup rule (REQ defined once, cited with deltas).
4. **Capability namespace table** — the domain codes you defined in Step 2.
5. **Status** — what's drafted vs. stubbed.
6. **Table of contents** — links to all persona chapters, traceability, glossary.

---

## Step 5 — Write `narrative/01-personas.md`

The persona map. For each persona:

1. **One paragraph** — who they are, what distinguishes them, what their goal is.
2. **Permission matrix** (if the codebase has a role hierarchy) — a markdown table:
   `| Capability | RoleA | RoleB | RoleC |` with ✅/— for each.
3. **Platform isolation rules** (if multiple user populations exist) — the hard boundaries
   between populations (e.g., one group cannot grant access to another).
4. **Per-persona restriction quick-reference** — a table of notable limitations per persona.

This file is read *before* the persona chapters — it's the reference for the deltas.

---

## Step 6 — Write `narrative/glossary.md`

Define every domain-specific term in the spec. Include:
- Business jargon native to this domain (the product's own vocabulary)
- Terms that mean something specific in this system (e.g., "organization", "flexible asset")
- Acronyms used in REQ statements

For each term, if it's governed by a requirement, note the REQ ID.

---

## Step 7 — Write per-persona chapters

Structure for each chapter:

```markdown
# <Persona Name>

> [One-line: who they are, highest-level distinction from other personas.]

[2–4 sentences of prose: what this persona accomplishes, what distinguishes their access
surface from adjacent personas, and why the rules for them matter.]

## <Capability domain>

[2–3 sentences: what this persona does in this domain and why the governing rules matter
from their vantage point. Focus on *consequence* — what goes wrong if these rules aren't right.]

- REQ-<DOMAIN>-NNN (CERTAIN) — The system shall … → ../catalog/<doc>.md
- REQ-<DOMAIN>-NNN (PROBABLE) — *Delta:* [different behavior for this persona vs the base rule] → ../catalog/<doc>.md

## <Next capability domain>
…
```

**Deciding where a REQ "lives":**
- The persona whose workflow *primarily* depends on this rule owns the REQ (it's defined there).
- Other personas *cite* it with a `*Delta:*` note if their behavior differs, or a plain cite if
  they just exercise the same rule.
- When two personas both claim a rule equally, default to the higher-privilege persona.

**Prose quality targets:**
- The domain section header should signal *why this domain matters to this persona*, not just label it.
- The introductory sentences should explain *consequence* — what breaks if these rules aren't right.
- The REQ statements should be testable: "The system shall X" means a QA engineer can write a test for it.

---

## Step 8 — Build `narrative/traceability.md`

A complete index of all requirements in the spec:

```markdown
# Traceability Matrix

> REQ → confidence → catalog doc → owning persona.
> Owner key: 10 Admin · 11 Manager · 12 Technician · ...

## <DOMAIN> — <Domain name>
| REQ | Conf. | Statement (abbrev.) | Catalog | Owner |
|---|---|---|---|---|
| <DOMAIN>-001 | CERTAIN | The system shall … (≤15 words) | [doc.md](../catalog/doc.md) | 10 |
```

Every REQ cited in any chapter must appear here. Every row here must be cited in at least one
chapter. Run this cross-check before declaring Phase 3 complete.

---

## Step 9 — Run the link checker

```bash
python reqs/scripts/link_checker.py reqs/
```

Fix every broken link before the work is done. Common issues:
- Narrative → catalog links with wrong relative depth
- Catalog → source links if source moved
- Anchor fragments that don't match headings exactly

The checker reports: `checked N links; broken=0 missing_anchors=0` when clean.

---

## Confirming with the user

After producing the skeleton (README + personas + outlines):

1. **Persona cut** — does the persona count feel right? Too many/few?
2. **Domain grouping** — do the REQ-ID domains match the system's actual architecture?
3. **Coverage** — are there capability areas in the catalog that didn't land in any chapter?

Then flesh each chapter to full prose before final review.
