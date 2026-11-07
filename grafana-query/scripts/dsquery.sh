#!/bin/bash
# dsquery.sh "<promql>" [fromISO] [toISO] — instant Prometheus query via grafana.datto.net /api/ds/query.
# Instant evaluates at <toISO>; put the window inside the expr (e.g. increase(...[7h])) and pass the same bounds.
# Defaults: last 6h. Requires a live grafana-connector session (grafana skill: login).
set -euo pipefail
EXPR="$1"; FROM="${2:-$(date -u -v-6H +%Y-%m-%dT%H:%M:%SZ)}"; TO="${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
DSUID="${DSUID:-mJmr4Z27z}"
SESSION="$HOME/.config/grafana-connector/session.json"
COOKIE=$(python3 -c "import json; d=json.load(open('$SESSION')); print(d['cookieName']+'='+d['cookieValue'])")
BODY=$(python3 - "$EXPR" "$FROM" "$TO" "$DSUID" <<'EOF'
import json,sys,datetime
expr, f, t, ds = sys.argv[1:5]
ms = lambda s: str(int(datetime.datetime.fromisoformat(s.replace('Z','+00:00')).timestamp()*1000))
print(json.dumps({"queries":[{"refId":"A","datasource":{"type":"prometheus","uid":ds},"expr":expr,"instant":True,"maxDataPoints":1}],"from":ms(f),"to":ms(t)}))
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
    fields = f['schema']['fields']
    labels = fields[1].get('labels', {}) if len(fields) > 1 else {}
    vals = f['data']['values']
    if len(vals) > 1 and vals[1]: rows.append((vals[1][-1], labels))
if not rows: print('  EMPTY FRAMES'); sys.exit(0)
for v, l in sorted(rows, key=lambda r: r[0], reverse=True): print(f'  {v:>20,.2f}  {l}')
"
