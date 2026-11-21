"""The supervised wave's wait / gate / merge loop (SPO-640), run by coordinator.sh.

Lifted out of coordinator.sh's inline heredoc (INNOV-463) so its settle paths can be
driven by a test. coordinator.sh owns spawn, walk, sweep and the report; this file only
moves data between orca, gh and the state file. Importing it has no side effects:
the env is read here, the loop runs in main().
"""
import json, os, re, subprocess, sys, time
RUN, STATE, WAVE, MAIN = (os.environ.get(k, '') for k in ('RUN','STATE','WAVE_HOME','MAIN_CHECKOUT'))
BASE = os.environ.get('BASE_BRANCH', '')

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
    # not --required: repos without required checks (sports-management) get a text
    # error there, not JSON. gate.py treats an empty list as PENDING, never MERGE.
    out = gh('pr', 'checks', str(pr), '--json', 'name,bucket')
    checks = json.loads(out) if out.lstrip().startswith('[') else []
    inp = json.dumps({'body': view.get('body', ''), 'checks': checks, 'mergeable': view.get('mergeable')})
    return subprocess.run([sys.executable, os.path.join(WAVE, 'gate.py')], input=inp, capture_output=True, text=True).stdout.strip()

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
            if time.time() - v.get('doneAt', time.time()) > 30 * 60:
                v['status'], v['reason'] = 'held', verdict + ' for 30 min'
        else:
            v['status'], v['reason'] = 'held', verdict.replace('CONFLICT', 'CONFLICT after one rebase')
        if v['status'] == 'held':
            gh('pr', 'edit', str(pr), '--add-label', 'wave-held')
            oj('orchestration', 'worker-retain', '--dispatch', v['dispatch'])
            if os.environ.get('WAVE_TRACKER') == 'linear':   # the worker already set it Done (step 5); a held PR is not done
                sh('orca', 'linear', 'status', 'set', k, '--to', os.environ['WAVE_STATE_HELD'], '--json')

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
