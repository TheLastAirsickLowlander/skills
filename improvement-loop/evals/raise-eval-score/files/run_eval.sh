#!/usr/bin/env bash
# Simulated eval harness. Scores prompt.txt against a fixed rubric and prints the score.
# Stands in for a real LLM-judged eval set.
set -euo pipefail
cd "$(dirname "$0")"
python3 - <<'EOF'
import re

with open("prompt.txt") as fh:
    text = fh.read()

score = 58

# 1. Declared output format (+12)
if re.search(r"output format|json", text, re.IGNORECASE):
    score += 12

# 2. Explicit label taxonomy: at least 4 of the 6 known labels (+15)
labels = ["billing", "technical", "account", "shipping", "refund", "other"]
if sum(1 for w in labels if re.search(w, text, re.IGNORECASE)) >= 4:
    score += 15

# 3. Few-shot examples: the word "example" at least twice (+14)
if len(re.findall(r"example", text, re.IGNORECASE)) >= 2:
    score += 14

# 4. Edge-case guidance: unclear/ambiguous input handling (+9)
if re.search(r"unclear|ambiguous|uncertain|confidence", text, re.IGNORECASE):
    score += 9

print(f"eval_score={min(score, 100)}")
EOF
