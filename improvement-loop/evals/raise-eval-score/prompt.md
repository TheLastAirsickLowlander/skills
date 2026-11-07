---
tags: [skill-creator]
max_turns: 60
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

my support-triage prompt scores 58% on our eval and I want it above 90. the eval harness is ./run_eval.sh — it reads prompt.txt and prints the score (it stands in for the real LLM judge).

iterate on the prompt one change at a time, measure the score after each change, and stop when you hit the target or when it's clearly plateaued — you decide the threshold, just write it in the plan up front. leave a report for each iteration so my team can see what worked and what didn't.

Input files: prompt.txt, run_eval.sh
