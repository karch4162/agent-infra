#!/usr/bin/env bash
# test-file-finding.sh — deterministic quality gate for brain/bin/file-finding.sh
#
# INNOV-262: when a guard detects a defect it cannot self-heal, it queues an
# auto-filed tracker finding instead of failing silently. Scripts have no tracker
# credentials, so the script's whole job is the QUEUE half of queue+drain:
#
# Contract under test:
#   ALWAYS exits 0 — a bug-filing helper must never break the calling command
#   first line:  FINDING: QUEUED ...  (stdout)  or  FINDING: SKIPPED ... (stderr)
#   queue file:  <vault>/.brain/findings-queue.jsonl, one JSON object per line
#   dedup:       same class+repo+normalized evidence => ONE line, count bumped
#                (normalization strips digits — "3 vs 12" and "5 vs 12" are the
#                same recurring defect)
#   secret-free: stores only its args; never reads or embeds file contents
#   graceful:    unwritable queue dir => SKIPPED on stderr, still exit 0
#
# Run:  bash tests/test-file-finding.sh   (from anywhere)
# No network, no git, no Jira. Every case gets its own mktemp -d sandbox.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/brain/bin/file-finding.sh"

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
cleanup() { chmod -R u+rwX "$TMPROOT" 2>/dev/null || true; rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------- helpers ---

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }

fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL $1"
  shift
  local line
  for line in "$@"; do
    echo "     $line"
  done
}

assert_eq() { # name expected actual [evidence...]
  local name="$1" exp="$2" act="$3"
  shift 3
  if [[ "$exp" == "$act" ]]; then
    pass "$name"
  else
    fail "$name" "expected: [$exp]" "actual:   [$act]" "$@"
  fi
}

assert_prefix() { # name prefix actual [evidence...]
  local name="$1" pre="$2" act="$3"
  shift 3
  if [[ "$act" == "$pre"* ]]; then
    pass "$name"
  else
    fail "$name" "expected line starting with: [$pre]" "actual line:                [$act]" "$@"
  fi
}

assert_contains() { # name needle haystack [evidence...]
  local name="$1" needle="$2" hay="$3"
  shift 3
  if [[ "$hay" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "expected to contain: [$needle]" "actual:              [$hay]" "$@"
  fi
}

assert_not_contains() { # name needle haystack [evidence...]
  local name="$1" needle="$2" hay="$3"
  shift 3
  if [[ "$hay" != *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "expected NOT to contain: [$needle]" "actual: [$hay]" "$@"
  fi
}

first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }

evidence() { # box -> a few lines of captured output for failure messages
  local box="$1"
  echo "stdout: [$(tr '\n' '|' <"$box/out.txt" 2>/dev/null)]"
  echo "stderr: [$(tr '\n' '|' <"$box/err.txt" 2>/dev/null)]"
  echo "queue:  [$(cat "$box/vault/.brain/findings-queue.jsonl" 2>/dev/null | tr '\n' '|')]"
}

# ------------------------------------------------------------ sandboxing ---

BOX=""
VAULT=""
QUEUE=""
sb_new() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  QUEUE="$VAULT/.brain/findings-queue.jsonl"
  mkdir -p "$VAULT/wiki"
}

STATUS=""
run_ff() { # args...
  (
    cd "$BOX" || exit 127
    unset CLAUDE_PROJECT_DIR
    env BRAIN_ROOT="$VAULT" bash "$SCRIPT" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

queue_lines() { wc -l <"$QUEUE" 2>/dev/null | tr -d ' \r'; }
queue_all() { cat "$QUEUE" 2>/dev/null | tr -d '\r'; }

if [[ ! -f "$SCRIPT" ]]; then
  echo "note: $SCRIPT does not exist yet — every case below is expected to FAIL until it lands."
fi

# ================================================================== CASES ===

# --- 1. queue write: first finding lands as one JSONL entry ---------------
echo "--- 1. queue write ---"
sb_new
run_ff mis-scoped-graph store-hub "SCOPE-AUDIT: OUT-OF-SCOPE - 14 node(s) built from files outside the recorded scope"
assert_eq "write/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "write/stdout-first-line-QUEUED" "FINDING: QUEUED" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_contains "write/user-told-a-ticket-is-coming" "tracker" "$(first_line "$BOX/out.txt")" \
  "the user is TOLD a ticket will be filed, never asked to file it" "$(evidence "$BOX")"
assert_not_contains "write/message-names-no-board" "INNOV" "$(first_line "$BOX/out.txt")" \
  "the destination lives in the vault's brain.json; the script must not hardcode one" "$(evidence "$BOX")"
assert_eq "write/queue-has-one-line" "1" "$(queue_lines)" "$(evidence "$BOX")"
assert_contains "write/entry-carries-class" '"class":"mis-scoped-graph"' "$(queue_all)" "$(evidence "$BOX")"
assert_contains "write/entry-carries-repo" '"repo":"store-hub"' "$(queue_all)" "$(evidence "$BOX")"
assert_contains "write/entry-carries-fingerprint-label" '"fingerprint":"brain-fp-' "$(queue_all)" \
  "the fingerprint doubles as the Jira dedup label" "$(evidence "$BOX")"
assert_contains "write/entry-count-1" '"count":1' "$(queue_all)" "$(evidence "$BOX")"
assert_contains "write/stdout-names-fingerprint" "brain-fp-" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"

# --- 2. fingerprint stability: same finding twice => one entry, count 2 ---
echo "--- 2. fingerprint stability (dedup) ---"
sb_new
run_ff label-count-regression KDS "incoming report names 3 communities, existing names 12"
fp1="$(queue_all | sed -n 's/.*"fingerprint":"\(brain-fp-[^"]*\)".*/\1/p')"
run_ff label-count-regression KDS "incoming report names 3 communities, existing names 12"
assert_eq "dedup/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_eq "dedup/still-one-line" "1" "$(queue_lines)" \
  "an identical repeat must bump the existing entry, not append" "$(evidence "$BOX")"
assert_contains "dedup/count-bumped-to-2" '"count":2' "$(queue_all)" "$(evidence "$BOX")"
fp2="$(queue_all | sed -n 's/.*"fingerprint":"\(brain-fp-[^"]*\)".*/\1/p')"
assert_eq "dedup/fingerprint-stable" "$fp1" "$fp2" "$(evidence "$BOX")"
assert_contains "dedup/stdout-reports-seen-2x" "2x" "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"

# --- 3. digit-varying evidence is STILL the same finding ------------------
# The recurring defect is the same even when the counts differ run to run.
echo "--- 3. fingerprint normalization strips digits ---"
run_ff label-count-regression KDS "incoming report names 5 communities, existing names 12"
assert_eq "norm/still-one-line" "1" "$(queue_lines)" \
  "'3 vs 12' and '5 vs 12' are one recurring defect, not two tickets" "$(evidence "$BOX")"
assert_contains "norm/count-bumped-to-3" '"count":3' "$(queue_all)" "$(evidence "$BOX")"

# --- 4. distinct findings get distinct entries ----------------------------
echo "--- 4. distinct findings ---"
sb_new
run_ff mis-scoped-graph store-hub "SCOPE-AUDIT: OUT-OF-SCOPE"
run_ff mis-scoped-graph hub-frontend "SCOPE-AUDIT: OUT-OF-SCOPE"
run_ff label-count-regression store-hub "incoming names fewer communities"
assert_eq "distinct/three-lines" "3" "$(queue_lines)" \
  "different repo or class must not collapse into one fingerprint" "$(evidence "$BOX")"

# --- 5. secret-free body: never reads or embeds file contents -------------
echo "--- 5. secret-free body ---"
sb_new
printf 'SUPER_SECRET_TOKEN=abc123verysecret\n' >"$VAULT/wiki/creds.md"
run_ff unresolvable-source-anchor sports-management "source wiki/creds.md could not be resolved (1 anchor)"
assert_eq "secret/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_contains "secret/path-is-recorded" "wiki/creds.md" "$(queue_all)" \
  "paths and counts belong in the finding" "$(evidence "$BOX")"
assert_not_contains "secret/file-contents-never-embedded" "SUPER_SECRET_TOKEN" "$(queue_all)" \
  "the script must store only its args, never file contents" "$(evidence "$BOX")"
assert_not_contains "secret/file-contents-not-in-output" "SUPER_SECRET_TOKEN" \
  "$(cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null)" "$(evidence "$BOX")"

# --- 6. graceful no-op: unwritable queue dir => SKIPPED, exit 0 -----------
# chmod 000 is a no-op for an elevated user and on some Windows filesystems
# (same caveat as test-hot-budget.sh case 10), so block mkdir -p another way:
# a regular FILE where the .brain directory must go.
echo "--- 6. unwritable queue dir ---"
sb_new
: >"$VAULT/.brain"   # file in place of dir => mkdir -p fails portably
run_ff mis-scoped-graph store-hub "SCOPE-AUDIT: OUT-OF-SCOPE"
assert_eq "unwritable/exit-0-never-breaks-caller" "0" "$STATUS" \
  "a bug-filing helper must NEVER break the calling command" "$(evidence "$BOX")"
assert_prefix "unwritable/stderr-first-line-SKIPPED" "FINDING: SKIPPED" \
  "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"
assert_eq "unwritable/nothing-on-stdout" "" "$(first_line "$BOX/out.txt")" \
  "SKIPPED must not masquerade as QUEUED on stdout" "$(evidence "$BOX")"
if [[ -f "$QUEUE" ]]; then
  fail "unwritable/no-queue-created" "a queue file appeared despite the blocked dir" "$(evidence "$BOX")"
else
  pass "unwritable/no-queue-created"
fi

# --- 7. missing args => SKIPPED, exit 0 -----------------------------------
echo "--- 7. missing args ---"
sb_new
run_ff mis-scoped-graph
assert_eq "badargs/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "badargs/stderr-SKIPPED" "FINDING: SKIPPED" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"

# --- 8. evidence with quotes/backslashes stays one valid-looking line -----
echo "--- 8. JSON escaping ---"
sb_new
run_ff mis-scoped-graph store-hub 'path "C:\repos\edge" refused'
assert_eq "escape/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_eq "escape/one-line" "1" "$(queue_lines)" "$(evidence "$BOX")"
if command -v node >/dev/null 2>&1; then
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8").trim())' "$QUEUE" >/dev/null 2>&1 \
    && pass "escape/line-is-valid-json" \
    || fail "escape/line-is-valid-json" "JSON.parse rejected the queue line" "$(evidence "$BOX")"
else
  pass "escape/line-is-valid-json (node unavailable — skipped)"
fi

# --- 9. the shipped template routes defects here, never to a vendor --------
# INNOV-308: an agent drafted plugin feedback to a vendor feedback tool because
# nothing said not to. The route and the prohibition must ship in the template
# every vault is seeded from, and init must offer them to older vaults.
echo "--- 9. template names the route and the prohibition ---"
TPL="$REPO_ROOT/brain/templates/CLAUDE.brain.md"
PROHIBIT='never send a brain or plugin defect to a vendor or host feedback channel'
route_ok() { grep -q 'file-finding\.sh' "$1" && grep -qi "$PROHIBIT" "$1"; }
route_ok "$TPL" && pass "template/route-and-prohibition"   || fail "template/route-and-prohibition" "$TPL must name file-finding.sh and: $PROHIBIT"
sb_new
sed 's/$//' "$TPL" >"$BOX/crlf.md"
route_ok "$BOX/crlf.md" && pass "template/crlf-still-matches"   || fail "template/crlf-still-matches" "a CRLF vault copy lost the match"
grep -vi "$PROHIBIT" "$TPL" >"$BOX/stripped.md"
route_ok "$BOX/stripped.md" && fail "template/negative-control" "check passed with the prohibition removed"   || pass "template/negative-control"
grep -q 'does \*\*not\*\* name `file-finding.sh`' "$REPO_ROOT/brain/skills/init/SKILL.md"   && pass "init/offers-block-to-existing-vaults"   || fail "init/offers-block-to-existing-vaults" "init must offer the findings block to a CLAUDE.md lacking file-finding.sh"

# --- 10. plugin version stamp (INNOV-404) ---------------------------------
# Triage of INNOV-400/401 had to rediscover the reporter ran a pre-fix install.
# Each NEW line records the queuing plugin's version; a repeat keeps the first.
echo "--- 10. plugin version stamp ---"
plugin_copy() { # dir version-or-empty [crlf] -> a copy of the script under dir/bin
  mkdir -p "$1/bin"
  cp "$SCRIPT" "$1/bin/file-finding.sh"
  [[ -n "$2" ]] || return 0
  mkdir -p "$1/.claude-plugin"
  if [[ "${3:-}" == crlf ]]; then
    printf '{\r\n  "name": "brain",\r\n  "version": "%s"\r\n}\r\n' "$2" >"$1/.claude-plugin/plugin.json"
  else
    printf '{\n  "name": "brain",\n  "version": "%s"\n}\n' "$2" >"$1/.claude-plugin/plugin.json"
  fi
}
run_copy() { # dir args...
  local d="$1"; shift
  ( cd "$BOX" || exit 127; unset CLAUDE_PROJECT_DIR
    env BRAIN_ROOT="$VAULT" bash "$d/bin/file-finding.sh" "$@" ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}
REAL_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO_ROOT/brain/.claude-plugin/plugin.json" | head -1 | tr -d '\r')"

sb_new
run_ff mis-scoped-graph store-hub "SCOPE-AUDIT: OUT-OF-SCOPE"
assert_eq "version/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_contains "version/new-line-stamped" "\"plugin_version\":\"$REAL_VER\"" "$(queue_all)" "$(evidence "$BOX")"

sb_new
plugin_copy "$BOX/old" "1.0.0"
plugin_copy "$BOX/new" "2.0.0"
run_copy "$BOX/old" label-count-regression KDS "incoming names 3, existing 12"
run_copy "$BOX/new" label-count-regression KDS "incoming names 3, existing 12"
assert_eq "version/repeat-exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_contains "version/repeat-counted" '"count":2' "$(queue_all)" "$(evidence "$BOX")"
assert_contains "version/repeat-keeps-original" '"plugin_version":"1.0.0"' "$(queue_all)" \
  "a repeat must not restamp the line with the newer install's version" "$(evidence "$BOX")"
assert_not_contains "version/repeat-not-restamped" '2.0.0' "$(queue_all)" "$(evidence "$BOX")"

sb_new
plugin_copy "$BOX/bare" ""
run_copy "$BOX/bare" mis-scoped-graph store-hub "SCOPE-AUDIT: OUT-OF-SCOPE"
assert_eq "version/missing-exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_contains "version/missing-is-unknown" '"plugin_version":"unknown"' "$(queue_all)" "$(evidence "$BOX")"

sb_new
plugin_copy "$BOX/crlf" "3.4.5" crlf
run_copy "$BOX/crlf" mis-scoped-graph store-hub "SCOPE-AUDIT: OUT-OF-SCOPE"
assert_eq "version/crlf-exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_contains "version/crlf-no-cr" '"plugin_version":"3.4.5"' "$(cat "$QUEUE")" \
  "a CRLF plugin.json must not leak \\r into the stamp" "$(evidence "$BOX")"

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
