#!/usr/bin/env bash
# test-changed-wiki-notes.sh — deterministic quality gate for
# brain/bin/changed-wiki-notes.sh
#
# Contract under test:
#   Prints one vault-relative `wiki/**/*.md` path per line for every ACTUALLY
#   changed note (git working tree / index), NOT what manifest.json claims.
#     - without --since : uncommitted changes only
#     - with --since <ref> : additionally, files changed between <ref> and HEAD
#     - deletions are never listed (nothing left to re-extract) — they have
#       their own --deleted stream, which lists nothing else (INNOV-292)
#     - only wiki/**/*.md — nothing outside wiki/, no non-.md files
#     - paths with spaces are emitted verbatim (git's porcelain quoting must be
#       undone), renames report only the NEW path
#     - --porcelain prints an integer count first, then the paths
#     - read-only: never mutates the vault
#     - exit 0 normally, exit 2 + usage on stderr for an unknown flag
#   Vault resolution: $BRAIN_ROOT, then $CLAUDE_PROJECT_DIR, then $PWD.
#
# Run:  bash tests/test-changed-wiki-notes.sh   (from anywhere)
# No network, no real vault, no node/python required.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
CWN="$REPO_ROOT/brain/bin/changed-wiki-notes.sh"

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

assert_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "expected: [$2]" "actual:   [$3]"
  fi
}

# Number of lines on stdout of the last run (a trailing unterminated line counts).
line_count() { # file
  local n
  n="$(grep -c '' "$1" 2>/dev/null || echo 0)"
  echo "${n:-0}"
}

# Creates a fresh vault sandbox and ASSIGNS the globals BOX / VAULT.
# Deliberately NOT run in a command substitution: it has to export state.
#
# Layout:
#   $BOX/vault/wiki/one.md, wiki/two.md, wiki/area/deep.md
#   $BOX/vault/README.md, logs/x.md, graphify-out/y.md
# All committed, tree clean.
new_vault() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  mkdir -p "$VAULT/wiki/area" "$VAULT/logs" "$VAULT/graphify-out"
  printf '# one\n' >"$VAULT/wiki/one.md"
  printf '# two\n' >"$VAULT/wiki/two.md"
  printf '# deep\n' >"$VAULT/wiki/area/deep.md"
  printf '# readme\n' >"$VAULT/README.md"
  printf '# log\n' >"$VAULT/logs/x.md"
  printf '# out\n' >"$VAULT/graphify-out/y.md"
  git_init_commit "$VAULT" "initial vault"
}

# core.autocrlf=false / core.eol=lf: a global autocrlf=true otherwise makes a
# freshly created repo look dirty on Windows and every case would false-pass.
git_init_commit() { # dir message
  local d="$1" msg="$2"
  git -c core.autocrlf=false -c core.eol=lf init -q "$d" >/dev/null 2>&1
  git -C "$d" config core.autocrlf false
  git -C "$d" config core.eol lf
  git -C "$d" config user.email "test@example.invalid"
  git -C "$d" config user.name "Harness"
  git -C "$d" config commit.gpgsign false
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "$msg" >/dev/null 2>&1
}

git_commit_all() { # dir message
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" commit -q -m "$2" >/dev/null 2>&1
}

# Runs the script against $VAULT with the CWD deliberately OUTSIDE the vault, so
# the run also proves $BRAIN_ROOT resolution. stdout -> $BOX/out.txt,
# stderr -> $BOX/err.txt. Echoes the exit status.
run_cwn() { # [args...]
  (
    cd "$BOX" || exit 99
    BRAIN_ROOT="$VAULT" bash "$CWN" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  echo $?
}

if [[ ! -f "$CWN" ]]; then
  for t in \
    "clean-tree/no-output" \
    "uncommitted/modified-and-added" \
    "deleted-note/not-listed" \
    "outside-wiki/never-listed" \
    "non-md-in-wiki/not-listed" \
    "since-ref/committed-note-listed" \
    "path-with-space/emitted-unquoted" \
    "rename/only-new-path" \
    "porcelain/count-matches-paths" \
    "unknown-flag/exit-2-usage-on-stderr" \
    "not-a-git-repo/exit-0-no-stdout" \
    "read-only/repo-state-unchanged"; do
    fail "$t" "brain/bin/changed-wiki-notes.sh does not exist at $CWN"
  done
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi

echo "--- changed-wiki-notes.sh ---"

# --- 1. clean tree => no stdout, exit 0 ------------------------------------
new_vault
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
if [[ -z "$got" && "$status" == "0" ]]; then
  pass "clean-tree/no-output"
else
  fail "clean-tree/no-output" \
    "expected: empty stdout, exit 0" \
    "actual:   exit [$status], stdout [$got]" \
    "stderr:   [$(cat "$BOX/err.txt")]"
fi

# --- 2. one modified + one added wiki note (uncommitted) -------------------
new_vault
printf '# one changed\n' >>"$VAULT/wiki/one.md"
mkdir -p "$VAULT/wiki/new"
printf '# three\n' >"$VAULT/wiki/new/three.md"
status="$(run_cwn)"
expected="$(printf 'wiki/new/three.md\nwiki/one.md')"
got="$(cat "$BOX/out.txt")"
assert_eq "uncommitted/modified-and-added" "$expected" "$got"
assert_eq "uncommitted/modified-and-added-exit-0" "0" "$status"

# --- 3. deleted note is NOT listed (nothing to re-extract) -----------------
new_vault
rm -f "$VAULT/wiki/two.md"
printf '# one changed\n' >>"$VAULT/wiki/one.md"
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
if grep -qF 'wiki/one.md' "$BOX/out.txt" && ! grep -qF 'wiki/two.md' "$BOX/out.txt"; then
  pass "deleted-note/not-listed"
else
  fail "deleted-note/not-listed" \
    "expected wiki/one.md present and the DELETED wiki/two.md absent" \
    "actual stdout: [$got]" \
    "exit: $status  stderr: [$(cat "$BOX/err.txt")]"
fi

# --- 4. changes outside wiki/ are never listed -----------------------------
new_vault
printf '# one changed\n' >>"$VAULT/wiki/one.md"
printf 'more\n' >>"$VAULT/logs/x.md"
printf 'more\n' >>"$VAULT/README.md"
printf 'more\n' >>"$VAULT/graphify-out/y.md"
printf '# brand new\n' >"$VAULT/logs/brand-new.md"
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
assert_eq "outside-wiki/never-listed" "wiki/one.md" "$got"

# --- 5. non-.md file inside wiki/ is not listed ----------------------------
new_vault
printf '# one changed\n' >>"$VAULT/wiki/one.md"
printf 'PNG-ish bytes\n' >"$VAULT/wiki/foo.png"
printf 'data\n' >"$VAULT/wiki/notes.txt"
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
assert_eq "non-md-in-wiki/not-listed" "wiki/one.md" "$got"

# --- 6. --since <ref>: note committed after <ref>, clean tree --------------
new_vault
ref="$(git -C "$VAULT" rev-parse HEAD)"
printf '# four\n' >"$VAULT/wiki/four.md"
git_commit_all "$VAULT" "add four"
status="$(run_cwn --since "$ref")"
got="$(cat "$BOX/out.txt")"
if grep -qF 'wiki/four.md' "$BOX/out.txt" && [[ "$status" == "0" ]]; then
  pass "since-ref/committed-note-listed"
else
  fail "since-ref/committed-note-listed" \
    "expected wiki/four.md listed for --since $ref (tree is clean), exit 0" \
    "actual: exit [$status], stdout [$got]" \
    "stderr: [$(cat "$BOX/err.txt")]"
fi
# ... and WITHOUT --since the same clean tree yields nothing.
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
assert_eq "since-ref/omitted-means-uncommitted-only" "" "$got"

# --- 7. wiki note whose path contains a space ------------------------------
# git status --porcelain renders this as "wiki/a note.md" (quoted); naive
# parsing leaks the quotes, splits the path, or emits backslash escapes.
new_vault
printf '# spaced\n' >"$VAULT/wiki/a note.md"
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
assert_eq "path-with-space/emitted-unquoted" "wiki/a note.md" "$got"
if [[ "$(line_count "$BOX/out.txt")" == "1" ]]; then
  pass "path-with-space/single-line"
else
  fail "path-with-space/single-line" \
    "expected exactly 1 output line" \
    "actual lines: $(line_count "$BOX/out.txt")" \
    "stdout (od -c): $(od -c "$BOX/out.txt" | head -n 3 | tr '\n' ' ')"
fi
if grep -qE '["\\]' "$BOX/out.txt"; then
  fail "path-with-space/no-quotes-or-backslashes" \
    "output contains a quote or backslash — porcelain quoting was not undone" \
    "stdout: [$got]"
else
  pass "path-with-space/no-quotes-or-backslashes"
fi

# --- 8. renamed wiki note (git mv, staged) => only the NEW path ------------
new_vault
git -C "$VAULT" mv "wiki/one.md" "wiki/renamed.md" >/dev/null 2>&1
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
if grep -qF 'wiki/renamed.md' "$BOX/out.txt" \
  && ! grep -qF 'wiki/one.md' "$BOX/out.txt" \
  && ! grep -qF -- '->' "$BOX/out.txt"; then
  pass "rename/only-new-path"
else
  fail "rename/only-new-path" \
    "expected only wiki/renamed.md — no old path, no 'old -> new' form" \
    "actual stdout: [$got]" \
    "exit: $status  stderr: [$(cat "$BOX/err.txt")]"
fi

# --- 9. --porcelain: first line is the count of the path lines -------------
new_vault
printf '# one changed\n' >>"$VAULT/wiki/one.md"
printf '# five\n' >"$VAULT/wiki/five.md"
status="$(run_cwn --porcelain)"
first="$(head -n 1 "$BOX/out.txt")"
total="$(line_count "$BOX/out.txt")"
rest=$((total - 1))
if [[ "$first" =~ ^[0-9]+$ ]] && [[ "$first" -eq "$rest" ]] && [[ "$status" == "0" ]]; then
  pass "porcelain/count-matches-paths"
else
  fail "porcelain/count-matches-paths" \
    "expected first line to be an integer equal to the number of following path lines" \
    "first line: [$first]  following lines: [$rest]  exit: [$status]" \
    "stdout: [$(cat "$BOX/out.txt")]" \
    "stderr: [$(cat "$BOX/err.txt")]"
fi

# --- 10. unknown flag => exit 2 with usage on stderr -----------------------
new_vault
status="$(run_cwn --definitely-not-a-flag)"
err="$(cat "$BOX/err.txt")"
if [[ "$status" == "2" ]] && grep -qi 'usage' "$BOX/err.txt"; then
  pass "unknown-flag/exit-2-usage-on-stderr"
else
  fail "unknown-flag/exit-2-usage-on-stderr" \
    "expected: exit 2 and a usage message on stderr" \
    "actual:   exit [$status]" \
    "stderr:   [$err]" \
    "stdout:   [$(cat "$BOX/out.txt")]"
fi

# --- 11. vault is not a git repo => exit 0, no stdout, note on stderr ------
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
printf '# lonely\n' >"$VAULT/wiki/lonely.md"
status="$(run_cwn)"
got="$(cat "$BOX/out.txt")"
err="$(cat "$BOX/err.txt")"
if [[ "$status" == "0" && -z "$got" && -n "$err" ]]; then
  pass "not-a-git-repo/exit-0-no-stdout"
else
  fail "not-a-git-repo/exit-0-no-stdout" \
    "expected: exit 0, empty stdout, non-empty stderr note" \
    "actual:   exit [$status], stdout [$got], stderr [$err]"
fi

# --- 12. read-only: repo state identical before and after ------------------
new_vault
printf '# one changed\n' >>"$VAULT/wiki/one.md"
printf '# six\n' >"$VAULT/wiki/six.md"
rm -f "$VAULT/wiki/two.md"
head_before="$(git -C "$VAULT" rev-parse HEAD)"
git -C "$VAULT" status --porcelain >"$BOX/status.before"
status="$(run_cwn --porcelain)"
status2="$(run_cwn --since "$head_before")"
head_after="$(git -C "$VAULT" rev-parse HEAD)"
git -C "$VAULT" status --porcelain >"$BOX/status.after"
assert_eq "read-only/head-unchanged" "$head_before" "$head_after"
if cmp -s "$BOX/status.before" "$BOX/status.after"; then
  pass "read-only/worktree-unchanged"
else
  fail "read-only/worktree-unchanged" \
    "git status --porcelain differs after running the script" \
    "before: [$(cat "$BOX/status.before")]" \
    "after:  [$(cat "$BOX/status.after")]" \
    "exit codes: [$status] [$status2]"
fi

# ---------------------------------------------------------- --deleted (INNOV-292) --
# A second stream: deleted wiki notes only. The default stream stays the /brain:save
# 5c work list (nothing to re-extract from a deleted note); --deleted feeds the
# check-concept-graph.sh staleness count, where a deletion leaves a phantom node.
echo "--- --deleted ---"

# Every deletion shape at once: unstaged ( D), staged (D ), modified-then-deleted
# (MD), renamed-then-deleted (RD — its HEAD source is the deletion), and
# added-then-deleted (AD, never in HEAD — so never in any graph, NOT a deletion). A modified and a brand-new note must stay out of this stream.
deletion_shapes() {
  new_vault
  printf '# gone-unstaged\n' >"$VAULT/wiki/gone-unstaged.md"
  printf '# gone-staged\n' >"$VAULT/wiki/gone-staged.md"
  printf '# gone-md\n' >"$VAULT/wiki/gone-md.md"
  git_commit_all "$VAULT" "notes to delete"
  rm -f "$VAULT/wiki/gone-unstaged.md"                                   #  D
  git -C "$VAULT" rm -q "wiki/gone-staged.md" >/dev/null 2>&1            # D
  printf 'edit\n' >>"$VAULT/wiki/gone-md.md"
  git -C "$VAULT" add "wiki/gone-md.md" >/dev/null 2>&1
  rm -f "$VAULT/wiki/gone-md.md"                                         # MD
  printf '# ad\n' >"$VAULT/wiki/never-committed.md"
  git -C "$VAULT" add "wiki/never-committed.md" >/dev/null 2>&1
  rm -f "$VAULT/wiki/never-committed.md"                                 # AD
  git -C "$VAULT" mv "wiki/two.md" "wiki/gone-rd-new.md" >/dev/null 2>&1
  rm -f "$VAULT/wiki/gone-rd-new.md"                                     # RD: two.md is the deletion
  printf '# one changed\n' >>"$VAULT/wiki/one.md"                        #  M
  printf '# fresh\n' >"$VAULT/wiki/fresh.md"                             # ??
  rm -f "$VAULT/logs/x.md"                                               # outside wiki/
}

deletion_shapes
status="$(run_cwn --deleted)"
expected="$(printf 'wiki/gone-md.md\nwiki/gone-staged.md\nwiki/gone-unstaged.md\nwiki/two.md')"
assert_eq "deleted/uncommitted-shapes" "$expected" "$(cat "$BOX/out.txt")" \
  "stderr: [$(cat "$BOX/err.txt")]"
assert_eq "deleted/uncommitted-shapes-exit-0" "0" "$status"

# Default output on the SAME fixture is unchanged: no deletion ever leaks into the
# work list. This is the assertion that fails if the two streams get merged.
status="$(run_cwn)"
assert_eq "default/no-deletion-leaks" "$(printf 'wiki/fresh.md\nwiki/one.md')" \
  "$(cat "$BOX/out.txt")"

# --porcelain composes with --deleted.
status="$(run_cwn --deleted --porcelain)"
assert_eq "deleted/porcelain-count" "4" "$(head -n 1 "$BOX/out.txt")"

# Committed range: a deletion committed after <ref> is listed with --since; the
# default --since stream still omits it.
new_vault
ref="$(git -C "$VAULT" rev-parse HEAD)"
git -C "$VAULT" rm -q "wiki/two.md" >/dev/null 2>&1
printf '# one changed\n' >>"$VAULT/wiki/one.md"
git_commit_all "$VAULT" "delete two, edit one"
status="$(run_cwn --deleted --since "$ref")"
assert_eq "deleted/since-committed-deletion" "wiki/two.md" "$(cat "$BOX/out.txt")" \
  "stderr: [$(cat "$BOX/err.txt")]"
status="$(run_cwn --since "$ref")"
assert_eq "default/since-no-deletion-leaks" "wiki/one.md" "$(cat "$BOX/out.txt")"

# A note deleted in the range but re-created in the working tree exists again —
# it belongs to the default stream, not this one.
printf '# two is back\n' >"$VAULT/wiki/two.md"
status="$(run_cwn --deleted --since "$ref")"
assert_eq "deleted/recreated-not-listed" "" "$(cat "$BOX/out.txt")"

# Renames are emitted as their new path by the default stream and must not also
# register as a deletion — staged (git mv) and committed, the latter even with
# rename detection switched off in the user's config.
new_vault
git -C "$VAULT" config diff.renames false   # status.renames follows it by default
git -C "$VAULT" mv "wiki/one.md" "wiki/renamed.md" >/dev/null 2>&1
status="$(run_cwn --deleted)"
assert_eq "deleted/staged-rename-not-a-deletion" "" "$(cat "$BOX/out.txt")"
new_vault
git -C "$VAULT" config diff.renames false
ref="$(git -C "$VAULT" rev-parse HEAD)"
git -C "$VAULT" mv "wiki/one.md" "wiki/renamed.md" >/dev/null 2>&1
git_commit_all "$VAULT" "rename one"
status="$(run_cwn --deleted --since "$ref")"
assert_eq "deleted/committed-rename-not-a-deletion" "" "$(cat "$BOX/out.txt")"

# Not a git repo => the same clean no-op as the default path.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
status="$(run_cwn --deleted)"
assert_eq "deleted/not-a-git-repo-exit-0" "0" "$status"
assert_eq "deleted/not-a-git-repo-no-stdout" "" "$(cat "$BOX/out.txt")"

# CRLF variant (SPO-346): the vault is autocrlf, so fixtures with CRLF content in an
# autocrlf=true repo must behave the same — an LF-only fixture can false-green.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
printf '# crlf one\r\nbody\r\n' >"$VAULT/wiki/one.md"
printf '# crlf two\r\nbody\r\n' >"$VAULT/wiki/two.md"
git_init_commit "$VAULT" "crlf vault"
git -C "$VAULT" config core.autocrlf true
ref="$(git -C "$VAULT" rev-parse HEAD)"
git -C "$VAULT" rm -q "wiki/one.md" >/dev/null 2>&1
git_commit_all "$VAULT" "delete crlf one"
rm -f "$VAULT/wiki/two.md"
status="$(run_cwn --deleted --since "$ref")"
assert_eq "deleted/crlf-vault" "$(printf 'wiki/one.md\nwiki/two.md')" "$(cat "$BOX/out.txt")" \
  "stderr: [$(cat "$BOX/err.txt")]"
status="$(run_cwn --since "$ref")"
assert_eq "default/crlf-vault-no-deletion-leaks" "" "$(cat "$BOX/out.txt")"

# NEGATIVE CONTROL: a mutant with the deletion stream switched on unconditionally
# (the streams crossed) must fail the leak assertion above — proof it can fail.
MUT="$TMPROOT/cwn-mutant.sh"
sed 's/^DELETED=0$/DELETED=1/' "$CWN" >"$MUT"
if cmp -s "$CWN" "$MUT"; then
  fail "negative-control/mutation-applied" "sed did not change the script — the mutant is vacuous"
else
  pass "negative-control/mutation-applied"
  deletion_shapes
  ( cd "$BOX" && BRAIN_ROOT="$VAULT" bash "$MUT" ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  if grep -qF 'wiki/gone-' "$BOX/out.txt"; then
    pass "negative-control/leak-detected"
  else
    fail "negative-control/leak-detected" \
      "the crossed-streams mutant should leak deletions into the default stream" \
      "stdout: [$(cat "$BOX/out.txt")]"
  fi
fi

# ------------------------------------------------- meta notes (INNOV-408) --
# wiki/log.md, hot.md and index.md never enter the concept graph, so neither
# stream lists them: not as a 5c work item, not as staleness. The names come
# from brain/bin/wiki-meta.mjs, so a name added there and not to the bash mirror
# fails here. CRLF content too: the vault is autocrlf.
echo "--- meta notes ---"
META="$(cd "$REPO_ROOT" && node --input-type=module -e "import { META_NOTES } from './brain/bin/wiki-meta.mjs'; console.log([...META_NOTES].join(' '))")"
if [[ -z "$META" ]]; then
  fail "meta/names-read" "could not read META_NOTES from brain/bin/wiki-meta.mjs"
else
  pass "meta/names-read"
fi
new_vault
for n in $META; do printf '# meta\r\nseed\r\n' >"$VAULT/wiki/$n"; done
mkdir -p "$VAULT/wiki/area"
git_commit_all "$VAULT" "meta notes"
ref="$(git -C "$VAULT" rev-parse HEAD)"
for n in $META; do printf 'appended\r\n' >>"$VAULT/wiki/$n"; done
printf '# one changed\n' >>"$VAULT/wiki/one.md"
status="$(run_cwn --since "$ref")"
assert_eq "meta/changed-not-listed" "wiki/one.md" "$(cat "$BOX/out.txt")"
git_commit_all "$VAULT" "edit meta"
status="$(run_cwn --since "$ref")"
assert_eq "meta/committed-not-listed" "wiki/one.md" "$(cat "$BOX/out.txt")"
for n in $META; do rm -f "$VAULT/wiki/$n"; done
status="$(run_cwn --deleted --since "$ref")"
assert_eq "meta/deleted-not-listed" "" "$(cat "$BOX/out.txt")"
# Negative control: a real note that merely ends in log.md is still listed.
printf '# x\n' >"$VAULT/wiki/area/release-log.md"
status="$(run_cwn)"
assert_eq "meta/lookalike-still-listed" "wiki/area/release-log.md" "$(cat "$BOX/out.txt")"

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
