#!/usr/bin/env bash
# test-check-freshness.sh — deterministic quality gate for brain/bin/check-freshness.sh
#
# /brain:save REWRITES wiki/hot.md. Saving from a branch that is behind
# origin/main therefore silently reverts other people's edits. check-freshness.sh
# gets the branch current when it safely can, and blocks the hot.md rewrite when
# it can't.
#
# Contract under test:
#   exit 0 => safe to rewrite wiki/hot.md
#   exit 1 => do NOT rewrite wiki/hot.md (the rest of the save still proceeds)
#   first line of output starts with `FRESHNESS: OK` (stdout)
#                                 or `FRESHNESS: BLOCKED` (stderr)
#   vault resolved from $BRAIN_ROOT -> $CLAUDE_PROJECT_DIR -> $PWD
#   --no-merge reports state and exits 1 when behind, mutating nothing
#
# Run:  bash tests/test-check-freshness.sh   (from anywhere)
# No network: `origin` is a local bare repo in a temp dir. No real vault is
# touched. Every case gets its own fresh mktemp -d sandbox.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
FRESH="$REPO_ROOT/brain/bin/check-freshness.sh"
SESSION="$REPO_ROOT/brain/bin/session.sh"
VAULT_COMMIT="$REPO_ROOT/brain/bin/vault-commit.sh"

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
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

assert_ne() { # name not_expected actual [evidence...]
  local name="$1" nexp="$2" act="$3"
  shift 3
  if [[ "$nexp" != "$act" ]]; then
    pass "$name"
  else
    fail "$name" "expected value to CHANGE from: [$nexp]" "actual:   [$act]" "$@"
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

assert_true() { # name condition_result(0/1) [evidence...]
  local name="$1" rc="$2"
  shift 2
  if [[ "$rc" -eq 0 ]]; then
    pass "$name"
  else
    fail "$name" "$@"
  fi
}

# First line of a file, with any trailing CR stripped (Git Bash / CRLF safety).
first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }

evidence() { # box -> a few lines of captured output for failure messages
  local box="$1"
  echo "stdout: [$(tr '\n' '|' <"$box/out.txt" 2>/dev/null)]"
  echo "stderr: [$(tr '\n' '|' <"$box/err.txt" 2>/dev/null)]"
}

# --------------------------------------------------------- git sandboxing ---

# Applied at init/clone time so line endings are LF regardless of the machine's
# global core.autocrlf.
GITOPTS=(-c core.autocrlf=false -c core.eol=lf)

# Identity + settings so commits work on a machine with no global git identity,
# and so nothing prompts, signs, or reaches out.
gitcfg() { # repo
  git -C "$1" config user.email "freshness-test@example.invalid"
  git -C "$1" config user.name "Freshness Test"
  git -C "$1" config commit.gpgsign false
  git -C "$1" config tag.gpgsign false
  git -C "$1" config core.autocrlf false
  git -C "$1" config advice.detachedHead false
}

# Builds a fresh isolated sandbox and assigns the globals BOX / ORIGIN / SEED /
# VAULT. Deliberately NOT run inside a command substitution: a previous harness
# in this repo did that, the assignments were lost, and state leaked between
# cases. Call it as a plain statement.
BOX=""
ORIGIN=""
SEED=""
VAULT=""
DEF="main"  # origin's default branch for the current sandbox (sb_new sets it)
sb_new() { # [default-branch, default main]
  DEF="${1:-main}"
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  ORIGIN="$BOX/origin.git"
  SEED="$BOX/seed"
  VAULT="$BOX/vault"

  git init --quiet --bare -b "$DEF" "$ORIGIN"

  # core.autocrlf must be off for the checkout itself, not just afterwards:
  # a machine with the global autocrlf=true would otherwise write CRLF working
  # files against an LF index and every sandbox would start out "dirty".
  git "${GITOPTS[@]}" init --quiet -b "$DEF" "$SEED"
  gitcfg "$SEED"
  mkdir -p "$SEED/wiki"
  printf 'hot cache\n' >"$SEED/wiki/hot.md"
  printf 'shared line 0\n' >"$SEED/shared.txt"
  git -C "$SEED" add -A
  git -C "$SEED" commit --quiet -m "seed"
  git -C "$SEED" remote add origin "$ORIGIN"
  git -C "$SEED" push --quiet -u origin "$DEF"

  # The vault under test: a clone, so `origin` is wired up and wiki/ exists
  # (satisfies the vault sanity check that sync-graph.sh also uses).
  git "${GITOPTS[@]}" clone --quiet "$ORIGIN" "$VAULT"
  gitcfg "$VAULT"
}

# Adds one commit to origin/<default> via the seed clone (simulates a teammate).
seed_push() { # msg relpath content
  local msg="$1" rel="$2" content="$3"
  mkdir -p "$(dirname "$SEED/$rel")"
  printf '%s' "$content" >"$SEED/$rel"
  git -C "$SEED" add -A
  git -C "$SEED" commit --quiet -m "$msg"
  git -C "$SEED" push --quiet origin "$DEF"
}

# Adds one commit on the vault's own branch (simulates the local user).
vault_commit() { # msg relpath content
  local msg="$1" rel="$2" content="$3"
  mkdir -p "$(dirname "$VAULT/$rel")"
  printf '%s' "$content" >"$VAULT/$rel"
  git -C "$VAULT" add -A
  git -C "$VAULT" commit --quiet -m "$msg"
}

origin_sha() { git --git-dir="$ORIGIN" rev-parse "refs/heads/$DEF" 2>/dev/null; }
vault_sha() { git -C "$VAULT" rev-parse HEAD 2>/dev/null; }

STATUS=""
# Runs the script under test against $1 (vault dir), capturing streams into
# $BOX/out.txt and $BOX/err.txt and the exit code into $STATUS.
run_fresh() { # vault [args...]
  local vault="$1"
  shift
  (
    cd "$vault" 2>/dev/null || exit 127
    unset CLAUDE_PROJECT_DIR
    BRAIN_ROOT="$vault" bash "$FRESH" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

if [[ ! -f "$FRESH" ]]; then
  echo "note: $FRESH does not exist yet — every case below is expected to FAIL until it lands."
fi

# ================================================================== CASES ===

# --- 1. up-to-date branch => exit 0, OK, HEAD unchanged -------------------
echo "--- 1. up-to-date ---"
sb_new
before="$(vault_sha)"
run_fresh "$VAULT"
assert_eq "up-to-date/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "up-to-date/stdout-first-line-OK" "FRESHNESS: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_eq "up-to-date/head-unchanged" "$before" "$(vault_sha)" "$(evidence "$BOX")"

# --- 2. THE COMMON CASE: 3 behind, 0 own => fast-forwarded ----------------
echo "--- 2. behind (fast-forward) ---"
sb_new
before="$(vault_sha)"
seed_push "teammate 1" "wiki/hot.md" "hot cache v1"
seed_push "teammate 2" "wiki/notes.md" "notes"
seed_push "teammate 3" "wiki/hot.md" "hot cache v3"
want="$(origin_sha)"
run_fresh "$VAULT"
after="$(vault_sha)"
assert_eq "behind/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "behind/stdout-first-line-OK" "FRESHNESS: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_ne "behind/head-actually-moved" "$before" "$after" "$(evidence "$BOX")"
assert_eq "behind/head-equals-origin-main-sha" "$want" "$after" \
  "the branch must actually fast-forward, not merely report being behind" \
  "$(evidence "$BOX")"
if cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -qiE 'fast[-_ ]?forward'; then
  pass "behind/output-mentions-fast-forward"
else
  fail "behind/output-mentions-fast-forward" \
    "expected output to mention 'fast-forward'" "$(evidence "$BOX")"
fi

# --- 3. behind + --no-merge => exit 1, nothing mutated --------------------
echo "--- 3. behind + --no-merge ---"
sb_new
before="$(vault_sha)"
seed_push "teammate 1" "wiki/hot.md" "hot cache v1"
seed_push "teammate 2" "wiki/notes.md" "notes"
seed_push "teammate 3" "wiki/hot.md" "hot cache v3"
origin_before="$(origin_sha)"
run_fresh "$VAULT" --no-merge
assert_eq "no-merge/exit-1" "1" "$STATUS" "$(evidence "$BOX")"
assert_eq "no-merge/head-unchanged" "$before" "$(vault_sha)" \
  "--no-merge must mutate nothing" "$(evidence "$BOX")"
assert_eq "no-merge/origin-ref-unchanged" "$origin_before" "$(origin_sha)" "$(evidence "$BOX")"

# --- 4. diverged, clean merge => exit 0, real merge commit ----------------
echo "--- 4. diverged, clean merge ---"
sb_new
seed_push "teammate touches fileB" "fileB.txt" "B content"
vault_commit "local touches fileA" "fileA.txt" "A content"
own_sha="$(vault_sha)"
run_fresh "$VAULT"
assert_eq "diverged-clean/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "diverged-clean/stdout-first-line-OK" "FRESHNESS: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
parents="$(git -C "$VAULT" rev-list --parents -n 1 HEAD 2>/dev/null | wc -w | tr -d ' ')"
assert_eq "diverged-clean/head-is-a-merge-commit-2-parents" "3" "$parents" \
  "(rev-list --parents -n1 HEAD prints <commit> <parent1> <parent2> = 3 tokens)" \
  "head: $(vault_sha)  own commit was: $own_sha" \
  "$(evidence "$BOX")"
tree="$(git -C "$VAULT" ls-tree -r --name-only HEAD 2>/dev/null | tr '\n' ' ')"
if [[ "$tree" == *"fileA.txt"* && "$tree" == *"fileB.txt"* ]]; then
  pass "diverged-clean/both-files-present-in-tree"
else
  fail "diverged-clean/both-files-present-in-tree" \
    "expected fileA.txt and fileB.txt in HEAD tree" "actual tree: [$tree]" "$(evidence "$BOX")"
fi

# --- 5. diverged, conflicting => exit 1, repo left CLEAN ------------------
echo "--- 5. diverged, conflicting ---"
sb_new
origin_before=""
seed_push "teammate rewrites shared line" "shared.txt" "shared line THEIRS"
origin_before="$(origin_sha)"
vault_commit "local rewrites shared line" "shared.txt" "shared line MINE"
own_sha="$(vault_sha)"
run_fresh "$VAULT"
assert_eq "conflict/exit-1" "1" "$STATUS" "$(evidence "$BOX")"
assert_prefix "conflict/stderr-first-line-BLOCKED" "FRESHNESS: BLOCKED" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"
if [[ -e "$VAULT/.git/MERGE_HEAD" ]]; then
  fail "conflict/no-merge-in-progress" \
    "$VAULT/.git/MERGE_HEAD exists — the script left a merge in progress" \
    "MERGE_HEAD: [$(cat "$VAULT/.git/MERGE_HEAD" 2>/dev/null)]" "$(evidence "$BOX")"
else
  pass "conflict/no-merge-in-progress"
fi
unmerged="$(git -C "$VAULT" status --porcelain 2>/dev/null | grep -E '^(U.|.U|AA|DD|AU|UA|DU|UD)' | tr '\n' '|')"
assert_eq "conflict/no-unmerged-entries-in-status" "" "$unmerged" \
  "git status --porcelain: [$(git -C "$VAULT" status --porcelain 2>/dev/null | tr '\n' '|')]" \
  "$(evidence "$BOX")"
assert_eq "conflict/own-commit-still-head" "$own_sha" "$(vault_sha)" "$(evidence "$BOX")"
commit_subjects="$(git -C "$VAULT" log --format=%s 2>/dev/null)"
if grep -qx "local rewrites shared line" <<<"$commit_subjects"; then
  pass "conflict/own-commit-intact-in-history"
else
  fail "conflict/own-commit-intact-in-history" \
    "expected commit subject 'local rewrites shared line' in log" \
    "log: [$(printf '%s' "$commit_subjects" | tr '\n' '|')]" "$(evidence "$BOX")"
fi
if grep -qx "missing commit subject" <<<"$commit_subjects"; then
  fail "conflict/missing-commit-not-in-history" \
    "a non-existent subject unexpectedly matched the commit log" \
    "log: [$(printf '%s' "$commit_subjects" | tr '\n' '|')]" "$(evidence "$BOX")"
else
  pass "conflict/missing-commit-not-in-history"
fi
assert_eq "conflict/origin-ref-unchanged-no-push" "$origin_before" "$(origin_sha)" \
  "a BLOCKED run must never commit to or push to origin" "$(evidence "$BOX")"

# --- 6. no origin remote at all => exit 0, skipped ------------------------
echo "--- 6. no origin remote ---"
sb_new
git -C "$VAULT" remote remove origin
before="$(vault_sha)"
run_fresh "$VAULT"
assert_eq "no-remote/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "no-remote/stdout-first-line-OK" "FRESHNESS: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
if grep -qi 'skip' "$BOX/out.txt"; then
  pass "no-remote/says-check-skipped"
else
  fail "no-remote/says-check-skipped" "expected stdout to say the check was skipped" \
    "$(evidence "$BOX")"
fi
assert_eq "no-remote/head-unchanged" "$before" "$(vault_sha)" "$(evidence "$BOX")"

# --- 7. origin configured but unreachable => exit 0, skipped --------------
echo "--- 7. origin unreachable ---"
sb_new
git -C "$VAULT" remote set-url origin "$BOX/no-such-repo-here.git"
before="$(vault_sha)"
run_fresh "$VAULT"
assert_eq "unreachable/exit-0-does-not-block-save" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "unreachable/stdout-first-line-OK" "FRESHNESS: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
if grep -qi 'skip' "$BOX/out.txt"; then
  pass "unreachable/says-check-skipped"
else
  fail "unreachable/says-check-skipped" "expected stdout to say the check was skipped" \
    "$(evidence "$BOX")"
fi
assert_eq "unreachable/head-unchanged" "$before" "$(vault_sha)" "$(evidence "$BOX")"

# --- 8. not a git repo at all => exit 0 ----------------------------------
echo "--- 8. not a git repo ---"
sb_new
NOGIT="$BOX/plainvault"
mkdir -p "$NOGIT/wiki"
printf 'hot cache\n' >"$NOGIT/wiki/hot.md"
run_fresh "$NOGIT"
assert_eq "not-a-repo/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "not-a-repo/stdout-first-line-OK" "FRESHNESS: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
if [[ -e "$NOGIT/.git" ]]; then
  fail "not-a-repo/did-not-init-a-repo" "the script created $NOGIT/.git" "$(evidence "$BOX")"
else
  pass "not-a-repo/did-not-init-a-repo"
fi

# --- 9. behind + dirty tree that the ff would overwrite => BLOCKED --------
echo "--- 9. behind + dirty working tree ---"
sb_new
seed_push "teammate edits shared.txt" "shared.txt" "shared line THEIRS"
origin_before="$(origin_sha)"
before="$(vault_sha)"
DIRTY_CONTENT='uncommitted work that must survive
line two
'
printf '%s' "$DIRTY_CONTENT" >"$VAULT/shared.txt"
printf '%s' "$DIRTY_CONTENT" >"$BOX/dirty.expected"
run_fresh "$VAULT"
assert_eq "dirty/exit-1" "1" "$STATUS" "$(evidence "$BOX")"
assert_prefix "dirty/stderr-first-line-BLOCKED" "FRESHNESS: BLOCKED" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"
if cmp -s "$BOX/dirty.expected" "$VAULT/shared.txt"; then
  pass "dirty/uncommitted-content-intact-byte-for-byte"
else
  fail "dirty/uncommitted-content-intact-byte-for-byte" \
    "the script discarded or altered uncommitted work in $VAULT/shared.txt" \
    "expected (od -c): $(od -c "$BOX/dirty.expected" | head -n 3 | tr '\n' ' ')" \
    "actual   (od -c): $(od -c "$VAULT/shared.txt" 2>/dev/null | head -n 3 | tr '\n' ' ')" \
    "$(evidence "$BOX")"
fi
assert_eq "dirty/head-unchanged" "$before" "$(vault_sha)" "$(evidence "$BOX")"
if [[ -e "$VAULT/.git/MERGE_HEAD" ]]; then
  fail "dirty/no-merge-in-progress" "$VAULT/.git/MERGE_HEAD exists" "$(evidence "$BOX")"
else
  pass "dirty/no-merge-in-progress"
fi
assert_eq "dirty/origin-ref-unchanged-no-push" "$origin_before" "$(origin_sha)" \
  "a BLOCKED run must never commit to or push to origin" "$(evidence "$BOX")"

# --- 10. no BLOCKED path ever writes to origin (aggregate re-check) -------
# Cases 3, 5 and 9 each assert origin's ref sha above; this case re-runs the
# three blocking scenarios in one fresh sandbox each and checks that origin has
# gained no new commits at all (ref sha AND commit count).
echo "--- 10. BLOCKED runs never touch origin ---"
origin_count() { git --git-dir="$ORIGIN" rev-list --count refs/heads/main 2>/dev/null; }

for scenario in no-merge conflict dirty; do
  sb_new
  case "$scenario" in
    no-merge)
      seed_push "teammate" "wiki/notes.md" "notes"
      args=(--no-merge)
      ;;
    conflict)
      seed_push "teammate rewrites shared line" "shared.txt" "shared line THEIRS"
      vault_commit "local rewrites shared line" "shared.txt" "shared line MINE"
      args=()
      ;;
    dirty)
      seed_push "teammate edits shared.txt" "shared.txt" "shared line THEIRS"
      printf 'uncommitted\n' >"$VAULT/shared.txt"
      args=()
      ;;
  esac
  o_sha_before="$(origin_sha)"
  o_count_before="$(origin_count)"
  run_fresh "$VAULT" ${args[@]+"${args[@]}"}
  assert_eq "no-push/$scenario/exit-1" "1" "$STATUS" "$(evidence "$BOX")"
  assert_eq "no-push/$scenario/origin-sha-unchanged" "$o_sha_before" "$(origin_sha)" \
    "$(evidence "$BOX")"
  assert_eq "no-push/$scenario/origin-commit-count-unchanged" "$o_count_before" "$(origin_count)" \
    "$(evidence "$BOX")"
done

# --- 11. INNOV-285 (a): a stale-branch save REPINS, and vault-commit accepts --
# The end-to-end defect: session.sh --start records branch:sha, this script then
# fast-forwards and moves HEAD, and before the fix vault-commit.sh --pin refused
# every stale-branch save. The freshness step must update the session's recorded
# pin when IT is the thing that moved HEAD.
echo "--- 11. stale-branch save: freshness repins its own move ---"
SID="fresh-sess-A"
# Runs session.sh / vault-commit.sh under the same identity check-freshness.sh's
# repin call will resolve from the environment.
run_sess() { # [args...]
  BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="$SID" bash "$SESSION" "$@" \
    >"$BOX/sout.txt" 2>"$BOX/serr.txt"
  SSTATUS=$?
}
run_commit() { # [args...]
  BRAIN_ROOT="$VAULT" bash "$VAULT_COMMIT" "$@" >"$BOX/cout.txt" 2>"$BOX/cerr.txt"
  CSTATUS=$?
}
run_fresh_sid() { # vault
  (
    cd "$1" 2>/dev/null || exit 127
    unset CLAUDE_PROJECT_DIR
    BRAIN_ROOT="$1" BRAIN_SESSION_ID="$SID" bash "$FRESH"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}
recorded_pin() { # -> what --print-pin replays, without the "  pin: " prefix
  BRAIN_ROOT="$VAULT" BRAIN_SESSION_ID="$SID" bash "$SESSION" --print-pin 2>/dev/null \
    | sed -n 's/^  pin: //p' | head -n 1 | tr -d '\r'
}

sb_new
printf 'logs/\nwiki/hot.md\nwiki/log.md\ngraphify/\n' >"$VAULT/.saveinclude"
run_sess --start save                                   # on main => creates brain/save-<date>
assert_eq "repin-ff/session-start-exit-0" "0" "$SSTATUS" \
  "session stderr: [$(tr '\n' '|' <"$BOX/serr.txt" 2>/dev/null)]"
pin_before="$(recorded_pin)"
seed_push "teammate 1" "wiki/hot.md" "hot cache v1"
seed_push "teammate 2" "wiki/notes.md" "notes"
want="$(origin_sha)"
run_fresh_sid "$VAULT"
assert_eq "repin-ff/freshness-exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "repin-ff/stdout-first-line-OK" "FRESHNESS: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_eq "repin-ff/head-fast-forwarded" "$want" "$(vault_sha)" "$(evidence "$BOX")"
pin_after="$(recorded_pin)"
assert_ne "repin-ff/pin-was-updated" "$pin_before" "$pin_after" \
  "the recorded pin must follow the freshness step's own HEAD move"
assert_eq "repin-ff/pin-sha-is-the-new-head" "${pin_after#*:}" "$(vault_sha)" \
  "pin after: [$pin_after]"
printf 'hot cache v1\nthis session adds a line\n' >"$VAULT/wiki/hot.md"
run_commit -m "stale-branch save, post-freshness pin" --pin "$pin_after"
assert_eq "repin-ff/vault-commit-accepts" "0" "$CSTATUS" \
  "pin: [$pin_after]" \
  "commit stderr: [$(tr '\n' '|' <"$BOX/cerr.txt" 2>/dev/null)]"

# --- 12. INNOV-285 (b): a FOREIGN HEAD move is still refused ---------------
# Another session commits after --start; freshness then merges upstream on top.
# Freshness saw the post-foreign sha as its "before", the record holds the true
# --start sha, so the repin must NOT happen — and vault-commit must still refuse
# the (correctly) stale pin. The guard survives the fix.
echo "--- 12. foreign HEAD move: pin NOT updated, vault-commit still refuses ---"
sb_new
printf 'logs/\nwiki/hot.md\nwiki/log.md\ngraphify/\n' >"$VAULT/.saveinclude"
run_sess --start save
pin_start="$(recorded_pin)"
echo "foreign edit" >>"$VAULT/wiki/hot.md"              # a concurrent session commits
git -C "$VAULT" add -A >/dev/null 2>&1
git -C "$VAULT" commit -qm "foreign session commit" >/dev/null 2>&1
seed_push "teammate" "wiki/notes.md" "notes"            # branch now diverged from origin
run_fresh_sid "$VAULT"
assert_eq "repin-foreign/freshness-exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "repin-foreign/stdout-first-line-OK" "FRESHNESS: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_eq "repin-foreign/pin-NOT-updated" "$pin_start" "$(recorded_pin)" \
  "a HEAD moved by another session must never be adopted into the pin" \
  "$(evidence "$BOX")"
if grep -qi 'pin was NOT updated' "$BOX/out.txt"; then
  pass "repin-foreign/freshness-says-so"
else
  fail "repin-foreign/freshness-says-so" \
    "expected a note that the session pin was not updated" "$(evidence "$BOX")"
fi
echo "mine" >>"$VAULT/wiki/log.md"
run_commit -m "must refuse: HEAD moved by another session" --pin "$pin_start"
assert_eq "repin-foreign/vault-commit-refuses" "1" "$CSTATUS" \
  "pin: [$pin_start]" \
  "commit stdout: [$(tr '\n' '|' <"$BOX/cout.txt" 2>/dev/null)]"

# --- 13. INNOV-332: a non-main/master default (trunk) is still guarded ------
# check-freshness.sh once hard-coded origin/main|master, so a trunk-default vault
# reported "skipped" and hot.md was rewritten from a stale base. The default must
# come from lib/branch.sh like every other script. Negative control: restore the
# literal main/master loop and this case reports skipped with HEAD unmoved.
echo "--- 13. trunk default: fast-forwarded, not skipped ---"
sb_new trunk
seed_push "teammate" "wiki/hot.md" "hot cache v1"
want="$(origin_sha)"
run_fresh "$VAULT"
assert_eq "trunk/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "trunk/fast-forwarded" "FRESHNESS: OK - fast-forwarded 1 commit(s) from origin/trunk"   "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"
assert_eq "trunk/head-equals-origin-trunk-sha" "$want" "$(vault_sha)" "$(evidence "$BOX")"

# --- 14. no origin/HEAD: the main/master safety net still finds the upstream --
# detect_default_branch() comes up empty without origin/HEAD (and gh cannot read
# a local-path remote), so the literal main/master net must still apply.
# INNOV-352: origin's own HEAD dangles too, or the unconditional
# `set-head --auto` would restore origin/HEAD and the net would go untested.
echo "--- 14. no origin/HEAD: main/master safety net ---"
sb_new
git -C "$VAULT" remote set-head origin -d >/dev/null 2>&1
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/nowhere
seed_push "teammate" "wiki/hot.md" "hot cache v1"
want="$(origin_sha)"
run_fresh "$VAULT"
assert_eq "no-origin-head/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "no-origin-head/fast-forwarded" "FRESHNESS: OK - fast-forwarded 1 commit(s) from origin/main"   "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"
assert_eq "no-origin-head/head-equals-origin-main-sha" "$want" "$(vault_sha)" "$(evidence "$BOX")"

# --- 15. INNOV-342: origin renamed its default => the NEW default is checked ---
# The stale local origin/HEAD still names main and origin/main still exists, so a
# resolve-before-fetch picked it, `fetch --prune` then deleted it, and rev-list's
# `|| echo 0` read the vanished ref as 0 behind. A plain "skipped" is no better:
# it exits 0 too, and hot.md is rewritten from the stale base either way.
# Negative controls: resolve before the fetch => "up to date with origin/main";
# drop the `remote set-head --auto` re-read => "skipped", HEAD unmoved.
echo "--- 15. origin default renamed: fast-forwarded from the new default ---"
sb_new
git --git-dir="$ORIGIN" branch -m main trunk
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/trunk
DEF="trunk"
printf 'hot cache v1' >"$SEED/wiki/hot.md"
git -C "$SEED" commit --quiet -am "teammate, on the renamed default"
git -C "$SEED" push --quiet origin HEAD:trunk
want="$(origin_sha)"
run_fresh "$VAULT"
assert_eq "renamed/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "renamed/fast-forwarded-from-trunk" "FRESHNESS: OK - fast-forwarded 1 commit(s) from origin/trunk" "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"
assert_eq "renamed/head-equals-origin-trunk-sha" "$want" "$(vault_sha)" "$(evidence "$BOX")"

# --- 16. INNOV-342: origin/<default> never fetched => the fetch finds it ------
# Resolving before the fetch reported "skipped" for a ref the fetch would have
# created. Negative control: fetch after the resolve and this reports skipped.
echo "--- 16. origin/main not fetched yet: fetched, then fast-forwarded ---"
sb_new
git -C "$VAULT" update-ref -d refs/remotes/origin/main
seed_push "teammate" "wiki/hot.md" "hot cache v1"
want="$(origin_sha)"
run_fresh "$VAULT"
assert_eq "unfetched/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "unfetched/fast-forwarded" "FRESHNESS: OK - fast-forwarded 1 commit(s) from origin/main" "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"
assert_eq "unfetched/head-equals-origin-main-sha" "$want" "$(vault_sha)" "$(evidence "$BOX")"

# --- 17. INNOV-352: origin switched its default but KEPT the old branch -------
# A fetch never refreshes origin/HEAD, and origin/main still exists, so case 15's
# missing-ref re-read never fired: freshness compared against the stale main and
# approved a hot.md rewrite missing trunk's commits. The refresh also persists
# origin/HEAD, so the later callers in the same save (vault-commit's
# branch_is_protected, reap-branches) see trunk too. Negative control: make the
# `set-head --auto` conditional again => "up to date with origin/main", HEAD unmoved.
echo "--- 17. origin default switched, old branch kept: checked against the new one ---"
sb_new
git --git-dir="$ORIGIN" branch trunk main
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/trunk
DEF="trunk"
printf 'hot cache v1' >"$SEED/wiki/hot.md"
git -C "$SEED" commit --quiet -am "teammate, on the new default"
git -C "$SEED" push --quiet origin HEAD:trunk
want="$(origin_sha)"
run_fresh "$VAULT"
assert_eq "switched/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "switched/fast-forwarded-from-trunk" "FRESHNESS: OK - fast-forwarded 1 commit(s) from origin/trunk" "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"
assert_eq "switched/head-equals-origin-trunk-sha" "$want" "$(vault_sha)" "$(evidence "$BOX")"
assert_eq "switched/origin-HEAD-persisted" "origin/trunk" \
  "$(git -C "$VAULT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" "$(evidence "$BOX")"

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
