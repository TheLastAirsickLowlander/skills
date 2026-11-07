# Iteration report template (ASD-STE100-inspired)

Reports are the audit trail of the loop. They are written for a reader who was not in
the session — a teammate, a manager, or the user three weeks from now. That reader must
be able to answer three questions in under a minute: what changed, what did it do, what
happens next.

## Style rules (STE-inspired, not strict STE)

The point of ASD-STE100 is that nobody misreads the report. Apply its spirit:

- **Short sentences.** Aim for 20 words or fewer. Split anything longer.
- **One idea per sentence.** Do not join a cause and an effect with "and". Use two
  sentences.
- **Plain words.** Use "use" not "utilize", "show" not "demonstrate", "start" not
  "initiate", "stop" not "terminate", "change" not "modification".
- **Active voice.** "The change removed 120 ms" — not "120 ms was removed".
- **No hedging about facts.** Data showed something or it did not. "The p95 fell by
  210 ms." Save judgment for the Analysis section, and mark it as judgment there.
- **Numbers carry units.** "210 ms", "4.2 %", "$38/day" — never bare numbers.
- **Imperatives for procedures.** "Run `measure.sh`. Record the median."

## Template

```markdown
# Report <NNN> — <change title>

- Date: <YYYY-MM-DD>
- Iteration: <N>
- Plan: ../plan.md

## Summary
<Two or three sentences: what changed, the delta on the primary metric, the decision.>

## Baseline
<Metric values before the change. When measured. How measured. One line per metric.>

## Change
<What changed. Files, config, or deploy steps. Exactly one hypothesis.>

## Result
| Metric | Before | After | Delta |
|---|---|---|---|
| <primary> | <value> | <value> | <±value unit, and %> |
| <guardrail> | <value> | <value> | <±value unit> |

## Analysis
<Why the delta looks like this. Keep/revert decision and the reason. Surprises.>

## Next step
<The next candidate change and its expected effect. Backlog changes made.>

## Stop-rule status
<Rule text. Consecutive sub-threshold count: N of allowed M. Loop continues / loop ends.>
```

## Example (filled)

```markdown
# Report 003 — Remove unused legacy analytics bundle

- Date: 2026-11-06
- Iteration: 3
- Plan: ../plan.md

## Summary
The deploy removed the legacy analytics bundle from the checkout page. The p95 load
time fell from 1.92 s to 1.61 s (−16 %). The change is kept.

## Baseline
p95 load time: 1.92 s. Measured at 14:05 UTC. Source: Grafana query
`checkout_p95` over the previous 60 minutes.
Error rate (guardrail): 0.4 %.

## Change
Removed the `legacy-analytics` script tag from `checkout.html`. No other file changed.
Hypothesis: the bundle blocked render for about 300 ms.

## Result
| Metric | Before | After | Delta |
|---|---|---|---|
| p95 load time | 1.92 s | 1.61 s | −0.31 s (−16 %) |
| Error rate | 0.4 % | 0.4 % | 0.0 |

## Analysis
The delta matches the hypothesis (expected ~300 ms, measured 310 ms). The bundle was
the largest remaining render-blocking resource. Decision: keep. The next-largest
blocking resource is now the font CSS at about 120 ms.

## Next step
Inline the critical font CSS (backlog #4). Expected effect: ~100 ms on p95. Added
backlog #7: preload the checkout hero image.

## Stop-rule status
Rule: stop after 2 consecutive iterations below 2 % improvement. Consecutive
sub-threshold count: 0 of 2. Loop continues.
```
