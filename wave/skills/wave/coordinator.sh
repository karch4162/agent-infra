#!/usr/bin/env bash
# Supervised wave (SPO-640): spawn the workers into one Orca Run, block on their
# worker_done, merge what the gate proves, then run the walk once nothing is live.
#
#   bash "$WAVE/coordinator.sh" SPO-640 quick:SPO-641 risk:SPO-642   # tier:ISSUE, default normal
#   bash "$WAVE/coordinator.sh" --resume run_5de25620f335            # continue after a crash
#
# Runs for the whole wave (hours). `/wave <issues>` starts it as a background job of
# the session (INNOV-463); from a terminal, give it its own. State lives in
# <main checkout>/.wave-run.<run>.json (git-excluded) plus the Orca Run, PR labels and
# worktrees, so --resume re-reads those and never re-spawns an issue that has a
# worktree (spawn.sh's claim guard). The merge decision is gate.py, pure and tested;
# the loop itself is autonomy/coordinator_loop.py. Ticket status and comments go
# through the tick's tracker adapter (jira_tracker.tracker_for, by WAVE_TRACKER).
#
# Human-gated by rule, never merged here: TIER risk, MIGRATION: yes, a fallback
# reviewer, a tie-break, a worker question. Those PRs get the wave-held label.
# The walk (step 3.5) runs only when worker-list shows nothing live: the walker owns
# the shared database, and that ordering is the whole safety argument.
# Known limits (v1): a worker that dies without worker_done leaves the loop waiting
# (resolve it with worker-stop/abandon per the Orca recovery reference, then --resume);
# an issue held on a question stays held after the human answers (merge it by hand).
# Bash 3.2-safe: every map lives in the state JSON, handled by python.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ "$WAVE_RUNTIME" = orca ] || { echo "wave: coordinator.sh needs WAVE_RUNTIME=orca; the direct runtime is supervised by autonomy/autonomy_tick.py" >&2; exit 1; }
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
export RUN STATE WAVE_HOME MAIN_CHECKOUT BASE_BRANCH WAVE_BASE WAVE_TRACKER WAVE_STATE_START WAVE_STATE_DONE
# The tracker adapter (jira_tracker.tracker_for, same as the tick) reads the queue, site
# and ClickUp list from the file; python on Windows needs the native path.
WAVE_CONFIG="$(cygpath -m "$WAVE_CONFIG" 2>/dev/null || echo "$WAVE_CONFIG")"; export WAVE_CONFIG
# A held ticket goes back here; the start state unless config.env names one.
export WAVE_STATE_HELD="${WAVE_STATE_HELD:-$WAVE_STATE_START}"
# A crashed loop must not fall through to the report: that printed "merged 0; held 0"
# as if the wave had settled, while every worker was still running unsupervised.
python "$WAVE_HOME_NATIVE/autonomy/coordinator_loop.py" || { echo "wave: coordinator loop crashed (traceback above); workers are unsupervised. Fix, then: bash \"\$WAVE/coordinator.sh\" --resume $RUN" >&2; exit 1; }

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
    COST="$(bash "$WAVE_HOME/cost.sh" "$ISSUE" 2>/dev/null)"
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
You are a dispatched worker: after the DONE - WALK line, send worker_done exactly once per your preamble: --outcome succeeded with the N routes / M findings in the summary, or --outcome failed with the whole BLOCKED line (and every NOT WALKED line) as the summary when you walked nothing."
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
