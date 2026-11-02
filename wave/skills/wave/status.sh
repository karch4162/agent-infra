#!/usr/bin/env bash
# Checklist steps 1 and 3, scoped to THIS repo's Orca worktrees.
#
#   bash "$WAVE/status.sh"           # leftovers: name | status | PR
#   bash "$WAVE/status.sh" --sweep   # prints rm commands for merged worktrees; read, then pipe to bash
#
# `orca worktree ps` lists every repo Orca manages. Unfiltered, the sweep once offered
# to delete a merged worktree from an unrelated work monorepo - hence the repo filter.
# Selector is name:<displayName>: the documented id:<repo>::<path> form returns
# selector_not_found on Windows and fails silently per line when piped.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "$WAVE_RUNTIME" = direct ]; then
  # Direct runtime: state is .claude/wave/runs/<slug>/status.json, joined with the
  # live PID, last log event and cost by wave_status.py (--sweep prints git worktree remove).
  exec "$WAVE_PY" "$WAVE_HOME/autonomy/wave_status.py" ${1:+"$1"}
fi
REPO_ID="$(orca_repo_id)"
[ -n "$REPO_ID" ] || { echo "$MAIN_CHECKOUT is not registered with Orca" >&2; exit 1; }

orca worktree ps --json | python -c "
import sys, json
repo, sweep = sys.argv[1], sys.argv[2] == '--sweep'
# ps emits worktreeId, list emits id; same <repoId>::<path> value. Read either, so a
# schema rename cannot turn the leftover check into a silent all-clear.
def worktree_id(w): return w.get('worktreeId') or w.get('id') or ''
for w in json.load(sys.stdin)['result']['worktrees']:
    if w['isMainWorktree'] or not worktree_id(w).startswith(repo + '::'): continue
    pr = w.get('linkedPR') or {}
    if not sweep:
        print(w['displayName'], '|', w.get('workspaceStatus'), '| PR', pr.get('number'), pr.get('state'))
    elif pr.get('state') == 'merged':
        print('orca worktree rm --worktree \"name:%s\" --force' % w['displayName'])
" "$REPO_ID" "${1:-}"
