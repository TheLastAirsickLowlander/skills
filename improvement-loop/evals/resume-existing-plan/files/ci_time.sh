#!/usr/bin/env bash
# Simulated CI pipeline timer. Prints the current pipeline wall time in minutes.
# Baseline pipeline is 25 min; caching, parallel tests and shallow clone each save time.
set -euo pipefail
cd "$(dirname "$0")"
python3 - <<'EOF'
import re

with open(".ci/pipeline.yaml") as fh:
    cfg = fh.read()

def enabled(flag):
    m = re.search(rf"^{flag}:\s*(\w+)", cfg, re.MULTILINE)
    return bool(m and m.group(1).strip().lower() == "true")

minutes = 25
if enabled("cache_deps"):
    minutes -= 9
if enabled("parallel_tests"):
    minutes -= 7
if enabled("shallow_clone"):
    minutes -= 2

print(f"ci_minutes={minutes}")
EOF
