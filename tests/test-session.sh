#!/usr/bin/env bash
# test-session.sh — deterministic quality gate for brain/bin/session.sh
#
# session.sh is the START-of-command half of INNOV-275. On 2026-08-05 two agent
# sessions shared one vault checkout: session B ran /brain:init, a PR merged, HEAD
# moved to `main` underneath session A, and session A committed onto protected
# `main` believing it was on its feature branch. PR 1 (vault-commit.sh) made the
# commit refuse. This is the other end: pick a committable branch BEFORE the work,
# notice the other session while it is still cheap, and hand the caller the pin
# that vault-commit.sh checks.
#
# Contract under test:
#   exit 0, stdout line 1 `SESSION: OK - ...`      => proceed
#   exit 0, stdout line 1 `SESSION: WARN - ...`    => proceed, a concurrent session exists
#   exit 1, stderr line 1 `SESSION: REFUSED - ...` => stop
#   on a successful --start (OK *or* WARN) stdout line 2 is exactly `  pin: <branch>:<sha>`
#   vault resolved from $BRAIN_ROOT -> $CLAUDE_PROJECT_DIR -> $PWD
#
# The refusals:
#   protected branch + another live session — REFUSED. `git checkout -b` switches
#       the branch for EVERY session in the working tree, so auto-creating here
#       would reproduce the incident using its own fix.
#   detached HEAD                           — REFUSED; no branch to record.
#   not a vault / not a git repo / no .saveinclude — REFUSED at start rather than
#       letting the command do an hour of work it can never commit.
# And the one thing that is deliberately NOT a refusal:
#   a corrupt session.json — WARN and proceed. A broken machine-local state file
#       must never wedge every command in the vault.
#
# IDENTITY NOTE — AND THE BUG THIS SUITE ONCE MISSED. session.sh used to call
# "this session" $PPID. Under the Claude Code harness every Bash tool call is a
# detached shell reparented to init, so $PPID is 1 for EVERY call of EVERY session:
# two different agent sessions both recorded pid 1, each read the other's record as
# its own, and the protected-branch REFUSAL — the entire point of INNOV-275 ask 4 —
# was dead code in the only runtime that matters.
#
# This suite passed anyway, because every case forged its foreign records by hand
# with synthetic, distinct pids. A test that CONSTRUCTS the identity it is testing
# cannot detect that the identity SOURCE is degenerate. So:
#   - identity is now driven through the real env var, $BRAIN_SESSION_ID, exactly as
#     a caller supplies it (section J), and the forged-record cases are kept only
#     for the record-parsing and liveness rules they actually test;
#   - BRAIN_SESSION_ID and CLAUDE_CODE_SESSION_ID are unset below, because this
#     suite RUNS INSIDE the harness — inheriting the ambient CLAUDE_CODE_SESSION_ID
#     would give every case the same identity and reintroduce the very collapse
#     under test;
#   - run_session passes the id explicitly ($SID), and run_session_noid runs with
#     BOTH vars unset, which is the degraded fallback path.
#
# Run:  bash tests/test-session.sh   (from anywhere)
# No network, no sleeping (BRAIN_SESSION_STALE_SECS forces the staleness branch).
# Real git repos in mktemp sandboxes; `gh` is a stub on PATH.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SESSION="$REPO_ROOT/brain/bin/session.sh"
VAULT_COMMIT="$REPO_ROOT/brain/bin/vault-commit.sh"

unset CLAUDE_PROJECT_DIR
unset BRAIN_SESSION_STALE_SECS
# See IDENTITY NOTE: this suite runs inside the harness, where
# CLAUDE_CODE_SESSION_ID is ambient. Leaving it set would silently give every case
# below the same identity — the exact defect this file now guards.
unset BRAIN_SESSION_ID
unset CLAUDE_CODE_SESSION_ID

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
LIVE_PID=""
cleanup() {
  [[ -n "$LIVE_PID" ]] && kill "$LIVE_PID" 2>/dev/null
  chmod -R u+rwX "$TMPROOT" 2>/dev/null || true
  rm -rf "$TMPROOT" 2>/dev/null || true
}
trap cleanup EXIT

# A genuinely running process to impersonate "the other session" with. A made-up
# pid would be fine on Windows (where nothing can prove a pid gone) but provably
# dead on Linux, so the foreign-session cases would stop testing anything there.
sleep 3600 &
LIVE_PID=$!

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
  if [[ "$exp" == "$act" ]]; then pass "$name"
  else fail "$name" "expected: [$exp]" "actual:   [$act]" "$@"; fi
}

assert_ne() { # name not-expected actual [evidence...]
  local name="$1" nexp="$2" act="$3"
  shift 3
  if [[ "$nexp" != "$act" ]]; then pass "$name"
  else fail "$name" "expected anything BUT: [$nexp]" "actual: [$act]" "$@"; fi
}

assert_prefix() { # name prefix actual [evidence...]
  local name="$1" pre="$2" act="$3"
  shift 3
  if [[ "$act" == "$pre"* ]]; then pass "$name"
  else fail "$name" "expected line starting with: [$pre]" "actual line:                [$act]" "$@"; fi
}

assert_contains() { # name needle haystack [evidence...]
  local name="$1" needle="$2" hay="$3"
  shift 3
  if [[ "$hay" == *"$needle"* ]]; then pass "$name"
  else fail "$name" "expected to contain: [$needle]" "actual:              [$hay]" "$@"; fi
}

assert_not_contains() { # name needle haystack [evidence...]
  local name="$1" needle="$2" hay="$3"
  shift 3
  if [[ "$hay" != *"$needle"* ]]; then pass "$name"
  else fail "$name" "expected NOT to contain: [$needle]" "actual:                  [$hay]" "$@"; fi
}

nth_line() { head -n "$2" "$1" 2>/dev/null | tail -n 1 | tr -d '\r'; }
first_line() { nth_line "$1" 1; }

evidence() {
  echo "exit:   [$STATUS]"
  echo "stdout: [$(tr '\n' '|' <"$BOX/out.txt" 2>/dev/null)]"
  echo "stderr: [$(tr '\n' '|' <"$BOX/err.txt" 2>/dev/null)]"
}

# ------------------------------------------------------------ gh stubs -----
# `gh` is a safety net for default-branch detection, never a dependency.
GH_NONE="$TMPROOT/gh-none"
GH_NOPR="$TMPROOT/gh-nopr"
mkdir -p "$GH_NONE" "$GH_NOPR"
cat >"$GH_NOPR/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  pr)   echo "" ;;
  repo) echo "" ;;
  *)    exit 1 ;;
esac
exit 0
SH
chmod +x "$GH_NOPR/gh"

# ------------------------------------------------------------ sandboxing ---
# Assigns the globals BOX / VAULT. Deliberately NOT run in a command substitution
# — the assignments would be lost and state would leak between cases.
BOX=""
VAULT=""

sb_new() { # [branch]
  local branch="${1:-brain/work}"
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  mkdir -p "$VAULT/wiki" "$VAULT/logs" "$VAULT/graphify/alpha"
  printf 'logs/\nwiki/hot.md\nwiki/log.md\ngraphify/\n' >"$VAULT/.saveinclude"
  echo "hot" >"$VAULT/wiki/hot.md"
  echo "log" >"$VAULT/wiki/log.md"
  git -C "$VAULT" init -q -b main >/dev/null 2>&1
  git -C "$VAULT" config user.email t@example.com
  git -C "$VAULT" config user.name "T"
  git -C "$VAULT" config commit.gpgsign false
  git -C "$VAULT" add -A >/dev/null 2>&1
  git -C "$VAULT" commit -qm "initial vault" >/dev/null 2>&1
  [[ "$branch" == "main" ]] || git -C "$VAULT" checkout -q -B "$branch" >/dev/null 2>&1
}

STATE() { echo "$VAULT/.brain/session.json"; }
state_text() { tr '\n' ' ' <"$(STATE)" 2>/dev/null; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
today() { date -u +%F; }

THIS_HOST="$( { hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown; } | tr -d '[:space:]' )"

# Writes a session.json holding exactly one foreign record. Used only where the
# thing under test is record PARSING or LIVENESS — never to establish identity,
# which section J drives through the env var instead.
FOREIGN_SID="sess-other"
forge_session() { # session_id branch sha started_at command [pid]
  mkdir -p "$VAULT/.brain"
  printf '[\n  {"session_id": "%s", "pid": %s, "host": "%s", "branch": "%s", "sha": "%s", "started_at": "%s", "command": "%s"}\n]\n' \
    "$1" "${6:-$LIVE_PID}" "$THIS_HOST" "$2" "$3" "$4" "$5" >"$VAULT/.brain/session.json"
}

# A record in the PRE-IDENTITY shape: a bare pid, no session_id, no host.
forge_legacy_session() { # pid branch sha started_at command
  mkdir -p "$VAULT/.brain"
  printf '[\n  {"pid": %s, "branch": "%s", "sha": "%s", "started_at": "%s", "command": "%s"}\n]\n' \
    "$1" "$2" "$3" "$4" "$5" >"$VAULT/.brain/session.json"
}

cur_branch() { git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null || true; }
head_sha()   { git -C "$VAULT" rev-parse HEAD 2>/dev/null || true; }
make_dirty() { echo "change $RANDOM" >>"$VAULT/wiki/log.md"; }

STATUS=""
GH_PATH=""
STALE_ENV=""
# The identity every run_session call presents. A session is an ID, not a process:
# the test does not need separate shells to be a separate session, and separate
# shells would NOT make it one.
SID="sess-A"

# Runs session.sh under the identity $SID.
run_session() { # [args...]
  local saved_path="$PATH"
  [[ -n "$GH_PATH" ]] && PATH="$GH_PATH:$PATH"
  BRAIN_ROOT="$VAULT" BRAIN_SESSION_STALE_SECS="${STALE_ENV:-3600}" \
    BRAIN_SESSION_ID="$SID" \
    bash "$SESSION" "$@" >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
  PATH="$saved_path"
}

# Runs session.sh with NO identity in the environment at all — the degraded
# fallback. Both vars are explicitly emptied rather than merely unexported, because
# an empty value must be treated the same as an unset one.
run_session_noid() { # [args...]
  local saved_path="$PATH"
  [[ -n "$GH_PATH" ]] && PATH="$GH_PATH:$PATH"
  BRAIN_ROOT="$VAULT" BRAIN_SESSION_STALE_SECS="${STALE_ENV:-3600}" \
    BRAIN_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" \
    bash "$SESSION" "$@" >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
  PATH="$saved_path"
}

# The session_id recorded by the most recent --start, read back out of the record.
recorded_id() { sed -n 's/.*"session_id": "\([^"]*\)".*/\1/p' "$(STATE)" 2>/dev/null | head -n 1; }

# Runs the PR-1 commit guard, so the pin can be shown to round-trip end to end.
CSTATUS=""
run_commit() { # [args...]
  local saved_path="$PATH"
  [[ -n "$GH_PATH" ]] && PATH="$GH_PATH:$PATH"
  BRAIN_ROOT="$VAULT" bash "$VAULT_COMMIT" "$@" >"$BOX/cout.txt" 2>"$BOX/cerr.txt"
  CSTATUS=$?
  PATH="$saved_path"
}

out_all() { cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | tr '\n' ' ' | tr -d '\r'; }
printed_pin() { sed -n 's/^  pin: //p' "$BOX/out.txt" 2>/dev/null | head -n 1 | tr -d '\r'; }

if [[ ! -f "$SESSION" ]]; then
  echo "note: $SESSION does not exist yet — every case below is expected to FAIL until it lands."
fi

echo "--- A. --start on a working branch: the ordinary case ---"

# --- 1. a fresh vault on a feature branch just registers -------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
sha="$(head_sha)"
run_session --start brain:save
assert_eq "start/feature-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "start/feature-verdict-OK" "SESSION: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_eq "start/feature-pin-line-is-line-2" "  pin: brain/work:$sha" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"
assert_eq "start/feature-branch-unchanged" "brain/work" "$(cur_branch)" "$(evidence)"
assert_contains "start/feature-record-written" "\"branch\": \"brain/work\"" "$(state_text)" "$(evidence)"
assert_contains "start/feature-records-the-command" "brain:save" "$(state_text)" "$(evidence)"
assert_eq "start/exactly-one-verdict-line" "1" \
  "$(cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -c '^SESSION: ' || true)" "$(evidence)"
assert_eq "start/success-stderr-carries-no-verdict" "0" \
  "$(grep -c '^SESSION: ' "$BOX/err.txt" 2>/dev/null || true)" "$(evidence)"

echo "--- B. --start on a protected branch, alone: create the branch ---"

# --- 2. main, no other session => branch auto-created, pin names the NEW one --
# This is ask 4 of INNOV-275, and it belongs at command START: the work must be on
# a committable branch from the first file write, not discovered at commit time.
sb_new "main"
GH_PATH="$GH_NONE"
sha="$(head_sha)"
run_session --start save
assert_eq "autobranch/exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "autobranch/verdict-OK" "SESSION: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_eq "autobranch/branch-created-and-checked-out" "brain/save-$(today)" "$(cur_branch)" "$(evidence)"
assert_contains "autobranch/OK-names-the-created-branch" "brain/save-$(today)" "$(first_line "$BOX/out.txt")" "$(evidence)"
# The pin MUST be the new branch. Pinning the branch we were on before the
# checkout would make vault-commit.sh refuse this session's own first commit.
assert_eq "autobranch/pin-is-the-NEW-branch" "  pin: brain/save-$(today):$sha" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"
assert_contains "autobranch/record-holds-the-new-branch" "\"branch\": \"brain/save-$(today)\"" "$(state_text)" "$(evidence)"

# --- 3. master is protected too, with no remote and no gh -----------------
# The literal-name safety net, not a detection result: a vault with no origin and
# no gh must still refuse to work directly on master.
sb_new "master"
GH_PATH="$GH_NONE"
run_session --start save
assert_eq "autobranch/master-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "autobranch/master-was-left" "brain/save-$(today)" "$(cur_branch)" "$(evidence)"

# --- 4. gh present but silent must not change the verdict -----------------
sb_new "main"
GH_PATH="$GH_NOPR"
run_session --start save
assert_eq "autobranch/with-gh-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "autobranch/with-gh-branch-created" "brain/save-$(today)" "$(cur_branch)" "$(evidence)"

# --- 5. a name collision gets a -2 suffix, never a failure ----------------
# Two saves on the same day in the same vault is normal, not an error.
sb_new "main"
GH_PATH="$GH_NONE"
git -C "$VAULT" branch "brain/save-$(today)" >/dev/null 2>&1
run_session --start save
assert_eq "autobranch/collision-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "autobranch/collision-suffixed" "brain/save-$(today)-2" "$(cur_branch)" "$(evidence)"
assert_eq "autobranch/collision-pin-matches" "  pin: brain/save-$(today)-2:$(head_sha)" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"

# --- 6. ...and again for -3 ------------------------------------------------
sb_new "main"
GH_PATH="$GH_NONE"
git -C "$VAULT" branch "brain/save-$(today)" >/dev/null 2>&1
git -C "$VAULT" branch "brain/save-$(today)-2" >/dev/null 2>&1
run_session --start save
assert_eq "autobranch/second-collision-suffixed" "brain/save-$(today)-3" "$(cur_branch)" "$(evidence)"

# --- 6b. a name taken on the REMOTE is a collision too (INNOV-333) ---------
# Another author's open PR branch exists only as origin/brain/save-<date>. Reusing
# the name sent a push onto their PR branch and merged the wrong save (INNOV-313).
# Case 2 is the negative control: with no ref at all the bare name is used.
sb_new "main"
GH_PATH="$GH_NONE"
git -C "$VAULT" update-ref "refs/remotes/origin/brain/save-$(today)" "$(head_sha)"
run_session --start save
assert_eq "autobranch/remote-collision-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "autobranch/remote-collision-suffixed" "brain/save-$(today)-2" "$(cur_branch)" "$(evidence)"
assert_eq "autobranch/remote-collision-pin-matches" "  pin: brain/save-$(today)-2:$(head_sha)" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"

# --- 6c. ...even when this checkout never fetched it (INNOV-410) -----------
# /brain:save starts its session before check-freshness fetches, so the other
# author's branch is on origin but not in refs/remotes yet. The name must still be
# taken. Negative control: the same origin without that branch keeps the bare name.
sb_new "main"
GH_PATH="$GH_NONE"
git clone -q --bare "$VAULT" "$BOX/origin.git" >/dev/null 2>&1
git -C "$VAULT" remote add origin "$BOX/origin.git"
run_session --start save
assert_eq "autobranch/unfetched-origin-free-name-kept" "brain/save-$(today)" "$(cur_branch)" "$(evidence)"
sb_new "main"
GH_PATH="$GH_NONE"
git clone -q --bare "$VAULT" "$BOX/origin.git" >/dev/null 2>&1
git -C "$BOX/origin.git" branch "brain/save-$(today)" main >/dev/null 2>&1
git -C "$VAULT" remote add origin "$BOX/origin.git"
run_session --start save
assert_eq "autobranch/unfetched-origin-collision-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "autobranch/unfetched-origin-collision-suffixed" "brain/save-$(today)-2" "$(cur_branch)" "$(evidence)"
assert_eq "autobranch/unfetched-origin-refs-untouched" "" \
  "$(git -C "$VAULT" for-each-ref refs/remotes 2>/dev/null)" "$(evidence)"

echo "--- C. concurrency: the 2026-08-05 incident ---"

# --- 7. protected branch + a live foreign session => REFUSE ---------------
# `git checkout -b` moves HEAD for EVERY session sharing the working tree. Doing it
# while somebody else works reproduces the incident using its own fix.
sb_new "main"
GH_PATH="$GH_NONE"
forge_session "$FOREIGN_SID" "brain/other-work" "$(head_sha)" "$(now_iso)" "brain:init"
run_session --start save
assert_eq "concurrent/protected-refused-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "concurrent/protected-verdict-on-stderr" "SESSION: REFUSED" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_eq "concurrent/protected-stdout-carries-no-verdict" "0" \
  "$(grep -c '^SESSION: ' "$BOX/out.txt" 2>/dev/null || true)" "$(evidence)"
assert_contains "concurrent/names-the-other-branch" "brain/other-work" "$(out_all)" "$(evidence)"
assert_contains "concurrent/names-the-other-session" "$FOREIGN_SID" "$(out_all)" "$(evidence)"
assert_contains "concurrent/explains-checkout-is-global" "EVERY session" "$(out_all)" "$(evidence)"
assert_contains "concurrent/offers-the-worktree-remedy" "worktree" "$(out_all)" "$(evidence)"
# THE mutation assertion: a refusal must not have switched the shared branch.
assert_eq "concurrent/branch-NOT-switched" "main" "$(cur_branch)" "$(evidence)"
assert_not_contains "concurrent/no-record-registered-for-us" "\"session_id\": \"$SID\"" "$(state_text)" "$(evidence)"
assert_contains "concurrent/other-session-record-preserved" "brain/other-work" "$(state_text)" "$(evidence)"

# --- 8. feature branch + a live foreign session => WARN, and proceed ------
# Nothing needs to move, so there is nothing to refuse — but the caller must be
# told, because the index and HEAD it is about to use are shared.
sb_new "brain/work"
GH_PATH="$GH_NONE"
sha="$(head_sha)"
forge_session "$FOREIGN_SID" "brain/other-work" "$sha" "$(now_iso)" "brain:init"
run_session --start save
assert_eq "concurrent/feature-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "concurrent/feature-verdict-WARN" "SESSION: WARN" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "concurrent/feature-names-the-other-branch" "brain/other-work" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "concurrent/feature-names-the-other-session" "$FOREIGN_SID" "$(first_line "$BOX/out.txt")" "$(evidence)"
# WARN is a success, so the pin line is still line 2 — a caller must be able to
# read it without first branching on the verdict.
assert_eq "concurrent/feature-WARN-still-prints-the-pin" "  pin: brain/work:$sha" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"
assert_contains "concurrent/feature-both-sessions-registered" "brain/other-work" "$(state_text)" "$(evidence)"
assert_contains "concurrent/feature-our-record-added" "brain/work" "$(state_text)" "$(evidence)"

echo "--- D. liveness: the timestamp is the reaper ---"

# --- 9. a record older than BRAIN_SESSION_STALE_SECS is not a live session --
# The pid below is genuinely alive; only the timestamp makes it stale. That is the
# point: on Git Bash a pid check cannot prove anything, so staleness must decide.
sb_new "main"
GH_PATH="$GH_NONE"
STALE_ENV="60"
forge_session "$FOREIGN_SID" "brain/abandoned" "$(head_sha)" "2020-01-01T00:00:00Z" "brain:save"
run_session --start save
assert_eq "stale/ignored-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "stale/ignored-verdict-OK" "SESSION: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_eq "stale/ignored-branch-created-anyway" "brain/save-$(today)" "$(cur_branch)" "$(evidence)"
# Pruned on write, so the file cannot grow without bound.
assert_not_contains "stale/record-pruned-on-write" "brain/abandoned" "$(state_text)" "$(evidence)"
STALE_ENV=""

# --- 10. the SAME record is live under a large enough window --------------
# Same forged record, same live pid — only BRAIN_SESSION_STALE_SECS differs. Both
# branches of the liveness rule are exercised without sleeping.
sb_new "main"
GH_PATH="$GH_NONE"
STALE_ENV="999999999"
forge_session "$FOREIGN_SID" "brain/abandoned" "$(head_sha)" "2020-01-01T00:00:00Z" "brain:save"
run_session --start save
assert_eq "stale/fresh-window-refuses" "1" "$STATUS" "$(evidence)"
assert_eq "stale/fresh-window-branch-not-switched" "main" "$(cur_branch)" "$(evidence)"
STALE_ENV=""

echo "--- E. --status reports and mutates nothing ---"

# --- 11. --status on a registered vault ------------------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
run_session --start save
before_state="$(cat "$(STATE)" 2>/dev/null)"
before_branch="$(cur_branch)"
before_sha="$(head_sha)"
run_session --status
assert_eq "status/exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "status/verdict-OK" "SESSION: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "status/reports-the-branch" "brain/work" "$(out_all)" "$(evidence)"
assert_eq "status/state-file-byte-identical" "$before_state" "$(cat "$(STATE)" 2>/dev/null)" "$(evidence)"
assert_eq "status/branch-unchanged" "$before_branch" "$(cur_branch)" "$(evidence)"
assert_eq "status/head-unchanged" "$before_sha" "$(head_sha)" "$(evidence)"

# --- 12. --status on a vault that has never had a session creates nothing --
# A read-only question must never be the thing that changes the answer.
sb_new "main"
GH_PATH="$GH_NONE"
run_session --status
assert_eq "status/no-sessions-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "status/creates-no-state-file" "0" "$([[ -e "$(STATE)" ]] && echo 1 || echo 0)" "$(evidence)"
assert_eq "status/does-not-create-dot-brain" "0" "$([[ -d "$VAULT/.brain" ]] && echo 1 || echo 0)" "$(evidence)"
assert_eq "status/does-not-switch-a-protected-branch" "main" "$(cur_branch)" "$(evidence)"

echo "--- F. --end deregisters only this session ---"

# --- 13. --end removes ours and leaves the other one ----------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
forge_session "$FOREIGN_SID" "brain/other-work" "$(head_sha)" "$(now_iso)" "brain:init"
run_session --start save
assert_contains "end/precondition-our-record-exists" "\"session_id\": \"$SID\"" "$(state_text)" "$(evidence)"
run_session --end
assert_eq "end/exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "end/verdict-OK" "SESSION: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_not_contains "end/our-record-removed" "\"session_id\": \"$SID\"" "$(state_text)" "$(evidence)"
assert_contains "end/other-record-survives" "brain/other-work" "$(state_text)" "$(evidence)"
assert_eq "end/leaves-the-branch-alone" "brain/work" "$(cur_branch)" "$(evidence)"

# --- 14. --end with nothing registered is a no-op, not a failure ----------
sb_new "brain/work"
GH_PATH="$GH_NONE"
run_session --end
assert_eq "end/idempotent-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "end/idempotent-verdict-OK" "SESSION: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"

echo "--- G. a corrupt state file WARNs; it never wedges the vault ---"

# --- 15. unparseable session.json => WARN, and the command proceeds -------
# The file is machine-local and gitignored. Failing closed here would turn one
# broken scratch file into an outage for every command in the vault.
sb_new "brain/work"
GH_PATH="$GH_NONE"
sha="$(head_sha)"
mkdir -p "$VAULT/.brain"
printf '{{{ this is not json at all\n' >"$VAULT/.brain/session.json"
run_session --start save
assert_eq "corrupt/exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "corrupt/verdict-WARN" "SESSION: WARN" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "corrupt/names-the-file" "session.json" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_eq "corrupt/still-prints-the-pin" "  pin: brain/work:$sha" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"
assert_contains "corrupt/file-repaired-by-the-write" "\"branch\": \"brain/work\"" "$(state_text)" "$(evidence)"

# --- 16. a corrupt file on a protected branch still auto-creates ----------
# "Cannot parse" resolves to "no live sessions", so the alone-on-main path applies.
sb_new "main"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/.brain"
printf 'garbage\n' >"$VAULT/.brain/session.json"
run_session --start save
assert_eq "corrupt/protected-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "corrupt/protected-branch-created" "brain/save-$(today)" "$(cur_branch)" "$(evidence)"

# --- 16b. --end on a corrupt file WARNs too, and repairs it ---------------
# The corrupt-file rule is not scoped to --start: every mode says so, and none of
# them fail on it.
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/.brain"
printf 'garbage\n' >"$VAULT/.brain/session.json"
run_session --end
assert_eq "corrupt/end-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "corrupt/end-verdict-WARN" "SESSION: WARN" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "corrupt/end-names-the-file" "session.json" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "corrupt/end-repaired-the-file" "[" "$(state_text)" "$(evidence)"

# --- 16c. --print-pin on a corrupt file refuses, and says why -------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/.brain"
printf 'garbage\n' >"$VAULT/.brain/session.json"
run_session --print-pin
assert_eq "corrupt/print-pin-refused" "1" "$STATUS" "$(evidence)"
assert_contains "corrupt/print-pin-names-the-file" "session.json" "$(out_all)" "$(evidence)"

echo "--- H. preconditions refuse at START, not an hour later ---"

# --- 17. missing .saveinclude => REFUSE -----------------------------------
# vault-commit.sh would refuse every commit in this vault. Saying so before the
# work is strictly friendlier than saying it after.
sb_new "brain/work"
GH_PATH="$GH_NONE"
rm -f "$VAULT/.saveinclude"
run_session --start save
assert_eq "precond/no-saveinclude-refused" "1" "$STATUS" "$(evidence)"
assert_prefix "precond/no-saveinclude-verdict" "SESSION: REFUSED" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_contains "precond/no-saveinclude-names-it" ".saveinclude" "$(out_all)" "$(evidence)"
assert_eq "precond/no-saveinclude-writes-nothing" "0" "$([[ -e "$(STATE)" ]] && echo 1 || echo 0)" "$(evidence)"

# --- 18. not a vault at all => REFUSE, and touch nothing ------------------
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/not-a-vault"
mkdir -p "$VAULT/src"
git -C "$VAULT" init -q -b main >/dev/null 2>&1
git -C "$VAULT" config user.email t@example.com
git -C "$VAULT" config user.name "T"
echo "code" >"$VAULT/src/main.js"
git -C "$VAULT" add -A >/dev/null 2>&1
git -C "$VAULT" commit -qm "some other repo" >/dev/null 2>&1
GH_PATH="$GH_NONE"
run_session --start save
assert_eq "precond/non-vault-refused" "1" "$STATUS" "$(evidence)"
assert_contains "precond/non-vault-explains" "brain vault" "$(out_all)" "$(evidence)"
assert_eq "precond/non-vault-branch-untouched" "main" "$(cur_branch)" "$(evidence)"

# --- 19. a vault that is not a git repo => REFUSE -------------------------
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
printf 'wiki/log.md\n' >"$VAULT/.saveinclude"
echo "log" >"$VAULT/wiki/log.md"
GH_PATH="$GH_NONE"
run_session --start save
assert_eq "precond/non-git-refused" "1" "$STATUS" "$(evidence)"
assert_contains "precond/non-git-explains" "not a git repo" "$(out_all)" "$(evidence)"

# --- 20. detached HEAD => REFUSE ------------------------------------------
# There is no branch to record, and a commit made here is unreachable the moment
# anything else in the shared checkout switches branches.
sb_new "brain/work"
GH_PATH="$GH_NONE"
git -C "$VAULT" checkout -q --detach >/dev/null 2>&1
run_session --start save
assert_eq "precond/detached-refused" "1" "$STATUS" "$(evidence)"
assert_contains "precond/detached-explains" "DETACHED HEAD" "$(out_all)" "$(evidence)"
assert_eq "precond/detached-writes-nothing" "0" "$([[ -e "$(STATE)" ]] && echo 1 || echo 0)" "$(evidence)"

# --- 21. --start without a command name => REFUSE -------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
run_session --start
assert_eq "args/start-needs-a-name" "1" "$STATUS" "$(evidence)"
assert_contains "args/start-needs-a-name-explains" "command" "$(out_all)" "$(evidence)"

# --- 22. an unknown argument is refused, never silently ignored -----------
sb_new "brain/work"
GH_PATH="$GH_NONE"
run_session --no-such-mode
assert_eq "args/unknown-refused" "1" "$STATUS" "$(evidence)"

echo "--- I. --print-pin, and the composition guarantee ---"

# --- 23. --print-pin replays what --start recorded ------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
sha="$(head_sha)"
run_session --start save
run_session --print-pin
assert_eq "print-pin/exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "print-pin/matches-start" "  pin: brain/work:$sha" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"

# --- 24. --print-pin with no session => REFUSE ----------------------------
# The pin is where HEAD was THEN; it cannot be reconstructed afterwards, and
# re-reading HEAD now would defeat the entire guard.
sb_new "brain/work"
GH_PATH="$GH_NONE"
run_session --print-pin
assert_eq "print-pin/no-session-refused" "1" "$STATUS" "$(evidence)"
assert_contains "print-pin/no-session-explains" "--start" "$(out_all)" "$(evidence)"

# --- 25. THE COMPOSITION GUARANTEE: the pin round-trips into vault-commit.sh --
# session.sh decides where the work happens; vault-commit.sh verifies nothing moved
# in between. Neither knows about the other beyond this one string.
sb_new "brain/work"
GH_PATH="$GH_NONE"
run_session --start save
pin="$(printed_pin)"
make_dirty
run_commit -m "save through the session pin" --pin "$pin"
assert_eq "compose/pin-accepted-by-vault-commit" "0" "$CSTATUS" \
  "pin: [$pin]" "commit stdout: [$(tr '\n' '|' <"$BOX/cout.txt")]" "commit stderr: [$(tr '\n' '|' <"$BOX/cerr.txt")]"
assert_prefix "compose/commit-verdict-OK" "VAULT-COMMIT: OK" "$(first_line "$BOX/cout.txt")" \
  "pin: [$pin]"

# --- 26. ...and the SAME pin is refused once HEAD moves -------------------
# The 2026-08-05 shape: another session commits or merges underneath this run.
sb_new "brain/work"
GH_PATH="$GH_NONE"
run_session --start save
pin="$(printed_pin)"
echo "other session" >>"$VAULT/wiki/log.md"          # a concurrent session commits
git -C "$VAULT" add -A >/dev/null 2>&1
git -C "$VAULT" commit -qm "concurrent session commit" >/dev/null 2>&1
moved_sha="$(head_sha)"
make_dirty
run_commit -m "mine" --pin "$pin"
assert_eq "compose/stale-pin-refused" "1" "$CSTATUS" \
  "pin: [$pin]" "commit stderr: [$(tr '\n' '|' <"$BOX/cerr.txt")]"
assert_eq "compose/stale-pin-head-unmoved" "$moved_sha" "$(head_sha)" "pin: [$pin]"

# --- 27. the auto-created branch's pin round-trips too --------------------
# The case that would break if --start pinned the branch it was on BEFORE the
# checkout: the session could never commit its own first change.
sb_new "main"
GH_PATH="$GH_NONE"
run_session --start save
pin="$(printed_pin)"
assert_eq "compose/autobranch-pin-names-new-branch" "brain/save-$(today):$(head_sha)" "$pin" "$(evidence)"
make_dirty
run_commit -m "first commit on the created branch" --pin "$pin"
assert_eq "compose/autobranch-pin-accepted" "0" "$CSTATUS" \
  "pin: [$pin]" "commit stderr: [$(tr '\n' '|' <"$BOX/cerr.txt")]"

echo "--- J. IDENTITY: driven through the env var, never forged ---"
# Everything below establishes "who is this session" the way a real caller does —
# by setting BRAIN_SESSION_ID — and never by hand-writing a record. That is the
# distinction the old suite missed: with identity forged, a degenerate identity
# SOURCE ($PPID, which is 1 for every call in the harness) is invisible.

state_ids() { sed -n 's/.*"session_id": "\([^"]*\)".*/\1/p' "$(STATE)" 2>/dev/null; }
count_records() { state_ids | grep -c . || true; }

# --- 28. two sessions, distinguished ONLY by BRAIN_SESSION_ID, feature branch --
# Session A registers on its branch; session B, differing from A in nothing but the
# id, must see A. Under the old $PPID identity both runs are the same shell, so A
# and B collapsed into one record and B saw nobody.
sb_new "brain/work"
GH_PATH="$GH_NONE"
sha="$(head_sha)"
SID="agent-A"; run_session --start brain:save
assert_eq "identity/A-registers-exit-0" "0" "$STATUS" "$(evidence)"
SID="agent-B"; run_session --start brain:init
assert_eq "identity/B-sees-A-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "identity/B-sees-A-verdict-WARN" "SESSION: WARN" "$(first_line "$BOX/out.txt")" "$(evidence)"
# INNOV-275's acceptance text: the warning must name the other session's BRANCH.
assert_contains "identity/B-warning-names-As-branch" "brain/work" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "identity/B-warning-names-As-command" "brain:save" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "identity/B-warning-names-As-id" "agent-A" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_eq "identity/B-still-prints-the-pin" "  pin: brain/work:$sha" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"
assert_eq "identity/two-distinct-records" "2" "$(count_records)" "state: [$(state_text)]"

# --- 29. THE REFUSAL, reached without forging anything --------------------
# This is the 2026-08-05 shape and the whole reason ask 4 exists. A is live; B
# starts from the protected branch; auto-creating a branch would move HEAD out from
# under A. Under $PPID identity this path was unreachable in the real harness.
sb_new "main"
GH_PATH="$GH_NONE"
SID="agent-A"; run_session --start brain:save
# NB: the command name is slugged into the branch, so 'brain:save' -> 'brain-save'.
assert_eq "identity/A-got-its-own-branch" "brain/brain-save-$(today)" "$(cur_branch)" "$(evidence)"
git -C "$VAULT" checkout -q main >/dev/null 2>&1     # B is looking at main, as A once was
SID="agent-B"; run_session --start brain:init
assert_eq "identity/B-on-main-REFUSED" "1" "$STATUS" "$(evidence)"
assert_prefix "identity/B-refusal-on-stderr" "SESSION: REFUSED" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_contains "identity/refusal-names-As-branch" "brain/brain-save-$(today)" "$(out_all)" "$(evidence)"
assert_contains "identity/refusal-names-As-command" "brain:save" "$(out_all)" "$(evidence)"
assert_contains "identity/refusal-names-As-id" "agent-A" "$(out_all)" "$(evidence)"
# The mutation assertion: a refusal must leave the shared checkout exactly as it was.
assert_eq "identity/refusal-left-HEAD-on-main" "main" "$(cur_branch)" "$(evidence)"
assert_eq "identity/refusal-registered-nothing" "1" "$(count_records)" "state: [$(state_text)]"
assert_eq "identity/refusal-did-not-create-Bs-branch" "" \
  "$(git -C "$VAULT" rev-parse --verify --quiet "refs/heads/brain/brain-init-$(today)" 2>/dev/null || true)" "$(evidence)"

# --- 30. the SAME id twice is ONE session, not two -----------------------
# Re-entrancy. A command that calls --start again (a retry, a nested helper) must
# not refuse itself or warn about itself — the temptation that makes collapsing
# identity look attractive.
sb_new "brain/work"
GH_PATH="$GH_NONE"
SID="agent-A"
run_session --start brain:save
run_session --start brain:save
assert_eq "reentrant/second-start-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "reentrant/second-start-still-OK" "SESSION: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_not_contains "reentrant/no-self-warning" "another session is live" "$(out_all)" "$(evidence)"
assert_eq "reentrant/still-one-record" "1" "$(count_records)" "state: [$(state_text)]"

# --- 31. ...including back on the protected branch -----------------------
# The harsh version: the same session returns to main and starts again. It must NOT
# refuse itself — there is no other session, only itself.
sb_new "main"
GH_PATH="$GH_NONE"
SID="agent-A"
run_session --start save
git -C "$VAULT" checkout -q main >/dev/null 2>&1
run_session --start save
assert_eq "reentrant/protected-not-self-refused" "0" "$STATUS" "$(evidence)"
assert_eq "reentrant/protected-got-a-second-branch" "brain/save-$(today)-2" "$(cur_branch)" "$(evidence)"
assert_eq "reentrant/protected-still-one-record" "1" "$(count_records)" "state: [$(state_text)]"

# --- 32. --end under X leaves Y alone; --print-pin under X is never Y's ---
# Identity collapse made --end delete a stranger's record and --print-pin replay a
# stranger's pin — a save pinned to a branch it never started on.
sb_new "brain/work"
GH_PATH="$GH_NONE"
a_sha="$(head_sha)"
SID="agent-A"; run_session --start brain:save
a_pin="$(printed_pin)"
git -C "$VAULT" checkout -q -B "brain/other" >/dev/null 2>&1   # B works elsewhere in the tree
b_sha="$(head_sha)"
SID="agent-B"; run_session --start brain:init
b_pin="$(printed_pin)"
assert_eq "isolation/A-pin-is-As-branch" "brain/work:$a_sha" "$a_pin" "state: [$(state_text)]"
assert_eq "isolation/B-pin-is-Bs-branch" "brain/other:$b_sha" "$b_pin" "state: [$(state_text)]"
SID="agent-A"; run_session --print-pin
assert_eq "isolation/A-print-pin-replays-As-own" "  pin: $a_pin" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"
assert_not_contains "isolation/A-print-pin-is-not-Bs" "brain/other" "$(out_all)" "$(evidence)"
SID="agent-A"; run_session --end
assert_eq "isolation/A-end-exit-0" "0" "$STATUS" "$(evidence)"
assert_not_contains "isolation/A-record-gone" "agent-A" "$(state_text)" "state: [$(state_text)]"
assert_contains "isolation/B-record-survives-As-end" "agent-B" "$(state_text)" "state: [$(state_text)]"
assert_contains "isolation/B-branch-survives-As-end" "brain/other" "$(state_text)" "state: [$(state_text)]"
SID="agent-B"; run_session --print-pin
assert_eq "isolation/B-pin-intact-after-As-end" "  pin: $b_pin" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"

# --- 33. CLAUDE_CODE_SESSION_ID is honoured when BRAIN_SESSION_ID is absent --
# The var the harness actually supplies. If this stops being read, every session in
# the harness silently falls back to the degraded per-checkout id.
sb_new "brain/work"
GH_PATH="$GH_NONE"
sha="$(head_sha)"
BRAIN_ROOT="$VAULT" CLAUDE_CODE_SESSION_ID="harness-xyz" \
  bash "$SESSION" --start brain:save >"$BOX/out.txt" 2>"$BOX/err.txt"; STATUS=$?
assert_eq "envvar/claude-id-start-exit-0" "0" "$STATUS" "$(evidence)"
assert_contains "envvar/claude-id-recorded" "\"session_id\": \"harness-xyz\"" "$(state_text)" "$(evidence)"
BRAIN_ROOT="$VAULT" CLAUDE_CODE_SESSION_ID="harness-xyz" \
  bash "$SESSION" --print-pin >"$BOX/out.txt" 2>"$BOX/err.txt"; STATUS=$?
assert_eq "envvar/claude-id-print-pin-found" "  pin: brain/work:$sha" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"
# BRAIN_SESSION_ID wins over it, so a test or a human can always take control.
BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="override-me" CLAUDE_CODE_SESSION_ID="harness-xyz" \
  bash "$SESSION" --start brain:init >"$BOX/out.txt" 2>"$BOX/err.txt"; STATUS=$?
assert_contains "envvar/brain-id-overrides-claude-id" "\"session_id\": \"override-me\"" "$(state_text)" "$(evidence)"
assert_contains "envvar/override-sees-the-harness-session" "harness-xyz" "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 34. THE REGRESSION GUARD the old suite lacked -----------------------
# Both vars unset, two --start calls from the SAME shell — hence the same $PPID, the
# same $$, the same everything a process can offer. They must NOT be one session.
# This is precisely the case that made the protected-branch refusal dead code.
sb_new "brain/work"
GH_PATH="$GH_NONE"
run_session_noid --start brain:save
assert_eq "noid/first-start-exit-0" "0" "$STATUS" "$(evidence)"
first_id="$(recorded_id)"
run_session_noid --start brain:init
assert_eq "noid/second-start-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "noid/two-distinct-records" "2" "$(count_records)" "state: [$(state_text)]"
assert_prefix "noid/second-start-sees-the-first" "SESSION: WARN" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "noid/warning-names-the-other-branch" "brain/work" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_ne "noid/ids-are-not-the-same-token" "$first_id" "$(state_ids | tail -n 1)" "state: [$(state_text)]"
# ...and the degradation is DECLARED, with the remedy, rather than pretended away.
assert_contains "noid/says-identity-was-generated" "generated" "$(out_all)" "$(evidence)"
assert_contains "noid/offers-the-export-remedy" "export BRAIN_SESSION_ID=" "$(out_all)" "$(evidence)"

# --- 35. ...and the same shell on a protected branch is REFUSED, not adopted --
# The safe direction: two runs we cannot tell apart are assumed to be two sessions.
sb_new "main"
GH_PATH="$GH_NONE"
run_session_noid --start brain:save
assert_eq "noid/first-got-a-branch" "brain/brain-save-$(today)" "$(cur_branch)" "$(evidence)"
git -C "$VAULT" checkout -q main >/dev/null 2>&1
run_session_noid --start brain:init
assert_eq "noid/second-on-main-REFUSED" "1" "$STATUS" "$(evidence)"
assert_eq "noid/second-left-HEAD-on-main" "main" "$(cur_branch)" "$(evidence)"

echo "--- K. records this script did not write ---"

# --- 36. a legacy pid-only record is a stranger, not noise ---------------
# Written by the pre-identity version of session.sh. It has no session_id. A fresh
# record we cannot identify is SOMEBODY, and the safe reading of somebody is "not
# me" — adopting it would hand a stranger's pin to whoever asked next.
sb_new "main"
GH_PATH="$GH_NONE"
forge_legacy_session "$LIVE_PID" "brain/legacy-work" "$(head_sha)" "$(now_iso)" "brain:save"
SID="agent-A"; run_session --start brain:init
assert_eq "legacy/treated-as-foreign-REFUSED" "1" "$STATUS" "$(evidence)"
assert_contains "legacy/refusal-names-its-branch" "brain/legacy-work" "$(out_all)" "$(evidence)"
assert_eq "legacy/left-HEAD-on-main" "main" "$(cur_branch)" "$(evidence)"

# --- 37. a legacy record on a feature branch warns and is carried forward --
sb_new "brain/work"
GH_PATH="$GH_NONE"
forge_legacy_session "$LIVE_PID" "brain/legacy-work" "$(head_sha)" "$(now_iso)" "brain:save"
SID="agent-A"; run_session --start brain:init
assert_eq "legacy/feature-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "legacy/feature-verdict-WARN" "SESSION: WARN" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "legacy/feature-names-its-branch" "brain/legacy-work" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "legacy/record-rewritten-with-an-id" "legacy-pid-$LIVE_PID" "$(state_text)" "$(evidence)"
assert_eq "legacy/both-records-kept" "2" "$(count_records)" "state: [$(state_text)]"

# --- 38. a record of an unknown shape does not crash anything ------------
# Well-formed JSON, no field this script recognises. It must degrade to the
# corrupt-file rule — WARN and proceed — not to a stack of unbound-variable errors.
sb_new "brain/work"
GH_PATH="$GH_NONE"
sha="$(head_sha)"
mkdir -p "$VAULT/.brain"
printf '[\n  {"who": "nobody", "when": "never"}\n]\n' >"$VAULT/.brain/session.json"
SID="agent-A"; run_session --start brain:save
assert_eq "unknown-shape/exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "unknown-shape/verdict-WARN" "SESSION: WARN" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_eq "unknown-shape/still-prints-the-pin" "  pin: brain/work:$sha" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"
assert_not_contains "unknown-shape/no-shell-errors" "unbound variable" "$(out_all)" "$(evidence)"
assert_contains "unknown-shape/file-repaired" "\"session_id\": \"agent-A\"" "$(state_text)" "$(evidence)"

# --- 39. an id with characters that would break the JSON reader is tamed --
# BRAIN_SESSION_ID is user input, and it round-trips through this script's own
# grep/sed reader. A quote in it must not be able to forge a second field.
sb_new "brain/work"
GH_PATH="$GH_NONE"
SID='ev"il, "branch": "brain/pwned'
run_session --start brain:save
assert_eq "sanitize/exit-0" "0" "$STATUS" "$(evidence)"
assert_contains "sanitize/branch-is-still-the-real-branch" "\"branch\": \"brain/work\"" "$(state_text)" "$(evidence)"
assert_not_contains "sanitize/injected-branch-absent" "brain/pwned" "$(state_text)" "$(evidence)"
run_session --print-pin
assert_eq "sanitize/pin-still-round-trips" "0" "$STATUS" "$(evidence)"
SID="sess-A"

echo "--- L. --repin: the freshness step moving HEAD is NOT a foreign move (INNOV-285) ---"
# /brain:save step 0b (check-freshness.sh) fast-forwards/merges the branch as part
# of THIS session's own save. Before --repin existed, that legitimate move made the
# --start pin stale and step 6's vault-commit --pin refused every stale-branch
# save. --repin updates the recorded pin ONLY when the caller can name the exact
# pre-move sha the record holds — a HEAD moved by another session cannot, so the
# moved-HEAD guard stays armed.

# --- 40. own freshness move: repin accepted, new pin round-trips into vault-commit --
sb_new "brain/work"
GH_PATH="$GH_NONE"
SID="sess-A"
run_session --start save
old_sha="$(head_sha)"
echo "landed upstream" >>"$VAULT/wiki/log.md"          # the freshness ff/merge, simulated
git -C "$VAULT" add -A >/dev/null 2>&1
git -C "$VAULT" commit -qm "freshness fast-forward" >/dev/null 2>&1
new_sha="$(head_sha)"
run_session --repin "$old_sha" "$new_sha"
assert_eq "repin/own-move-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "repin/own-move-verdict-OK" "SESSION: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_eq "repin/own-move-prints-new-pin" "  pin: brain/work:$new_sha" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"
run_session --print-pin
assert_eq "repin/print-pin-replays-the-NEW-sha" "  pin: brain/work:$new_sha" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"
make_dirty
run_commit -m "stale-branch save after freshness repin" --pin "brain/work:$new_sha"
assert_eq "repin/vault-commit-accepts-the-new-pin" "0" "$CSTATUS" \
  "commit stderr: [$(tr '\n' '|' <"$BOX/cerr.txt")]"

# --- 41. foreign move: repin REFUSED, old pin kept, vault-commit still refuses --
# The caller (freshness) saw sha1 before its merge, but the record holds sha0 —
# something ELSE moved HEAD first. The pin must not be rewritten.
sb_new "brain/work"
GH_PATH="$GH_NONE"
SID="sess-A"
run_session --start save
sha0="$(head_sha)"
echo "other session" >>"$VAULT/wiki/log.md"            # a concurrent session commits
git -C "$VAULT" add -A >/dev/null 2>&1
git -C "$VAULT" commit -qm "concurrent session commit" >/dev/null 2>&1
sha1="$(head_sha)"
run_session --repin "$sha1" "$sha1"
assert_eq "repin/foreign-move-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "repin/foreign-move-REFUSED" "SESSION: REFUSED" "$(first_line "$BOX/err.txt")" "$(evidence)"
run_session --print-pin
assert_eq "repin/foreign-move-pin-unchanged" "  pin: brain/work:$sha0" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"
make_dirty
run_commit -m "must refuse" --pin "brain/work:$sha0"
assert_eq "repin/vault-commit-still-refuses-after-foreign-move" "1" "$CSTATUS" \
  "commit stdout: [$(tr '\n' '|' <"$BOX/cout.txt")]"

# --- 42. a branch switch is never a repinnable move ------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
SID="sess-A"
run_session --start save
sha="$(head_sha)"
git -C "$VAULT" checkout -q -B "brain/other" >/dev/null 2>&1
run_session --repin "$sha" "$sha"
assert_eq "repin/branch-switch-exit-1" "1" "$STATUS" "$(evidence)"
assert_contains "repin/branch-switch-names-both-branches" "brain/other" "$(out_all)" "$(evidence)"
run_session --print-pin
assert_eq "repin/branch-switch-pin-unchanged" "  pin: brain/work:$sha" "$(nth_line "$BOX/out.txt" 2)" "$(evidence)"

# --- 43. no session registered => nothing to repin, and that is OK ---------
# check-freshness.sh also runs standalone (outside /brain:save); a missing record
# must not turn the freshness check into a failure.
sb_new "brain/work"
GH_PATH="$GH_NONE"
SID="sess-A"
run_session --repin "$(head_sha)" "$(head_sha)"
assert_eq "repin/no-session-exit-0" "0" "$STATUS" "$(evidence)"
assert_contains "repin/no-session-says-nothing-to-repin" "nothing to repin" "$(out_all)" "$(evidence)"

# --- 44. --repin without both shas is a refusal, not an unpinned success ---
sb_new "brain/work"
GH_PATH="$GH_NONE"
SID="sess-A"
run_session --start save
run_session --repin "$(head_sha)"
assert_eq "repin/missing-arg-exit-1" "1" "$STATUS" "$(evidence)"
assert_prefix "repin/missing-arg-REFUSED" "SESSION: REFUSED" "$(first_line "$BOX/err.txt")" "$(evidence)"

echo "--- M. --end removes this session's write-hot pin, and only it (INNOV-321) ---"

# --- 45. a real pin -> write cycle, then --end: the per-session pin is gone ---
# write-hot.sh keeps its pin after --write on purpose (a budget trim writes again
# without re-pinning), so --end is where it is spent. Without this, every harness
# session leaves one .brain/hot-<id>.pin behind forever.
WRITE_HOT="$REPO_ROOT/brain/bin/write-hot.sh"
sb_new "brain/work"
GH_PATH="$GH_NONE"
SID="sess-A"
run_session --start save
echo "new hot" >"$BOX/new-hot.md"
BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="$SID" bash "$WRITE_HOT" --pin >/dev/null 2>&1
BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="$SID" bash "$WRITE_HOT" --write "$BOX/new-hot.md" >/dev/null 2>&1
assert_eq "hotpin/precondition-pin-survives-write" "1" \
  "$([[ -f "$VAULT/.brain/hot-$SID.pin" ]] && echo 1 || echo 0)" "$(evidence)"
printf 'x\tt\n' >"$VAULT/.brain/hot-$FOREIGN_SID.pin"   # another live session's pin
printf 'x\tt\n' >"$VAULT/.brain/hot.pin"                # the id-less shared pin
run_session --end
assert_eq "hotpin/end-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "hotpin/own-pin-removed" "0" \
  "$([[ -e "$VAULT/.brain/hot-$SID.pin" ]] && echo 1 || echo 0)" "$(evidence)"
assert_eq "hotpin/foreign-pin-survives" "1" \
  "$([[ -f "$VAULT/.brain/hot-$FOREIGN_SID.pin" ]] && echo 1 || echo 0)" "$(evidence)"
assert_eq "hotpin/shared-pin-survives" "1" \
  "$([[ -f "$VAULT/.brain/hot.pin" ]] && echo 1 || echo 0)" "$(evidence)"

# --- 46. the pin id is write-hot.sh's, not SELF_ID: GROK_SESSION_ID counts ---
# session.sh's own identity ignores GROK_SESSION_ID and falls back to session.id,
# so deriving the pin path from SELF_ID would miss a Grok session's pin.
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/.brain"
printf 'x\tt\n' >"$VAULT/.brain/hot-grok-1.pin"
BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" GROK_SESSION_ID="grok-1" \
  bash "$SESSION" --end >"$BOX/out.txt" 2>"$BOX/err.txt"; STATUS=$?
assert_eq "hotpin/grok-end-exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "hotpin/grok-pin-removed" "0" \
  "$([[ -e "$VAULT/.brain/hot-grok-1.pin" ]] && echo 1 || echo 0)" "$(evidence)"

# ------------------------------------------------------------------ done ---
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
