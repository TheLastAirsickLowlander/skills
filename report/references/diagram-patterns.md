# Diagram patterns for self-contained HTML

Inline SVG only. No external files, no script tags. Copy a pattern and adjust the
numbers. Keep charts honest: start value axes at 0 unless a note says why not.

## 1. Trend bar chart (metric per iteration)

Use for: the primary metric across iterations, or before/after.

```html
<figure>
  <svg viewBox="0 0 640 300" role="img" aria-labelledby="fig1-title" width="640">
    <title id="fig1-title">Bar chart of p95 latency per iteration</title>
    <!-- axes -->
    <line x1="60" y1="250" x2="600" y2="250" stroke="#333" />
    <line x1="60" y1="250" x2="60" y2="20" stroke="#333" />
    <!-- y-axis label, rotated, WITH UNIT -->
    <text x="20" y="135" transform="rotate(-90 20 135)" text-anchor="middle"
          font-size="13">p95 latency (ms)</text>
    <!-- one bar per data point: x = 90 + i*110, height scaled to value -->
    <rect x="90"  y="50"  width="60" height="200" fill="#4c78a8" />
    <text x="120" y="42"  text-anchor="middle" font-size="13">1515</text>
    <text x="120" y="268" text-anchor="middle" font-size="12">baseline</text>
    <rect x="200" y="90"  width="60" height="160" fill="#4c78a8" />
    <text x="230" y="82"  text-anchor="middle" font-size="13">1215</text>
    <text x="230" y="268" text-anchor="middle" font-size="12">iter 1</text>
    <!-- target line, dashed, with label -->
    <line x1="60" y1="118" x2="600" y2="118" stroke="#c0392b" stroke-dasharray="6 4" />
    <text x="595" y="112" text-anchor="end" font-size="12" fill="#c0392b">goal: 1000 ms</text>
  </svg>
  <figcaption>Figure 1. The p95 latency per iteration. The dashed line shows the goal.</figcaption>
</figure>
```

Rules: label both axes, put units in the axis label, write the value on top of each
bar, draw the target as a dashed line when there is one.

## 2. Flowchart (process, 3+ steps)

Use for: the loop, the pipeline, the request path.

```html
<figure>
  <svg viewBox="0 0 640 140" role="img" aria-labelledby="fig2-title" width="640">
    <title id="fig2-title">Flowchart of one iteration</title>
    <g font-size="13" text-anchor="middle">
      <rect x="20"  y="50" width="130" height="40" rx="6" fill="#eef" stroke="#446" />
      <text x="85"  y="74">Measure baseline</text>
      <rect x="180" y="50" width="130" height="40" rx="6" fill="#eef" stroke="#446" />
      <text x="245" y="74">Make one change</text>
      <rect x="340" y="50" width="130" height="40" rx="6" fill="#eef" stroke="#446" />
      <text x="405" y="74">Measure again</text>
      <rect x="500" y="50" width="120" height="40" rx="6" fill="#efe" stroke="#464" />
      <text x="560" y="74">Keep or revert</text>
      <!-- arrows -->
      <line x1="150" y1="70" x2="176" y2="70" stroke="#333" marker-end="url(#arr)" />
      <line x1="310" y1="70" x2="336" y2="70" stroke="#333" marker-end="url(#arr)" />
      <line x1="470" y1="70" x2="496" y2="70" stroke="#333" marker-end="url(#arr)" />
      <defs><marker id="arr" markerWidth="8" markerHeight="8" refX="7" refY="4"
        orient="auto"><path d="M0,0 L8,4 L0,8 z" fill="#333" /></marker></defs>
    </g>
  </svg>
  <figcaption>Figure 2. One iteration of the improvement loop.</figcaption>
</figure>
```

Rules: 3–6 boxes. One verb phrase per box. Arrows left to right.

## 3. Block diagram (components and relations)

Use for: system parts, before/after architecture. Boxes with a name and one line of
detail, connected with labeled lines ("reads from", "writes to"). Same SVG mechanics
as the flowchart.

## General rules

- Every `<svg>` gets a `<title>` (screen readers) and sits in a `<figure>` with a
  `<figcaption>`. The text refers to the figure by number: "See Figure 1."
- One to three figures per report. Each must replace a paragraph, not decorate one.
- Flat colors, one accent color, no gradients. The report must read well printed in
  black and white.
- Widths around 640 px, `viewBox` set, so the figure scales with the page.
