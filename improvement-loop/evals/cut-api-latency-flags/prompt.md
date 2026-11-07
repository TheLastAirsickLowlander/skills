---
tags: [skill-creator]
max_turns: 60
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

the API at work is too slow and I want to chip away at it properly this time. this repo is a simulation of the production service — run ./measure.sh to get the current p95 latency in ms (that's our "prod" reading, the config toggles in config.json model real features we could disable or restructure). I want to get p95 under 1000 ms.

set up an improvement loop for this and start iterating: one change at a time, measure after each change, keep going until you hit the goal or the improvements flatline. pick whatever stop rule seems sensible and write it down in the plan. I'm in meetings all afternoon so just get on with it and leave me a trail I can review.

Input files: config.json, measure.sh
