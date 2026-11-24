#!/usr/bin/env bash
# test-drain-findings.sh — gate for brain/bin/drain-findings.mjs (INNOV-425).
#
# The findings drain was model prose, and improvised tickets lost their labels,
# fingerprint and Plugin version line. This pins the payloads the script emits:
# label set, title, description (incl. Plugin version, "unknown" for pre-INNOV-404
# queue lines), the search query, the 3-create cap, and done's line removal.
#
# Run:  bash tests/test-drain-findings.sh   (from anywhere; needs node)
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
DF="$REPO_ROOT/brain/bin/drain-findings.mjs"

PASSED=0
FAILED=0
TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL $1"; shift; local l; for l in "$@"; do echo "     $l"; done; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]" "actual:   [$3]"; fi; }

VAULT=""
QUEUE=""
new_vault() { # [tracker-json]
  VAULT="$(mktemp -d "$TMPROOT/vXXXXXX")"
  QUEUE="$VAULT/.brain/findings-queue.jsonl"
  mkdir -p "$VAULT/.brain"
  [[ -n "${1:-}" ]] && printf '{"other": 1, "tracker": %s}\n' "$1" >"$VAULT/brain.json"
  return 0
}
line() { # fp class [plugin_version]  -> one queue line (no version field when omitted)
  local ver=""
  [[ -n "${3:-}" ]] && ver=",\"plugin_version\":\"$3\""
  printf '{"fingerprint":"brain-fp-%s","class":"%s","repo":"store-hub","evidence":"14 node(s) out of scope","count":2,"first_seen":"2026-11-01T00:00:00Z","last_seen":"2026-11-02T00:00:00Z"%s}\n' "$1" "$2" "$ver"
}
run() { BRAIN_ROOT="$VAULT" node "$DF" "$@" >"$TMPROOT/out.json" 2>"$TMPROOT/err.txt"; STATUS=$?; }
# q <js expression over o (the parsed stdout)>
q() { node -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); const r=(new Function("o","return ("+process.argv[2]+")"))(o); process.stdout.write(typeof r==="string"?r:JSON.stringify(r))' "$TMPROOT/out.json" "$1" 2>/dev/null || echo ERR; }

JIRA='{"type": "jira", "project": "INNOV"}'

# --- 1. create payload: label set, title, description incl. Plugin version ---
echo "--- 1. create payload ---"
new_vault "$JIRA"
line aaa111 mis-scoped-graph 0.24.2 >"$QUEUE"
run plan
assert_eq "create/exit-0" "0" "$STATUS"
assert_eq "create/action" "create" "$(q 'o.actions[0].action')"
assert_eq "create/labels" '["brain-plugin","brain-autofiled","brain-fp-aaa111"]' "$(q 'o.actions[0].labels')"
assert_eq "create/title" "[brain-autofiled] mis-scoped-graph in store-hub" "$(q 'o.actions[0].title')"
assert_eq "create/project" "INNOV" "$(q 'o.actions[0].project')"
for want in "Class: mis-scoped-graph" "Repo: store-hub" "Fingerprint: brain-fp-aaa111" "Evidence: 14 node(s) out of scope" \
            "Count: 2" "First seen: 2026-11-01T00:00:00Z" "Last seen: 2026-11-02T00:00:00Z" "Plugin version: 0.24.2"; do
  assert_eq "create/description-has: $want" "true" "$(q "o.actions[0].description.split('\n').includes('$want')")"
done
assert_eq "create/plan-leaves-queue-intact" "1" "$(wc -l <"$QUEUE" | tr -d ' ')"

# --- 2. pre-INNOV-404 line (no plugin_version) says unknown; CRLF queue + BOM brain.json
echo "--- 2. pre-404 + CRLF ---"
new_vault
printf '\xEF\xBB\xBF{"tracker": %s}\r\n' "$JIRA" >"$VAULT/brain.json"
line bbb222 shrink-guard-refusal | sed 's/$/\r/' >"$QUEUE"
run plan
assert_eq "pre404/action" "create" "$(q 'o.actions[0].action')"
assert_eq "pre404/version-unknown" "true" "$(q "o.actions[0].description.split('\n').includes('Plugin version: unknown')")"
assert_eq "pre404/labels" '["brain-plugin","brain-autofiled","brain-fp-bbb222"]' "$(q 'o.actions[0].labels')"

# --- 3. search: Jira JQL and Linear label --------------------------------------
echo "--- 3. search ---"
new_vault "$JIRA"
line aaa111 mis-scoped-graph 0.24.2 >"$QUEUE"
run search
assert_eq "search/jira-jql" "project = INNOV AND labels = brain-fp-aaa111 AND statusCategory != Done" "$(q 'o.findings[0].search.jql')"
new_vault '{"type": "linear", "team": "Brain"}'
line aaa111 mis-scoped-graph >"$QUEUE"
run search
assert_eq "search/linear" '{"team":"Brain","label":"brain-fp-aaa111"}' "$(q 'o.findings[0].search')"
run plan
assert_eq "create/linear-team" "Brain" "$(q 'o.actions[0].team')"

# --- 4. comment on an open match; the cap counts creates only ------------------
echo "--- 4. comment + cap ---"
new_vault "$JIRA"
{ line f1 c1 0.1.0; line f2 c2; line f3 c3; line f4 c4; line f5 c5; } >"$QUEUE"
run plan --open brain-fp-f1=INNOV-301
assert_eq "cap/actions" '["comment","create","create","create","held"]' "$(q 'o.actions.map(a=>a.action)')"
assert_eq "comment/key" "INNOV-301" "$(q 'o.actions[0].key')"
assert_eq "comment/body" "seen again: 2x, last 2026-11-02T00:00:00Z, evidence: 14 node(s) out of scope, Plugin version: 0.1.0" "$(q 'o.actions[0].body')"
assert_eq "cap/held-is-last" "brain-fp-f5" "$(q 'o.actions[4].fingerprint')"
run plan --open brain-fp-nope=INNOV-1
assert_eq "plan/unknown-open-refused" "2" "$STATUS"

# --- 5. done removes only the named lines; empties delete the file -------------
echo "--- 5. done ---"
echo 'not json' >>"$QUEUE"
run done brain-fp-f1 brain-fp-f2
assert_eq "done/removed" "2" "$(q 'o.removed')"
assert_eq "done/left-incl-malformed" "4" "$(q 'o.left')"
assert_eq "done/kept-f3" "1" "$(grep -c 'brain-fp-f3' "$QUEUE")"
assert_eq "done/kept-malformed" "1" "$(grep -c 'not json' "$QUEUE")"
assert_eq "done/f1-gone" "0" "$(grep -c 'brain-fp-f1' "$QUEUE")"
printf '{"fingerprint":"brain-fp-x OR project = SECRET","class":"c","repo":"r"}
' >>"$QUEUE"
run search
assert_eq "plan/counts-malformed" "2" "$(q 'o.malformed')"
assert_eq "search/injected-fp-never-reaches-jql" "false" "$(q "JSON.stringify(o.findings).includes('SECRET')")"
new_vault "$JIRA"
line d1 c1 >"$QUEUE"
run done brain-fp-d1
[[ -e "$QUEUE" ]] && fail "done/empty-deletes-file" "queue file still exists" || pass "done/empty-deletes-file"

# --- 6. no tracker / tracker none / empty queue: status, exit 0, no payloads ----
echo "--- 6. states ---"
new_vault
line e1 c1 >"$QUEUE"
run plan
assert_eq "state/no-tracker" "no-tracker:0:undefined" "$(q 'o.state')":"$STATUS":"$(q 'String(o.actions)')"
new_vault '{"type": "none"}'
line e1 c1 >"$QUEUE"
run search
assert_eq "state/none" "none" "$(q 'o.state')"
new_vault "$JIRA"
run plan
assert_eq "state/empty" "empty" "$(q 'o.state')"

# --- 7. negative control: a payload without the label set or version line fails
echo "--- 7. negative control ---"
new_vault "$JIRA"
line aaa111 mis-scoped-graph 0.24.2 >"$QUEUE"
sed -e "s/\[\.\.\.LABELS, f\.fingerprint\]/[f.fingerprint]/" -e "/Plugin version: \${v(f.plugin_version)}\`,/d" "$DF" >"$TMPROOT/broken.mjs"
BRAIN_ROOT="$VAULT" node "$TMPROOT/broken.mjs" plan >"$TMPROOT/out.json" 2>/dev/null
assert_eq "negative/labels-would-be-caught" "false" "$(q "o.actions[0].labels.includes('brain-plugin')")"
assert_eq "negative/version-would-be-caught" "false" "$(q "o.actions[0].description.includes('Plugin version:')")"

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
