#!/usr/bin/env bash
# test-concept-graph-staleness.sh — deterministic quality gate for
# brain/bin/check-concept-graph.sh (INNOV-286)
#
# /brain:save step 5c gated the wiki concept-graph refresh on notes changed THIS
# session only; staleness accumulated across prior sessions was invisible. A
# recorded incident: 2 session-changed notes, concept graph 517 documents behind,
# step reported green. The guard measures the TOTAL — wiki notes added/modified
# since the last commit that touched graphify-out/graph.json — from git, never
# from manifest.json (INNOV-271: it over-reports hundreds when ten changed).
#
# Contract under test:
#   exit 0 + first line "CONCEPT-GRAPH: OK - N document(s) ..."  (stdout) when
#            N <= threshold (default 25, CONCEPT_GRAPH_THRESHOLD overrides)
#   exit 1 + first line "CONCEPT-GRAPH: STALE - N document(s) behind" (stderr)
#            when N > threshold — WARN polarity, the caller relays but proceeds
#   exit 0 + "CONCEPT-GRAPH: SKIPPED - ..." when not measurable: no graph.json,
#            not a git repo, or graph.json never committed. Never a crash.
#   read-only; vault from $BRAIN_ROOT -> $CLAUDE_PROJECT_DIR -> $PWD
#
# Run:  bash tests/test-concept-graph-staleness.sh   (from anywhere)
# No network, no real vault, no node/python required.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
GUARD="$REPO_ROOT/brain/bin/check-concept-graph.sh"
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

first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }

evidence() { # box
  local box="$1"
  echo "stdout: [$(tr '\n' '|' <"$box/out.txt" 2>/dev/null)]"
  echo "stderr: [$(tr '\n' '|' <"$box/err.txt" 2>/dev/null)]"
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

# Creates a fresh vault sandbox and ASSIGNS the globals BOX / VAULT.
# Deliberately NOT run in a command substitution — the assignments would be
# lost. Layout: wiki/ notes + graphify-out/graph.json, all committed together,
# i.e. a graph that is CURRENT at birth.
new_vault() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  mkdir -p "$VAULT/wiki" "$VAULT/graphify-out"
  printf '# one\n' >"$VAULT/wiki/one.md"
  printf '# two\n' >"$VAULT/wiki/two.md"
  printf '{"nodes":[]}\n' >"$VAULT/graphify-out/graph.json"
  git_init_commit "$VAULT" "initial vault + graph"
}

# add_notes <dir> <prefix> <n> — writes n new wiki notes named <prefix>-i.md
add_notes() { # dir prefix n
  local d="$1" prefix="$2" n="$3" i=1
  while [[ "$i" -le "$n" ]]; do
    printf '# %s %d\n' "$prefix" "$i" >"$d/wiki/$prefix-$i.md"
    i=$((i + 1))
  done
}

STATUS=""
# Runs a guard script against $VAULT with the CWD deliberately OUTSIDE the
# vault, so every run also proves $BRAIN_ROOT resolution. Streams captured in
# $BOX/out.txt / $BOX/err.txt, exit code in $STATUS.
run_guard() { # script [VAR=value...]
  local script="$1"
  shift
  (
    cd "$BOX" || exit 99
    unset CLAUDE_PROJECT_DIR
    unset CONCEPT_GRAPH_THRESHOLD
    env BRAIN_ROOT="$VAULT" "$@" bash "$script"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

if [[ ! -f "$GUARD" ]]; then
  echo "note: $GUARD does not exist yet — every case below is expected to FAIL until it lands."
fi

# ================================================================== CASES ===

# --- 1. THE INCIDENT SHAPE: 2 session notes, 32 stale total => STALE --------
# Prior sessions commit 30 notes AFTER the graph's last commit; this session
# adds 2 uncommitted notes. The session-only view sees 2 (green); the total is
# 32 (> 25) and must WARN, naming 32.
echo "--- 1. acceptance: accumulated staleness across sessions ---"
new_vault
add_notes "$VAULT" prior 30
git_commit_all "$VAULT" "prior sessions: 30 notes, graph never rebuilt"
add_notes "$VAULT" session 2
run_guard "$GUARD"
assert_eq "acceptance/exit-1" "1" "$STATUS" \
  "2 session notes must not hide 32 total stale documents" "$(evidence "$BOX")"
assert_prefix "acceptance/stderr-first-line-STALE" "CONCEPT-GRAPH: STALE" \
  "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"
assert_contains "acceptance/names-N-32" "32 document(s) behind" \
  "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"
assert_contains "acceptance/names-threshold" "25" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"
assert_eq "acceptance/nothing-on-stdout" "" "$(first_line "$BOX/out.txt")" \
  "the STALE verdict belongs on stderr" "$(evidence "$BOX")"

# --- 2. current graph => OK, exit 0, count reported --------------------------
echo "--- 2. current graph ---"
new_vault
run_guard "$GUARD"
assert_eq "current/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "current/stdout-first-line-OK" "CONCEPT-GRAPH: OK" \
  "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"
assert_contains "current/reports-zero" "0 document(s)" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"

# --- 3. a few notes behind (<= threshold) => still OK, but N visible ---------
echo "--- 3. two notes behind, under threshold ---"
new_vault
add_notes "$VAULT" small 2
run_guard "$GUARD"
assert_eq "under-threshold/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "under-threshold/OK" "CONCEPT-GRAPH: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_contains "under-threshold/reports-2" "2 document(s)" "$(first_line "$BOX/out.txt")" \
  "the number must be visible on the OK path too" "$(evidence "$BOX")"

# --- 4. no graphify-out/graph.json => SKIPPED, exit 0, no crash --------------
echo "--- 4. no graph.json ---"
new_vault
git -C "$VAULT" rm -q graphify-out/graph.json >/dev/null 2>&1
git_commit_all "$VAULT" "drop graph"
run_guard "$GUARD"
assert_eq "no-graph/exit-0" "0" "$STATUS" \
  "a vault with no wiki graph yet must not crash or warn" "$(evidence "$BOX")"
assert_prefix "no-graph/SKIPPED" "CONCEPT-GRAPH: SKIPPED" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_contains "no-graph/names-the-file" "graph.json" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"

# --- 5. graph.json exists but never committed => SKIPPED, says so ------------
echo "--- 5. graph.json never committed ---"
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
printf '# one\n' >"$VAULT/wiki/one.md"
git_init_commit "$VAULT" "notes only"
mkdir -p "$VAULT/graphify-out"
printf '{"nodes":[]}\n' >"$VAULT/graphify-out/graph.json"
run_guard "$GUARD"
assert_eq "never-committed/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "never-committed/SKIPPED" "CONCEPT-GRAPH: SKIPPED" \
  "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"
assert_contains "never-committed/says-never-committed" "never been committed" \
  "$(first_line "$BOX/out.txt")" \
  "the line must say it outright, not guess a staleness number" "$(evidence "$BOX")"

# --- 6. not a git repo => SKIPPED, exit 0 ------------------------------------
echo "--- 6. not a git repo ---"
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki" "$VAULT/graphify-out"
printf '{"nodes":[]}\n' >"$VAULT/graphify-out/graph.json"
run_guard "$GUARD"
assert_eq "no-git/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "no-git/SKIPPED" "CONCEPT-GRAPH: SKIPPED" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"

# --- 7. threshold override tightens the gate ---------------------------------
echo "--- 7. CONCEPT_GRAPH_THRESHOLD=5 ---"
new_vault
add_notes "$VAULT" mid 6
git_commit_all "$VAULT" "six notes after graph"
run_guard "$GUARD" CONCEPT_GRAPH_THRESHOLD=5
assert_eq "custom-5/exit-1" "1" "$STATUS" \
  "the threshold must be able to tighten, not only loosen" "$(evidence "$BOX")"
assert_prefix "custom-5/STALE" "CONCEPT-GRAPH: STALE" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"
assert_contains "custom-5/names-6" "6 document(s) behind" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"

# --- 8. junk threshold falls back to 25 rather than disabling the gate -------
echo "--- 8. junk CONCEPT_GRAPH_THRESHOLD ---"
new_vault
add_notes "$VAULT" prior 30
git_commit_all "$VAULT" "30 notes after graph"
run_guard "$GUARD" CONCEPT_GRAPH_THRESHOLD=lots
assert_eq "junk-threshold/still-exit-1" "1" "$STATUS" \
  "a typo'd threshold must not silently disable the gate" "$(evidence "$BOX")"
assert_contains "junk-threshold/STALE-verdict-present" "CONCEPT-GRAPH: STALE" \
  "$(tr '\n' ' ' <"$BOX/err.txt" | tr -d '\r')" \
  "the stderr note about the junk value may precede the verdict" "$(evidence "$BOX")"
assert_contains "junk-threshold/falls-back-to-25" "threshold 25" \
  "$(tr '\n' ' ' <"$BOX/err.txt" | tr -d '\r')" "$(evidence "$BOX")"

# --- 9. rebuilt + recommitted graph resets the clock -------------------------
echo "--- 9. recommitting the graph resets staleness ---"
new_vault
add_notes "$VAULT" prior 30
git_commit_all "$VAULT" "30 notes"
printf '{"nodes":["rebuilt"]}\n' >"$VAULT/graphify-out/graph.json"
git_commit_all "$VAULT" "rebuild graph"
run_guard "$GUARD"
assert_eq "reset/exit-0" "0" "$STATUS" \
  "a graph committed after the notes is current again" "$(evidence "$BOX")"
assert_prefix "reset/OK" "CONCEPT-GRAPH: OK" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
assert_contains "reset/reports-zero" "0 document(s)" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"

# --- 10. read-only: the guard never mutates the vault ------------------------
echo "--- 10. read-only ---"
new_vault
add_notes "$VAULT" prior 30
git_commit_all "$VAULT" "30 notes"
status_before="$(git -C "$VAULT" status --porcelain | tr '\n' '|')"
head_before="$(git -C "$VAULT" rev-parse HEAD)"
run_guard "$GUARD"
assert_eq "read-only/exit-1" "1" "$STATUS" "$(evidence "$BOX")"
assert_eq "read-only/worktree-unchanged" "$status_before" \
  "$(git -C "$VAULT" status --porcelain | tr '\n' '|')" "$(evidence "$BOX")"
assert_eq "read-only/HEAD-unchanged" "$head_before" "$(git -C "$VAULT" rev-parse HEAD)" \
  "$(evidence "$BOX")"

# --- 11. verdict discipline: exactly one CONCEPT-GRAPH line per run ----------
echo "--- 11. verdict discipline ---"
for shape in ok stale; do
  new_vault
  if [[ "$shape" == "stale" ]]; then
    add_notes "$VAULT" prior 30
    git_commit_all "$VAULT" "30 notes"
  fi
  run_guard "$GUARD"
  count="$(cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -c '^CONCEPT-GRAPH:')"
  assert_eq "verdict/$shape/exactly-one-verdict-line" "1" "$count" "$(evidence "$BOX")"
done

# --- 12. NEGATIVE CONTROL: strip the total-staleness computation -------------
# A mutated guard whose --since is removed sees only the SESSION view — the
# exact INNOV-286 bug. Against the acceptance fixture it must flip STALE -> OK,
# proving case 1's assertion is what catches the regression (non-vacuous).
echo "--- 12. negative control ---"
MUTDIR="$TMPROOT/mutant-bin"
mkdir -p "$MUTDIR"
cp "$CWN" "$MUTDIR/changed-wiki-notes.sh"
sed 's/ --since "$LAST"//' "$GUARD" >"$MUTDIR/check-concept-graph.sh"
if grep -q -- '--since "$LAST"' "$MUTDIR/check-concept-graph.sh"; then
  fail "negative-control/mutation-applied" "sed failed to strip --since from the mutant"
else
  pass "negative-control/mutation-applied"
fi
new_vault
add_notes "$VAULT" prior 30
git_commit_all "$VAULT" "prior sessions: 30 notes"
add_notes "$VAULT" session 2
run_guard "$MUTDIR/check-concept-graph.sh"
assert_eq "negative-control/session-only-view-goes-green" "0" "$STATUS" \
  "the mutant (session-only view) must report OK here — that flip is what proves" \
  "case 1 really tests the accumulated-staleness computation" "$(evidence "$BOX")"
assert_prefix "negative-control/mutant-reports-OK" "CONCEPT-GRAPH: OK" \
  "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"
run_guard "$GUARD"
assert_eq "negative-control/real-guard-still-STALE-on-same-fixture" "1" "$STATUS" \
  "$(evidence "$BOX")"

# --- 13. missing sibling script => SKIPPED, never "OK - 0" -------------------
# A stale install can ship this guard without changed-wiki-notes.sh (doctor
# check 7's recorded incident). A broken measurement must not read as green.
echo "--- 13. missing changed-wiki-notes.sh ---"
LONEDIR="$TMPROOT/lone-bin"
mkdir -p "$LONEDIR"
cp "$GUARD" "$LONEDIR/check-concept-graph.sh"
new_vault
add_notes "$VAULT" prior 30
git_commit_all "$VAULT" "30 notes"
run_guard "$LONEDIR/check-concept-graph.sh"
assert_eq "missing-sibling/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_prefix "missing-sibling/SKIPPED-not-OK" "CONCEPT-GRAPH: SKIPPED" \
  "$(first_line "$BOX/out.txt")" \
  "a broken measurement must land on SKIPPED, never OK - 0" "$(evidence "$BOX")"
assert_contains "missing-sibling/names-the-sibling" "changed-wiki-notes.sh" \
  "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"

# --- 14. deletions count 1:1 (INNOV-292) --------------------------------------
# A deleted note leaves a phantom node in the graph, so it makes the graph stale
# exactly as much as a modified one. Fixture: 30 notes extracted into a graph
# committed AFTER them (current), then notes are deleted.
echo "--- 14. deletions count toward staleness, 1:1 ---"
graphed_vault() { # n notes, graph rebuilt after them => OK at birth
  new_vault
  add_notes "$VAULT" old "$1"
  git_commit_all "$VAULT" "$1 notes"
  printf '{"nodes":["rebuilt"]}\n' >"$VAULT/graphify-out/graph.json"
  git_commit_all "$VAULT" "rebuild graph"
}
delete_notes() { # dir prefix from to — one rm, not one per note (Windows spawn tax)
  local i="$3" paths=""
  while [[ "$i" -le "$4" ]]; do
    paths="$paths $1/wiki/$2-$i.md"
    i=$((i + 1))
  done
  # shellcheck disable=SC2086 # fixture paths have no spaces; word-split on purpose
  rm -f $paths
}

# deletion-only, above threshold: 20 committed + 6 uncommitted = 26 > 25
graphed_vault 30
delete_notes "$VAULT" old 1 20
git_commit_all "$VAULT" "cleanup: delete 20 notes"
delete_notes "$VAULT" old 21 26
run_guard "$GUARD"
assert_eq "deletion-only/exit-1" "1" "$STATUS" \
  "26 deleted notes are 26 phantom nodes — the graph is stale" "$(evidence "$BOX")"
assert_contains "deletion-only/names-26" "26 document(s) behind" \
  "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"
# INNOV-351: an incremental --update cannot drop deleted notes' nodes (graphify's
# shrink guard refuses the smaller graph after the update has already forgotten
# the deletions), so the remedy for a deletion must be the full rebuild.
assert_full_rebuild_remedy() { # name — reads $BOX/err.txt
  local err
  err="$(tr -d '\r' <"$BOX/err.txt")"
  assert_contains "$1/remedy-full-rebuild" "rm graphify-out/graph.json" "$err" "$(evidence "$BOX")"
  if [[ "$err" == *"(skill, wiki --update)"* ]]; then
    fail "$1/remedy-not-update" "a deletion must not be sent to wiki --update" "$(evidence "$BOX")"
  else
    pass "$1/remedy-not-update"
  fi
}
assert_full_rebuild_remedy deletion-only
assert_contains "deletion-only/remedy-names-26-deleted" "26 of them are deleted notes" \
  "$(tr -d '\r' <"$BOX/err.txt")" "$(evidence "$BOX")"

# negative control: deletion-only, at threshold stays OK (no heavier weighting)
graphed_vault 30
delete_notes "$VAULT" old 1 5
git_commit_all "$VAULT" "delete 5"
run_guard "$GUARD" CONCEPT_GRAPH_THRESHOLD=5
assert_eq "deletion-under-threshold/exit-0" "0" "$STATUS" "$(evidence "$BOX")"
assert_contains "deletion-under-threshold/OK-5" "OK - 5 document(s)" \
  "$(first_line "$BOX/out.txt")" "$(evidence "$BOX")"

# mixed: 3 modified + 3 deleted = 6 > 5 — the streams are summed
graphed_vault 30
printf 'edit\n' >>"$VAULT/wiki/old-1.md"
printf 'edit\n' >>"$VAULT/wiki/old-2.md"
printf 'edit\n' >>"$VAULT/wiki/old-3.md"
delete_notes "$VAULT" old 4 6
run_guard "$GUARD" CONCEPT_GRAPH_THRESHOLD=5
assert_eq "mixed/exit-1" "1" "$STATUS" "$(evidence "$BOX")"
assert_contains "mixed/names-6" "6 document(s) behind" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"
assert_full_rebuild_remedy mixed

# CRLF variant (SPO-346): an autocrlf vault with CRLF notes counts the same.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki" "$VAULT/graphify-out"
i=1
while [[ "$i" -le 6 ]]; do
  printf '# crlf %d\r\nbody\r\n' "$i" >"$VAULT/wiki/crlf-$i.md"
  i=$((i + 1))
done
printf '{"nodes":[]}\r\n' >"$VAULT/graphify-out/graph.json"
git_init_commit "$VAULT" "crlf vault + graph"
git -C "$VAULT" config core.autocrlf true
delete_notes "$VAULT" crlf 1 6
run_guard "$GUARD" CONCEPT_GRAPH_THRESHOLD=5
assert_eq "crlf-deletions/exit-1" "1" "$STATUS" "$(evidence "$BOX")"
assert_contains "crlf-deletions/names-6" "6 document(s) behind" \
  "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"
assert_full_rebuild_remedy crlf-deletions

# NEGATIVE CONTROL: a guard that drops the --deleted stream is the INNOV-292 bug;
# on the deletion-only fixture it must go green, proving the case above can fail.
DELMUT="$TMPROOT/deleted-mutant-bin"
mkdir -p "$DELMUT"
cp "$CWN" "$DELMUT/changed-wiki-notes.sh"
sed 's/^DELETED_LIST=.*/DELETED_LIST=""/' "$GUARD" >"$DELMUT/check-concept-graph.sh"
if cmp -s "$GUARD" "$DELMUT/check-concept-graph.sh"; then
  fail "deleted-negative-control/mutation-applied" "sed did not change the guard"
else
  pass "deleted-negative-control/mutation-applied"
fi
graphed_vault 30
delete_notes "$VAULT" old 1 26
run_guard "$DELMUT/check-concept-graph.sh"
assert_eq "deleted-negative-control/mutant-goes-green" "0" "$STATUS" \
  "without the --deleted stream, 26 phantom nodes read as OK - 0" "$(evidence "$BOX")"
run_guard "$GUARD"
assert_eq "deleted-negative-control/real-guard-STALE" "1" "$STATUS" "$(evidence "$BOX")"

# add/modify-only STALE keeps the --update remedy: proves the branch exists.
new_vault
add_notes "$VAULT" prior 30
run_guard "$GUARD"
assert_contains "no-deletions/remedy-update" "(skill, wiki --update)" \
  "$(tr -d '\r' <"$BOX/err.txt")" "$(evidence "$BOX")"
if grep -q 'rm graphify-out/graph.json' "$BOX/err.txt"; then
  fail "no-deletions/no-full-rebuild" "no note was deleted; --update is enough" "$(evidence "$BOX")"
else
  pass "no-deletions/no-full-rebuild"
fi

# NEGATIVE CONTROL (INNOV-351): a guard that never counts deletions for the
# remedy sends a deletion to --update, where the phantom nodes survive.
RMUT="$TMPROOT/remedy-mutant-bin"
mkdir -p "$RMUT"
cp "$CWN" "$RMUT/changed-wiki-notes.sh"
sed 's/^D=.*/D=0/' "$GUARD" >"$RMUT/check-concept-graph.sh"
if cmp -s "$GUARD" "$RMUT/check-concept-graph.sh"; then
  fail "remedy-negative-control/mutation-applied" "sed did not change the guard"
else
  pass "remedy-negative-control/mutation-applied"
fi
graphed_vault 30
delete_notes "$VAULT" old 1 26
run_guard "$RMUT/check-concept-graph.sh"
assert_contains "remedy-negative-control/mutant-says-update" "(skill, wiki --update)" \
  "$(tr -d '\r' <"$BOX/err.txt")" "$(evidence "$BOX")"

# --- 12. STALE names the count at the last save (INNOV-300) ------------------
# A skip that becomes routine compounds: the skip line must show N AND what N
# was at the previous save. "Last save" = the last commit touching logs/ (every
# /brain:save commits its session log); M = notes changed graph..that commit.
echo "--- 12. was M at last save ---"
save_commit() { # dir slug — what a /brain:save commit looks like to git
  mkdir -p "$1/logs"
  printf '# %s\n' "$2" >"$1/logs/$2.md"
  git_commit_all "$1" "save: $2"
}

# graph -> 5 notes -> save (skipped 5c) -> 3 notes => N=8, was 5
new_vault
add_notes "$VAULT" before 5
save_commit "$VAULT" s1
add_notes "$VAULT" after 3
git_commit_all "$VAULT" "3 more notes"
run_guard "$GUARD" CONCEPT_GRAPH_THRESHOLD=5
assert_eq "last-save/exit-1" "1" "$STATUS" "$(evidence "$BOX")"
assert_contains "last-save/names-8" "8 document(s) behind" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"
assert_contains "last-save/was-5" "was 5 at last save" "$(first_line "$BOX/err.txt")" \
  "the compounding must be visible on the verdict line itself" "$(evidence "$BOX")"

# CRLF variant: an autocrlf vault counts the same (the vault is autocrlf).
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki" "$VAULT/graphify-out"
printf '{"nodes":[]}\r\n' >"$VAULT/graphify-out/graph.json"
git_init_commit "$VAULT" "crlf vault + graph"
git -C "$VAULT" config core.autocrlf true
i=1
while [[ "$i" -le 4 ]]; do
  printf '# crlf %d\r\nbody\r\n' "$i" >"$VAULT/wiki/crlf-$i.md"
  i=$((i + 1))
done
save_commit "$VAULT" s1
printf '# late\r\n' >"$VAULT/wiki/late.md"
run_guard "$GUARD" CONCEPT_GRAPH_THRESHOLD=3
assert_contains "last-save-crlf/was-4" "was 4 at last save" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"

# a save that refreshed 5c commits graph + log together => was 0
new_vault
printf '{"nodes":["rebuilt"]}\n' >"$VAULT/graphify-out/graph.json"
save_commit "$VAULT" s1
add_notes "$VAULT" after 30
run_guard "$GUARD"
assert_contains "last-save-refreshed/was-0" "was 0 at last save" \
  "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"

# graph rebuilt AFTER the last save => at that save the graph was older; the
# count against the current graph is 0 (the clock was reset since).
new_vault
add_notes "$VAULT" before 5
save_commit "$VAULT" s1
printf '{"nodes":["rebuilt"]}\n' >"$VAULT/graphify-out/graph.json"
git_commit_all "$VAULT" "rebuild graph"
add_notes "$VAULT" after 30
run_guard "$GUARD"
assert_contains "graph-after-save/was-0" "was 0 at last save" \
  "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"

# vault nested in a repo under a path with regex metacharacters: M still counts
# (a regex-interpolated prefix would match nothing and report was 0). Git for
# Windows cannot enter a path containing '[', and no Windows-legal character is
# a BRE metachar git can enter, so this case runs where the path is usable
# (the ubuntu CI job) and says so where it is not.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/repo/v[1].x"
mkdir -p "$VAULT/wiki" "$VAULT/graphify-out"
git init -q "$BOX/repo" >/dev/null 2>&1
if git -C "$VAULT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf '{"nodes":[]}\n' >"$VAULT/graphify-out/graph.json"
  git_init_commit "$BOX/repo" "nested vault + graph"
  add_notes "$VAULT" before 4
  save_commit "$VAULT" s1
  add_notes "$VAULT" after 2
  run_guard "$GUARD" CONCEPT_GRAPH_THRESHOLD=3
  assert_contains "last-save-nested-regex-path/was-4" "was 4 at last save" \
    "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"
else
  echo "SKIP last-save-nested-regex-path: git cannot enter '$VAULT' on this platform"
fi

# never saved => says so, never invents a number
new_vault
add_notes "$VAULT" prior 30
git_commit_all "$VAULT" "30 notes"
run_guard "$GUARD"
assert_contains "no-save/says-so" "no prior save" "$(first_line "$BOX/err.txt")" \
  "$(evidence "$BOX")"

# NEGATIVE CONTROL: measuring M up to HEAD instead of the save commit reports
# today's number twice — the compounding disappears.
MMUT="$TMPROOT/m-mutant-bin"
mkdir -p "$MMUT"
cp "$CWN" "$MMUT/changed-wiki-notes.sh"
sed 's/^SAVE=.*/SAVE="$(git -C "$VAULT" rev-parse HEAD)"/' "$GUARD" >"$MMUT/check-concept-graph.sh"
if cmp -s "$GUARD" "$MMUT/check-concept-graph.sh"; then
  fail "m-negative-control/mutation-applied" "sed did not change the guard"
else
  pass "m-negative-control/mutation-applied"
fi
new_vault
add_notes "$VAULT" before 5
save_commit "$VAULT" s1
add_notes "$VAULT" after 3
git_commit_all "$VAULT" "3 more notes"
run_guard "$MMUT/check-concept-graph.sh" CONCEPT_GRAPH_THRESHOLD=5
assert_contains "m-negative-control/mutant-reports-8" "was 8 at last save" \
  "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"

# --- 13. STALE remedy text no longer says skipping is fine (INNOV-300) -------
echo "--- 13. STALE remedy wording ---"
new_vault
add_notes "$VAULT" prior 30
run_guard "$GUARD"
if grep -q 'still allowed' "$BOX/err.txt"; then
  fail "remedy/no-skip-is-fine" "STALE must not tell the saver skipping is fine" \
    "$(evidence "$BOX")"
else
  pass "remedy/no-skip-is-fine"
fi
assert_contains "remedy/decline-needs-reason" "reason" "$(tr '\n' ' ' <"$BOX/err.txt")" \
  "$(evidence "$BOX")"

# --- 13b. meta notes are never staleness (INNOV-408) -------------------------
# 5c never extracts wiki/log.md, hot.md or index.md, so editing them every save
# must not read as the graph falling behind. One real note is the control.
echo "--- 13b. meta notes ---"
new_vault
printf '# log\r\n' >"$VAULT/wiki/log.md"
printf '# hot\r\n' >"$VAULT/wiki/hot.md"
printf '# index\r\n' >"$VAULT/wiki/index.md"
git_commit_all "$VAULT" "meta notes"
printf '{"nodes":[1]}\n' >"$VAULT/graphify-out/graph.json"
git_commit_all "$VAULT" "graph built"
printf 'appended\r\n' | tee -a "$VAULT/wiki/log.md" "$VAULT/wiki/hot.md" >>"$VAULT/wiki/index.md"
printf 'edited\n' >>"$VAULT/wiki/one.md"
run_guard "$GUARD"
assert_contains "meta/not-staleness" "OK - 1 document(s) behind" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
rm -f "$VAULT/wiki/log.md" "$VAULT/wiki/hot.md"
run_guard "$GUARD"
assert_contains "meta/deleted-not-staleness" "OK - 1 document(s) behind" "$(first_line "$BOX/out.txt")" \
  "$(evidence "$BOX")"
# M (the count at the last save) excludes them too: 2 real notes + 3 meta notes
# before the save must read "was 2", not "was 5".
new_vault
printf '# log\n' >"$VAULT/wiki/log.md"
printf '# hot\n' >"$VAULT/wiki/hot.md"
printf '# index\n' >"$VAULT/wiki/index.md"
git_commit_all "$VAULT" "meta notes"
printf '{"nodes":[1]}\n' >"$VAULT/graphify-out/graph.json"
git_commit_all "$VAULT" "graph built"
printf 'appended\n' | tee -a "$VAULT/wiki/log.md" "$VAULT/wiki/hot.md" >>"$VAULT/wiki/index.md"
add_notes "$VAULT" before 2
save_commit "$VAULT" s1
add_notes "$VAULT" after 3
run_guard "$GUARD" CONCEPT_GRAPH_THRESHOLD=3
assert_contains "meta/not-in-last-save-count" "5 document(s) behind, was 2 at last save" \
  "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"
# Only meta notes before the save: the filter matches nothing and still reads 0.
new_vault
printf '# log\n' >"$VAULT/wiki/log.md"
git_commit_all "$VAULT" "meta note"
printf '{"nodes":[1]}\n' >"$VAULT/graphify-out/graph.json"
git_commit_all "$VAULT" "graph built"
printf 'appended\n' >>"$VAULT/wiki/log.md"
save_commit "$VAULT" s1
add_notes "$VAULT" after 4
run_guard "$GUARD" CONCEPT_GRAPH_THRESHOLD=3
assert_contains "meta/only-meta-before-save-reads-0" "4 document(s) behind, was 0 at last save" \
  "$(first_line "$BOX/err.txt")" "$(evidence "$BOX")"

# --- 14. save step 5c contract (INNOV-300) ------------------------------------
# The fixture for the 2026-09-14 incident: a PM's refresh hit graphify's shrink
# guard, the skill said nothing, her agent proposed an already-ruled-out
# workaround, and "skip 5c" became team policy. These are the sentences that
# prevent each link of that chain; each fails against the pre-INNOV-300 text.
echo "--- 14. save step 5c text ---"
STEP5C="$(awk '/^5c\. /{on=1} /^6\. /{on=0} on' "$REPO_ROOT/brain/skills/save/SKILL.md" | tr -d '\r')"
for want in \
  'runs the refresh without asking' \
  '5c SKIPPED (<reason>) — CONCEPT-GRAPH: STALE - N document(s) behind, was M at last save' \
  'CONCEPT-GRAPH: BLOCKED - graphify not installed, run /brain:init' \
  'refused to shrink' \
  '5c never extracts those three meta notes' \
  'narrow-detect.mjs" --full' \
  'INNOV-408 migration, --force' \
  'never `--update --force`' \
  'Never `--force`' \
  'Do not propose any other workaround' \
  'changed-wiki-notes.sh" --deleted --since' \
  'the only other case where `--force` is right' \
  'build_merge' \
  'DETECT-NARROW:' \
  'never `--update` when a note was deleted'; do
  assert_contains "save-5c/has:$want" "$want" "$STEP5C" \
    "brain/skills/save/SKILL.md step 5c must carry this sentence"
done
for gone in \
  'Deliberately skipping the refresh stays allowed' \
  'WARN only — it blocks nothing' \
  'each in its own chunk'; do
  if [[ "$STEP5C" == *"$gone"* ]]; then
    fail "save-5c/lacks:$gone" "step 5c still presents the refresh as optional"
  else
    pass "save-5c/lacks:$gone"
  fi
done
OUTFMT="$(awk '/^## Output format/{on=1} /^## Notes/{on=0} on' "$REPO_ROOT/brain/skills/save/SKILL.md" | tr -d '\r')"
assert_contains "save-output/BLOCKED-shape" "CONCEPT-GRAPH: BLOCKED" "$OUTFMT"
assert_contains "save-output/SKIPPED-shape" "5c SKIPPED (" "$OUTFMT"
assert_contains "readme/scenario-E-names-5c" "includes the wiki graph refresh" \
  "$(grep '^| \*\*E ' "$REPO_ROOT/brain/README.md")"

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
