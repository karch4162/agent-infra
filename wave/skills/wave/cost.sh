#!/usr/bin/env bash
# Per-ticket token split: Claude worker session vs each Codex call (plan review,
# diff review, Astra tie-break), to see what each tier costs and how often Astra runs.
#   bash "$WAVE/cost.sh" INNOV-309 INNOV-301
# Worker numbers come from ~/.claude/projects/<worktree>/*.jsonl; review numbers from
# the "tokens used" lines Codex leaves in .wave-review.*.err / .wave-plan-review.*.err.
# Grok prints no token count, so it is not listed.
# Worktree paths come from Orca: it does not put them next to the main checkout (INNOV-406).
set -uo pipefail
WORKTREES="$(orca worktree list --json 2>/dev/null)"
RC=0
for ISSUE in "$@"; do
  WT="$(printf '%s' "$WORKTREES" | python -c "
import sys,json; s=sys.stdin.read(); ws=json.loads(s[s.index('{'):])['result']['worktrees']
print(next((w['path'] for w in ws if w.get('displayName')==sys.argv[1]), ''))" "$(tr 'A-Z' 'a-z' <<< "$ISSUE")" 2>/dev/null)"
  [ -n "$WT" ] || { echo "no worktree found for $ISSUE" >&2; RC=1; continue; }
  python - "$ISSUE" "$WT" <<'PY'
import json,sys,os,glob,re,collections
issue,wt=sys.argv[1:3]
proj=os.path.expanduser('~/.claude/projects/'+wt.replace(':','-').replace('/','-').replace(chr(92),'-'))
per=collections.defaultdict(collections.Counter)
for f in glob.glob(proj+'/*.jsonl'):
    for line in open(f,encoding='utf-8',errors='ignore'):
        try: m=json.loads(line).get('message') or {}
        except Exception: continue
        u=m.get('usage')
        if u and m.get('model'):
            for k,v in u.items():
                if isinstance(v,(int,float)): per[m['model']][k]+=v
print(issue)
for model,c in sorted(per.items(),key=lambda kv:-kv[1]['cache_read_input_tokens']):
    print(f"  worker {model:32} cache_read={c['cache_read_input_tokens']/1e6:.1f}M cache_write={c['cache_creation_input_tokens']/1e3:.0f}k out={c['output_tokens']/1e3:.0f}k")
for err in sorted(glob.glob(os.path.join(wt,'.wave-review.*.err'))+glob.glob(os.path.join(wt,'.wave-plan-review.*.err'))):
    txt=open(err,encoding='utf-8',errors='ignore').read()
    used=sum(int(n.replace(',','')) for n in re.findall(r'tokens used\s*\n\s*([\d,]+)',txt))
    if not used: continue
    stage=os.path.basename(err)[len('.wave-'):-len('.err')]   # review.codex-terra, plan-review.astra, ...
    print(f"  {stage:39}total={used/1e3:.0f}k")
PY
done
exit "$RC"
