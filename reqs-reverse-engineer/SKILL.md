---
name: reqs-reverse-engineer
description: 'Three-phase workflow for reverse-engineering requirements from any codebase into a structured two-part documentation system: an artifact-level reference catalog and a persona-driven narrative spec with numbered, confidence-tagged, source-traced requirements. Use this skill whenever the user wants to understand what an existing system does from its code, extract business rules from source, create requirements documentation from a codebase rather than from stakeholders, produce a product spec by reading the code, figure out what a repo does, document the behavior of a system they inherited, or reverse-engineer a workflow. Trigger on: "reverse engineer requirements", "extract reqs from code", "document what this does", "what does this codebase do", "requirements from code", "spec from the code", "understand this repo", "what are the business rules in", "document the behavior of". Also trigger when the user asks to move from one phase to the next (Explorer → Catalog → Narrative) or mentions coverage.md or the catalog.'
---

# Requirements Reverse-Engineering Workflow

A systematic three-phase process for turning source code into living requirements documentation.
Each phase has a clear input, a clear output, and a natural handoff to the next.

## Output structure

```
reqs/
  README.md            entry point: Part I → narrative/, Part II → catalog/
  catalog/
    coverage.md        living file checklist (created in Phase 1, updated in Phase 2)
    index.md           catalog table of contents
    <domain>.md        per-artifact requirement docs
  narrative/
    README.md          overview, REQ-ID scheme, how to read the spec
    01-personas.md     persona catalog + permission matrix + platform map
    <NN>-<persona>.md  per-persona chapters (prose + numbered REQs)
    traceability.md    REQ → confidence → catalog doc → owning persona
    glossary.md
```

## The three phases

| Phase | Reads | Produces | Start here when… |
|---|---|---|---|
| **1 — Explorer** | codebase | `catalog/coverage.md` | no `reqs/` exists yet |
| **2 — Catalog** | coverage.md + code | `catalog/*.md` | coverage.md exists |
| **3 — Narrative** | catalog/ | `narrative/` | catalog/ is populated |

After Phase 3, run the **link checker** to verify every relative link resolves.

**Entering mid-stream:** detect which phase to enter by checking what exists. If `reqs/` is absent → Phase 1. If `coverage.md` exists but `catalog/` is thin → Phase 2. If `catalog/` is populated → Phase 3.

---

## Phase 1 — Explorer

> Full instructions: [`references/phase-1-explorer.md`](references/phase-1-explorer.md)

**Goal:** map the territory before extraction begins. Produce `catalog/coverage.md` — a
comprehensive, annotated checklist of every file/directory worth reverse-engineering.

**Key steps:**
1. Inspect the root layout; identify the stack (languages, frameworks, patterns).
2. Map the codebase into layers: data models, business logic/services, API/controllers, UI/frontend, config/infra. Note tests — scan for behavior-encoding specs, but skip routine unit tests.
3. For each layer, assess which files/directories are high-value (encode business rules, domain logic, access control, integrations, state machines).
4. Write `reqs/catalog/coverage.md`.
5. Confirm the checklist with the user before proceeding to Phase 2.

**Parallelize:** spawn one Explore subagent per major directory. Merge results into coverage.md.

---

## Phase 2 — Catalog

> Full instructions: [`references/phase-2-catalog.md`](references/phase-2-catalog.md)

**Goal:** extract requirements from every high-value file in coverage.md. Produce per-domain
docs under `catalog/`.

**Key steps:**
1. Group coverage.md entries by domain (e.g., models, API, UI, integrations, infra).
2. For each domain, spawn an Explore subagent to read the files and extract findings.
3. Write findings as catalog docs — one or a few per domain, not one per file.
4. Update coverage.md status (✅ / ⏭️) as files are processed.
5. Confirm catalog completeness with user before proceeding to Phase 3.

**Parallelize:** one subagent per domain, running concurrently.

---

## Phase 3 — Narrative

> Full instructions: [`references/phase-3-narrative.md`](references/phase-3-narrative.md)

**Goal:** re-organize catalog findings by **persona**, producing a readable spec with numbered,
traced requirements.

**Key steps:**
1. Identify personas (actors) from the catalog.
2. Identify capability domains and define REQ-ID codes.
3. Write `narrative/README.md`, `narrative/01-personas.md`, and `narrative/glossary.md` in full.
4. Write per-persona chapters as annotated outlines (prose stubs + REQ lines).
5. Confirm shape with user; flesh out to full prose.
6. Build `narrative/traceability.md`.
7. Run link checker.

---

## Link checker

After Phase 3, verify all relative links resolve:

```bash
python reqs/scripts/link_checker.py reqs/
```

The script (bundled at [`scripts/link_checker.py`](scripts/link_checker.py)) checks:
- Catalog source links → files under `src/` (or wherever source lives)
- Narrative → catalog cross-links
- In-document anchor fragments

Output: `checked N links; broken=0 missing_anchors=0` means the doc tree is consistent.
Fix any broken links before considering the work complete.
