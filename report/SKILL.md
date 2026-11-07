---
name: report
description: 'Turn a completed analysis into a clear, self-contained HTML document written in ASD-STE100-inspired Simplified Technical English, with inline diagrams where they aid understanding. The skill auto-detects recent analysis artifacts (for example improvement-loop plans and reports), confirms the source with the user, then writes one portable .html file — short sentences, plain words, labeled figures, accurate numbers, no external dependencies. Use this skill whenever the user wants to document, explain, share, or present the results of an analysis, investigation, benchmark, experiment, or improvement run as a readable document or report. Trigger on: "STE100", "STE report", "simplified technical english", "turn this into a document", "write up the results", "explain this analysis", "generate a report", "document the findings", "make this shareable", "report on what we did".'
---

# STE Report

Turn finished analysis into a document a busy reader can trust in one pass. The
discipline comes from ASD-STE100 (Simplified Technical English): if a sentence can be
misread, rewrite it. The output is one self-contained HTML file — it must open
correctly from an email attachment with no network.

## Step 1 — Find the analysis

Auto-detect, then confirm. Search in this order:

1. `improvement/plan.md` and `improvement/reports/` — output of the improvement-loop
   skill. This is the richest source: goal, metrics, per-iteration changes, results.
2. Recently modified analysis-like documents: `*.md` files with results, findings,
   benchmark tables, or investigation notes.
3. Anything the user points you to.

Report what you found (files, dates, headline numbers) and **confirm with the user**
before writing: is this the right analysis, and who will read the document? The
audience decides how much background the document needs. If nothing is found, say so
and ask where the analysis lives. **Never invent source data** — a document about
made-up results is worse than no document.

## Step 2 — Extract the facts

Read everything in the confirmed source. List, before writing any HTML:

- The goal (and target number, if any)
- What was measured, and how
- Each change/step, in order, with its measured effect
- The final result versus the baseline
- The conclusion and the next steps

Every number in the document must come from this list. If a number is not in the
source, it does not go in the document.

## Step 3 — Write the document

Default output path: `<analysis-dir>/ste-report.html` (for improvement-loop sources,
`improvement/ste-report.html`). One file only.

**Hard requirements:**

- **Self-contained.** Inline CSS, inline SVG. No external scripts, styles, fonts,
  images, or CDN links. Test: it must render with the network cable pulled.
- **STE-inspired language.** Short sentences (aim ≤ 20 words). One idea per sentence.
  Plain words ("use", not "utilize"). Active voice. Numbers always carry units.
  Facts are stated plainly; judgment is marked as judgment. Full rules and a
  word-swap table: [`references/ste-guide.md`](references/ste-guide.md).
- **Honest structure.** Use this section order:

  1. **Title + summary** — what was done, the result, the next step. Three to five
     sentences.
  2. **Background** — the goal and why it matters.
  3. **What was measured** — the metrics and the measurement method.
  4. **What changed** — one short subsection per change, in order.
  5. **Results** — a table of the numbers, plus a trend figure when there are 3+
     data points.
  6. **What the results mean** — analysis. Mark interpretation as interpretation.
  7. **Next steps**
  8. **Glossary** — every technical term the document uses, in one line each.
  9. **Appendix** — the raw data table.

## Step 4 — Add diagrams for clarity

Add a diagram when it replaces a paragraph of explanation, not as decoration. One to
three figures is the right range for most reports. Guidance and copy-ready SVG
patterns (trend chart, flowchart, block diagram):
[`references/diagram-patterns.md`](references/diagram-patterns.md).

Rules:

- Metric over iterations/time → bar or line chart, axes labeled **with units**.
- A process of 3+ steps → flowchart.
- Components and their relations → block diagram.
- Every figure is an inline `<svg>` inside a `<figure>` with a `<figcaption>`, and
  the text refers to it ("See Figure 1."). Give the `<svg>` a `<title>` for screen
  readers.
- If `mmdc` (mermaid-cli) is available you may author in Mermaid and prerender to
  inline SVG. Never use a CDN script tag — that breaks self-containment.

## Step 5 — Verify, then deliver

Run the checker and fix what it flags:

```bash
python3 <skill-dir>/scripts/check_ste_report.py <report.html>
```

It fails on external references (broken self-containment) and warns on missing
figures, missing figcaptions, and sentences over 25 words. Then re-read the document
once against your fact list from step 2 — every number correct, every claim traced.

Tell the user the file path and give a three-sentence spoken summary: what the
document says, what the result was, what happens next.
