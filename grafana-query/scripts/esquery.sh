#!/bin/bash
# esquery.sh "<lucene>" <termsField> [fromISO] [toISO] — Elasticsearch terms agg via grafana.datto.net /api/ds/query.
# Example: esquery.sh 'pod:(use1-pod-9) AND apiMethod:*' apiMethod 2026-09-14T10:00:00Z 2026-09-14T14:00:00Z
# Requires a live grafana-connector session (grafana skill: login).
set -euo pipefail
QUERY="$1"; FIELD="$2"; FROM="${3:-$(date -u -v-6H +%Y-%m-%dT%H:%M:%SZ)}"; TO="${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
DSUID="${DSUID:-2abKPc8nz}"
SESSION="$HOME/.config/grafana-connector/session.json"
COOKIE=$(python3 -c "import json; d=json.load(open('$SESSION')); print(d['cookieName']+'='+d['cookieValue'])")
BODY=$(python3 - "$QUERY" "$FIELD" "$FROM" "$TO" "$DSUID" <<'EOF'
import json,sys,datetime
q, field, f, t, ds = sys.argv[1:6]
ms = lambda s: str(int(datetime.datetime.fromisoformat(s.replace('Z','+00:00')).timestamp()*1000))
print(json.dumps({"queries":[{"refId":"A","datasource":{"type":"elasticsearch","uid":ds},
  "query":q,"metrics":[{"type":"count","id":"1"}],
  "bucketAggs":[{"type":"terms","field":field,"id":"2","settings":{"size":"30","order":"desc","orderBy":"_count"}}],
  "timeField":"@timestamp"}],"from":ms(f),"to":ms(t)}))
EOF
)
RESP=$(curl -s -b "$COOKIE" -H "Content-Type: application/json" -X POST https://grafana.datto.net/api/ds/query -d "$BODY")
echo "$RESP" | python3 -c "
import json,sys
r = json.load(sys.stdin)
if 'results' not in r:
    print('AUTH/API ERROR:', json.dumps(r)[:200])
    print('-> re-login: cd ~/.agents/skills/grafana && bun scripts/cli.ts login --url https://grafana.datto.net')
    sys.exit(1)
frames = r['results'].get('A', {}).get('frames', [])
if not frames: print('  NO DATA'); sys.exit(0)
rows = []
for f in frames:
    vals = f['data']['values']
    if len(vals) >= 2: rows.extend(zip(vals[1], vals[0]))
for v, k in sorted(rows, reverse=True): print(f'  {v:>14,.0f}  {k}')
"
