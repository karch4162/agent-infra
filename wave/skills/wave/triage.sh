#!/usr/bin/env bash
# Labelling pre-grep (SKILL.md step 4). For each candidate issue (not yet agent-ready),
# resolve each file:line it cites against the base ref, hand the ticket plus the
# live excerpts to a cheap headless model, and print one table row per issue:
#   issue | refs ok/missing | HOLDS/STALE/UNCLEAR - why
# The human still applies the label. Issues citing no file:line are listed but not judged
# (that trait is the agent-ready predictor, so a ticket without it is not a candidate).
#
#   bash "$WAVE/triage.sh" SPO-378 SPO-236          # linear: selected candidates
#   bash "$WAVE/triage.sh" --all                    # linear: all Backlog candidates
#   bash "$WAVE/triage.sh" --json issues.json ...   # any tracker: issues saved as JSON
#   bash "$WAVE/triage.sh" 86bcw6zh5 / --all       # clickup: via autonomy/clickup_tracker.py
#   TRIAGER=agy bash "$WAVE/triage.sh" SPO-378      # grok (default) | agy | sonnet
# --json takes a Jira search result ({"issues":{"nodes":[...]}} or a list), one Jira
# issue, or Linear issue objects. Jira has no CLI here, so the host session fetches
# the candidates with the Atlassian MCP (markdown body format) and saves them.
set -uo pipefail; shopt -s nullglob   # nullglob: an empty candidate set prints an empty table, not a bogus row

TRIAGER="${TRIAGER:-grok}"
FALLBACK="${FALLBACK:-}"
PAR="${PAR:-2}"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
git fetch -q origin "$BASE_BRANCH"
BASE="$WAVE_BASE"
OUT="$(cygpath -m "$(mktemp -d)" 2>/dev/null || mktemp -d)"   # Windows python cannot open /tmp/...

judge() {  # $1 = triager, $2 = prompt; read-only, no tools needed - everything is inline
  case "$1" in
    agy)    timeout 300 agy --mode plan --dangerously-skip-permissions --print-timeout 4m -p "$2" ;;
    grok)   timeout 300 grok --permission-mode dontAsk -p "$2" ;;
    sonnet) timeout 300 claude -p "$2" --model sonnet ;;
  esac </dev/null 2>/dev/null
}

triage_one() {  # $1 = issue json file
  python - "$1" "$BASE" > "$1.prompt" <<'PY'
import sys, json, re, subprocess
i = json.load(open(sys.argv[1], encoding='utf-8')); base = sys.argv[2]
body = (i.get('description') or '')
refs = sorted(set(re.findall(r'[\w./\[\]()@-]+\.(?:tsx?|jsx?|mjs|sql|md|sh|py|json|ya?ml|dart|go|java):\d+', body)))
ok = miss = 0; excerpts = []
tree = subprocess.run(['git', 'ls-tree', '-r', '--name-only', base], capture_output=True, text=True, encoding='utf-8').stdout.splitlines()
for r in refs:
    path, line = r.rsplit(':', 1); line = int(line)
    if path not in tree:  # partial path (court-list.tsx, reservations/route.ts): unique suffix wins
        hits = [t for t in tree if t.endswith('/' + path)]
        if len(hits) == 1: path = hits[0]
    p = subprocess.run(['git', 'show', f'{base}:{path}'], capture_output=True, text=True, encoding='utf-8', errors='replace')
    if p.returncode != 0:
        miss += 1; excerpts.append(f'--- {r}: FILE MISSING at {base}'); continue
    lines = p.stdout.split('\n'); ok += 1
    lo, hi = max(1, line - 4), min(len(lines), line + 4)
    snippet = '\n'.join(f'{n}: {lines[n-1]}' for n in range(lo, hi + 1))
    excerpts.append(f'--- {r} (live at {base}):\n{snippet}')
print(f'REFS {ok} {miss}')
print(f'''Ticket {i["identifier"]}: {i["title"]}

{body[:3500]}

The ticket cites the file:line references below. Each is shown as it is RIGHT NOW on {base} (the ticket may be older than the code). Decide whether the ticket's premise still holds at these lines: the defect or gap it describes is still visible there. Do not use any tools; everything you need is here. Reply with exactly one line, no markdown:
VERDICT: HOLDS|STALE|UNCLEAR - <one sentence, cite the deciding file:line>

{chr(10).join(excerpts)}''')
PY
  read -r _ okc missc < <(head -1 "$1.prompt" | tr -d '\015')   # Windows python prints CRLF
  if [ "$((okc + missc))" -eq 0 ]; then echo "no file:line cited" > "$1.verdict"; return; fi
  P="$(tail -n +2 "$1.prompt" | tr -d '\015')"; V=""; USED=""
  for T in $TRIAGER $FALLBACK; do   # a throttled or silent triager falls through
    V="$(judge "$T" "$P" | tr -d '\015' | grep -m1 '^VERDICT:')"; USED="$T"
    [ -n "$V" ] && break
  done
  echo "${V:-VERDICT: (no answer from $TRIAGER $FALLBACK)}" | sed "s/^VERDICT: //; s/\$/ [$USED]/" > "$1.verdict"
  echo "$okc/$missc" > "$1.refs"
}

# Normalise any tracker's issue shape to {identifier, title, description} files.
split_issues() {  # stdin = JSON
  python -c "
import sys, json
d = json.load(sys.stdin)
if isinstance(d, dict): d = (d.get('issues') or {}).get('nodes') if isinstance(d.get('issues'), dict) else d.get('issues', [d])
for i in d:
    f = i.get('fields') or {}
    labels = [l.get('name', l) if isinstance(l, dict) else l for l in (i.get('labels') or f.get('labels') or [])]
    if 'agent-ready' in labels and sys.argv[2] == 'skip-ready': continue
    o = {'identifier': i.get('identifier') or i['key'], 'title': i.get('title') or f.get('summary', ''),
         'description': i.get('description') or f.get('description') or ''}
    if not isinstance(o['description'], str): o['description'] = json.dumps(o['description'])
    json.dump(o, open(sys.argv[1] + '/' + o['identifier'] + '.json', 'w', encoding='utf-8'))
" "$OUT" "$1"
}

if [ "$#" -eq 0 ]; then
  echo "Specify candidate issue IDs, --json FILE..., or --all for an intentional full-backlog pass." >&2
  exit 2
elif [ "$1" = "--json" ]; then
  shift; for f in "$@"; do split_issues keep < "$f"; done
elif [ "$WAVE_TRACKER" = "clickup" ]; then
  CU="$WAVE_HOME/autonomy/clickup_tracker.py"   # get/queue print {identifier,title,description,...}
  if [ "$1" = "--all" ]; then
    "$WAVE_PY" "$CU" queue --status "${WAVE_QUEUE_STATUS:-backlog}" | split_issues skip-ready
  else
    for id in "$@"; do "$WAVE_PY" "$CU" get "$id" | split_issues keep; done
  fi
elif [ "$WAVE_TRACKER" != "linear" ]; then
  echo "triage: $WAVE_TRACKER issues can't be fetched from the shell; save them with the MCP and pass --json FILE" >&2
  exit 2
elif [ "$1" != "--all" ]; then
  for id in "$@"; do orca linear issue "$id" --json | python -c "import sys,json; d=json.load(sys.stdin)['result']; print(json.dumps(d.get('issue',d)))" | split_issues keep; done
else
  orca linear list-issues --team "${WAVE_LINEAR_TEAM:?set WAVE_LINEAR_TEAM for triage --all}" --state Backlog --json |
    python -c "import sys,json; print(json.dumps(json.load(sys.stdin)['result']['issues']))" | split_issues skip-ready
fi

for f in "$OUT"/*.json; do
  while [ "$(jobs -rp | wc -l)" -ge "$PAR" ]; do sleep 1; done
  triage_one "$f" &
done; wait

printf '| Issue | Refs ok/missing | Verdict (%s) | Title |\n|---|---|---|---|\n' "$TRIAGER"
for f in "$OUT"/*.json; do
  id="$(basename "$f" .json)"; title="$(python -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8'))['title'][:70])" "$f")"
  printf '| %s | %s | %s | %s |\n' "$id" "$(cat "$f.refs" 2>/dev/null || echo -)" "$(cat "$f.verdict")" "$title"
done
rm -rf "$OUT"
