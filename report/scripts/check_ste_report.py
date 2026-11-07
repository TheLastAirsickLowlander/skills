#!/usr/bin/env python3
"""Check an STE report HTML file for self-containment and basic STE compliance.

Hard failures (exit 1):
  - external references: src=/href= pointing at http(s):// or protocol-relative //
  - <script> tags (scripts are unnecessary for a static report and often mean a CDN)
  - CSS @import or url(...) fetching remote resources

Warnings (exit stays 0):
  - no <svg> figure
  - <svg> without <title> (accessibility)
  - <figure> without <figcaption>
  - sentences over 25 words in the visible text

Usage: python3 check_ste_report.py path/to/report.html
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

EXTERNAL_ATTR = re.compile(r"""(?:src|href)\s*=\s*["'](?:https?:)?//""", re.IGNORECASE)
SCRIPT_TAG = re.compile(r"<script\b", re.IGNORECASE)
CSS_REMOTE = re.compile(r"@import|url\(\s*['\"]?(?:https?:)?//", re.IGNORECASE)
STYLE_BLOCK = re.compile(r"<style\b.*?</style>", re.IGNORECASE | re.DOTALL)
SVG_BLOCK = re.compile(r"<svg\b.*?</svg>", re.IGNORECASE | re.DOTALL)
ANY_TAG = re.compile(r"<[^>]+>")
SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")
WORD = re.compile(r"[A-Za-z0-9µ%']+")


def visible_text(html: str) -> str:
    text = STYLE_BLOCK.sub(" ", html)
    text = SVG_BLOCK.sub(" ", text)
    # Block-level tag boundaries end a sentence even without punctuation.
    text = re.sub(r"</(?:h[1-6]|p|li|div|figcaption|caption|td|th|tr|section)>", ". ", text, flags=re.IGNORECASE)
    text = ANY_TAG.sub(" ", text)
    text = text.replace("&nbsp;", " ")
    return re.sub(r"\s+", " ", text)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"FAIL: file not found: {path}")
        return 2
    html = path.read_text(encoding="utf-8")

    failures: list[str] = []
    warnings: list[str] = []

    for match in EXTERNAL_ATTR.finditer(html):
        start = max(0, match.start() - 40)
        failures.append(f"external reference: ...{html[start:match.end() + 40]!r}...")
    if SCRIPT_TAG.search(html):
        failures.append("<script> tag present — a self-contained report must not load scripts")
    for match in CSS_REMOTE.finditer(html):
        start = max(0, match.start() - 40)
        failures.append(f"remote CSS reference: ...{html[start:match.end() + 40]!r}...")

    svgs = SVG_BLOCK.findall(html)
    if not svgs:
        warnings.append("no <svg> figure found — most reports need at least one diagram")
    for i, svg in enumerate(svgs, 1):
        if "<title>" not in svg:
            warnings.append(f"svg #{i} has no <title> (screen-reader label)")
    figures = re.findall(r"<figure\b.*?</figure>", html, re.IGNORECASE | re.DOTALL)
    for i, fig in enumerate(figures, 1):
        if "<figcaption>" not in fig.lower():
            warnings.append(f"figure #{i} has no <figcaption>")

    long_sentences = []
    for sentence in SENTENCE_SPLIT.split(visible_text(html)):
        words = WORD.findall(sentence)
        if len(words) > 25:
            long_sentences.append((len(words), " ".join(words[:12]) + " …"))
    for count, preview in long_sentences:
        warnings.append(f"sentence over 25 words ({count} words): {preview}")

    for failure in failures:
        print(f"FAIL: {failure}")
    for warning in warnings:
        print(f"warn: {warning}")
    print(
        f"\n{path.name}: {len(failures)} failure(s), {len(warnings)} warning(s), "
        f"{len(svgs)} svg figure(s)"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
