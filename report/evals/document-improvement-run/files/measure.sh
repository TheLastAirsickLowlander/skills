#!/usr/bin/env bash
# Simulated production latency probe. Prints the current p95 in milliseconds.
# Baseline service cost is 800 ms; each enabled feature in config.json adds its cost.
set -euo pipefail
cd "$(dirname "$0")"
python3 - <<'EOF'
import json

with open("config.json") as fh:
    cfg = json.load(fh)

base = 800
extra = sum(v["latency_ms"] for v in cfg.values() if v.get("enabled"))
print(f"p95_latency_ms={base + extra}")
EOF
