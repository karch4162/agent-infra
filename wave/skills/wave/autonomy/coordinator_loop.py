"""The supervised wave's wait / gate / merge loop (SPO-640), run by coordinator.sh.

Lifted out of coordinator.sh's inline heredoc (INNOV-463) so its settle paths can be
driven by a test. coordinator.sh owns spawn, walk, sweep and the report; this file only
moves data between orca, gh and the state file. Importing it has no side effects:
the env is read here, the loop runs in main().
"""
import json, math, os, re, subprocess, sys, time
RUN, STATE, WAVE, MAIN = (os.environ.get(k, '') for k in ('RUN','STATE','WAVE_HOME','MAIN_CHECKOUT'))
BASE = os.environ.get('BASE_BRANCH', '')
CONFIG = os.environ.get('WAVE_CONFIG', '')   # the repo's config.env, as lib.sh resolved it
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

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
LOCK = STATE + '.lock'
def pid_alive(pid):
    if os.name != 'nt':
        try: os.kill(pid, 0); return True
        except OSError: return False
    import ctypes  # os.kill(pid, 0) TERMINATES on Windows; ask the kernel instead
    k = ctypes.windll.kernel32; h = k.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
    if not h: return False
    code = ctypes.c_ulong(); k.GetExitCodeProcess(h, ctypes.byref(code)); k.CloseHandle(h)
    return code.value == 259   # STILL_ACTIVE
def take_lock():
    # Killing the bash wrapper orphans this python loop (2026-10-22: two loops on one Run,
    # the stale one overwrote the state file every tick). One loop per Run, enforced here.
    if os.path.exists(LOCK):
        try: other = int(open(LOCK).read().strip() or 0)
        except ValueError: other = 0
        if other and other != os.getpid() and pid_alive(other):
            sys.exit(f"another coordinator loop (pid {other}) is alive on {RUN}; kill it first: {LOCK}")
    open(LOCK, 'w').write(str(os.getpid()))
def reconcile(d):
    # --resume trusts GitHub, not the file: a merge that happened under a lost loop is still a merge.
    for k, v in d['issues'].items():
        if v['status'] in ('running', 'done'):
            pr = pr_number(v)
            if pr and json.loads(gh('pr', 'view', str(pr), '--json', 'state')).get('state') == 'MERGED':
                v.update(status='merged', pr=pr); log(k, f'PR #{pr} already merged; reconciled')
        elif v['status'] == 'held' and v.get('pr') and pr_merged(v['pr']) and not v.get('mergedByHand'):
            # a human merged a held PR: undo the hold's ticket rewind, but it stays held here
            # (never walked or swept as a clean wave merge; the gate never passed it)
            v['mergedByHand'] = True; log(k, f"held PR #{v['pr']} merged by hand; ticket back to done")
            track(k, status=os.environ.get('WAVE_STATE_DONE'), comment=f"wave: held PR #{v['pr']} merged by hand")
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
_TRACKER = []   # memo: [adapter or None]
def tracker():
    # The tick's adapter (jira_tracker.tracker_for), picked by WAVE_TRACKER: Jira via acli,
    # ClickUp via REST; linear gets the write-only linear_tracker (not in tracker_for, so
    # the tick is unchanged); unset gets None. Never raises: a crash here leaves every
    # worker unsupervised, and the ticket is a courtesy copy of state that lives on GitHub.
    if not _TRACKER:
        t = None
        try:
            from pathlib import Path
            from autonomy_config import load_autonomy_config
            from jira_tracker import tracker_for
            cfg = load_autonomy_config(Path(CONFIG) if CONFIG else None)
            if cfg.tracker == 'linear':
                from linear_tracker import LinearTrackerAdapter
                t = LinearTrackerAdapter()
            else:
                t = tracker_for(cfg)
            if t is None:
                log(f"tracker: no adapter for WAVE_TRACKER={cfg.tracker or '(unset)'}; tickets are not updated")
        except Exception as e:  # noqa: BLE001
            log('tracker: unavailable, tickets are not updated:', str(e)[:200])
        _TRACKER.append(t)
    return _TRACKER[0]
def track(k, status=None, comment=None):
    t = tracker()
    if t is None: return
    # separately: a refused transition must not swallow the comment that says why
    for what, arg in (('set_status', status), ('comment', comment)):
        if not arg: continue
        try: getattr(t, what)(k, arg)
        except Exception as e: log(k, f'tracker {what} failed:', str(e)[:200])  # noqa: BLE001
def track_hold(k, v):
    # the worker already set the done state (step 5); a held PR is not done
    pr = f" (PR #{v['pr']})" if v.get('pr') else ''
    track(k, status=os.environ.get('WAVE_STATE_HELD') or os.environ.get('WAVE_STATE_START'),
          comment=f"wave: held{pr} - {v['reason']}")
def pr_merged(pr):
    # A PR merged outside this loop (by hand, or the merge landed but gh exited non-zero)
    # is merged, not held: a hold would rewind its ticket from done.
    try: return json.loads(gh('pr', 'view', str(pr), '--json', 'state') or '{}').get('state') == 'MERGED'
    except ValueError: return False
def merge_sha(pr):
    try: return (json.loads(gh('pr', 'view', str(pr), '--json', 'mergeCommit') or '{}').get('mergeCommit') or {}).get('oid') or ''
    except ValueError: return ''

def gate(pr):
    view = json.loads(gh('pr', 'view', str(pr), '--json', 'body,mergeable'))
    # not --required: repos without required checks (sports-management) get a text
    # error there, not JSON. gate.py treats an empty list as PENDING, never MERGE.
    out = gh('pr', 'checks', str(pr), '--json', 'name,bucket')
    checks = json.loads(out) if out.lstrip().startswith('[') else []
    inp = json.dumps({'body': view.get('body', ''), 'checks': checks, 'mergeable': view.get('mergeable')})
    return subprocess.run([sys.executable, os.path.join(WAVE, 'gate.py')], input=inp, capture_output=True, text=True).stdout.strip()

# Orca escalates whenever a worker's turn ends without worker_done, which includes a Claude
# worker handing off to a background review or an advisor call (INNOV-464: all three workers of
# run_634d93c19dcc were held this way while still live, then sent worker_done to nobody).
# Anchored to the start of Orca's own message: the body goes on to quote the worker's last
# output, and the phrase quoted there must not turn a real escalation into a grace wait.
TURN_END = re.compile(r'Worker \S+ ended its turn without sending worker_done\b')
def turn_end_grace_s():
    try: m = float(os.environ.get('WAVE_TURN_END_GRACE_MIN') or 60)
    except ValueError: m = 60
    return m * 60 if math.isfinite(m) and m > 0 else 60 * 60   # nan/inf/0 would never (or always) hold
def parked_why_not(v):
    """'' while a turn-ended worker may keep running; otherwise why it is held. The clock starts
    at the first turn-end and later ones never reset it, or a looping worker never hits the cap.
    Only a definite non-live state holds at once: 'unverifiable' (no status heartbeat for a while,
    e.g. a long review.sh) or an unreadable worker-show is waited on, bounded by the same cap."""
    v.setdefault('turnEndAt', time.time())
    try: liveness = (str(oj('orchestration', 'worker-show', '--dispatch', v['dispatch']).get('liveness') or '').split() or [None])[0]
    except Exception: liveness = None   # noqa: BLE001 - unknown, not dead; the cap still bounds the wait
    # the concise view renders "unverifiable (<detail>)"; the state is the first word
    if liveness and liveness not in ('live', 'unverifiable'): return f'worker not live ({liveness})'
    cap = turn_end_grace_s()
    if time.time() - v['turnEndAt'] > cap:
        return f"{liveness or 'unreadable'} {cap / 60:g} min after its turn ended, no worker_done"
    return ''
def recheck_parked(d):
    # escalations are events: a parked worker that goes quiet is only caught by this poll
    for k, v in d['issues'].items():
        if v['status'] != 'running' or not v.get('turnEndAt'): continue
        why = parked_why_not(v)
        if why:
            v['status'], v['reason'] = 'held', f'escalation needs human ({why})'
            log(k, '->', v['status'], v['reason']); track_hold(k, v)

def consume(d):
    r = oj('orchestration', 'check', '--run', RUN, '--wait', '--types', 'worker_done,escalation,question', '--timeout-ms', '120000')
    for m in r.get('messages', []):
        p = m.get('payload') or {}
        p = json.loads(p) if isinstance(p, str) else p   # older Orca builds sent a JSON string
        if m.get('type') not in ('worker_done', 'question', 'escalation'):
            continue   # heartbeats ride in the same FIFO batch (--types is only the wake condition)
        k = by_dispatch(d, p.get('dispatchId'), p.get('taskId'))
        if not k: log('message for unknown dispatch', m.get('type'), p); continue
        v = d['issues'][k]
        if v['status'] != 'running':
            log('ignoring', m['type'], 'for', k, 'already', v['status']); continue   # replay-safe
        if m['type'] == 'worker_done':
            n = re.search(r'PR #(\d+)', m.get('body') or '')
            v['pr'] = int(n.group(1)) if n else v['pr']
            v['status'] = 'done' if p.get('outcome') == 'succeeded' else 'held'
            v['doneAt'] = time.time()
            if v['status'] == 'held': v['reason'] = 'worker failed: ' + (m.get('body') or '')[:160]
        elif m['type'] == 'escalation' and TURN_END.match((m.get('body') or '').lstrip()):
            why = parked_why_not(v)
            if not why:
                log(k, 'turn ended, worker still live; waiting for worker_done'); continue
            v['status'] = 'held'; v['reason'] = f"escalation needs human ({why}): " + (m.get('body') or '')[:160]
        else:  # a question or any other escalation: the coordinator never guesses for a worker
            v['status'] = 'held'; v['reason'] = f"{m['type']} needs human: " + (m.get('body') or '')[:160]
        log(k, '->', v['status'], v['reason'])
        if v['status'] == 'held': track_hold(k, v)
    if r.get('deliveryId'):
        oj('orchestration', 'check', '--run', RUN, '--ack', r['deliveryId'], '--timeout-ms', '1')
    recheck_parked(d)

def settle(d):
    for k, v in d['issues'].items():
        if v['status'] != 'done': continue
        pr = pr_number(v)
        if not pr:
            v['status'], v['reason'] = 'held', 'worker_done without a PR number'; track_hold(k, v); continue
        v['pr'] = pr
        if pr_merged(pr):
            # merged before the gate passed it (a self-merge, or a human): hold for a person,
            # never walk or sweep it as a clean merge; the ticket keeps the worker's done state
            v['status'], v['reason'] = 'held', 'PR merged outside the coordinator; never gated'
            gh('pr', 'edit', str(pr), '--add-label', 'wave-held')
            oj('orchestration', 'worker-retain', '--dispatch', v['dispatch'])
            track(k, comment=f"wave: held (PR #{pr}) - {v['reason']}"); continue
        verdict = gate(pr)
        log(k, f'PR #{pr}', verdict)
        if verdict == 'MERGE':
            if subprocess.run(['gh', 'pr', 'merge', str(pr), '--merge'], cwd=MAIN, capture_output=True).returncode == 0 \
                    or pr_merged(pr):
                v['status'] = 'merged'; oj('orchestration', 'worker-release', '--dispatch', v['dispatch'])
                sha = merge_sha(pr)
                track(k, comment=f"wave: PR #{pr} merged" + (f" as {sha}" if sha else ''))
            else:
                v['status'], v['reason'] = 'held', 'gh pr merge failed'
        elif verdict == 'CONFLICT' and not v['rebased']:
            # one rebase on the same proven terminal; a second conflict is held
            handle = oj('orchestration', 'worker-show', '--dispatch', v['dispatch']).get('terminal', {}).get('handle') \
                or oj('orchestration', 'worker-show', '--dispatch', v['dispatch']).get('agentTerminalHandle')
            if not handle:
                v['status'], v['reason'] = 'held', 'CONFLICT and no terminal handle to redispatch'; track_hold(k, v); continue
            spec = (f"PR #{pr} conflicts with {BASE} after a sibling merged. Rebase this worktree on origin/{BASE}, "
                    "resolve conflicts, rerun /preflight, push with --force-with-lease, then send worker_done "
                    f"--outcome succeeded with PR #{pr} in the summary. Change nothing else.")
            r = oj('orchestration', 'worker-start', '--run', RUN, '--terminal', handle, '--worktree', f"name:{v['slug']}", '--spec', spec)
            if r.get('dispatchId'):
                v.update(status='running', rebased=True, task=r.get('taskId', v['task']), dispatch=r['dispatchId'])
                v.pop('turnEndAt', None)   # a new dispatch gets its own turn-end clock
            else:
                v['status'], v['reason'] = 'held', 'CONFLICT; rebase redispatch failed'
        elif verdict.startswith('PENDING'):
            if time.time() - v.get('doneAt', time.time()) > 30 * 60:
                v['status'], v['reason'] = 'held', verdict + ' for 30 min'
        else:
            v['status'], v['reason'] = 'held', verdict.replace('CONFLICT', 'CONFLICT after one rebase')
        if v['status'] == 'held':
            gh('pr', 'edit', str(pr), '--add-label', 'wave-held')
            oj('orchestration', 'worker-retain', '--dispatch', v['dispatch'])
            track_hold(k, v)

def main():
    take_lock()
    d = load(); reconcile(d); save(d)
    while any(v['status'] in ('running', 'done') for v in d['issues'].values()):
        if any(v['status'] == 'running' for v in d['issues'].values()): consume(d)
        settle(d); save(d)
        if all(v['status'] == 'done' for v in d['issues'].values() if v['status'] in ('running','done')): time.sleep(60)  # CI pending
    save(d)
    os.remove(LOCK)
    log('workers settled:', {k: v['status'] for k, v in d['issues'].items()})


if __name__ == '__main__':
    main()
