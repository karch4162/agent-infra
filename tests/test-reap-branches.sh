#!/usr/bin/env bash
# test-reap-branches.sh — deterministic quality gate for brain/bin/reap-branches.sh
#
# Contract under test (INNOV-309 slice 1):
#   After a save has committed, leave the checkout on the default branch and
#   delete the brain/* branches whose work has already landed.
#     - merged brain/* branches are deleted; the checkout ends on the default
#     - an UNMERGED branch is NEVER deleted, even when pushed with -u (INNOV-379):
#       the script reports it under KEPT, and the commits are still reachable
#     - branches outside the brain/* namespace are never touched
#     - the default branch fast-forwards to origin/<default> when it is behind,
#       and a DIVERGED default is reported, never merged
#     - another live session in the checkout => REFUSED, nothing changed
#     - a switch git will not make (local changes in the way) => REFUSED, nothing
#       changed, nothing forced
#     - detached HEAD => REFUSED
#   Contract lines: "REAP: OK - ..." on stdout exit 0, "REAP: REFUSED - ..." on
#   stderr exit 1.
#
# Run:  bash tests/test-reap-branches.sh   (from anywhere)
# No network, no real vault. Never touches a vault outside its own sandbox.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
REAP="$REPO_ROOT/brain/bin/reap-branches.sh"

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
  local line
  for line in "$@"; do echo "     $line"; done
}

assert_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]" "actual:   [$3]"; fi
}

assert_contains() { # name haystack needle
  case "$2" in
    *"$3"*) pass "$1" ;;
    *)      fail "$1" "expected to contain: [$3]" "actual: [$2]" ;;
  esac
}

git_config() { # dir
  git -C "$1" config core.autocrlf false
  git -C "$1" config core.eol lf
  git -C "$1" config user.email "test@example.invalid"
  git -C "$1" config user.name "Harness"
  git -C "$1" config commit.gpgsign false
}

# Creates a sandbox and ASSIGNS the globals BOX / VAULT / REMOTE.
# Deliberately not in a command substitution: it exports state.
#
#   $REMOTE          a bare repo, origin, default branch 'main'
#   $VAULT           a clone of it, wiki/ + logs/, on 'main'
# Branch litter is added per case by the helpers below.
new_vault() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  REMOTE="$BOX/remote.git"
  VAULT="$BOX/vault"

  local seed="$BOX/seed"
  mkdir -p "$seed/wiki" "$seed/logs"
  printf '# hot\n' >"$seed/wiki/hot.md"
  printf '# log\n' >"$seed/logs/x.md"
  # session.sh --status REFUSES a vault with no allowlist, and the reap asks it
  # about concurrent sessions — so a vault without this file is not a fixture of
  # anything real.
  printf 'logs/\nwiki/hot.md\nwiki/log.md\n' >"$seed/.saveinclude"
  git -c core.autocrlf=false -c core.eol=lf init -q -b main "$seed" >/dev/null 2>&1
  git_config "$seed"
  git -C "$seed" add -A >/dev/null 2>&1
  git -C "$seed" commit -q -m "initial vault" >/dev/null 2>&1

  git init -q --bare -b main "$REMOTE" >/dev/null 2>&1
  git -C "$seed" remote add origin "$REMOTE" >/dev/null 2>&1
  git -C "$seed" push -q origin main >/dev/null 2>&1

  git -c core.autocrlf=false -c core.eol=lf clone -q "$REMOTE" "$VAULT" >/dev/null 2>&1
  git_config "$VAULT"
  # origin/HEAD is what detect_default_branch() reads first; a fresh clone sets it,
  # but make it explicit so the case does not depend on the git version.
  git -C "$VAULT" remote set-head origin main >/dev/null 2>&1
}

# A branch whose work has ALREADY LANDED on main: branch, commit, merge into main,
# leave the branch behind. This is the litter shape the ticket measured.
merged_branch() { # name
  git -C "$VAULT" checkout -q -b "$1" main
  printf '%s\n' "$1" >>"$VAULT/logs/x.md"
  git -C "$VAULT" commit -q -am "work on $1" >/dev/null 2>&1
  git -C "$VAULT" checkout -q main
  git -C "$VAULT" merge -q --no-edit "$1" >/dev/null 2>&1
}

# A branch with a commit that is NOT on main. Deleting this would lose work.
unmerged_branch() { # name
  git -C "$VAULT" checkout -q -b "$1" main
  printf 'unmerged work on %s\n' "$1" >>"$VAULT/logs/x.md"
  git -C "$VAULT" commit -q -am "unmerged work on $1" >/dev/null 2>&1
  git -C "$VAULT" checkout -q main
}

# Runs the script against $VAULT from OUTSIDE it, proving $BRAIN_ROOT resolution.
# stdout -> $BOX/out.txt, stderr -> $BOX/err.txt. Echoes the exit status.
run_reap() { # [args...]
  (
    cd "$BOX" || exit 99
    BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="test-self" bash "$REAP" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  echo $?
}

cur_branch() { git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null; }

branch_exists() { # name
  git -C "$VAULT" show-ref --verify --quiet "refs/heads/$1"
}

if [[ ! -f "$REAP" ]]; then
  fail "reap-branches.sh/exists" "brain/bin/reap-branches.sh does not exist at $REAP"
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi

# ============================================ merged litter is drained =======
new_vault
merged_branch "brain/save-2026-09-01"
merged_branch "brain/save-2026-09-02"
git -C "$VAULT" checkout -q -b "brain/save-2026-09-03" main   # the "current save"
merged_branch_head="$(git -C "$VAULT" rev-parse HEAD)"

status="$(run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "merged/exit-0" "0" "$status"
assert_contains "merged/ok-line" "$out" "REAP: OK -"
assert_eq "merged/ends-on-default" "main" "$(cur_branch)"
if branch_exists "brain/save-2026-09-01" || branch_exists "brain/save-2026-09-02"; then
  fail "merged/litter-deleted" "a fully merged brain/* branch survived the reap" "$out"
else
  pass "merged/litter-deleted"
fi
# The current save branch has no commits of its own here, so it too is merged.
assert_contains "merged/reports-count" "$out" "deleted 3 merged brain/* branch(es)"

# ================================== the load-bearing case: unmerged survives =
# `git branch -d` must refuse, the script must report it, and the commit must
# still be reachable afterwards. If this ever fails, the script is losing work.
new_vault
merged_branch "brain/save-2026-09-01"
unmerged_branch "brain/save-2026-09-09"
unmerged_sha="$(git -C "$VAULT" rev-parse "brain/save-2026-09-09")"
git -C "$VAULT" checkout -q "brain/save-2026-09-09"

status="$(run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "unmerged/exit-0" "0" "$status"
if branch_exists "brain/save-2026-09-09"; then
  pass "unmerged/branch-survives"
else
  fail "unmerged/branch-survives" "AN UNMERGED BRANCH WAS DELETED — work lost" "$out"
fi
assert_eq "unmerged/commit-still-reachable" \
  "$unmerged_sha" "$(git -C "$VAULT" rev-parse "brain/save-2026-09-09" 2>/dev/null)"
assert_contains "unmerged/reported-as-kept" "$out" "KEPT"
assert_contains "unmerged/named-in-output" "$out" "brain/save-2026-09-09"
assert_eq "unmerged/ends-on-default" "main" "$(cur_branch)"
if branch_exists "brain/save-2026-09-01"; then
  fail "unmerged/merged-sibling-still-drained" "the merged sibling survived" "$out"
else
  pass "unmerged/merged-sibling-still-drained"
fi

# ================================= branches outside brain/* are not touched ==
new_vault
merged_branch "feature/mine"
merged_branch "promote/notes"
merged_branch "brain/save-2026-09-01"
git -C "$VAULT" checkout -q main

status="$(run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "namespace/exit-0" "0" "$status"
if branch_exists "feature/mine" && branch_exists "promote/notes"; then
  pass "namespace/non-brain-branches-untouched"
else
  fail "namespace/non-brain-branches-untouched" "a branch outside brain/* was deleted" "$out"
fi
if branch_exists "brain/save-2026-09-01"; then
  fail "namespace/brain-branch-drained" "the brain/* branch survived" "$out"
else
  pass "namespace/brain-branch-drained"
fi

# ================================================ fast-forward from origin ===
new_vault
# Advance the remote behind our back, the way a merged PR does.
other="$BOX/other"
git -c core.autocrlf=false -c core.eol=lf clone -q "$REMOTE" "$other" >/dev/null 2>&1
git_config "$other"
printf 'landed elsewhere\n' >>"$other/logs/x.md"
git -C "$other" commit -q -am "landed via PR" >/dev/null 2>&1
git -C "$other" push -q origin main >/dev/null 2>&1
remote_sha="$(git -C "$other" rev-parse HEAD)"
git -C "$VAULT" checkout -q -b "brain/save-2026-09-10" main

status="$(run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "ff/exit-0" "0" "$status"
assert_eq "ff/default-advanced" "$remote_sha" "$(git -C "$VAULT" rev-parse main)"
assert_contains "ff/reported" "$out" "fast-forwarded 1 commit(s) from origin/main"

# ====================================== another live session => REFUSED ======
new_vault
merged_branch "brain/save-2026-09-01"
git -C "$VAULT" checkout -q -b "brain/save-2026-09-11" main
before_branch="$(cur_branch)"
# A real record written by the real writer, under a DIFFERENT session id.
BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="somebody-else" \
  bash "$REPO_ROOT/brain/bin/session.sh" --start "/brain:promote" >/dev/null 2>&1

status="$(run_reap)"
err="$(cat "$BOX/err.txt")"
assert_eq "concurrent/exit-1" "1" "$status"
assert_contains "concurrent/refused-line" "$err" "REAP: REFUSED - 1 other session(s) are live"
assert_eq "concurrent/branch-unchanged" "$before_branch" "$(cur_branch)"
if branch_exists "brain/save-2026-09-01"; then
  pass "concurrent/nothing-deleted"
else
  fail "concurrent/nothing-deleted" "a branch was deleted despite the refusal" "$err"
fi

# ============================ a switch git will not make => REFUSED, no force =
new_vault
git -C "$VAULT" checkout -q -b "brain/save-2026-09-12" main
printf 'work in progress\n' >>"$VAULT/logs/x.md"
git -C "$VAULT" commit -q -am "committed on the save branch" >/dev/null 2>&1
# An uncommitted change to the same file main has at a different content: the
# switch would have to overwrite it, so git refuses.
printf 'uncommitted\n' >>"$VAULT/logs/x.md"
before_branch="$(cur_branch)"
before_file="$(cat "$VAULT/logs/x.md")"

status="$(run_reap)"
err="$(cat "$BOX/err.txt")"
assert_eq "dirty/exit-1" "1" "$status"
assert_contains "dirty/refused-line" "$err" "REAP: REFUSED - could not switch"
assert_eq "dirty/branch-unchanged" "$before_branch" "$(cur_branch)"
assert_eq "dirty/worktree-unchanged" "$before_file" "$(cat "$VAULT/logs/x.md")"
# Negative control for the case below: the index matches HEAD here, so the
# missed-sync diagnosis must not fire on an ordinary worktree change.
case "$err" in
  *"reset -q HEAD"*) fail "dirty/no-index-remedy" "printed the index-sync remedy for a worktree change" "$err" ;;
  *)                 pass "dirty/no-index-remedy" ;;
esac

# ============== a missed vault-commit index sync => REFUSED, with the remedy ==
# INNOV-377: vault-commit.sh's post-commit sync lost to a held index.lock, so the
# shared index kept the pre-commit versions of the committed paths (a modified
# one as a staged revert, a new one untracked). git's own refusal ("untracked
# working tree files would be removed") does not say why; the reap must.
new_vault
git -C "$VAULT" checkout -q -b "brain/save-2026-10-04" main
printf 'saved\n' >>"$VAULT/logs/x.md"
printf 'a new log\n' >"$VAULT/logs/new.md"
git -C "$VAULT" add -A >/dev/null 2>&1
git -C "$VAULT" commit -qm "the save" >/dev/null 2>&1
git -C "$VAULT" reset -q HEAD~ -- logs/x.md logs/new.md   # the sync that never landed

status="$(run_reap)"
err="$(cat "$BOX/err.txt")"
assert_eq "stale-index/exit-1" "1" "$status"
assert_contains "stale-index/refused-line" "$err" "REAP: REFUSED - could not switch"
assert_contains "stale-index/says-why" "$err" "index sync"
assert_contains "stale-index/names-new-file" "$err" "logs/new.md"
assert_eq "stale-index/branch-unchanged" "brain/save-2026-10-04" "$(cur_branch)"
remedy="$(printf '%s\n' "$err" | grep 'reset -q HEAD --' | tail -n 1)"
assert_contains "stale-index/remedy-printed" "$remedy" "reset -q HEAD --"
assert_contains "stale-index/remedy-literal-pathspecs" "$remedy" "--literal-pathspecs"
eval "$remedy"
status="$(run_reap)"
assert_eq "stale-index/remedy-unblocks-reap" "0" "$status"
assert_eq "stale-index/on-main-after-remedy" "main" "$(cur_branch)"

# INNOV-455: a missed sync on a big save (1458 paths on 2026-11-17) printed every
# path on one line, too long to paste. Past the inline limit the exact list goes
# to a file under the git dir and the line stays short whatever the count. Names
# with a space and a non-ASCII character prove the file carries them verbatim.
new_vault
git -C "$VAULT" checkout -q -b "brain/save-2026-10-05" main
i=0
while [[ $i -lt 40 ]]; do
  printf 'log %s\n' "$i" >"$VAULT/logs/community number $i é with a long descriptive name.md"
  i=$((i + 1))
done
git -C "$VAULT" add -A >/dev/null 2>&1
git -C "$VAULT" commit -qm "the big save" >/dev/null 2>&1
git -C "$VAULT" reset -q HEAD~ -- logs/   # the sync that never landed

status="$(run_reap)"
err="$(cat "$BOX/err.txt")"
assert_eq "stale-index-big/exit-1" "1" "$status"
remedy="$(printf '%s\n' "$err" | grep 'reset -q HEAD --' | tail -n 1 | tr -d '\r')"
assert_contains "stale-index-big/remedy-reads-a-file" "$remedy" "--pathspec-from-file="
assert_contains "stale-index-big/remedy-literal-pathspecs" "$remedy" "--literal-pathspecs"
# 40 inline names are ~2400 chars; the file form is the vault path plus ~150.
if [[ ${#remedy} -lt $(( ${#VAULT} * 2 + 200 )) ]]; then pass "stale-index-big/remedy-is-short"
else fail "stale-index-big/remedy-is-short" "${#remedy} chars: $remedy"; fi
eval "$remedy"
assert_eq "stale-index-big/remedy-clears-index" "0" \
  "$(git -C "$VAULT" diff --cached --name-only HEAD | grep -c . || true)"
status="$(run_reap)"
assert_eq "stale-index-big/remedy-unblocks-reap" "0" "$status"

# A STAGED edit made after the commit, on a path the commit touched, also differs
# from HEAD, but it is somebody's work, not a missed sync: resetting it would
# drop it. The diagnosis must match the parent's content, not just the name.
new_vault
git -C "$VAULT" checkout -q -b "brain/save-2026-10-06" main
printf 'saved\n' >>"$VAULT/logs/x.md"
git -C "$VAULT" commit -q -am "the save" >/dev/null 2>&1
printf 'staged later\n' >>"$VAULT/logs/x.md"
git -C "$VAULT" add logs/x.md >/dev/null 2>&1
staged_blob="$(git -C "$VAULT" ls-files -s logs/x.md)"
status="$(run_reap)"
err="$(cat "$BOX/err.txt")"
assert_eq "staged-edit/exit-1" "1" "$status"
case "$err" in
  *"reset -q HEAD"*) fail "staged-edit/no-index-remedy" "offered a reset that would drop a staged edit" "$err" ;;
  *)                 pass "staged-edit/no-index-remedy" ;;
esac
assert_eq "staged-edit/index-untouched" "$staged_blob" "$(git -C "$VAULT" ls-files -s logs/x.md)"

# ================================================= detached HEAD => REFUSED ==
new_vault
git -C "$VAULT" checkout -q --detach main
status="$(run_reap)"
err="$(cat "$BOX/err.txt")"
assert_eq "detached/exit-1" "1" "$status"
assert_contains "detached/refused-line" "$err" "REAP: REFUSED - the vault is in DETACHED HEAD"

# ==================================================== not a vault => REFUSED =
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/notavault"
mkdir -p "$VAULT"
status="$(run_reap)"
err="$(cat "$BOX/err.txt")"
assert_eq "not-a-vault/exit-1" "1" "$status"
assert_contains "not-a-vault/refused-line" "$err" "doesn't look like a brain vault"

# ====================================================== unknown flag =========
new_vault
status="$(run_reap --wat)"
err="$(cat "$BOX/err.txt")"
assert_eq "unknown-flag/exit-1" "1" "$status"
assert_contains "unknown-flag/refused-line" "$err" "REAP: REFUSED - unknown argument"

# ================== kept-branch report: work that reached main by no route ===
# The real instance: a branch that ADDS notes absent from main and EDITS a file
# main has (the 9 hub notes + wiki/index.md). It must be flagged even though not
# every path is absent. main then moves on, so "behind" is non-zero.
new_vault
git -C "$VAULT" checkout -q -b "brain/promote-hub" main
printf 'hub note\n' >"$VAULT/wiki/hub-a.md"
printf 'edit\n' >>"$VAULT/wiki/hot.md"
git -C "$VAULT" add -A >/dev/null 2>&1
git -C "$VAULT" commit -q -m "hub notes" >/dev/null 2>&1
git -C "$VAULT" checkout -q main
merged_branch "brain/save-2026-09-01"
git -C "$VAULT" checkout -q main

status="$(run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "report-absent/exit-0" "0" "$status"
assert_contains "report-absent/ok-line-unchanged" "$(head -n 1 "$BOX/out.txt")" "REAP: OK - on 'main'"
assert_contains "report-absent/line" "$out" \
  "brain/promote-hub: 1 unmerged commit(s), 1 behind main, paths absent from main (1 of 2) — POSSIBLE LOST WORK"

# Negative control: a kept branch whose only path exists on main is reported, but
# is NOT called lost work. Fails if the flag fires on every kept branch.
new_vault
unmerged_branch "brain/save-2026-09-09"
status="$(run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "report-present/exit-0" "0" "$status"
assert_contains "report-present/line" "$out" \
  "brain/save-2026-09-09: 1 unmerged commit(s), 0 behind main, paths present on main"
case "$out" in
  *"POSSIBLE LOST WORK"*) fail "report-present/not-flagged" "flagged a branch whose paths are all on main" "$out" ;;
  *) pass "report-present/not-flagged" ;;
esac

# This save's own branch is normally kept with a new, absent log: tagged, not
# flagged, or every save would cry wolf.
new_vault
git -C "$VAULT" checkout -q -b "brain/save-2026-09-13" main
printf 'session\n' >"$VAULT/logs/2026-09-13.md"
git -C "$VAULT" add -A >/dev/null 2>&1
git -C "$VAULT" commit -q -m "save" >/dev/null 2>&1
status="$(run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "report-own/exit-0" "0" "$status"
assert_contains "report-own/tagged" "$out" \
  "brain/save-2026-09-13: 1 unmerged commit(s), 0 behind main, paths absent from main (1 of 1) (this save's branch, not landed yet)"
case "$out" in
  *"POSSIBLE LOST WORK"*) fail "report-own/not-flagged" "flagged this save's own branch" "$out" ;;
  *) pass "report-own/not-flagged" ;;
esac

# No kept branches => no report lines.
new_vault
merged_branch "brain/save-2026-09-01"
git -C "$VAULT" checkout -q main
status="$(run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "report-none/exit-0" "0" "$status"
case "$out" in
  *"unmerged commit"*|*KEPT*) fail "report-none/no-lines" "report lines with nothing kept" "$out" ;;
  *) pass "report-none/no-lines" ;;
esac

# =========================== pushed with -u but unmerged survives (INNOV-379) =
# The real instance: the save branch was pushed with `push -u` and a PR opened,
# then the reap deleted it. With an upstream set, `git branch -d` checks merged-ness
# against origin/<branch>, which equals the branch right after a push, so -d alone
# deletes unmerged work. The script must check against the default branch itself.
new_vault
git -C "$VAULT" checkout -q -b "brain/save-2026-10-04" main
printf 'session\n' >"$VAULT/logs/2026-10-04.md"
git -C "$VAULT" add -A >/dev/null 2>&1
git -C "$VAULT" commit -q -m "save" >/dev/null 2>&1
git -C "$VAULT" push -q -u origin "brain/save-2026-10-04" >/dev/null 2>&1
pushed_sha="$(git -C "$VAULT" rev-parse HEAD)"

# Negative control: the fixture really is the bug shape. Plain `git branch -d`, the
# only guard the script had before INNOV-379, deletes this unmerged branch.
cp -R "$VAULT" "$BOX/control"
git -C "$BOX/control" checkout -q main
if git -C "$BOX/control" branch -d "brain/save-2026-10-04" >/dev/null 2>&1; then
  pass "pushed/control-plain-d-deletes-it"
else
  fail "pushed/control-plain-d-deletes-it" "git branch -d refused; the fixture does not reproduce the bug"
fi

# A stub gh on PATH answers the open-PR lookup; the fixture remote is a local path,
# so a real gh could not.
mkdir -p "$BOX/stubbin"
cat >"$BOX/stubbin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "pr list" ]] && echo "https://github.com/example/vault/pull/166"
exit 0
EOF
chmod +x "$BOX/stubbin/gh"
status="$(PATH="$BOX/stubbin:$PATH" run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "pushed/exit-0" "0" "$status"
if branch_exists "brain/save-2026-10-04"; then
  pass "pushed/branch-survives"
else
  fail "pushed/branch-survives" "A PUSHED-BUT-UNMERGED BRANCH WAS DELETED" "$out"
fi
assert_eq "pushed/commit-still-reachable" \
  "$pushed_sha" "$(git -C "$VAULT" rev-parse "brain/save-2026-10-04" 2>/dev/null)"
assert_contains "pushed/reported-kept" "$out" "kept 1 unmerged"
assert_contains "pushed/pr-note" "$out" \
  "pushed to origin/brain/save-2026-10-04, open PR https://github.com/example/vault/pull/166"

# A pushed branch that HAS landed on main is still drained: the new check must not
# turn every pushed branch into litter.
new_vault
git -C "$VAULT" checkout -q -b "brain/save-2026-10-05" main
printf 'landed\n' >>"$VAULT/logs/x.md"
git -C "$VAULT" commit -q -am "landed" >/dev/null 2>&1
git -C "$VAULT" push -q -u origin "brain/save-2026-10-05" >/dev/null 2>&1
git -C "$VAULT" checkout -q main
git -C "$VAULT" merge -q --no-edit "brain/save-2026-10-05" >/dev/null 2>&1
status="$(run_reap)"
out="$(cat "$BOX/out.txt")"
assert_eq "pushed-merged/exit-0" "0" "$status"
if branch_exists "brain/save-2026-10-05"; then
  fail "pushed-merged/drained" "a pushed branch already merged into main survived" "$out"
else
  pass "pushed-merged/drained"
fi

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
