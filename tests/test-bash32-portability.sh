#!/usr/bin/env bash
# test-bash32-portability.sh — shipped shell scripts must run on bash 3.2.
#
# WHY THIS EXISTS. macOS ships bash 3.2 as /bin/bash, and the plugin's scripts
# are executed with whatever bash the user's system provides (INNOV-284). Any
# bash-4+ construct — mapfile/readarray, associative arrays, case-conversion
# parameter expansions, &>> — is a syntax or runtime error there, and the
# failure surfaces on someone else's laptop, not in CI. This suite is a static
# gate: it greps every .sh under brain/, wave/ and tools/ for the whole construct class, so a
# regression fails here first.
#
# Run:  bash tests/test-bash32-portability.sh   (from anywhere)
# No network, no vault, no interpreters beyond grep.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

PASSED=0
FAILED=0
TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }
fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL $1"
  shift
  local l
  for l in "$@"; do echo "     $l"; done
}

# The construct class under test, as grep -E patterns. One pattern per line.
BASH4_PATTERNS='\bmapfile\b
\breadarray\b
declare -A
\$\{[A-Za-z_]+\^\^
\$\{[A-Za-z_]+,,
&>>'

# scan_file <path> — prints file:line for every bash-4+ construct hit; silent
# and status 0 when the file is clean. The one function both the gate and the
# negative control go through.
scan_file() {
  local f="$1" p hits="" out
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    out="$(grep -nE "$p" "$f" 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      hits="${hits}$(printf '%s\n' "$out" | sed "s|^|$f:|")
"
    fi
  done <<EOF
$BASH4_PATTERNS
EOF
  if [[ -n "$hits" ]]; then printf '%s' "$hits"; return 1; fi
  return 0
}

# --- negative control ---------------------------------------------------------
# A fixture that contains a bash-4 construct must be DETECTED by scan_file.
# If this fails, the patterns are silently broken and the gate below proves
# nothing.
FIXTURE="$TMPROOT/fixture.sh"
printf '#!/bin/bash\nmapfile -t lines < input.txt\n' >"$FIXTURE"
if control_hits="$(scan_file "$FIXTURE")"; then
  fail "negative-control/mapfile-detected" "scan_file found nothing in a fixture containing mapfile"
else
  if [[ "$control_hits" == *"$FIXTURE:2:"* ]]; then
    pass "negative-control/mapfile-detected"
  else
    fail "negative-control/mapfile-detected" "hit list missing $FIXTURE:2" "got: [$control_hits]"
  fi
fi

# --- the gate: every shipped .sh under brain/ and wave/, plus tools/ -----------
# tools/ is in scope: maintainers run it on macOS too. tests/ and .github/ are
# out of scope: they run in CI or dev machines with a
# modern bash, not on end-user macOS.
scanned=0
violations=""
while IFS= read -r f; do
  scanned=$((scanned + 1))
  if ! file_hits="$(scan_file "$f")"; then
    violations="${violations}${file_hits}"
  fi
done < <(find "$REPO_ROOT/brain" "$REPO_ROOT/wave" "$REPO_ROOT/tools" -type f -name '*.sh' | sort)

if [[ $scanned -eq 0 ]]; then
  fail "gate/found-scripts" "no .sh files found under $REPO_ROOT/brain — gate scanned nothing"
else
  pass "gate/found-scripts ($scanned scripts)"
fi

if [[ -z "$violations" ]]; then
  pass "gate/no-bash4-constructs"
else
  fail "gate/no-bash4-constructs" "bash-4+ constructs in shipped scripts:" "$violations"
fi

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
