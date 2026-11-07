# Cache investigation notes — 2026-11-02

## Question
Why did p95 on /search jump after the 1.14 deploy?

## Findings
- Cache hit rate dropped from 92 % (Oct 28) to 71 % (Oct 30). This is the combined
  Cloudflare + Redis rate.
- The 1.14 deploy changed the cache key to include the full Accept-Language header.
  Key cardinality exploded: 4,100 distinct keys/hour before, 61,000 keys/hour after.
- Redis memory is fine (41 % used). But evictions went up 9×: from 120/min to
  1,100/min.
- p95 on /search went from 340 ms (Oct 28) to 890 ms (Oct 30).
- Rollback of the key change on Oct 31 restored the hit rate to 90 % and p95 to
  355 ms.

## Conclusion
The Accept-Language key change caused the regression. The rollback fixed it. The new
key scheme buckets language to 6 values and is safe to re-try.

## Next steps
- Add a hit-rate alert when the rate goes below 85 %.
- Document the key scheme in the runbook.
