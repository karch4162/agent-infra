#!/usr/bin/env bash
# test-verify-findings.sh — gate for brain/bin/verify-findings.mjs (INNOV-371).
#
# Contract under test:
#   - record writes one record per judged item (blob, date, pr, subtype, drift)
#   - queue carries a recorded item whose note is unchanged: not counted
#     against --max, flagged "carried"
#   - an edited note is re-queued (negative control for the carry-over)
#   - CRLF→LF re-encoding alone does not invalidate (blob is LF-normalized)
#   - a record past --ttl-days is re-queued
#   - invalid verdicts refuse the whole batch and write nothing
#   - prior records whose item left the queue are pruned; this run's are kept
#   - logs/ (where the file lives) is on the template .saveinclude
#   - the dead-link brief searches community stubs by old members (INNOV-402)
#
# Run:  bash tests/test-verify-findings.sh   (from anywhere; needs node)
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
FRESH="$REPO_ROOT/brain/bin/freshness.mjs"
VF="$REPO_ROOT/brain/bin/verify-findings.mjs"

PASSED=0
FAILED=0
TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT
pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }
fail() {
  FAILED=$((FAILED + 1)); echo "FAIL $1"; shift
  local line; for line in "$@"; do echo "     $line"; done
}
check() { # check <name> <cond-exit> <detail>
  if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "$3"; fi
}

VAULT="$TMPROOT/vault"
mkdir -p "$VAULT/wiki"
FIND="$VAULT/logs/verify-findings.json"
note() { # note <name> <crlf:0|1> <last_verified> <confidence> <body>
  local nl='\n'; [[ "$2" == 1 ]] && nl='\r\n'
  printf -- "---${nl}id: $1${nl}tags: [x, y]${nl}last_verified: $3${nl}confidence: $4${nl}---${nl}# $1${nl}$5${nl}" >"$VAULT/wiki/$1.md"
}
note a 0 2020-01-01 medium 'Retry limit is 3.'
note b 1 2020-06-01 medium 'CRLF claim.'
note c 0 2099-01-01 low 'Low confidence only.'
note d 0 2099-01-01 medium 'See [[Gone Target]].'

scan() { BRAIN_ROOT="$VAULT" node "$FRESH" --json >"$TMPROOT/scan.json" 2>/dev/null; }
queue() { BRAIN_ROOT="$VAULT" node "$VF" queue "$TMPROOT/scan.json" "$@" >"$TMPROOT/q.txt" 2>"$TMPROOT/q.err"; }
# qcount <carried|work> [note] → number of queue lines
qcount() {
  node -e 'const [f,want,note]=process.argv.slice(1);
    const l=require("fs").readFileSync(f,"utf8").split("\n").filter(Boolean).map(JSON.parse)
      .filter(x=>(want==="carried")===!!x.carried).filter(x=>!note||x.note===note);
    process.stdout.write(String(l.length))' "$TMPROOT/q.txt" "$1" "${2:-}" 2>/dev/null || echo ERR
}
record() { BRAIN_ROOT="$VAULT" node "$VF" record "$TMPROOT/scan.json" "$TMPROOT/v.jsonl" "$@" >"$TMPROOT/r.txt" 2>&1; }
field() { # field <note> <expr on record r> → value
  node -e 'const [f,n,e]=process.argv.slice(1);
    const r=JSON.parse(require("fs").readFileSync(f,"utf8")).find(x=>x.note===n);
    process.stdout.write(String(r===undefined?"MISSING":eval(e)))' "$FIND" "$1" "$2" 2>/dev/null || echo ERR
}

# --- 1. empty store: nothing carried, --max slices work ----------------------
scan; queue --max 2
check "queue/no-store-work" "$([[ "$(qcount work)" == 2 && "$(qcount carried)" == 0 ]]; echo $?)" "q: [$(cat "$TMPROOT/q.txt" "$TMPROOT/q.err")]"
queue
check "queue/dead-link-first" "$([[ "$(head -1 "$TMPROOT/q.txt")" == *'"kind":"dead-link"'* ]]; echo $?)" "first: [$(head -1 "$TMPROOT/q.txt")]"

# --- 2. invalid verdicts refuse the batch -------------------------------------
printf '%s\n' '{"note":"wiki/a.md","kind":"claim","verdict":"cannot-tell","reason":"no subtype"}' >"$TMPROOT/v.jsonl"
record; rc=$?
check "record/refuses-missing-subtype" "$([[ $rc -ne 0 && ! -e "$FIND" ]]; echo $?)" "rc=$rc out: [$(cat "$TMPROOT/r.txt")]"
printf '%s\n' '{"note":"wiki/a.md","kind":"claim","verdict":"cannot-tell","subtype":"line-drift","reason":"moved"}' >"$TMPROOT/v.jsonl"
record; rc=$?
check "record/refuses-drift-without-pairs" "$([[ $rc -ne 0 && ! -e "$FIND" ]]; echo $?)" "rc=$rc out: [$(cat "$TMPROOT/r.txt")]"

printf '%s
' '{"note":"wiki/../../outside.md","kind":"dead-link","target":"x","verdict":"none","reason":"escape"}' >"$TMPROOT/v.jsonl"
printf 'x
' >"$TMPROOT/outside.md"
record; rc=$?
check "record/refuses-path-escape" "$([[ $rc -ne 0 && ! -e "$FIND" ]]; echo $?)" "rc=$rc out: [$(cat "$TMPROOT/r.txt")]"

printf '%s
' '{"note":"wiki/d.md","kind":"dead-link","target":"Gone Target","verdict":"draft","reason":"no replacement named"}' >"$TMPROOT/v.jsonl"
record; rc=$?
check "record/refuses-draft-without-replacement" "$([[ $rc -ne 0 && ! -e "$FIND" ]]; echo $?)" "rc=$rc out: [$(cat "$TMPROOT/r.txt")]"

# --- 3. record one per judged item --------------------------------------------
cat >"$TMPROOT/v.jsonl" <<'EOF'
{"note":"wiki/a.md","kind":"claim","verdict":"cannot-tell","subtype":"line-drift","drift":[{"old":"src/x.ts:10","new":"src/x.ts:14"}],"reason":"LINE DRIFT: moved","evidence":{"refs":["repo/src/x.ts:14"],"branch":"main","sha":"abc1234"}}
{"note":"wiki/b.md","kind":"claim","verdict":"cannot-tell","subtype":"anchor-unverifiable","reason":"repo foo not checked out"}
{"note":"wiki/d.md","kind":"dead-link","target":"Gone Target","verdict":"none","reason":"no candidate"}
EOF
record --pr 42; rc=$?
check "record/writes" "$([[ $rc -eq 0 && "$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).length))' "$FIND")" == 3 ]]; echo $?)" "rc=$rc out: [$(cat "$TMPROOT/r.txt")]"
check "record/fields" "$([[ "$(field wiki/a.md 'r.pr+"|"+r.subtype+"|"+r.drift[0].new+"|"+r.evidence.sha+"|"+r.blob.length')" == '42|line-drift|src/x.ts:14|abc1234|40' ]]; echo $?)" "got: [$(field wiki/a.md 'JSON.stringify(r)')]"
check "record/dead-link-target" "$([[ "$(field wiki/d.md 'r.target+"|"+r.verdict')" == 'Gone Target|none' ]]; echo $?)" "got: [$(field wiki/d.md 'JSON.stringify(r)')]"

cp "$FIND" "$TMPROOT/before.json"
printf '%s
' '{"note":"wiki/c.md","kind":"claim","verdict":"holds","reason":"ok"}' '{"note":"wiki/a.md","kind":"claim","verdict":"maybe","reason":"bad"}' >"$TMPROOT/v.jsonl"
record; rc=$?
check "record/refusal-keeps-store" "$([[ $rc -ne 0 ]] && cmp -s "$FIND" "$TMPROOT/before.json"; echo $?)" "rc=$rc out: [$(cat "$TMPROOT/r.txt")]"

# --- 4. second run: judged items carried, --max spent on new ones only --------
scan; queue --max 1
check "queue/carries-judged" "$([[ "$(qcount carried)" == 3 && "$(qcount work)" == 1 && "$(qcount work wiki/c.md)" == 1 ]]; echo $?)" "q: [$(cat "$TMPROOT/q.txt")]"
check "queue/carried-verdict" "$(grep -q '"carried":{"verdict":"cannot-tell","subtype":"anchor-unverifiable"' "$TMPROOT/q.txt"; echo $?)" "q: [$(cat "$TMPROOT/q.txt")]"

# --- 5. CRLF→LF alone keeps the verdict; a real edit drops it -----------------
node -e 'const f=process.argv[1],fs=require("fs");fs.writeFileSync(f,fs.readFileSync(f,"utf8").replace(/\r\n/g,"\n"))' "$VAULT/wiki/b.md"
scan; queue
check "queue/crlf-reencode-still-carried" "$([[ "$(qcount carried wiki/b.md)" == 1 ]]; echo $?)" "q: [$(cat "$TMPROOT/q.txt")]"
note b 1 2020-06-01 medium 'CRLF claim, edited.'
scan; queue
check "queue/edited-note-requeued" "$([[ "$(qcount work wiki/b.md)" == 1 && "$(qcount carried wiki/b.md)" == 0 ]]; echo $?)" "q: [$(cat "$TMPROOT/q.txt")]"

# --- 6. TTL ------------------------------------------------------------------
node -e 'const f=process.argv[1],fs=require("fs");const a=JSON.parse(fs.readFileSync(f,"utf8"));
  a.find(r=>r.note==="wiki/d.md").date="2000-01-01";fs.writeFileSync(f,JSON.stringify(a))' "$FIND"
queue
check "queue/expired-requeued" "$([[ "$(qcount work wiki/d.md)" == 1 ]]; echo $?)" "q: [$(cat "$TMPROOT/q.txt")]"
queue --ttl-days 100000
check "queue/ttl-flag" "$([[ "$(qcount carried wiki/d.md)" == 1 ]]; echo $?)" "q: [$(cat "$TMPROOT/q.txt")]"

# --- 7. prune: an item that left the queue loses its prior record -------------
note a 0 2099-01-01 medium 'Retry limit is 3.'   # "bumped": no longer stale
scan
printf '%s\n' '{"note":"wiki/c.md","kind":"claim","verdict":"holds","reason":"repo/src/y.ts:3","evidence":{"refs":["repo/src/y.ts:3"],"branch":"main","sha":"def5678"}}' >"$TMPROOT/v.jsonl"
note c 0 2099-01-01 medium 'Low confidence only.'  # applied: low → medium
scan; record; rc=$?
check "record/prunes-applied" "$([[ $rc -eq 0 && "$(field wiki/a.md 'r')" == MISSING ]]; echo $?)" "a: [$(field wiki/a.md 'JSON.stringify(r)')]"
check "record/keeps-this-run" "$([[ "$(field wiki/c.md 'r.verdict+"|"+r.pr')" == 'holds|null' ]]; echo $?)" "c: [$(field wiki/c.md 'JSON.stringify(r)')]"
check "record/keeps-still-queued" "$([[ "$(field wiki/d.md 'r.verdict')" == none ]]; echo $?)" "d: [$(field wiki/d.md 'JSON.stringify(r)')]"

printf '%s
' '{"note":"wiki/d.md","kind":"dead-link","target":"Gone Target","verdict":"draft","replacement":"gone-target-draft","reason":"only a draft"}' >"$TMPROOT/v.jsonl"
record
check "record/keeps-replacement" "$([[ "$(field wiki/d.md 'r.verdict+"|"+r.replacement')" == 'draft|gone-target-draft' ]]; echo $?)" "d: [$(field wiki/d.md 'JSON.stringify(r)')]"

# --- 7b. a dead-link verdict is keyed on the target side too (INNOV-398) ------
# A relabel regenerates community stubs without touching the linking note; a
# stored `none` must be re-judged, not carried. Stub written CRLF (vault is autocrlf).
printf '%s\n' '{"note":"wiki/d.md","kind":"dead-link","target":"Gone Target","verdict":"none","reason":"no candidate"}' \
  '{"note":"wiki/b.md","kind":"claim","verdict":"cannot-tell","subtype":"anchor-unverifiable","reason":"repo foo not checked out"}' >"$TMPROOT/v.jsonl"
record
scan; queue
check "queue/dead-link-carried-unchanged" "$([[ "$(qcount carried wiki/d.md)" == 1 ]]; echo $?)" "q: [$(cat "$TMPROOT/q.txt")]"
mkdir -p "$VAULT/graphify/r/communities"
printf -- '---\r\naliases:\r\n  - _COMMUNITY_Gone Target\r\n---\r\n# stub\r\n' >"$VAULT/graphify/r/communities/_COMMUNITY_Old Name.md"
queue
check "queue/relabel-requeues-dead-link" "$([[ "$(qcount work wiki/d.md)" == 1 && "$(qcount carried wiki/d.md)" == 0 ]]; echo $?)" "q: [$(cat "$TMPROOT/q.txt")]"
check "queue/relabel-keeps-claims-carried" "$([[ "$(qcount carried wiki/b.md)" == 1 ]]; echo $?)" "q: [$(cat "$TMPROOT/q.txt")]"
record
queue
check "queue/rejudged-dead-link-carried" "$([[ "$(qcount carried wiki/d.md)" == 1 ]]; echo $?)" "q: [$(cat "$TMPROOT/q.txt")]"
# An alias-only change (rename-protected stub, same filename) also re-queues.
printf -- '---\r\naliases:\r\n  - _COMMUNITY_Other Label\r\n---\r\n# stub\r\n' >"$VAULT/graphify/r/communities/_COMMUNITY_Old Name.md"
queue
check "queue/alias-change-requeues-dead-link" "$([[ "$(qcount work wiki/d.md)" == 1 ]]; echo $?)" "q: [$(cat "$TMPROOT/q.txt")]"

# --- 7c. the dead-link brief searches community stubs (INNOV-402) ------------
# A dead [[_COMMUNITY_*]] link has no stub by name or alias, so only the old
# stub's members can point at its relabeled successor. Without this the
# subagent searches wiki/ alone and every stub link comes back `none`.
BRIEF="$(grep -F '**Dead link:**' "$REPO_ROOT/brain/skills/verify/SKILL.md" | tr -d '\r')"
for want in 'graphify/*/communities' 'members:' 'stub basename as `replacement`'; do
  check "skill/dead-link-brief-has:$want" "$([[ "$BRIEF" == *"$want"* ]]; echo $?)" "verify/SKILL.md dead-link brief must carry: $want"
done

# --- 8. the file is on the save path ------------------------------------------
check "saveinclude/logs" "$(grep -qx 'logs/' "$REPO_ROOT/brain/templates/saveinclude"; echo $?)" "logs/ missing from brain/templates/saveinclude"

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
