#!/usr/bin/env bash
# test-wave-autonomy.sh — the wave plugin's direct runtime + autonomy gates.
#
# Runs the python unit suites that ship next to the code (wave/skills/wave/autonomy/
# test_*.py): merge policy, daily cap + run lock, backlog watch, plan loop, grok
# verdict parsing, preflight DENY scan, aggregate report. CI loops tests/test-*.sh,
# so this wrapper is how they get there. No network, no CLIs: everything is faked.
#
# Run:  bash tests/test-wave-autonomy.sh   (from anywhere)
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
AUTONOMY="$REPO_ROOT/wave/skills/wave/autonomy"

if command -v python >/dev/null 2>&1; then PY=python
elif command -v python3 >/dev/null 2>&1; then PY=python3
else echo "SKIP: no python on PATH" >&2; exit 0; fi

# The modules resolve <repo>/.claude/wave from the git common dir; point them at a
# scratch repo so a developer's real config.env never leaks into the suite.
BOX="$(mktemp -d)"
trap 'rm -rf "$BOX"' EXIT
git -C "$BOX" init -q -b trunk
export WAVE_REPO
WAVE_REPO="$(cygpath -m "$BOX" 2>/dev/null || echo "$BOX")"

status=0
for suite in test_wave_autonomy.py test_wave_infra_blockers.py; do
  echo "--- $suite ---"
  if (cd "$AUTONOMY" && "$PY" "$suite" 2>&1 | tail -n 4); then
    :
  fi
  # unittest exits non-zero on failure; re-check the exit status without the tail
  (cd "$AUTONOMY" && "$PY" "$suite" >/dev/null 2>&1) || { echo "FAIL $suite"; status=1; }
done

echo "--- every autonomy script parses and answers --help / imports ---"
for f in "$AUTONOMY"/*.py; do
  "$PY" -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$f" || { echo "FAIL parse $f"; status=1; }
done
(cd "$AUTONOMY" && "$PY" autonomy_tick.py --help >/dev/null) || { echo "FAIL autonomy_tick --help"; status=1; }
(cd "$AUTONOMY" && "$PY" wave_status.py --runs "$BOX/none" | grep -q "no runs") || { echo "FAIL wave_status empty"; status=1; }

[ "$status" = 0 ] && echo "PASS wave-autonomy" || echo "FAIL wave-autonomy"
exit "$status"
