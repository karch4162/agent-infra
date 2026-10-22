#!/usr/bin/env bash
# Supervised wave (SPO-640): spawn the workers into one Orca Run, block on their
# worker_done, merge what the gate proves, then run the walk once nothing is live.
#
#   bash "$WAVE/coordinator.sh" SPO-640 quick:SPO-641 risk:SPO-642   # tier:ISSUE, default normal
#   bash "$WAVE/coordinator.sh" --resume run_5de25620f335            # continue after a crash
#
# Runs for the whole wave (hours): start it from its own terminal. State lives in
# <main checkout>/.wave-run.<run>.json (git-excluded) plus the Orca Run, PR labels and
# worktrees, so --resume re-reads those and never re-spawns an issue that has a
# worktree (spawn.sh's claim guard). The merge decision is gate.py, pure and tested;
# this file only moves data between orca, gh and the state file.
#
# Human-gated by rule, never merged here: TIER risk, MIGRATION: yes, a fallback
# reviewer, a tie-break, a worker question. Those PRs get the wave-held label.
# The walk (step 3.5) runs only when worker-list shows nothing live: the walker owns
# the shared database, and that ordering is the whole safety argument.
# Bash 3.2-safe: every map lives in the state JSON, handled by python.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
REPO_ID="$(orca_repo_id)"
[ -n "$REPO_ID" ] || { echo "$MAIN_CHECKOUT is not registered with Orca" >&2; exit 1; }
wave_exclude '.wave-run.*'

if [ "${1:-}" = "--resume" ]; then
  RUN="$2"; shift 2
else
  [ $# -gt 0 ] || { echo "usage: coordinator.sh [tier:]ISSUE... | --resume <run_id>" >&2; exit 1; }
  RUN="$(orca orchestration run-create --objective "wave $(date +%F) $*" --json |
    python -c "import sys,json;r=json.load(sys.stdin)['result'];print(r.get('run',r).get('id') or r['runId'])")"
fi
STATE="$MAIN_CHECKOUT/.wave-run.$RUN.json"
[ -f "$STATE" ] || echo "{\"run\":\"$RUN\",\"issues\":{}}" > "$STATE"
echo "RUN $RUN  state $STATE"

# held PRs are findable later even after the Run is gone
(cd "$MAIN_CHECKOUT" && gh label create wave-held --color B60205 --description "wave coordinator held this PR for a human" --force >/dev/null 2>&1) || true

# --- spawn ------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in *:*) TIER="${arg%%:*}"; ISSUE="${arg#*:}" ;; *) TIER=normal; ISSUE="$arg" ;; esac
  if python -c "import sys,json;sys.exit(0 if sys.argv[1] in json.load(open(sys.argv[2]))['issues'] else 1)" "$ISSUE" "$STATE"; then
    echo "skip $ISSUE: already in this run"; continue
  fi
  line="$(TIER="$TIER" WAVE_RUN="$RUN" bash "$WAVE_HOME/spawn.sh" "$ISSUE")" || { echo "spawn failed: $ISSUE" >&2; continue; }
  echo "spawned $line (tier $TIER)"
  python - "$STATE" "$ISSUE" "$TIER" $line <<'PY'
import json,sys
state,issue,tier,_,task,dispatch=sys.argv[1:7]
d=json.load(open(state))
d['issues'][issue]={'tier':tier,'task':task,'dispatch':dispatch,'slug':issue.lower(),'status':'running','pr':None,'reason':'','rebased':False}
json.dump(d,open(state,'w'),indent=1)
PY
done

# --- wait / gate / merge loop -----------------------------------------------
export RUN STATE WAVE_HOME MAIN_CHECKOUT BASE_BRANCH WAVE_BASE
python - <<'PY'
import json, os, re, subprocess, sys, time
RUN, STATE, WAVE, MAIN = (os.environ[k] for k in ('RUN','STATE','WAVE_HOME','MAIN_CHECKOUT'))
BASE = os.environ['BASE_BRANCH']

def sh(*args, check=False, cwd=None):
    r = subprocess.run(args, capture_output=True, text=True, cwd=cwd)
    if check and r.returncode: raise RuntimeError(f"{args[:3]} -> {r.stderr.strip()[:300]}")
    return r.stdout
def oj(*args):  # orca --json -> result
    out = sh('orca', *args, '--json')
    out = out[out.index('{'):] if '{' in out else '{}'   # crashpad noise precedes the JSON on Windows
    return json.loads(out).get('result', {})
def gh(*args): return sh('gh', *args, cwd=MAIN)
def load(): return json.load(open(STATE))
def save(d): json.dump(d, open(STATE, 'w'), indent=1)
def log(*a): print(time.strftime('%H:%M:%S'), *a, flush=True)

def by_dispatch(d, dispatch, task):
    for k, v in d['issues'].items():
        if v['dispatch'] == dispatch or v['task'] == task: return k
def pr_number(v):
    if v['pr']: return v['pr']
    for w in oj('worktree', 'list').get('worktrees', []):
        if w.get('displayName') == v['slug'] and (w.get('linkedPR') or {}).get('number'):
            return w['linkedPR']['number']
def gate(pr):
    view = json.loads(gh('pr', 'view', str(pr), '--json', 'body,mergeable'))
    checks = json.loads(gh('pr', 'checks', str(pr), '--required', '--json', 'name,bucket') or '[]')
    inp = json.dumps({'body': view.get('body', ''), 'checks': checks, 'mergeable': view.get('mergeable')})
    return subprocess.run([sys.executable, os.path.join(WAVE, 'gate.py')], input=inp, capture_output=True, text=True).stdout.strip()

def consume(d):
    r = oj('orchestration', 'check', '--run', RUN, '--wait', '--types', 'worker_done,escalation,question', '--timeout-ms', '120000')
    for m in r.get('messages', []):
        p = json.loads(m.get('payload') or '{}')
        k = by_dispatch(d, p.get('dispatchId'), p.get('taskId'))
        if not k: log('message for unknown dispatch', m.get('type'), p); continue
        v = d['issues'][k]
        if m['type'] == 'worker_done':
            n = re.search(r'PR #(\d+)', m.get('body') or '')
            v['pr'] = int(n.group(1)) if n else v['pr']
            v['status'] = 'done' if p.get('outcome') == 'succeeded' else 'held'
            if v['status'] == 'held': v['reason'] = 'worker failed: ' + (m.get('body') or '')[:160]
        else:  # question or escalation: the coordinator never guesses for a worker
            v['status'] = 'held'; v['reason'] = f"{m['type']} needs human: " + (m.get('body') or '')[:160]
        log(k, '->', v['status'], v['reason'])
    if r.get('deliveryId'):
        oj('orchestration', 'check', '--run', RUN, '--ack', r['deliveryId'], '--timeout-ms', '1')

def settle(d):
    for k, v in d['issues'].items():
        if v['status'] != 'done': continue
        pr = pr_number(v)
        if not pr:
            v['status'], v['reason'] = 'held', 'worker_done without a PR number'; continue
        v['pr'] = pr
        verdict = gate(pr)
        log(k, f'PR #{pr}', verdict)
        if verdict == 'MERGE':
            if subprocess.run(['gh', 'pr', 'merge', str(pr), '--merge'], cwd=MAIN, capture_output=True).returncode == 0:
                v['status'] = 'merged'; oj('orchestration', 'worker-release', '--dispatch', v['dispatch'])
            else:
                v['status'], v['reason'] = 'held', 'gh pr merge failed'
        elif verdict == 'CONFLICT' and not v['rebased']:
            # one rebase on the same proven terminal; a second conflict is held
            handle = oj('orchestration', 'worker-show', '--dispatch', v['dispatch']).get('terminal', {}).get('handle') \
                or oj('orchestration', 'worker-show', '--dispatch', v['dispatch']).get('agentTerminalHandle')
            if not handle:
                v['status'], v['reason'] = 'held', 'CONFLICT and no terminal handle to redispatch'; continue
            spec = (f"PR #{pr} conflicts with {BASE} after a sibling merged. Rebase this worktree on origin/{BASE}, "
                    "resolve conflicts, rerun /preflight, push with --force-with-lease, then send worker_done "
                    f"--outcome succeeded with PR #{pr} in the summary. Change nothing else.")
            r = oj('orchestration', 'worker-start', '--run', RUN, '--terminal', handle, '--worktree', f"name:{v['slug']}", '--spec', spec)
            if r.get('dispatchId'):
                v.update(status='running', rebased=True, task=r.get('taskId', v['task']), dispatch=r['dispatchId'])
            else:
                v['status'], v['reason'] = 'held', 'CONFLICT; rebase redispatch failed'
        elif verdict.startswith('PENDING'):
            pass
        else:
            v['status'], v['reason'] = 'held', verdict.replace('CONFLICT', 'CONFLICT after one rebase')
        if v['status'] == 'held':
            gh('pr', 'edit', str(pr), '--add-label', 'wave-held')
            oj('orchestration', 'worker-retain', '--dispatch', v['dispatch'])

d = load()
while any(v['status'] in ('running', 'done') for v in d['issues'].values()):
    if any(v['status'] == 'running' for v in d['issues'].values()): consume(d)
    settle(d); save(d)
    if all(v['status'] == 'done' for v in d['issues'].values() if v['status'] in ('running','done')): time.sleep(60)  # CI pending
save(d)
log('workers settled:', {k: v['status'] for k, v in d['issues'].items()})
PY

# --- walk, sweep, report (only when nothing is live) -------------------------
LIVE="$(orca orchestration worker-list --run "$RUN" --terminal-state active --json 2>/dev/null | python -c "import sys,json;print(len(json.load(sys.stdin).get('result',{}).get('workers',[])))" 2>/dev/null || echo "?")"
[ "$LIVE" = "0" ] || { echo "not walking: worker-list still shows $LIVE active worker(s); resolve, then --resume $RUN" >&2; exit 2; }

MERGED="$(python -c "import sys,json;print(' '.join(k for k,v in json.load(open(sys.argv[1]))['issues'].items() if v['status']=='merged'))" "$STATE")"
MERGED_PRS="$(python -c "import sys,json;print(' '.join(str(v['pr']) for v in json.load(open(sys.argv[1]))['issues'].values() if v['status']=='merged'))" "$STATE")"

if [ -n "$MERGED" ]; then
  ( cd "$MAIN_CHECKOUT" && git fetch --prune origin && git switch "$BASE_BRANCH" && git merge --ff-only "$WAVE_BASE" ) \
    || { echo "main checkout would not fast-forward; fix by hand, then --resume $RUN" >&2; exit 2; }
  # cost split before any sweep: cost.sh reads the worktrees
  for ISSUE in $MERGED; do
    PR="$(python -c "import sys,json;print(json.load(open(sys.argv[1]))['issues'][sys.argv[2]]['pr'])" "$STATE" "$ISSUE")"
    COST="$(cd "$MAIN_CHECKOUT" && bash "$WAVE_HOME/cost.sh" "$ISSUE" 2>/dev/null)"
    [ -n "$COST" ] && (cd "$MAIN_CHECKOUT" && gh pr comment "$PR" --body "$(printf '## Wave cost\n```\n%s\n```' "$COST")" >/dev/null)
  done
fi

WALK_RESULT="skipped (no .claude/wave/walk.sh)"
if [ -n "$MERGED_PRS" ] && [ -f "$ROOT/.claude/wave/walk.sh" ]; then
  CHECKLIST="$(for PR in $MERGED_PRS; do
    (cd "$MAIN_CHECKOUT" && gh pr view "$PR" --json body --jq .body) | grep -E '^(NOT VERIFIED IN BROWSER:|MIGRATION: yes)' | sed "s/^/PR #$PR: /"
  done)"
  if [ -z "$CHECKLIST" ]; then
    WALK_RESULT="skipped (no NOT VERIFIED IN BROWSER or MIGRATION: yes line in merged PRs)"
  else
    WALK_NAME="walk-$(date +%F)-${RUN#run_}"
    WALK_PROMPT="$(DRY_RUN=1 bash "$ROOT/.claude/wave/walk.sh" "$WALK_NAME" <<< "$CHECKLIST")
You are a dispatched worker: after the DONE - WALK line, send worker_done exactly once per your preamble, --outcome succeeded with the N routes / M findings in the summary."
    orca orchestration worker-start --run "$RUN" --spec "$WALK_PROMPT" --worktree new-top-level --name "$WALK_NAME" \
      --repo "id:$REPO_ID" --base-branch "$WAVE_BASE" --agent claude --json >/dev/null \
      || { echo "walker failed to start; checklist:"; echo "$CHECKLIST"; exit 2; }
    echo "walker $WALK_NAME started; waiting"
    WALK_RESULT="walker sent no worker_done"
    for _ in 1 2 3 4 5 6 7 8; do   # up to 2h; the prompt time-boxes itself at ~45 min
      OUT="$(orca orchestration check --run "$RUN" --wait --types worker_done --timeout-ms 900000 --json)"
      WALK_RESULT="$(python -c "
import sys,json; s=sys.stdin.read(); r=json.loads(s[s.index('{'):]).get('result',{})
m=[x for x in r.get('messages',[]) if x.get('type')=='worker_done']
print(m[0].get('body','')[:300] if m else '')
did=r.get('deliveryId'); print('ACK '+did if did else '')" <<< "$OUT")"
      ACK="$(sed -n 's/^ACK //p' <<< "$WALK_RESULT")"; WALK_RESULT="$(sed '/^ACK /d;/^$/d' <<< "$WALK_RESULT")"
      [ -n "$ACK" ] && orca orchestration check --run "$RUN" --ack "$ACK" --timeout-ms 1 --json >/dev/null
      [ -n "$WALK_RESULT" ] && break
    done
    (cd "$MAIN_CHECKOUT" && npm run db:start >/dev/null 2>&1) && WALK_RESULT="$WALK_RESULT | db:start back up" || WALK_RESULT="$WALK_RESULT | db:start NOT confirmed"
  fi
fi

# sweep merged worktrees only; held ones keep their checkout for the human
( cd "$MAIN_CHECKOUT" && bash "$WAVE_HOME/status.sh" --sweep | bash ) >/dev/null 2>&1 || true

python - "$STATE" "$WALK_RESULT" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); I=d['issues']
merged=[f"{k} #{v['pr']}" for k,v in I.items() if v['status']=='merged']
held=[f"{k}" + (f" #{v['pr']}" if v['pr'] else '') + f" - {v['reason']}" for k,v in I.items() if v['status']=='held']
print(f"WAVE {d['run']}: merged {len(merged)} ({', '.join(merged) or '-'}); held {len(held)}" + (": " + '; '.join(held) if held else '') + f"; walk: {sys.argv[2]}")
print("Now: review the wave-held PRs, read the walker's tickets, and run /brain:save once.")
PY
