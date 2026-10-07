#!/usr/bin/env bash
# test-vault-commit.sh — deterministic quality gate for brain/bin/vault-commit.sh
#
# vault-commit.sh is THE single commit path into a brain vault (INNOV-275). Every
# guard that used to live scattered across sync-graph.sh, plus the .saveinclude
# enforcement that used to be a line of prose in the /brain:save skill, is here.
# It exists because the guards were on the wrong side: sync-graph.sh carried six
# references' worth of protected-branch checking while /brain:save step 6 — the
# path that actually put a commit on protected `main` on 2026-08-05 — ran raw
# `git add` / `git commit` with nothing at all.
#
# Contract under test:
#   exit 0 => committed, or nothing to commit
#   exit 1 => REFUSED, and NOTHING was staged and NOTHING was committed
#   first line of output starts with `VAULT-COMMIT: OK`      (stdout)
#                                 or `VAULT-COMMIT: REFUSED` (stderr)
#   vault resolved from $BRAIN_ROOT -> $CLAUDE_PROJECT_DIR -> $PWD
#
# The refusals, and which flag (if any) overrides each:
#   protected/default branch  — NO override at all (INNOV-275 retired the old one)
#   open PR on this branch    — --force-commit overrides
#   HEAD moved since --pin    — NO override; a moved HEAD makes intent unknown
#   no/empty .saveinclude     — NO override; a vault with no allowlist has no
#                               permission model and there is no safe default
#   index holds a path the allowlist forbids — NO override; this is the one that
#                               makes "no command commits outside .saveinclude"
#                               a property rather than an intention, because the
#                               git index is shared by every session in the tree
#   --pr-paths (INNOV-363)    — NO override: no --pin, a named path under chats/,
#                               gitignored or outside the vault, or ANY path
#                               already staged (checked before staging)
#
# Run:  bash tests/test-vault-commit.sh   (from anywhere)
# No network. Real git repos in mktemp sandboxes; `gh` is a stub on PATH.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
GUARD="$REPO_ROOT/brain/bin/vault-commit.sh"

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

assert_ne() { # name not-expected actual [evidence...]
  local name="$1" nexp="$2" act="$3"
  shift 3
  if [[ "$nexp" != "$act" ]]; then
    pass "$name"
  else
    fail "$name" "expected anything BUT: [$nexp]" "actual: [$act]" "$@"
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
  if [[ "$hay" != *"$needle"* ]]; then pass "$name"
  else fail "$name" "expected NOT to contain: [$needle]" "actual:                  [$hay]" "$@"; fi
}

# First line of a file, with any trailing CR stripped (Git Bash / CRLF safety).
first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }

evidence() {
  echo "exit:   [$STATUS]"
  echo "stdout: [$(tr '\n' '|' <"$BOX/out.txt" 2>/dev/null)]"
  echo "stderr: [$(tr '\n' '|' <"$BOX/err.txt" 2>/dev/null)]"
}

# ------------------------------------------------------------ gh stubs -----
# `gh` is a safety net for the open-PR guard, never a dependency. Three PATHs:
#   GH_NONE — no gh at all ("cannot tell" must look exactly like "no PR")
#   GH_NOPR — gh answers, no open PR
#   GH_PR   — gh answers with open PR #4242 on any branch
GH_NONE="$TMPROOT/gh-none"
GH_NOPR="$TMPROOT/gh-nopr"
GH_PR="$TMPROOT/gh-pr"
mkdir -p "$GH_NONE" "$GH_NOPR" "$GH_PR"

cat >"$GH_NOPR/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  pr)   echo "" ;;
  repo) echo "" ;;
  *)    exit 1 ;;
esac
exit 0
SH
cat >"$GH_PR/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  pr)   echo "4242" ;;
  repo) echo "" ;;
  *)    exit 1 ;;
esac
exit 0
SH
chmod +x "$GH_NOPR/gh" "$GH_PR/gh"

# ------------------------------------------------------------ sandboxing ---

# Assigns the globals BOX / VAULT. Deliberately NOT run in a command
# substitution — the assignments would be lost and state would leak between
# cases (a previous harness in this repo made exactly that mistake).
BOX=""
VAULT=""

# A vault on branch $1 (default: a normal working branch) with one commit, a
# default .saveinclude, and wiki/ + logs/ + graphify/ populated.
sb_new() { # [branch]
  local branch="${1:-brain/work}"
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  mkdir -p "$VAULT/wiki" "$VAULT/logs" "$VAULT/graphify/alpha"
  printf 'logs/\nwiki/hot.md\nwiki/log.md\ngraphify/\ngraphify-out/graph.json\n' >"$VAULT/.saveinclude"
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

# Makes an allowlisted file dirty so there is something to commit.
make_dirty() { echo "change $RANDOM" >>"$VAULT/wiki/log.md"; }

head_sha()     { git -C "$VAULT" rev-parse HEAD 2>/dev/null || true; }
head_subject() { git -C "$VAULT" log -1 --format=%s 2>/dev/null || true; }
staged_list()  { git -C "$VAULT" diff --cached --name-only 2>/dev/null; }
staged_count() { staged_list | grep -c . || true; }

STATUS=""
GH_PATH=""
GIT_WRAP=""   # a dir holding a `git` wrapper, prepended to PATH for one case
# Runs the guard, capturing streams into $BOX/out.txt / $BOX/err.txt and the exit
# code into $STATUS. $GH_PATH (if set) is prepended to PATH for the gh stub.
run_guard() { # [args...]
  (
    cd "$VAULT" 2>/dev/null || cd "$BOX" || exit 127
    unset CLAUDE_PROJECT_DIR
    [[ -n "$GH_PATH" ]] && export PATH="$GH_PATH:$PATH"
    [[ -n "$GIT_WRAP" ]] && export PATH="$GIT_WRAP:$PATH"
    BRAIN_ROOT="$VAULT" bash "$GUARD" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

out_all() { cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | tr '\n' ' ' | tr -d '\r'; }

if [[ ! -f "$GUARD" ]]; then
  echo "note: $GUARD does not exist yet — every case below is expected to FAIL until it lands."
fi

echo "--- A. the happy path and the contract ---"

# --- 1. commits on a normal branch ----------------------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "save: test session"
assert_eq "happy/exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "happy/stdout-verdict-line" "VAULT-COMMIT: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_ne "happy/head-moved" "$before" "$(head_sha)" "$(evidence)"
assert_eq "happy/commit-message-used" "save: test session" "$(head_subject)" "$(evidence)"
assert_contains "happy/names-the-committed-path" "wiki/log.md" "$(out_all)" "$(evidence)"
assert_contains "happy/names-the-branch" "brain/work" "$(out_all)" "$(evidence)"

# --- 2. nothing to commit is exit 0, not a failure ------------------------
# A clean save is a normal outcome, not an error: a session that changed nothing
# allowlisted must not fail the whole /brain:save.
sb_new "brain/work"
GH_PATH="$GH_NONE"
before="$(head_sha)"
run_guard -m "nothing here"
assert_eq "empty/exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "empty/verdict-is-OK" "VAULT-COMMIT: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "empty/says-nothing-to-commit" "nothing to commit" "$(out_all)" "$(evidence)"
assert_eq "empty/head-unmoved" "$before" "$(head_sha)" "$(evidence)"

# --- 3. --print-allowlist reports the resolved list, changes nothing ------
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard --print-allowlist
assert_eq "print-allowlist/exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "print-allowlist/head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_eq "print-allowlist/stages-nothing" "0" "$(staged_count)" "$(evidence)"
assert_contains "print-allowlist/lists-an-entry" "wiki/hot.md" "$(out_all)" "$(evidence)"

# --- 4. comments and blank lines in .saveinclude are ignored --------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
printf '# a comment\n\n   \nwiki/log.md\n\t# indented comment\n  logs/  \n' >"$VAULT/.saveinclude"
run_guard --print-allowlist
allow_lines="$(grep -c . "$BOX/out.txt" 2>/dev/null || echo 0)"
assert_eq "parse/only-real-entries-survive" "2" "$allow_lines" "$(evidence)"
assert_contains "parse/whitespace-trimmed" "logs/" "$(out_all)" "$(evidence)"

echo "--- B. the protected-branch refusal (no override) ---"

# --- 5. refuses on main ---------------------------------------------------
# This is the 2026-08-05 incident, reproduced through the path that caused it.
for branch in main master; do
  sb_new "$branch"
  GH_PATH="$GH_NONE"
  make_dirty
  before="$(head_sha)"
  run_guard -m "should not land"
  assert_eq "protected/$branch/exit-1" "1" "$STATUS" "$(evidence)"
  assert_prefix "protected/$branch/stderr-verdict-line" "VAULT-COMMIT: REFUSED" "$(first_line "$BOX/err.txt")" "$(evidence)"
  assert_eq "protected/$branch/head-unmoved" "$before" "$(head_sha)" "$(evidence)"
  assert_contains "protected/$branch/names-the-branch" "$branch" "$(out_all)" "$(evidence)"
done

# --- 6. a refusal stages NOTHING -----------------------------------------
# INNOV-275 changed this from the old sync-graph.sh behaviour ("left STAGED").
# The git index is global to the checkout, so a refusal that leaves a payload in
# it hands the next session a commit it never chose.
sb_new "main"
GH_PATH="$GH_NONE"
make_dirty
run_guard -m "should not land"
assert_eq "protected/index-untouched" "0" "$(staged_count)" "staged: [$(staged_list | tr '\n' ' ')]" "$(evidence)"
assert_contains "protected/says-nothing-was-staged" "Nothing was staged" "$(out_all)" "$(evidence)"

# --- 7. --force-commit does NOT override it ------------------------------
# INNOV-270 shipped --force-commit as a bypass here; INNOV-275 retires it. An
# overridable guard on the vault's most damaging operation is exactly the
# "rule shipped as prose" failure mode this workstream exists to remove.
sb_new "main"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "forced" --force-commit
assert_eq "protected/force-commit-still-refuses" "1" "$STATUS" "$(evidence)"
assert_eq "protected/force-commit-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "protected/force-commit-says-no-override" "no flag to override" "$(out_all)" "$(evidence)"

# --- 8. the DETECTED default branch is protected even when it isn't main ---
# 'trunk' is outside the literal main/master net, so only origin/HEAD catches it.
sb_new "trunk"
GH_PATH="$GH_NONE"
git -C "$VAULT" update-ref refs/remotes/origin/trunk "$(head_sha)" >/dev/null 2>&1
git -C "$VAULT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk >/dev/null 2>&1
make_dirty
before="$(head_sha)"
run_guard -m "should not land"
assert_eq "protected/detected-default-refused" "1" "$STATUS" "$(evidence)"
assert_eq "protected/detected-default-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "protected/detected-default-named" "trunk" "$(out_all)" "$(evidence)"

# --- 9. a branch that merely LOOKS like a default is not protected --------
# The safety net is the literal names main/master, not "anything main-ish".
sb_new "brain/mainline-work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "fine"
assert_eq "protected/lookalike-branch-still-commits" "0" "$STATUS" "$(evidence)"
assert_ne "protected/lookalike-head-moved" "$before" "$(head_sha)" "$(evidence)"

echo "--- C. the open-PR refusal (--force-commit DOES override) ---"

# --- 10. refuses on a branch with an open PR ------------------------------
sb_new "brain/work"
GH_PATH="$GH_PR"
make_dirty
before="$(head_sha)"
run_guard -m "would pile onto a PR"
assert_eq "pr/refused" "1" "$STATUS" "$(evidence)"
assert_eq "pr/head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "pr/names-the-pr-number" "4242" "$(out_all)" "$(evidence)"
assert_eq "pr/index-untouched" "0" "$(staged_count)" "$(evidence)"

# --- 11. --force-commit overrides THIS one --------------------------------
# Unlike the protected branch, "yes, add this to my own open PR" is a coherent
# intent worth being able to express.
sb_new "brain/work"
GH_PATH="$GH_PR"
make_dirty
before="$(head_sha)"
run_guard -m "deliberately into the PR" --force-commit
assert_eq "pr/force-commit-overrides" "0" "$STATUS" "$(evidence)"
assert_ne "pr/force-commit-head-moved" "$before" "$(head_sha)" "$(evidence)"

# --- 12. no gh => "cannot tell" must look exactly like "no PR" ------------
# A vault with no GitHub remote, or a machine with no gh, keeps working. The
# guard is a safety net, never a dependency.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "no gh here"
assert_eq "pr/missing-gh-still-commits" "0" "$STATUS" "$(evidence)"
assert_ne "pr/missing-gh-head-moved" "$before" "$(head_sha)" "$(evidence)"

# --- 13. gh present, no open PR => commits --------------------------------
sb_new "brain/work"
GH_PATH="$GH_NOPR"
make_dirty
before="$(head_sha)"
run_guard -m "clean branch"
assert_eq "pr/no-open-pr-commits" "0" "$STATUS" "$(evidence)"
assert_ne "pr/no-open-pr-head-moved" "$before" "$(head_sha)" "$(evidence)"

echo "--- D. the HEAD pin (no override) ---"

# --- 14. a matching pin commits normally ----------------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "pinned" --pin "brain/work:$before"
assert_eq "pin/matching-pin-commits" "0" "$STATUS" "$(evidence)"
assert_ne "pin/matching-pin-head-moved" "$before" "$(head_sha)" "$(evidence)"

# --- 15. a moved SHA refuses ----------------------------------------------
# The concurrent-session case: another session merged a PR underneath this run,
# so the commit would land on a base its author never selected.
sb_new "brain/work"
GH_PATH="$GH_NONE"
stale_sha="$(head_sha)"
echo "other session" >>"$VAULT/wiki/log.md"
git -C "$VAULT" add -A >/dev/null 2>&1
git -C "$VAULT" commit -qm "concurrent session commit" >/dev/null 2>&1
now_sha="$(head_sha)"
make_dirty
run_guard -m "mine" --pin "brain/work:$stale_sha"
assert_eq "pin/moved-sha-refused" "1" "$STATUS" "$(evidence)"
assert_eq "pin/moved-sha-head-unmoved" "$now_sha" "$(head_sha)" "$(evidence)"
assert_eq "pin/moved-sha-index-untouched" "0" "$(staged_count)" "$(evidence)"
assert_contains "pin/reports-pinned-sha" "$stale_sha" "$(out_all)" "$(evidence)"
assert_contains "pin/reports-current-sha" "$now_sha" "$(out_all)" "$(evidence)"

# --- 16. a moved BRANCH refuses -------------------------------------------
# HEAD is global to the checkout: another session's `checkout` moves it for
# everyone, and a long-running session cannot notice on its own.
sb_new "brain/work"
GH_PATH="$GH_NONE"
sha="$(head_sha)"
make_dirty
run_guard -m "mine" --pin "brain/somewhere-else:$sha"
assert_eq "pin/moved-branch-refused" "1" "$STATUS" "$(evidence)"
assert_contains "pin/reports-both-branches" "brain/somewhere-else" "$(out_all)" "$(evidence)"

# --- 17. --force-commit does NOT bypass the pin ---------------------------
# --force-commit means "I know about the open PR and want it anyway". A moved
# HEAD makes the caller's intent genuinely unknown — there is nothing to force.
sb_new "brain/work"
GH_PATH="$GH_NONE"
sha="$(head_sha)"
make_dirty
run_guard -m "forced" --pin "brain/work:0000000000000000000000000000000000000000" --force-commit
assert_eq "pin/force-commit-does-not-bypass" "1" "$STATUS" "$(evidence)"
assert_contains "pin/force-commit-says-so" "does NOT override" "$(out_all)" "$(evidence)"

# --- 18. a malformed pin refuses; it is never treated as "unpinned" -------
# A caller that meant to pin and typo'd the format must not silently get an
# unguarded commit — that is the fail-open direction, and it is the dangerous one.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "typo" --pin "not-a-valid-pin"
assert_eq "pin/malformed-refused" "1" "$STATUS" "$(evidence)"
assert_eq "pin/malformed-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "pin/malformed-explains" "BRANCH:SHA" "$(out_all)" "$(evidence)"

# --- 18b. session.sh --print-pin's whole banner is malformed, not "HEAD moved" --
# INNOV-315: save passed --print-pin's stdout through unchanged. The banner has
# colons, so it passed the *:* check, split into branch "SESSION" and a sha of
# prose, and was reported as the moved-HEAD refusal — for a HEAD that never moved.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
banner="$(printf 'SESSION: OK - pin for session s1 as recorded\n  pin: brain/work:%s' "$before")"
run_guard -m "banner" --pin "$banner"
assert_eq "pin/banner-refused" "1" "$STATUS" "$(evidence)"
assert_eq "pin/banner-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_eq "pin/banner-index-untouched" "0" "$(staged_count)" "$(evidence)"
assert_contains "pin/banner-explains" "BRANCH:SHA" "$(out_all)" "$(evidence)"
assert_not_contains "pin/banner-not-head-moved" "HEAD moved" "$(out_all)" "$(evidence)"

# --- 18c. an explicitly EMPTY --pin refuses; it is never "unpinned" ----------
# save extracts the pin with `--print-pin | sed`; if --print-pin refuses, the sed
# still succeeds and yields "". That must fail closed, not commit unguarded.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "empty pin" --pin ""
assert_eq "pin/empty-refused" "1" "$STATUS" "$(evidence)"
assert_eq "pin/empty-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "pin/empty-explains" "BRANCH:SHA" "$(out_all)" "$(evidence)"
run_guard -m "empty pin" --pin=
assert_eq "pin/empty-eq-form-refused" "1" "$STATUS" "$(evidence)"

echo "--- E. the allowlist: staging AND index verification ---"

# --- 19. only allowlisted paths are staged --------------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/chats"
echo "private transcript" >"$VAULT/chats/secret.md"
echo "trusted knowledge" >"$VAULT/wiki/some-note.md"
make_dirty
run_guard -m "save"
assert_eq "allowlist/commits" "0" "$STATUS" "$(evidence)"
tracked="$(git -C "$VAULT" ls-files 2>/dev/null | tr '\n' ' ')"
assert_eq "allowlist/private-chats-not-committed" "0" "$(git -C "$VAULT" ls-files chats/ 2>/dev/null | grep -c . || true)" "tracked: [$tracked]" "$(evidence)"
assert_eq "allowlist/untrusted-wiki-note-not-committed" "0" "$(git -C "$VAULT" ls-files wiki/some-note.md 2>/dev/null | grep -c . || true)" "tracked: [$tracked]" "$(evidence)"
assert_contains "allowlist/allowlisted-path-was-committed" "wiki/log.md" "$tracked" "$(evidence)"

# --- 20. THE INDEX CHECK: another session's staged file refuses the commit --
# This is the case that makes the guarantee real. Staging discipline only
# governs what THIS command adds; the index is shared by every session in the
# checkout, so anything at all can already be sitting in it.
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/chats"
echo "private transcript" >"$VAULT/chats/secret.md"
git -C "$VAULT" add -f chats/secret.md >/dev/null 2>&1   # "another session"
make_dirty
before="$(head_sha)"
run_guard -m "would publish a secret"
assert_eq "index/contaminated-refused" "1" "$STATUS" "$(evidence)"
assert_eq "index/contaminated-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "index/names-the-offending-path" "chats/secret.md" "$(out_all)" "$(evidence)"
# INNOV-369: the refusal leaves none of THIS run's paths staged. The index is
# not literally empty — case 21 is the other session's path, which stays.
assert_eq "index/contaminated-stages-nothing-of-ours" "chats/secret.md" "$(staged_list | tr -d '\r')" "$(evidence)"

# --- 21. ...and it does NOT unstage the other session's work --------------
# Unstaging someone else's staged work would be its own kind of damage. Refusing
# is the whole remedy; the human decides what to do with the index.
assert_contains "index/other-sessions-work-left-alone" "chats/secret.md" "$(staged_list | tr '\n' ' ')" "$(evidence)"

# --- 21b. the foreign-path check runs BEFORE the first `git add` -----------
# Negative control for INNOV-369's up-front check. Staging, refusing and then
# unstaging ends in the same index, so the index alone cannot tell the two
# apart. A held index.lock can: `git diff --cached` still reads, `git add` fails.
# With the check up front the refusal names the foreign path; without it, the
# run reaches `git add` and refuses on the lock instead.
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/chats"
echo "private transcript" >"$VAULT/chats/secret.md"
git -C "$VAULT" add -f chats/secret.md >/dev/null 2>&1   # "another session"
make_dirty
: >"$VAULT/.git/index.lock"                              # a concurrent git process
run_guard -m "would publish a secret"
rm -f "$VAULT/.git/index.lock"
assert_eq "index/precheck-refused" "1" "$STATUS" "$(evidence)"
assert_contains "index/precheck-names-foreign-path" "chats/secret.md" "$(out_all)" "$(evidence)"
assert_not_contains "index/precheck-never-reached-git-add" "git add" "$(first_line "$BOX/err.txt")" "$(evidence)"

# --- 21c. a `git add` failing midway unstages what this run already added ---
# sb_new's allowlist ends with graphify-out/graph.json. Gitignore it and the
# loop stages wiki/log.md, then fails on the ignored entry. Without the unstage,
# wiki/log.md stays staged for the next session's commit to carry.
sb_new "brain/work"
GH_PATH="$GH_NONE"
printf 'graphify-out/\n' >"$VAULT/.gitignore"
mkdir -p "$VAULT/graphify-out"
echo "{}" >"$VAULT/graphify-out/graph.json"
make_dirty
before="$(head_sha)"
run_guard -m "midway failure"
assert_eq "midway/refused" "1" "$STATUS" "$(evidence)"
assert_contains "midway/names-the-failed-add" "graphify-out/graph.json" "$(out_all)" "$(evidence)"
assert_eq "midway/head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_eq "midway/index-empty" "0" "$(staged_count)" "staged: [$(staged_list | tr '\n' ' ')]" "$(evidence)"

# --- 21d. ...and leaves a path staged BEFORE the run exactly where it was ----
# Another session's allowlisted path passes the up-front check; the unstage
# must only take back what this run added.
sb_new "brain/work"
GH_PATH="$GH_NONE"
printf 'graphify-out/\n' >"$VAULT/.gitignore"
mkdir -p "$VAULT/graphify-out"
echo "{}" >"$VAULT/graphify-out/graph.json"
echo "their log" >"$VAULT/logs/2026-10-02-other.md"
git -C "$VAULT" add logs/2026-10-02-other.md >/dev/null 2>&1   # "another session"
echo "mine" >"$VAULT/logs/2026-10-02-mine.md"
make_dirty
run_guard -m "midway failure"
assert_eq "midway/pre-staged-refused" "1" "$STATUS" "$(evidence)"
assert_eq "midway/pre-staged-survives-alone" "logs/2026-10-02-other.md" "$(staged_list | tr -d '\r')" "$(evidence)"
assert_contains "midway/says-shared-index-untouched" "shared index was not touched" "$(out_all)" "$(evidence)"

# --- 21d2. ...and keeps that path's staged BLOB, not just its name (INNOV-375) --
# Staging used to happen in the shared index, so re-adding wiki/log.md replaced
# the other session's staged blob A with this run's B and a refusal could not
# put A back. Compare blob SHAs: a path-list assert passes either way.
sb_new "brain/work"
GH_PATH="$GH_NONE"
printf 'graphify-out/\n' >"$VAULT/.gitignore"
mkdir -p "$VAULT/graphify-out"
echo "{}" >"$VAULT/graphify-out/graph.json"
echo "content A" >"$VAULT/wiki/log.md"
git -C "$VAULT" add wiki/log.md >/dev/null 2>&1                 # "another session"
blob_a="$(git -C "$VAULT" hash-object wiki/log.md)"
echo "content B" >"$VAULT/wiki/log.md"
run_guard -m "late refusal"
assert_eq "blob/late-refusal-refused" "1" "$STATUS" "$(evidence)"
assert_eq "blob/pre-staged-blob-kept" "$blob_a" \
  "$(git -C "$VAULT" ls-files -s wiki/log.md | awk '{print $2}')" "$(evidence)"
assert_eq "blob/no-private-index-left" "0" \
  "$(ls "$VAULT/.git" | grep -c '^vault-commit-index' || true)" "$(evidence)"

# A `git` wrapper on PATH that runs $WRAP_ACTION against the SHARED index once,
# just before the guard's commit step (`commit-tree` now, `commit` before
# INNOV-375, so the case fails against the old script), then runs the real git.
REAL_GIT="$(command -v git)"
make_git_wrap() { # action-script [trigger-arg-pattern]
  GIT_WRAP="$BOX/wrap"
  mkdir -p "$GIT_WRAP"
  cat >"$GIT_WRAP/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    ${2:-commit|commit-tree})
      if [[ ! -f "$BOX/wrap/fired" ]]; then
        : >"$BOX/wrap/fired"
        if [[ "${3:-}" == after ]]; then
          "$REAL_GIT" "\$@"; rc=\$?
          ( unset GIT_INDEX_FILE; cd "$VAULT" && $1 ) >/dev/null 2>&1
          exit \$rc
        fi
        ( unset GIT_INDEX_FILE; cd "$VAULT" && $1 ) >/dev/null 2>&1
      fi
      break ;;
  esac
done
exec "$REAL_GIT" "\$@"
SH
  chmod +x "$GIT_WRAP/git"
}

# --- 21d3. a path staged after verification is NOT committed (INNOV-375 gap 1) --
# `git commit` committed whatever the shared index held at that moment, checked
# or not. The commit is now the verified tree, so the late chats/ path stays out.
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/chats"
echo "private transcript" >"$VAULT/chats/late.md"
make_dirty
make_git_wrap "'$REAL_GIT' add -f chats/late.md"
run_guard -m "save"
GIT_WRAP=""
assert_eq "race/late-stage-wrapper-fired" "yes" "$([[ -f "$BOX/wrap/fired" ]] && echo yes)" "$(evidence)"
assert_eq "race/late-stage-commits" "0" "$STATUS" "$(evidence)"
assert_eq "race/late-stage-not-in-commit" "0" \
  "$(git -C "$VAULT" ls-tree -r --name-only HEAD | grep -c '^chats/' || true)" "$(evidence)"
assert_contains "race/late-stage-committed-ours" "wiki/log.md" \
  "$(git -C "$VAULT" show --name-only --format= HEAD | tr '\n' ' ')" "$(evidence)"
assert_eq "race/late-stage-left-staged-for-its-owner" "chats/late.md" "$(staged_list | tr -d '\r')" "$(evidence)"

# --- 21d4. HEAD moved before the ref update => refused, nothing lost (CAS) ---
# Another session commits onto the branch after the guards ran. The update-ref
# compare-and-swap refuses; the intruder stays HEAD, the shared index unchanged.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
index_before="$(git -C "$VAULT" ls-files -s | tr '\n' '|')"
make_git_wrap "'$REAL_GIT' update-ref refs/heads/brain/work \$('$REAL_GIT' commit-tree 'HEAD^{tree}' -p HEAD -m intruder)"
run_guard -m "loses the race"
GIT_WRAP=""
assert_eq "cas/refused" "1" "$STATUS" "$(evidence)"
assert_eq "cas/intruder-is-head" "intruder" "$(head_subject)" "$(evidence)"
assert_eq "cas/intruder-parent-is-before" "$before" "$(git -C "$VAULT" rev-parse HEAD^ 2>/dev/null)" "$(evidence)"
assert_eq "cas/shared-index-unchanged" "$index_before" "$(git -C "$VAULT" ls-files -s | tr '\n' '|')" "$(evidence)"
assert_contains "cas/explains" "HEAD moved" "$(out_all)" "$(evidence)"

# --- 21d4b. a branch CHECKOUT mid-run refuses, too ---------------------------
# A checkout to a new branch at the same SHA passes the ref CAS, so the run
# re-checks where HEAD points before it moves the ref.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
make_git_wrap "'$REAL_GIT' checkout -q -b other"
run_guard -m "loses the race"
GIT_WRAP=""
assert_eq "cas/checkout-refused" "1" "$STATUS" "$(evidence)"
assert_eq "cas/checkout-pinned-branch-unmoved" "$before" "$(git -C "$VAULT" rev-parse brain/work)" "$(evidence)"
assert_eq "cas/checkout-new-branch-unmoved" "$before" "$(git -C "$VAULT" rev-parse other 2>/dev/null)" "$(evidence)"

# --- 21d4c. a pre-staged allowlisted path outside this run's entries stays out --
# The private index is based on HEAD, so the commit carries only what this run
# staged; the other session's path stays staged for it.
sb_new "brain/work"
GH_PATH="$GH_NONE"
echo "their log" >"$VAULT/logs/other.md"
git -C "$VAULT" add logs/other.md >/dev/null 2>&1                # "another session"
make_dirty
run_guard -m "subset" -- wiki/log.md
assert_eq "base/subset-commits" "0" "$STATUS" "$(evidence)"
assert_eq "base/pre-staged-not-swept-in" "" "$(git -C "$VAULT" ls-tree --name-only HEAD logs/other.md)" "$(evidence)"
assert_eq "base/pre-staged-left-for-owner" "logs/other.md" "$(staged_list | tr -d '\r')" "$(evidence)"

# --- 21d4d. a STALE shared index cannot revert an earlier commit -------------
# If the post-commit index sync fails (lock held, crash), the shared index keeps
# pre-commit entries. Copy-based staging committed that stale state as a revert.
sb_new "brain/work"
GH_PATH="$GH_NONE"
echo "a" >"$VAULT/logs/a.md"
run_guard -m "first" -- logs/
git -C "$VAULT" reset -q HEAD~ -- logs/a.md >/dev/null 2>&1      # the sync that never ran
make_dirty
run_guard -m "second" -- wiki/log.md
assert_eq "stale/second-commits" "0" "$STATUS" "$(evidence)"
assert_eq "stale/first-commit-not-reverted" "logs/a.md" "$(git -C "$VAULT" ls-tree --name-only HEAD logs/a.md)" "$(evidence)"

# --- 21d4e. commit.gpgsign is honoured: a failing signer refuses -------------
# commit-tree signs only with -S. Without passing it on, a vault that requires
# signing would get unsigned commits where `git commit` refuses.
sb_new "brain/work"
GH_PATH="$GH_NONE"
git -C "$VAULT" config commit.gpgsign true
git -C "$VAULT" config gpg.program false
make_dirty
before="$(head_sha)"
run_guard -m "must be signed"
assert_eq "sign/refused" "1" "$STATUS" "$(evidence)"
assert_eq "sign/head-unmoved" "$before" "$(head_sha)" "$(evidence)"

# --- 21d4f. commit hooks still run: a pre-commit scanner can refuse ----------
# commit-tree runs no hooks, so the guard runs them. The hook lives on a
# relative core.hooksPath and must see the PRIVATE index: the shared one has
# nothing staged, so a hook reading it would pass the secret.
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/.githooks"
printf '#!/usr/bin/env bash\ngit diff --cached | grep -q SECRET && { echo "secret found"; exit 1; }\nexit 0\n' >"$VAULT/.githooks/pre-commit"
chmod +x "$VAULT/.githooks/pre-commit"
git -C "$VAULT" config core.hooksPath .githooks
echo "SECRET=1" >>"$VAULT/wiki/log.md"
before="$(head_sha)"
run_guard -m "carries a secret"
assert_eq "hooks/pre-commit-refused" "1" "$STATUS" "$(evidence)"
assert_eq "hooks/pre-commit-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "hooks/pre-commit-output-relayed" "secret found" "$(out_all)" "$(evidence)"

# --- 21d4g. ...and a commit-msg hook can rewrite the message ----------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
printf '#!/usr/bin/env bash\necho "Hooked: yes" >>"$1"\n' >"$VAULT/.git/hooks/commit-msg"
chmod +x "$VAULT/.git/hooks/commit-msg"
make_dirty
run_guard -m "save"
assert_eq "hooks/commit-msg-commits" "0" "$STATUS" "$(evidence)"
assert_contains "hooks/commit-msg-applied" "Hooked: yes" "$(git -C "$VAULT" log -1 --format=%B)" "$(evidence)"

# --- 21d4h. a checkout during the guards' `gh` call refuses ------------------
# The ref the commit moves is captured with the branch the guards judge. A
# checkout while `gh` runs must not let the commit land on the new branch.
sb_new "brain/work"
mkdir -p "$BOX/gh-checkout"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == pr ]] && ( cd "%s" && git checkout -q -b other ) >/dev/null 2>&1\necho ""\nexit 0\n' "$VAULT" >"$BOX/gh-checkout/gh"
chmod +x "$BOX/gh-checkout/gh"
GH_PATH="$BOX/gh-checkout"
make_dirty
before="$(head_sha)"
run_guard -m "loses the race"
assert_eq "guards/checkout-during-gh-refused" "1" "$STATUS" "$(evidence)"
assert_eq "guards/checkout-during-gh-pinned-unmoved" "$before" "$(git -C "$VAULT" rev-parse brain/work)" "$(evidence)"
assert_eq "guards/checkout-during-gh-new-unmoved" "$before" "$(git -C "$VAULT" rev-parse other 2>/dev/null)" "$(evidence)"

# --- 21d4i. a newer commit before the index sync is not reverted ------------
# Another session commits wiki/log.md right after this run's ref update. The
# sync must not reset the shared index back to this run's (older) commit.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
make_git_wrap "echo newer >>wiki/log.md && '$REAL_GIT' add wiki/log.md && '$REAL_GIT' commit -qm newer" "update-ref" after
run_guard -m "save"
GIT_WRAP=""
assert_eq "sync/newer-commit-ours-ok" "0" "$STATUS" "$(evidence)"
assert_eq "sync/newer-commit-is-head" "newer" "$(head_subject)" "$(evidence)"
assert_eq "sync/newer-commit-not-reverted-in-index" "0" "$(staged_count)" "staged: [$(staged_list | tr '\n' ' ')]" "$(evidence)"

# --- 21d4j. a stale entry for a TRACKED file does not wedge the next save -----
# A missed sync leaves `MM wiki/log.md` (index at the old blob). Resetting the
# private index with `read-tree -m` refused that ("not uptodate") on every run.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
run_guard -m "first" -- wiki/log.md
log_blob="$(git -C "$VAULT" rev-parse HEAD:wiki/log.md)"
git -C "$VAULT" reset -q HEAD~ -- wiki/log.md >/dev/null 2>&1   # the sync that never ran
echo "a log" >"$VAULT/logs/2026-10-03.md"
run_guard -m "second" -- logs/
assert_eq "stale/tracked-second-commits" "0" "$STATUS" "$(evidence)"
assert_eq "stale/tracked-not-reverted" "$log_blob" "$(git -C "$VAULT" rev-parse HEAD:wiki/log.md)" "$(evidence)"

# --- 21d4k. what pre-commit stages is committed, and verified ----------------
# `git commit` writes the tree after pre-commit, so a hook's staged fix ships.
# The allowlist check runs on that tree: a hook staging chats/ is refused.
sb_new "brain/work"
GH_PATH="$GH_NONE"
printf '#!/usr/bin/env bash\necho generated >wiki/hot.md && git add wiki/hot.md\n' >"$VAULT/.git/hooks/pre-commit"
chmod +x "$VAULT/.git/hooks/pre-commit"
make_dirty
run_guard -m "save"
assert_eq "hooks/pre-commit-staging-commits" "0" "$STATUS" "$(evidence)"
assert_eq "hooks/pre-commit-staged-file-shipped" "generated" "$(git -C "$VAULT" show HEAD:wiki/hot.md | tr -d '\r')" "$(evidence)"
sb_new "brain/work"
GH_PATH="$GH_NONE"
printf '#!/usr/bin/env bash\nmkdir -p chats && echo x >chats/h.md && git add -f chats/h.md\n' >"$VAULT/.git/hooks/pre-commit"
chmod +x "$VAULT/.git/hooks/pre-commit"
make_dirty
before="$(head_sha)"
run_guard -m "save"
assert_eq "hooks/pre-commit-forbidden-refused" "1" "$STATUS" "$(evidence)"
assert_eq "hooks/pre-commit-forbidden-head-unmoved" "$before" "$(head_sha)" "$(evidence)"

# --- 21d5. a successful commit leaves the shared index in line with HEAD -----
# The committed paths are reset to the new commit in the shared index; without
# that, the index still holds the old blob and a later commit reverts it.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
run_guard -m "save"
assert_eq "sync/commits" "0" "$STATUS" "$(evidence)"
assert_eq "sync/index-matches-head" "0" "$(staged_count)" "staged: [$(staged_list | tr '\n' ' ')]" "$(evidence)"
assert_eq "sync/no-private-index-left" "0" \
  "$(ls "$VAULT/.git" | grep -c '^vault-commit-index' || true)" "$(evidence)"

# --- 21d5b. the sync outlasts a lock held across several tries (INNOV-377) ---
# Observed: something on the machine held index.lock right after the commit, and
# the old 0/1/2 s retries all lost to it. A `git` wrapper holds a real index.lock
# around the first $1 sync calls (the pathspec-from-file reset), then gets out of
# the way. 4 locked tries fails the old three-try loop: the negative control.
make_lock_wrap() { # locked-tries
  GIT_WRAP="$BOX/lockwrap"
  mkdir -p "$GIT_WRAP"
  cat >"$GIT_WRAP/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" reset "*"--pathspec-from-file=-"*)
    n=\$(cat "$BOX/lockwrap/n" 2>/dev/null || echo 0)
    if [[ \$n -lt $1 ]]; then
      echo \$((n + 1)) >"$BOX/lockwrap/n"
      : >"$VAULT/.git/index.lock"
      "$REAL_GIT" "\$@"; rc=\$?
      rm -f "$VAULT/.git/index.lock"
      exit \$rc
    fi ;;
esac
exec "$REAL_GIT" "\$@"
SH
  chmod +x "$GIT_WRAP/git"
}
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
make_lock_wrap 4
run_guard -m "save"
GIT_WRAP=""
assert_eq "sync-lock/wrapper-fired" "4" "$(cat "$BOX/lockwrap/n" 2>/dev/null)" "$(evidence)"
assert_eq "sync-lock/commits" "0" "$STATUS" "$(evidence)"
assert_eq "sync-lock/lands-within-window" "0" "$(staged_count)" "staged: [$(staged_list | tr '\n' ' ')]" "$(evidence)"
assert_not_contains "sync-lock/no-warning" "WARNING" "$(out_all)" "$(evidence)"

# --- 21d5c. a lock that never clears: the WARNING and remedy print LAST ------
# The caller reads the head of the output, and the warning used to sit before
# "Push when ready", after the committed-path list. Now it is the tail, and the
# printed remedy (the script's own --no-renames listing) actually clears it.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
echo "new" >"$VAULT/logs/new.md"
make_lock_wrap 99
run_guard -m "save"
GIT_WRAP=""
last="$(tail -n 1 "$BOX/out.txt" | tr -d '\r')"
assert_eq "sync-lock/never-clears-commits" "0" "$STATUS" "$(evidence)"
assert_contains "sync-lock/warning-in-tail" "WARNING" "$(tail -n 5 "$BOX/out.txt")" "$(evidence)"
assert_contains "sync-lock/remedy-is-last-line" "reset -q HEAD --" "$last" "$(evidence)"
# INNOV-389: the warning names its cause. git's own stderr from the last try is
# printed inside the block; it used to go to /dev/null, so a held lock could not be
# told from any other failure.
assert_contains "sync-lock/warning-says-what-git-said" "git said:" \
  "$(sed -n '/WARNING/,$p' "$BOX/out.txt")" "$(evidence)"
assert_contains "sync-lock/git-error-names-the-lock" "index.lock" \
  "$(sed -n '/WARNING/,$p' "$BOX/out.txt")" "$(evidence)"
assert_contains "sync-lock/remedy-literal-pathspecs" "--literal-pathspecs" "$last" "$(evidence)"
assert_not_contains "sync-lock/push-not-after-warning" "Push when ready" \
  "$(sed -n '/WARNING/,$p' "$BOX/out.txt")" "$(evidence)"
assert_eq "sync-lock/index-stale-before-remedy" "2" "$(git -C "$VAULT" diff --cached --name-only HEAD | grep -c . || true)" "$(evidence)"
eval "$last"
assert_eq "sync-lock/remedy-clears-index" "0" "$(git -C "$VAULT" diff --cached --name-only HEAD | grep -c . || true)" "$(evidence)"

# --- 21e. a staged RENAME out of a forbidden path is seen by its source -----
# With rename detection, `diff --cached --name-only` prints only the destination,
# so a rename chats/ -> logs/ read as an allowlisted logs/ path, and the commit
# carried the chats/ deletion. Both index reads must list the source too.
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/chats"
echo "private transcript" >"$VAULT/chats/old.md"
git -C "$VAULT" add -f chats/old.md >/dev/null 2>&1
git -C "$VAULT" commit -qm "a tracked private file" >/dev/null 2>&1
git -C "$VAULT" mv chats/old.md logs/old.md >/dev/null 2>&1   # "another session"
make_dirty
before="$(head_sha)"
run_guard -m "would carry a chats/ rename"
assert_eq "index/rename-refused" "1" "$STATUS" "$(evidence)"
assert_eq "index/rename-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "index/rename-names-the-source" "chats/old.md" "$(out_all)" "$(evidence)"

# --- 22. no .saveinclude => REFUSE, never a permissive default ------------
# There is no safe fallback: committing everything publishes chats/, committing
# nothing makes every save a silent no-op. So it fails closed.
sb_new "brain/work"
GH_PATH="$GH_NONE"
rm -f "$VAULT/.saveinclude"
make_dirty
before="$(head_sha)"
run_guard -m "no allowlist"
assert_eq "allowlist/missing-refused" "1" "$STATUS" "$(evidence)"
assert_eq "allowlist/missing-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_eq "allowlist/missing-stages-nothing" "0" "$(staged_count)" "$(evidence)"
assert_contains "allowlist/missing-names-the-remedy" ".saveinclude" "$(out_all)" "$(evidence)"

# --- 23. an all-comments .saveinclude is an EMPTY allowlist, and refuses ---
sb_new "brain/work"
GH_PATH="$GH_NONE"
printf '# everything is commented out\n\n' >"$VAULT/.saveinclude"
make_dirty
run_guard -m "empty allowlist"
assert_eq "allowlist/empty-refused" "1" "$STATUS" "$(evidence)"
assert_contains "allowlist/empty-explains" "no entries" "$(out_all)" "$(evidence)"

# --- 24. a caller asking for a non-allowlisted path is refused, not trimmed --
# Silently dropping it would make the caller's commit quietly incomplete, which
# is worse than a loud refusal: the caller believes it committed something it did not.
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/chats"
echo "x" >"$VAULT/chats/secret.md"
make_dirty
run_guard -m "explicit bad path" -- chats/
assert_eq "allowlist/explicit-bad-path-refused" "1" "$STATUS" "$(evidence)"
assert_contains "allowlist/explicit-bad-path-named" "chats" "$(out_all)" "$(evidence)"

# --- 25. a caller CAN ask for a subset of the allowlist -------------------
# sync-graph.sh does exactly this: it commits the two paths it wrote, not the
# whole allowlist, so it does not sweep up another command's session log.
sb_new "brain/work"
GH_PATH="$GH_NONE"
echo "a log entry" >"$VAULT/logs/2026-08-05-other.md"
make_dirty
run_guard -m "subset only" -- wiki/log.md
assert_eq "allowlist/subset-commits" "0" "$STATUS" "$(evidence)"
assert_eq "allowlist/subset-excluded-path-not-committed" "0" \
  "$(git -C "$VAULT" ls-files logs/ 2>/dev/null | grep -c . || true)" "$(evidence)"
assert_contains "allowlist/subset-included-path-committed" "wiki/log.md" \
  "$(git -C "$VAULT" ls-files 2>/dev/null | tr '\n' ' ')" "$(evidence)"

# --- 26. an allowlist entry with nothing on disk is skipped, not an error --
# A fresh vault has no graphify-out/ yet. An allowlist naming a path the vault
# does not have is normal and must never fail a save.
sb_new "brain/work"
GH_PATH="$GH_NONE"
printf 'wiki/log.md\ngraphify-out/graph.json\ngraphify-out/communities/\nlogs/\n' >"$VAULT/.saveinclude"
make_dirty
run_guard -m "missing entries are fine"
assert_eq "allowlist/absent-entry-not-an-error" "0" "$STATUS" "$(evidence)"
assert_prefix "allowlist/absent-entry-verdict-OK" "VAULT-COMMIT: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"

# --- 26b. a non-ASCII file name under an allowlisted dir commits (INNOV-323) --
# graphify community stubs take their name from the label, em dash and all. Read
# with core.quotepath, git hands back "\342\200\224" in quotes, which no
# .saveinclude glob matches, so an allowlisted stub was refused as foreign.
# Each sandbox pins core.quotepath on: a global quotepath=false would let a
# newline-delimited read see the name verbatim and hide the bug.
EMDASH=$'\xe2\x80\x94'
STUB="graphify-out/communities/IXS-ACC ${EMDASH} Accessibility Floor.md"
sb_new "brain/work"
git -C "$VAULT" config core.quotepath true
GH_PATH="$GH_NONE"
printf 'wiki/log.md\ngraphify-out/communities/\n' >"$VAULT/.saveinclude"
mkdir -p "$VAULT/graphify-out/communities"
echo "stub" >"$VAULT/$STUB"
run_guard -m "non-ascii stub"
assert_eq "nonascii/staged-by-guard-commits" "0" "$STATUS" "$(evidence)"
assert_eq "nonascii/staged-by-guard-in-head" "$STUB" \
  "$(git -C "$VAULT" ls-tree -r -z --name-only HEAD -- graphify-out/communities | tr -d '\0')" "$(evidence)"

# Same stub, already in the shared index, under a CRLF .saveinclude: this is the
# pre-staged read (read_index), a separate listing from the tree check above.
sb_new "brain/work"
git -C "$VAULT" config core.quotepath true
GH_PATH="$GH_NONE"
printf 'wiki/log.md\r\ngraphify-out/communities/\r\n' >"$VAULT/.saveinclude"
mkdir -p "$VAULT/graphify-out/communities"
echo "stub" >"$VAULT/$STUB"
git -C "$VAULT" add -- "$STUB" >/dev/null 2>&1
run_guard -m "pre-staged non-ascii stub"
assert_eq "nonascii/pre-staged-commits" "0" "$STATUS" "$(evidence)"
assert_eq "nonascii/pre-staged-in-head" "$STUB" \
  "$(git -C "$VAULT" ls-tree -r -z --name-only HEAD -- graphify-out/communities | tr -d '\0')" "$(evidence)"

# Negative control: a non-ASCII path the allowlist does NOT cover is still
# refused, and named as written rather than octal-quoted.
sb_new "brain/work"
git -C "$VAULT" config core.quotepath true
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/private"
echo "x" >"$VAULT/private/a ${EMDASH} b.md"
git -C "$VAULT" add -- "private/a ${EMDASH} b.md" >/dev/null 2>&1
before="$(head_sha)"
run_guard -m "foreign non-ascii"
assert_eq "nonascii/foreign-refused" "1" "$STATUS" "$(evidence)"
assert_eq "nonascii/foreign-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "nonascii/foreign-named-verbatim" "private/a ${EMDASH} b.md" "$(out_all)" "$(evidence)"

echo "--- F. arguments, vault resolution, and other preconditions ---"

# --- 27. no message => refuse --------------------------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
run_guard
assert_eq "args/no-message-refused" "1" "$STATUS" "$(evidence)"
assert_contains "args/no-message-explains" "commit message" "$(out_all)" "$(evidence)"

# --- 28. an unknown flag is refused, never silently ignored ---------------
# A typo'd flag that is ignored is a guard that quietly did not apply.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "x" --no-such-flag
assert_eq "args/unknown-flag-refused" "1" "$STATUS" "$(evidence)"
assert_eq "args/unknown-flag-head-unmoved" "$before" "$(head_sha)" "$(evidence)"

# --- 29. flags may follow the path arguments -----------------------------
# Callers build these argv lists programmatically; argument order is a silly
# thing to have to get right.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
sha="$(head_sha)"
run_guard -m "flags after paths" --pin "brain/work:$sha"
assert_eq "args/flag-order-independent" "0" "$STATUS" "$(evidence)"

# --- 30. not a vault => refuse, and touch nothing ------------------------
# The guard must not be pointable at some unrelated repo by a wrong BRAIN_ROOT.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/not-a-vault"
mkdir -p "$VAULT/src"
git -C "$VAULT" init -q -b feature >/dev/null 2>&1
git -C "$VAULT" config user.email t@example.com
git -C "$VAULT" config user.name "T"
echo "code" >"$VAULT/src/main.js"
GH_PATH="$GH_NONE"
run_guard -m "should never touch this repo"
assert_eq "vault/non-vault-refused" "1" "$STATUS" "$(evidence)"
assert_contains "vault/non-vault-explains" "brain vault" "$(out_all)" "$(evidence)"
assert_eq "vault/non-vault-index-untouched" "0" "$(staged_count)" "$(evidence)"

# --- 31. a vault that is not a git repo => refuse ------------------------
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
printf 'wiki/log.md\n' >"$VAULT/.saveinclude"
echo "log" >"$VAULT/wiki/log.md"
GH_PATH="$GH_NONE"
run_guard -m "nowhere to commit"
assert_eq "vault/non-git-refused" "1" "$STATUS" "$(evidence)"
assert_contains "vault/non-git-explains" "not a git repo" "$(out_all)" "$(evidence)"

# --- 32. exactly one verdict line, on exactly one stream ------------------
# The contract is that a caller can branch on the first line without parsing
# prose. Two verdict lines, or a verdict on the wrong stream, breaks that.
sb_new "main"
GH_PATH="$GH_NONE"
make_dirty
run_guard -m "refused"
verdicts="$(cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -c '^VAULT-COMMIT: ' || true)"
assert_eq "contract/refusal-has-exactly-one-verdict-line" "1" "$verdicts" "$(evidence)"
assert_eq "contract/refusal-stdout-carries-no-verdict" "0" \
  "$(grep -c '^VAULT-COMMIT: ' "$BOX/out.txt" 2>/dev/null || true)" "$(evidence)"

sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
run_guard -m "committed"
assert_eq "contract/success-has-exactly-one-verdict-line" "1" \
  "$(cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -c '^VAULT-COMMIT: ' || true)" "$(evidence)"
assert_eq "contract/success-stderr-carries-no-verdict" "0" \
  "$(grep -c '^VAULT-COMMIT: ' "$BOX/err.txt" 2>/dev/null || true)" "$(evidence)"

echo "--- G. --pr-paths: PR-bound commits of named paths outside the allowlist ---"
# INNOV-363. Trusted notes (wiki/<area>/*.md) are off .saveinclude by design, so
# /brain:promote, /brain:tidy and /brain:verify committed them with raw git and
# re-implemented the guards in prose. --pr-paths gives them this script's guards
# instead: the protected-branch refusal and the pin (both non-overridable), the
# open-PR guard, an EMPTY index before staging, and exactly the named paths.

# A trusted-note edit: a path the allowlist does not cover.
make_trusted_dirty() { mkdir -p "$VAULT/wiki/area"; echo "fact $RANDOM" >>"$VAULT/wiki/area/note.md"; }

# --- 33. a named trusted path commits on a working branch -------------------
sb_new "brain/work"
GH_PATH="$GH_NOPR"
make_trusted_dirty
make_dirty                                   # an allowlisted change NOT named
before="$(head_sha)"
run_guard -m "verify: 1 verified" --pin "brain/work:$before" --pr-paths wiki/area/note.md
assert_eq "pr-paths/commits-exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "pr-paths/verdict-line" "VAULT-COMMIT: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_eq "pr-paths/commit-message-used" "verify: 1 verified" "$(head_subject)" "$(evidence)"
assert_eq "pr-paths/commits-only-the-named-path" "wiki/area/note.md" \
  "$(git -C "$VAULT" show --name-only --format= HEAD | tr -d '\r')" "$(evidence)"
assert_contains "pr-paths/unnamed-change-left-in-tree" "wiki/log.md" \
  "$(git -C "$VAULT" status --porcelain)" "$(evidence)"

# --- 34. a named deletion is staged (promote drops and moves drafts) --------
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/wiki/_drafts"
echo "draft" >"$VAULT/wiki/_drafts/d.md"
git -C "$VAULT" add -A >/dev/null 2>&1
git -C "$VAULT" commit -qm "a draft" >/dev/null 2>&1
rm "$VAULT/wiki/_drafts/d.md"
make_trusted_dirty
before="$(head_sha)"
run_guard -m "promote" --pin "brain/work:$before" --pr-paths wiki/_drafts/d.md wiki/area/note.md
assert_eq "pr-paths/deletion-exit-0" "0" "$STATUS" "$(evidence)"
assert_contains "pr-paths/deletion-committed" "D	wiki/_drafts/d.md" \
  "$(git -C "$VAULT" show --name-status --format= HEAD | tr -d '\r')" "$(evidence)"

# --- 35. refuses on the protected branch, even pinned and named -------------
sb_new "main"
GH_PATH="$GH_NONE"
make_trusted_dirty
before="$(head_sha)"
run_guard -m "onto main" --pin "main:$before" --pr-paths wiki/area/note.md --force-commit
assert_eq "pr-paths/protected-refused" "1" "$STATUS" "$(evidence)"
assert_prefix "pr-paths/protected-verdict" "VAULT-COMMIT: REFUSED" "$(first_line "$BOX/err.txt")" "$(evidence)"
assert_eq "pr-paths/protected-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_eq "pr-paths/protected-index-untouched" "0" "$(staged_count)" "$(evidence)"
assert_contains "pr-paths/protected-reason" "protected/default branch" "$(out_all)" "$(evidence)"

# --- 36. refuses on a moved pin ---------------------------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
stale_sha="$(head_sha)"
make_dirty
git -C "$VAULT" commit -qam "concurrent session commit" >/dev/null 2>&1
make_trusted_dirty
now_sha="$(head_sha)"
run_guard -m "mine" --pin "brain/work:$stale_sha" --pr-paths wiki/area/note.md
assert_eq "pr-paths/moved-pin-refused" "1" "$STATUS" "$(evidence)"
assert_eq "pr-paths/moved-pin-head-unmoved" "$now_sha" "$(head_sha)" "$(evidence)"
assert_eq "pr-paths/moved-pin-index-untouched" "0" "$(staged_count)" "$(evidence)"
assert_contains "pr-paths/moved-pin-reason" "HEAD moved" "$(out_all)" "$(evidence)"

# --- 37. the pin is REQUIRED: no pin is a refusal, never "unpinned" ---------
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_trusted_dirty
before="$(head_sha)"
run_guard -m "unpinned" --pr-paths wiki/area/note.md
assert_eq "pr-paths/no-pin-refused" "1" "$STATUS" "$(evidence)"
assert_contains "pr-paths/no-pin-explains" "--pr-paths needs --pin" "$(out_all)" "$(evidence)"
assert_eq "pr-paths/no-pin-head-unmoved" "$before" "$(head_sha)" "$(evidence)"

# --- 38. refuses when a stray path is already staged — BEFORE staging -------
# Unlike the default mode's allowlist check, this refuses on ANY staged path,
# allowlisted or not: the PR must carry exactly what the caller named.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
git -C "$VAULT" add wiki/log.md >/dev/null 2>&1   # "another session"
make_trusted_dirty
before="$(head_sha)"
run_guard -m "stray" --pin "brain/work:$before" --pr-paths wiki/area/note.md
assert_eq "pr-paths/stray-refused" "1" "$STATUS" "$(evidence)"
assert_eq "pr-paths/stray-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "pr-paths/stray-named" "wiki/log.md" "$(out_all)" "$(evidence)"
assert_contains "pr-paths/stray-reason" "already holds" "$(out_all)" "$(evidence)"
assert_eq "pr-paths/stray-named-path-not-staged" "wiki/log.md" "$(staged_list | tr -d '\r')" "$(evidence)"

# --- 39. refuses a gitignored path ------------------------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
printf 'private/\n' >"$VAULT/.gitignore"
git -C "$VAULT" add .gitignore >/dev/null 2>&1
git -C "$VAULT" commit -qm "ignore private" >/dev/null 2>&1
mkdir -p "$VAULT/private"
echo "secret" >"$VAULT/private/x.md"
before="$(head_sha)"
run_guard -m "ignored" --pin "brain/work:$before" --pr-paths private/x.md
assert_eq "pr-paths/gitignored-refused" "1" "$STATUS" "$(evidence)"
assert_contains "pr-paths/gitignored-named" "private/x.md" "$(out_all)" "$(evidence)"
assert_contains "pr-paths/gitignored-reason" "gitignored" "$(out_all)" "$(evidence)"
assert_eq "pr-paths/gitignored-index-untouched" "0" "$(staged_count)" "$(evidence)"

# --- 40. refuses chats/, including via a '..' walk --------------------------
for p in chats/secret.md wiki/../chats/secret.md; do
  sb_new "brain/work"
  GH_PATH="$GH_NONE"
  mkdir -p "$VAULT/chats"
  echo "private transcript" >"$VAULT/chats/secret.md"
  before="$(head_sha)"
  run_guard -m "chats" --pin "brain/work:$before" --pr-paths "$p"
  assert_eq "pr-paths/chats-refused/$p" "1" "$STATUS" "$(evidence)"
  assert_eq "pr-paths/chats-index-untouched/$p" "0" "$(staged_count)" "$(evidence)"
  assert_contains "pr-paths/chats-reason/$p" "chats/" "$(out_all)" "$(evidence)"
done

# --- 41. --pr-paths with no path is a refusal, never "the whole allowlist" ---
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "nothing named" --pin "brain/work:$before" --pr-paths
assert_eq "pr-paths/no-paths-refused" "1" "$STATUS" "$(evidence)"
assert_eq "pr-paths/no-paths-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "pr-paths/no-paths-reason" "names no path" "$(out_all)" "$(evidence)"

# --- 42. the open-PR guard still applies ------------------------------------
sb_new "brain/work"
GH_PATH="$GH_PR"
make_trusted_dirty
before="$(head_sha)"
run_guard -m "onto a PR" --pin "brain/work:$before" --pr-paths wiki/area/note.md
assert_eq "pr-paths/open-pr-refused" "1" "$STATUS" "$(evidence)"
assert_contains "pr-paths/open-pr-named" "4242" "$(out_all)" "$(evidence)"

# --- 43. only literal FILE paths: a glob or a directory would sweep in
# unreviewed drafts and unnamed edits, and "covered by a named path" would pass.
for p in '*' 'wiki' 'wiki/*.md'; do
  sb_new "brain/work"
  GH_PATH="$GH_NONE"
  mkdir -p "$VAULT/wiki/_drafts"
  echo "unreviewed" >"$VAULT/wiki/_drafts/unreviewed.md"
  make_trusted_dirty
  before="$(head_sha)"
  run_guard -m "sweep" --pin "brain/work:$before" --pr-paths "$p"
  assert_eq "pr-paths/not-a-file-refused/$p" "1" "$STATUS" "$(evidence)"
  assert_eq "pr-paths/not-a-file-head-unmoved/$p" "$before" "$(head_sha)" "$(evidence)"
  assert_eq "pr-paths/not-a-file-index-untouched/$p" "0" "$(staged_count)" "$(evidence)"
done

# --- 44. a TRACKED file under a newer ignore rule is still gitignored ---------
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/private"
echo "secret" >"$VAULT/private/x.md"
git -C "$VAULT" add private/x.md >/dev/null 2>&1
git -C "$VAULT" commit -qm "tracked before the rule" >/dev/null 2>&1
printf 'private/\n' >"$VAULT/.gitignore"
git -C "$VAULT" add .gitignore >/dev/null 2>&1
git -C "$VAULT" commit -qm "ignore private" >/dev/null 2>&1
echo "more" >>"$VAULT/private/x.md"
before="$(head_sha)"
run_guard -m "tracked ignored" --pin "brain/work:$before" --pr-paths private/x.md
assert_eq "pr-paths/tracked-ignored-refused" "1" "$STATUS" "$(evidence)"
assert_eq "pr-paths/tracked-ignored-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "pr-paths/tracked-ignored-reason" "(gitignored)" "$(out_all)" "$(evidence)"

# --- 45. a path that neither exists nor is tracked refuses with NOTHING staged,
# even when an earlier named path is valid (no half-staged index to recover).
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_trusted_dirty
before="$(head_sha)"
run_guard -m "typo" --pin "brain/work:$before" --pr-paths wiki/area/note.md wiki/area/typo.md
assert_eq "pr-paths/missing-refused" "1" "$STATUS" "$(evidence)"
assert_contains "pr-paths/missing-named" "wiki/area/typo.md" "$(out_all)" "$(evidence)"
assert_eq "pr-paths/missing-index-untouched" "0" "$(staged_count)" "$(evidence)"

# --- 46. named paths with no change refuse: the caller expected a commit, and an
# exit 0 would let it push and open a PR without its edits.
sb_new "brain/work"
GH_PATH="$GH_NONE"
before="$(head_sha)"
run_guard -m "no change" --pin "brain/work:$before" --pr-paths wiki/hot.md
assert_eq "pr-paths/no-change-refused" "1" "$STATUS" "$(evidence)"
assert_contains "pr-paths/no-change-reason" "no changes" "$(out_all)" "$(evidence)"

# --- 47. INNOV-380: a commit advances this session's own pin -----------------
# A save that needs a second commit (a hot.md budget trim) re-reads the pin with
# --print-pin. Before the fix the record still held the pre-commit sha, so the
# session's own first commit read as "HEAD moved" and the second was refused.
SESSION_SH="$REPO_ROOT/brain/bin/session.sh"
SID="vc-sess-380"
run_guard_sid() { # [args...] — run_guard under this session's identity
  (
    cd "$VAULT" || exit 127
    unset CLAUDE_PROJECT_DIR
    export PATH="$GH_NONE:$PATH"
    BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="$SID" bash "$GUARD" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}
recorded_pin() {
  BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="$SID" bash "$SESSION_SH" --print-pin 2>/dev/null \
    | sed -n 's/^  pin: //p' | head -n 1 | tr -d '\r'
}

recorded_pid() { grep -o '"pid": [0-9]*' "$VAULT/.brain/session.json" 2>/dev/null | head -n 1; }

sb_new "main"
BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="$SID" bash "$SESSION_SH" --start save >/dev/null 2>&1
pid_start="$(recorded_pid)"
make_dirty
run_guard_sid -m "save" --pin "$(recorded_pin)"
assert_eq "repin/first-commit-ok" "0" "$STATUS" "$(evidence)"
# The repin runs in vault-commit's short-lived shell; recording THAT pid would let
# the pid reap (Linux/macOS) read the still-running save as a dead session.
assert_eq "repin/start-pid-kept" "$pid_start" "$(recorded_pid)" "$(evidence)"
assert_eq "repin/pin-sha-is-new-head" "$(head_sha)" "$(p="$(recorded_pin)"; echo "${p#*:}")" "$(evidence)"
echo "trimmed hot" >"$VAULT/wiki/hot.md"
run_guard_sid -m "budget trim" --pin "$(recorded_pin)"
assert_eq "repin/second-commit-ok" "0" "$STATUS" "$(evidence)"
assert_eq "repin/second-commit-landed" "budget trim" "$(head_subject)" "$(evidence)"

# --- 48. ...but a FOREIGN commit between them is still refused (negative control)
# The repin follows only the move this run made; it must never adopt another
# session's commit, or the moved-HEAD guard is gone.
sb_new "main"
BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="$SID" bash "$SESSION_SH" --start save >/dev/null 2>&1
make_dirty
run_guard_sid -m "save" --pin "$(recorded_pin)"
assert_eq "repin-foreign/first-commit-ok" "0" "$STATUS" "$(evidence)"
mine="$(head_sha)"
echo "foreign" >>"$VAULT/wiki/hot.md"
git -C "$VAULT" commit -qam "foreign session commit" >/dev/null 2>&1
foreign="$(head_sha)"
make_dirty
run_guard_sid -m "must refuse" --pin "$(recorded_pin)"
assert_eq "repin-foreign/second-commit-refused" "1" "$STATUS" "$(evidence)"
assert_eq "repin-foreign/head-unmoved" "$foreign" "$(head_sha)" "$(evidence)"
assert_eq "repin-foreign/pin-not-adopted" "$mine" "$(p="$(recorded_pin)"; echo "${p#*:}")" "$(evidence)"

# --- 48b. a foreign commit right after this run's ref update: no repin -------
# The sync sees HEAD past this commit, so the pin must stay at the pre-commit
# sha; repinning to this commit would make runtime.mjs's own before->HEAD repin
# refuse and report a landed commit as a failure.
sb_new "main"
BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="$SID" bash "$SESSION_SH" --start save >/dev/null 2>&1
pin_start="$(recorded_pin)"
make_dirty
make_git_wrap "echo newer >>wiki/hot.md && '$REAL_GIT' add wiki/hot.md && '$REAL_GIT' commit -qm newer" "update-ref" after
(export BRAIN_SESSION_ID="$SID"; run_guard -m "save" --pin "$pin_start")
GIT_WRAP=""
assert_eq "repin-race/wrapper-fired" "yes" "$([[ -f "$BOX/wrap/fired" ]] && echo yes)" "$(evidence)"
assert_eq "repin-race/foreign-is-head" "newer" "$(head_subject)" "$(evidence)"
assert_eq "repin-race/pin-not-advanced" "$pin_start" "$(recorded_pin)" "$(evidence)"

# --- 49. no explicit session id => no repin ---------------------------------
# Without BRAIN_SESSION_ID / CLAUDE_CODE_SESSION_ID, session.sh resolves the
# last-started id, which can be ANOTHER session that started on the same sha:
# repinning it would adopt this commit into that session's pin.
sb_new "main"
(unset BRAIN_SESSION_ID CLAUDE_CODE_SESSION_ID; BRAIN_ROOT="$VAULT" bash "$SESSION_SH" --start save >/dev/null 2>&1)
pin_start="$(unset BRAIN_SESSION_ID CLAUDE_CODE_SESSION_ID; BRAIN_ROOT="$VAULT" bash "$SESSION_SH" --print-pin 2>/dev/null | sed -n 's/^  pin: //p' | tr -d '\r')"
make_dirty
(unset BRAIN_SESSION_ID CLAUDE_CODE_SESSION_ID; run_guard -m "anonymous" --pin "$pin_start")
assert_ne "repin-anon/committed" "${pin_start#*:}" "$(head_sha)" "$(evidence)"
assert_eq "repin-anon/pin-untouched" "$pin_start" \
  "$(unset BRAIN_SESSION_ID CLAUDE_CODE_SESSION_ID; BRAIN_ROOT="$VAULT" bash "$SESSION_SH" --print-pin 2>/dev/null | sed -n 's/^  pin: //p' | tr -d '\r')" "$(evidence)"
# ...nor with an id session.sh sanitizes to empty: it falls back the same way,
# even when CLAUDE_CODE_SESSION_ID is valid (BRAIN_SESSION_ID wins when set).
sb_new "main"
(unset BRAIN_SESSION_ID CLAUDE_CODE_SESSION_ID; BRAIN_ROOT="$VAULT" bash "$SESSION_SH" --start save >/dev/null 2>&1)
pin_start="$(unset BRAIN_SESSION_ID CLAUDE_CODE_SESSION_ID; BRAIN_ROOT="$VAULT" bash "$SESSION_SH" --print-pin 2>/dev/null | sed -n 's/^  pin: //p' | tr -d '\r')"
make_dirty
(export BRAIN_SESSION_ID='!' CLAUDE_CODE_SESSION_ID="$SID"; run_guard -m "sanitized-away id" --pin "$pin_start")
assert_ne "repin-anon/sanitized-id-committed" "${pin_start#*:}" "$(head_sha)" "$(evidence)"
assert_eq "repin-anon/sanitized-id-pin-untouched" "$pin_start" \
  "$(unset BRAIN_SESSION_ID CLAUDE_CODE_SESSION_ID; BRAIN_ROOT="$VAULT" bash "$SESSION_SH" --print-pin 2>/dev/null | sed -n 's/^  pin: //p' | tr -d '\r')" "$(evidence)"

# ------------------------------------------------------------------ done ---
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
