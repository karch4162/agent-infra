#!/usr/bin/env bash
# test-land-save.sh — brain/bin/land-save.sh pushes, opens and merges a save PR
# itself (INNOV-389), resolving only the known conflict files.
#
# Each case runs in a clone of a bare `origin`, with a stub `gh` on PATH that
# keeps PR state in files and performs `pr merge --merge` FOR REAL inside the
# bare repo (merge-tree + commit-tree), so "landed" is checked against origin's
# actual history rather than against a log of gh calls.
#
# Pins: a clean save lands and reap then deletes its branch; two saves racing on
# log.md (union) and hot.md (HOT, then a fold through write-hot.sh lands it, and a
# hot.md that moved again re-HOTs); a conflict outside the known paths is LEFT
# OPEN with origin's default untouched; graphify-out/ keeps origin's whole tree;
# no remote / no gh auth / a non-save branch / an out-of-sync index / a path
# outside origin's .saveinclude, or content origin's brain.json now denies
# (INNOV-297), are SKIPPED with nothing pushed; a moved remote
# branch is never overwritten; a blocked merge is LEFT OPEN; a dirty trusted note
# in the checkout never stops a landing, and is never touched.
#
# Run:  bash tests/test-land-save.sh   (from anywhere)
# No network.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID GROK_SESSION_ID  # never the real vault
export BRAIN_SESSION_ID=land-test
export LAND_MERGE_RETRY_SECS=0

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
BIN="$REPO_ROOT/brain/bin"
LAND="$BIN/land-save.sh"

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
assert_eq() { # name expected actual [evidence]
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]" "actual:   [$3]" "${4:-}"; fi
}
assert_contains() { # name haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to contain: [$3]" "actual: [$2]"; fi
}
assert_not_contains() { # name haystack needle
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "expected NOT to contain: [$3]" "actual: [$2]"; fi
}

# --- the stub gh -------------------------------------------------------------
# State lives in $GH_STATE: pr-<n>.head / pr-<n>.state (open|merged), a counter.
# Knobs: GH_AUTH_RC (auth status exit code), GH_MERGE_ERR (pr merge fails with
# this on stderr), GH_MERGE_FAIL_TIMES (fail the first n merges, then succeed).
STUB="$TMPROOT/bin"
mkdir -p "$STUB"
cat >"$STUB/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
arg_after() { # flag args...
  local f="$1"; shift
  while [[ $# -gt 0 ]]; do [[ "$1" == "$f" ]] && { echo "$2"; return; }; shift; done
}
open_pr_for() { # head
  local f
  for f in "$GH_STATE"/pr-*.head; do
    [[ -f "$f" ]] || continue
    n="${f##*/pr-}"; n="${n%.head}"
    [[ "$(cat "$f")" == "$1" && "$(cat "$GH_STATE/pr-$n.state")" == open ]] && { echo "$n"; return; }
  done
}
case "$1 $2" in
  "auth status") exit "${GH_AUTH_RC:-0}" ;;
  "repo view") exit 1 ;;
  "pr list")
    n="$(open_pr_for "$(arg_after --head "$@")")"
    [[ -n "$n" ]] || exit 0
    case "$*" in
      *"--json url"*) echo "https://github.com/o/vault/pull/$n" ;;
      *) echo "$n" ;;
    esac
    exit 0 ;;
  "pr create")
    n=$(( $(cat "$GH_STATE/counter" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$GH_STATE/counter"
    arg_after --head "$@" >"$GH_STATE/pr-$n.head"
    arg_after --base "$@" >"$GH_STATE/pr-$n.base"
    arg_after --title "$@" >"$GH_STATE/pr-$n.title"
    echo open >"$GH_STATE/pr-$n.state"
    [[ -z "${GH_ON_CREATE:-}" ]] || bash -c "$GH_ON_CREATE" >/dev/null 2>&1
    echo "https://github.com/o/vault/pull/$n"
    exit 0 ;;
  "pr merge")
    n="$3"
    if [[ -n "${GH_MERGE_FAIL_TIMES:-}" ]]; then
      done_n="$(cat "$GH_STATE/merge-fails" 2>/dev/null || echo 0)"
      if [[ "$done_n" -lt "$GH_MERGE_FAIL_TIMES" ]]; then
        echo $((done_n + 1)) >"$GH_STATE/merge-fails"
        echo "GraphQL: Pull request is not mergeable: mergeability is still being computed" >&2
        exit 1
      fi
    fi
    if [[ -n "${GH_MERGE_ERR:-}" ]]; then echo "$GH_MERGE_ERR" >&2; exit 1; fi
    head="$(cat "$GH_STATE/pr-$n.head")"; base="$(cat "$GH_STATE/pr-$n.base")"
    bsha="$(git -C "$GH_ORIGIN" rev-parse "refs/heads/$base")"
    hsha="$(git -C "$GH_ORIGIN" rev-parse "refs/heads/$head")"
    tree="$(git -C "$GH_ORIGIN" merge-tree --write-tree "$bsha" "$hsha" 2>/dev/null)" || {
      echo "Pull request #$n is not mergeable: the merge commit cannot be cleanly created." >&2; exit 1; }
    tree="$(printf '%s\n' "$tree" | head -n 1)"
    m="$(git -C "$GH_ORIGIN" commit-tree "$tree" -p "$bsha" -p "$hsha" -m "Merge pull request #$n from $head")"
    git -C "$GH_ORIGIN" update-ref "refs/heads/$base" "$m" "$bsha"
    echo merged >"$GH_STATE/pr-$n.state"
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB/gh"

# --- fixtures ----------------------------------------------------------------
# A bare origin holding a minimal vault on main, and a clone of it ($VAULT) with
# origin/HEAD set (as a real clone has). The vault's .saveinclude is the
# shipped template, so the allowlist under test is the real one.
CRLF=0
new_sandbox() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  ORIGIN="$BOX/origin.git"
  SEED="$BOX/seed"
  VAULT="$BOX/vault"
  GH_STATE="$BOX/gh"
  GH_LOG="$BOX/gh.log"
  mkdir -p "$GH_STATE"
  : >"$GH_LOG"
  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$SEED"
  git -C "$SEED" remote add origin "$ORIGIN"
  cfg "$SEED"
  mkdir -p "$SEED/wiki/area" "$SEED/logs" "$SEED/graphify-out/communities"
  cp "$REPO_ROOT/brain/templates/saveinclude" "$SEED/.saveinclude"
  cp "$REPO_ROOT/brain/templates/gitignore" "$SEED/.gitignore"
  wr "$SEED/wiki/hot.md" '# Hot cache' '' 'base focus'
  wr "$SEED/wiki/log.md" '# Log' '- 2026-10-01 — base.'
  wr "$SEED/wiki/area/note.md" 'trusted note'
  wr "$SEED/logs/2026-10-01-base.md" 'base log'
  wr "$SEED/graphify-out/graph.json" '{"build":"base"}'
  wr "$SEED/graphify-out/communities/c1.md" 'base c1'
  git -C "$SEED" add -A
  git -C "$SEED" commit -q -m "scaffold"
  git -C "$SEED" push -q origin main
  git clone -q -c core.autocrlf="$(ac)" "$ORIGIN" "$VAULT"
  cfg "$VAULT"
}
ac() { if [[ $CRLF -eq 1 ]]; then echo true; else echo false; fi; }
cfg() {
  git -C "$1" config user.email t@t.t
  git -C "$1" config user.name t
  if [[ $CRLF -eq 1 ]]; then git -C "$1" config core.autocrlf true; else git -C "$1" config core.autocrlf false; fi
}
wr() { # file lines... (CRLF line endings when CRLF=1)
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"
  if [[ $CRLF -eq 1 ]]; then printf '%s\r\n' "$@" >"$f"; else printf '%s\n' "$@" >"$f"; fi
}
ap() { # file line — append one line
  if [[ $CRLF -eq 1 ]]; then printf '%s\r\n' "$2" >>"$1"; else printf '%s\n' "$2" >>"$1"; fi
}
# A save on a fresh brain/save-* branch in $1 (a checkout): a log, a log.md line,
# and a hot.md rewrite. Committed with raw git — fixture setup, not the path under test.
save_in() { # checkout tag [branch]
  local co="$1" tag="$2" br="${3:-brain/save-2026-10-06}"
  git -C "$co" checkout -q -b "$br"
  wr "$co/logs/2026-10-06-$tag.md" "log $tag"
  ap "$co/wiki/log.md" "- 2026-10-06 — $tag."
  wr "$co/wiki/hot.md" '# Hot cache' '' "focus $tag"
  git -C "$co" add -A
  git -C "$co" commit -q -m "save: 2026-10-06 session — $tag"
}
# Another save that landed on origin main first, from its own clone.
other_lands() { # tag [extra-fn]
  local co="$BOX/other"
  rm -rf "$co"
  git clone -q -c core.autocrlf="$(ac)" "$ORIGIN" "$co"
  cfg "$co"
  wr "$co/logs/2026-10-06-$1.md" "log $1"
  ap "$co/wiki/log.md" "- 2026-10-06 — $1."
  wr "$co/wiki/hot.md" '# Hot cache' '' "focus $1"
  if [[ -n "${2:-}" ]]; then "$2" "$co"; fi
  git -C "$co" add -A
  git -C "$co" commit -q -m "$1 landed"
  git -C "$co" push -q origin main
}
run_land() { # [args...] -> OUT, ST
  OUT="$(cd "$VAULT" && PATH="$STUB:$PATH" GH_LOG="$GH_LOG" GH_STATE="$GH_STATE" GH_ORIGIN="$ORIGIN" \
    BRAIN_ROOT="$VAULT" bash "$LAND" "$@" 2>&1)"
  ST=$?
}
origin_has() { git -C "$ORIGIN" cat-file -e "main:$1" 2>/dev/null && echo yes || echo no; }
origin_show() { git -C "$ORIGIN" show "main:$1" 2>/dev/null | tr -d '\r'; }
origin_main() { git -C "$ORIGIN" rev-parse main; }
remote_branch() { git -C "$ORIGIN" rev-parse -q --verify "refs/heads/$1" 2>/dev/null || echo none; }
first() { printf '%s\n' "$OUT" | head -n 1 | tr -d '\r'; }
gh_called() { grep -c "^$1" "$GH_LOG" || true; }

echo "--- 1. a clean save: pushed, PR, --merge, landed; reap then deletes the branch ---"
new_sandbox
save_in "$VAULT" one
head_before="$(git -C "$VAULT" rev-parse HEAD)"
run_land
assert_eq "clean/exit-0" "0" "$ST" "$OUT"
assert_eq "clean/verdict" "LAND: MERGED #1" "$(first)" "$OUT"
assert_eq "clean/log-on-origin" "yes" "$(origin_has logs/2026-10-06-one.md)"
assert_eq "clean/branch-tip-is-ancestor" "0" \
  "$(git -C "$ORIGIN" merge-base --is-ancestor "$head_before" main; echo $?)"
assert_contains "clean/merge-not-squash" "$(grep '^pr merge' "$GH_LOG")" "--merge"
assert_not_contains "clean/no-squash" "$(grep '^pr merge' "$GH_LOG")" "--squash"
assert_not_contains "clean/no-delete-branch-flag" "$(grep '^pr merge' "$GH_LOG")" "--delete-branch"
assert_contains "clean/merges-exactly-the-verified-tip" "$(grep "^pr merge" "$GH_LOG")" "--match-head-commit $head_before"
assert_contains "clean/title-from-subject" "$(cat "$GH_STATE/pr-1.title")" "save: 2026-10-06 — one"
assert_eq "clean/remote-branch-deleted" "none" "$(remote_branch brain/save-2026-10-06)"
assert_eq "clean/local-head-unmoved" "$head_before" "$(git -C "$VAULT" rev-parse HEAD)"
assert_eq "clean/local-branch-unmoved" "brain/save-2026-10-06" "$(git -C "$VAULT" rev-parse --abbrev-ref HEAD)"
reap_out="$(PATH="$STUB:$PATH" GH_LOG="$GH_LOG" GH_STATE="$GH_STATE" BRAIN_ROOT="$VAULT" bash "$BIN/reap-branches.sh" 2>&1)"
assert_contains "clean/reap-deletes-it" "$reap_out" "deleted 1 merged brain/* branch(es)"
assert_eq "clean/reap-left-on-main" "main" "$(git -C "$VAULT" rev-parse --abbrev-ref HEAD)"

echo "--- 1b. merge retried while GitHub is still computing mergeability ---"
new_sandbox
save_in "$VAULT" retry
GH_MERGE_FAIL_TIMES=2 run_land
assert_eq "retry/verdict" "LAND: MERGED #1" "$(first)" "$OUT"
assert_eq "retry/three-attempts" "3" "$(gh_called 'pr merge')"

for CRLF in 0 1; do
for ATTR in 0 1; do
tag="crlf$CRLF-attr$ATTR"
echo "--- 2. [$tag] two saves race on log.md + hot.md: HOT, fold, land ---"
new_sandbox
if [[ $ATTR -eq 1 ]]; then
  printf 'wiki/log.md merge=union\n' >"$BOX/attrs"
  cp "$BOX/attrs" "$VAULT/.gitattributes"
  git -C "$VAULT" add .gitattributes; git -C "$VAULT" commit -q -m attrs; git -C "$VAULT" push -q origin main
fi
save_in "$VAULT" mine
other_lands theirs
main_before="$(origin_main)"
run_land
assert_eq "race[$tag]/exit-0" "0" "$ST" "$OUT"
assert_contains "race[$tag]/hot-verdict" "$(first)" "LAND: HOT"
assert_eq "race[$tag]/nothing-pushed" "none" "$(remote_branch brain/save-2026-10-06)"
assert_eq "race[$tag]/main-untouched" "$main_before" "$(origin_main)"
assert_eq "race[$tag]/no-pr" "0" "$(gh_called 'pr create')"
# The agent folds origin's hot.md in, through the guarded writer, and commits.
( cd "$VAULT" && BRAIN_ROOT="$VAULT" bash "$BIN/write-hot.sh" --pin >/dev/null 2>&1 )
wr "$BOX/folded" '# Hot cache' '' 'focus theirs' 'focus mine'
( cd "$VAULT" && BRAIN_ROOT="$VAULT" bash "$BIN/write-hot.sh" --write "$BOX/folded" >/dev/null 2>&1 )
vc_out="$(cd "$VAULT" && PATH="$STUB:$PATH" GH_LOG="$GH_LOG" GH_STATE="$GH_STATE" BRAIN_ROOT="$VAULT" \
  bash "$BIN/vault-commit.sh" -m "save: fold hot.md" 2>&1)"
assert_contains "race[$tag]/fold-committed" "$vc_out" "VAULT-COMMIT: OK"
run_land
assert_eq "race[$tag]/lands" "LAND: MERGED #1" "$(first)" "$OUT"
log_now="$(origin_show wiki/log.md)"
assert_contains "race[$tag]/log-has-theirs" "$log_now" "- 2026-10-06 — theirs."
assert_contains "race[$tag]/log-has-mine" "$log_now" "- 2026-10-06 — mine."
assert_not_contains "race[$tag]/log-no-markers" "$log_now" "<<<<<<<"
assert_eq "race[$tag]/hot-is-folded" "$(printf '# Hot cache\n\nfocus theirs\nfocus mine')" "$(origin_show wiki/hot.md)"
assert_eq "race[$tag]/both-logs" "yes yes" \
  "$(origin_has logs/2026-10-06-mine.md) $(origin_has logs/2026-10-06-theirs.md)"
assert_eq "race[$tag]/ack-cleared" "no" "$([[ -f "$VAULT/.git/brain-land-hot" ]] && echo yes || echo no)"
done
done
CRLF=0

echo "--- 2b. hot.md moved AGAIN after the fold: HOT again, nothing overwritten ---"
new_sandbox
save_in "$VAULT" mine
other_lands theirs
run_land
assert_contains "rehot/first-hot" "$(first)" "LAND: HOT"
( cd "$VAULT" && BRAIN_ROOT="$VAULT" bash "$BIN/write-hot.sh" --pin >/dev/null 2>&1 )
wr "$BOX/folded" '# Hot cache' '' 'focus theirs' 'focus mine'
( cd "$VAULT" && BRAIN_ROOT="$VAULT" bash "$BIN/write-hot.sh" --write "$BOX/folded" >/dev/null 2>&1 )
( cd "$VAULT" && PATH="$STUB:$PATH" GH_LOG="$GH_LOG" GH_STATE="$GH_STATE" BRAIN_ROOT="$VAULT" \
  bash "$BIN/vault-commit.sh" -m "save: fold" >/dev/null 2>&1 )
other_lands third
main_before="$(origin_main)"
run_land
assert_contains "rehot/hot-again" "$(first)" "LAND: HOT"
assert_eq "rehot/main-untouched" "$main_before" "$(origin_main)"
assert_eq "rehot/third-hot-kept" "focus third" "$(origin_show wiki/hot.md | tail -n 1)"

echo "--- 2c. a HOT that was never folded stays HOT (the record alone proves nothing) ---"
new_sandbox
save_in "$VAULT" mine
other_lands theirs
run_land
assert_contains "nofold/first-hot" "$(first)" "LAND: HOT"
main_before="$(origin_main)"
run_land
assert_contains "nofold/still-hot" "$(first)" "LAND: HOT"
assert_eq "nofold/main-untouched" "$main_before" "$(origin_main)"
assert_eq "nofold/theirs-hot-kept" "focus theirs" "$(origin_show wiki/hot.md | tail -n 1)"
assert_eq "nofold/record-not-in-tree" "" "$(git -C "$VAULT" status --porcelain --ignored | grep -v '^!! .brain/' || true)"
# A record left by another branch does not count either.
git -C "$VAULT" checkout -q -b brain/save-2026-10-07
wr "$VAULT/wiki/hot.md" "# Hot cache" "" "focus other branch"
git -C "$VAULT" commit -qam "edit hot on another save branch"
run_land
assert_contains "nofold/other-branch-hot" "$(first)" "LAND: HOT"

echo "--- 3. a conflict outside the known paths: LEFT OPEN, main untouched ---"
new_sandbox
# Both sides edit a path the fixture's own .saveinclude allows, but that is not
# one of the mechanically resolvable files.
widen() { printf 'wiki/area/\n' >>"$1/.saveinclude"; }
widen "$SEED"; git -C "$SEED" commit -qam widen; git -C "$SEED" push -q origin main
git -C "$VAULT" pull -q
save_in "$VAULT" mine
wr "$VAULT/wiki/area/note.md" 'mine'
git -C "$VAULT" commit -qam "mine edits note"
edit_note() { wr "$1/wiki/area/note.md" 'theirs'; }
other_lands theirs edit_note
main_before="$(origin_main)"
run_land
assert_eq "unknown/exit-0" "0" "$ST" "$OUT"
assert_contains "unknown/left-open" "$(first)" "LAND: LEFT OPEN #1"
assert_contains "unknown/names-path" "$OUT" "wiki/area/note.md"
assert_eq "unknown/main-untouched" "$main_before" "$(origin_main)"
assert_eq "unknown/branch-pushed-as-is" "$(git -C "$VAULT" rev-parse HEAD)" "$(remote_branch brain/save-2026-10-06)"
assert_eq "unknown/no-merge-attempt" "0" "$(gh_called 'pr merge')"

echo "--- 4. graphify-out/ conflict: origin's whole tree wins, origin-only files stay ---"
new_sandbox
save_in "$VAULT" mine
wr "$VAULT/graphify-out/graph.json" '{"build":"mine"}'
wr "$VAULT/graphify-out/communities/mine-only.md" 'mine only'
git -C "$VAULT" add -A; git -C "$VAULT" commit -q -m "mine graph"
# keep hot.md out of this case: restore base hot.md on the save branch
git -C "$VAULT" checkout -q main -- wiki/hot.md; git -C "$VAULT" commit -q -m "keep hot"
their_graph() {
  wr "$1/graphify-out/graph.json" '{"build":"theirs"}'
  wr "$1/graphify-out/communities/theirs-only.md" 'theirs only'
  git -C "$1" checkout -q HEAD -- wiki/hot.md
}
other_lands theirs their_graph
run_land
assert_eq "graph/lands" "LAND: MERGED #1" "$(first)" "$OUT"
assert_eq "graph/origin-build" '{"build":"theirs"}' "$(origin_show graphify-out/graph.json)"
assert_eq "graph/origin-only-file-kept" "yes" "$(origin_has graphify-out/communities/theirs-only.md)"
assert_eq "graph/mine-only-not-mixed-in" "no" "$(origin_has graphify-out/communities/mine-only.md)"
assert_eq "graph/log-landed" "yes" "$(origin_has logs/2026-10-06-mine.md)"

echo "--- 5. no remote / gh unauthenticated: SKIPPED, nothing changes ---"
new_sandbox
save_in "$VAULT" mine
git -C "$VAULT" remote remove origin
head_before="$(git -C "$VAULT" rev-parse HEAD)"
run_land
assert_eq "noremote/exit-0" "0" "$ST" "$OUT"
assert_contains "noremote/skipped" "$(first)" "LAND: SKIPPED"
assert_eq "noremote/head-intact" "$head_before" "$(git -C "$VAULT" rev-parse HEAD)"
new_sandbox
save_in "$VAULT" mine
GH_AUTH_RC=1 run_land
assert_contains "noauth/skipped" "$(first)" "LAND: SKIPPED"
assert_contains "noauth/says-gh" "$(first)" "gh"
assert_eq "noauth/nothing-pushed" "none" "$(remote_branch brain/save-2026-10-06)"

echo "--- 6. a non-save branch is never landed ---"
new_sandbox
save_in "$VAULT" mine brain/promote-2026-10-06
run_land
assert_contains "promote/skipped" "$(first)" "LAND: SKIPPED"
assert_eq "promote/nothing-pushed" "none" "$(remote_branch brain/promote-2026-10-06)"
assert_eq "promote/no-gh-pr-calls" "0" "$(grep -c '^pr ' "$GH_LOG" || true)"

echo "--- 7. shared index out of sync: SKIPPED with the reset remedy, nothing pushed ---"
# Negative control for the ticket's index check: without it this save would land.
new_sandbox
save_in "$VAULT" mine
git -C "$VAULT" reset -q HEAD^ -- wiki/log.md logs/2026-10-06-mine.md   # what a lost sync leaves
run_land
assert_eq "index/exit-0" "0" "$ST" "$OUT"
assert_eq "index/verdict" "LAND: SKIPPED - shared index out of sync" "$(first | sed 's/ (.*//')" "$OUT"
assert_contains "index/remedy" "$OUT" "reset -q HEAD --"
assert_contains "index/remedy-names-path" "$OUT" "wiki/log.md"
assert_eq "index/nothing-pushed" "none" "$(remote_branch brain/save-2026-10-06)"
assert_eq "index/no-gh-pr-calls" "0" "$(grep -c '^pr ' "$GH_LOG" || true)"
assert_eq "index/not-reset-for-you" "2" "$(git -C "$VAULT" diff --cached --name-only HEAD | grep -c . || true)"
# Staged work that is NOT a lost sync: no remedy offered.
new_sandbox
save_in "$VAULT" mine
wr "$VAULT/wiki/area/note.md" 'user staged this'
git -C "$VAULT" add wiki/area/note.md
run_land
assert_contains "staged/skipped" "$(first)" "LAND: SKIPPED - shared index out of sync"
assert_not_contains "staged/no-remedy" "$OUT" "reset -q HEAD --"

echo "--- 8. a path outside origin's .saveinclude: SKIPPED, even if the local one allows it ---"
new_sandbox
save_in "$VAULT" mine
printf 'private/\n' >>"$VAULT/.saveinclude"            # widened locally, never on origin
wr "$VAULT/private/secret.md" 'secret'
git -C "$VAULT" add -A; git -C "$VAULT" commit -q -m "sneak"
run_land
assert_contains "scope/skipped" "$(first)" "LAND: SKIPPED"
assert_contains "scope/names-path" "$OUT" "private/secret.md"
assert_eq "scope/nothing-pushed" "none" "$(remote_branch brain/save-2026-10-06)"

for CRLF in 0 1; do
echo "--- 8b. [crlf$CRLF] origin's brain.json tightened after the save branched: SKIPPED (INNOV-297) ---"
policy_lands() { # brain.json body — origin main gains it, and nothing else
  local co="$BOX/policy"
  rm -rf "$co"
  git clone -q -c core.autocrlf="$(ac)" "$ORIGIN" "$co"
  cfg "$co"
  wr "$co/brain.json" "$1"
  git -C "$co" add brain.json
  git -C "$co" commit -q -m policy
  git -C "$co" push -q origin main
}
new_sandbox
save_in "$VAULT" mine
ap "$VAULT/logs/2026-10-06-mine.md" 'paired with Jane Doe'
git -C "$VAULT" commit -q -am "name"
policy_lands '{"deniedPatterns": ["\\bJane Doe\\b"]}'
run_land
assert_contains "policy[$CRLF]/skipped" "$(first)" "LAND: SKIPPED - 'brain/save-2026-10-06' breaks origin/main's brain.json policy"
assert_contains "policy[$CRLF]/names-it" "$OUT" "logs/2026-10-06-mine.md: line 2 matches deniedPatterns entry"
assert_eq "policy[$CRLF]/nothing-pushed" "none" "$(remote_branch brain/save-2026-10-06)"
new_sandbox   # negative control: the same policy, a save without the name, lands
save_in "$VAULT" mine
policy_lands '{"deniedPatterns": ["\\bJane Doe\\b"]}'
run_land
assert_eq "policy[$CRLF]/clean-save-lands" "LAND: MERGED #1" "$(first)" "$OUT"
done
CRLF=0

echo "--- 9. the remote save branch moved: push rejected, never overwritten ---"
new_sandbox
save_in "$VAULT" mine
foreign="$(git -C "$VAULT" commit-tree "$(git -C "$VAULT" rev-parse HEAD^{tree})" -p main -m foreign)"
git -C "$VAULT" push -q origin "$foreign:refs/heads/brain/save-2026-10-06"
run_land
assert_contains "lease/left-open" "$(first)" "push rejected"
assert_eq "lease/remote-intact" "$foreign" "$(remote_branch brain/save-2026-10-06)"
assert_eq "lease/no-merge" "0" "$(gh_called 'pr merge')"

echo "--- 10. a dirty trusted note in the checkout: lands anyway, note untouched ---"
new_sandbox
save_in "$VAULT" mine
wr "$VAULT/wiki/area/note.md" 'work in progress'
run_land
assert_eq "dirty/lands" "LAND: MERGED #1" "$(first)" "$OUT"
assert_eq "dirty/note-untouched" "work in progress" "$(tr -d '\r' <"$VAULT/wiki/area/note.md")"
assert_eq "dirty/note-not-published" "trusted note" "$(origin_show wiki/area/note.md)"

echo "--- 11. merge blocked by a required review: LEFT OPEN with gh's reason ---"
new_sandbox
save_in "$VAULT" mine
GH_MERGE_ERR="GraphQL: At least 1 approving review is required by reviewers with write access." run_land
assert_contains "blocked/left-open" "$(first)" "LAND: LEFT OPEN #1 - merge blocked"
assert_contains "blocked/gh-reason" "$OUT" "approving review"
assert_eq "blocked/main-has-no-log" "no" "$(origin_has logs/2026-10-06-mine.md)"

echo "--- 12. nothing ahead of origin: SKIPPED ---"
new_sandbox
git -C "$VAULT" checkout -q -b brain/save-2026-10-06
run_land
assert_contains "empty/skipped" "$(first)" "nothing to land"

echo "--- 13. origin narrows .saveinclude while landing: re-read before merge, LEFT OPEN ---"
new_sandbox
save_in "$VAULT" mine
narrow() { # drop logs/ from origin main's policy, as another PR would
  local co="$BOX/narrow"
  git clone -q -c core.autocrlf=false "$ORIGIN" "$co"; cfg "$co"
  grep -v "^logs/" "$co/.saveinclude" >"$co/.si"; mv "$co/.si" "$co/.saveinclude"
  git -C "$co" commit -qam narrow; git -C "$co" push -q origin main
}
export BOX ORIGIN CRLF; export -f narrow cfg ac
GH_ON_CREATE=narrow run_land
assert_contains "narrowed/left-open" "$(first)" "LAND: LEFT OPEN #1"
assert_contains "narrowed/names-path" "$(first)" "logs/2026-10-06-mine.md"
assert_eq "narrowed/no-merge" "0" "$(gh_called 'pr merge')"
assert_eq "narrowed/log-not-published" "no" "$(origin_has logs/2026-10-06-mine.md)"

echo
echo "passed: $PASSED  failed: $FAILED"
[[ $FAILED -eq 0 ]]
