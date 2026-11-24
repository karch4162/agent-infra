#!/usr/bin/env bash
# test-ci-built-mirrors.sh: /brain:save leaves code mirrors to CI when the vault builds
# them there (INNOV-468).
#
# A vault that commits .github/workflows/brain-mirrors.yml rebuilds its code mirrors on
# ubuntu every night. Community ids are stable per platform only, so a save that also
# rebuilds and publishes them on Windows re-clusters the mirror on every save/nightly
# pair. Pinned here:
#   - `sync-graph.sh --ci-check` prints the save's skip line when the workflow is
#     committed, with a changed covered repo present, and copies nothing;
#   - without the workflow it says local, so step 5 builds as before (negative control);
#   - a hand-run sync in a CI vault warns about the churn but still runs;
#   - an untracked workflow file is not the signal (it must be committed);
#   - BRAIN_MIRRORS_BUILDER=ci suppresses the warning (test-ci-mirrors.sh runs
#     ci-mirrors.mjs, which sets it, against a vault that commits the workflow).
#
# Run:  bash tests/test-ci-built-mirrors.sh   (from anywhere)
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR BRAIN_MIRRORS_BUILDER  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SYNC="$REPO_ROOT/brain/bin/sync-graph.sh"

PASSED=0
FAILED=0
TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected [$3] in [$2]"; fi; }
assert_not_contains() { if [[ "$2" == *"$3"* ]]; then fail "$1" "unexpected [$3] in [$2]"; else pass "$1"; fi; }

# A vault with one mirror whose covered repo was rebuilt this session (repo-side
# graph.json differs from the mirror). $1 = vault dir, $2 = 1 to commit the CI workflow.
make_vault() {
  local v="$1"
  mkdir -p "$v/graphify/demo" "$v/wiki" "$TMPROOT/repos/demo/graphify-out"
  printf '{"nodes":[],"links":[],"old":true}\n' > "$v/graphify/demo/graph.json"
  printf '{"nodes":[],"links":[],"new":true}\n' > "$TMPROOT/repos/demo/graphify-out/graph.json"
  printf '# Graph Report\n' > "$TMPROOT/repos/demo/graphify-out/GRAPH_REPORT.md"
  if [[ "$2" != 0 ]]; then
    mkdir -p "$v/.github/workflows"
    printf 'name: brain-mirrors\r\n' > "$v/.github/workflows/brain-mirrors.yml"
  fi
  git -C "$v" init -q
  git -C "$v" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  if [[ "$2" == 1 ]]; then
    git -C "$v" add .github
    git -C "$v" -c user.email=t@t -c user.name=t commit -q -m workflow
  fi
}

# $2: 1 = workflow committed, 0 = none, untracked = on disk but never committed.
CIV="$TMPROOT/ci-vault"; make_vault "$CIV" 1
LOCALV="$TMPROOT/local-vault"; make_vault "$LOCALV" 0
UNTRACKEDV="$TMPROOT/untracked-vault"; make_vault "$UNTRACKEDV" untracked

# --- the save step 5 probe ------------------------------------------------------
out=$(BRAIN_ROOT="$CIV" REPOS_DIR="$TMPROOT/repos" bash "$SYNC" --ci-check 2>&1); rc=$?
assert_contains "ci vault: --ci-check prints the skip line" "$out" \
  "Graph sync: skipped - mirrors built in CI (.github/workflows/brain-mirrors.yml)"
[[ $rc -eq 0 ]] && pass "ci vault: --ci-check exits 0" || fail "ci vault: --ci-check exits 0" "rc=$rc"
if grep -q '"old":true' "$CIV/graphify/demo/graph.json"; then
  pass "ci vault: --ci-check copies nothing (the changed repo's mirror is untouched)"
else
  fail "ci vault: --ci-check must not sync"
fi

out=$(BRAIN_ROOT="$LOCALV" REPOS_DIR="$TMPROOT/repos" bash "$SYNC" --ci-check 2>&1); rc=$?
assert_contains "local vault: --ci-check says build here" "$out" "Graph sync: local"
assert_not_contains "local vault: --ci-check never says skipped" "$out" "skipped"
[[ $rc -eq 0 ]] && pass "local vault: --ci-check exits 0" || fail "local vault: --ci-check exits 0" "rc=$rc"

out=$(BRAIN_ROOT="$UNTRACKEDV" REPOS_DIR="$TMPROOT/repos" bash "$SYNC" --ci-check 2>&1)
assert_contains "untracked workflow: not the signal, build here" "$out" "Graph sync: local"

# --- a hand-run sync warns in a CI vault, and still runs ---------------------------
WARN="MIRRORS: WARN"
out=$(BRAIN_ROOT="$CIV" REPOS_DIR="$TMPROOT/repos" bash "$SYNC" --no-commit 2>&1); rc=$?
assert_contains "ci vault: a local sync warns about cross-platform churn" "$out" "$WARN"
assert_contains "ci vault: the warning names the workflow to run instead" "$out" "--only demo"
[[ $rc -eq 0 ]] && pass "ci vault: the warned sync exits 0" || fail "ci vault: the warned sync exits 0" "rc=$rc"
if grep -q '"new":true' "$CIV/graphify/demo/graph.json"; then
  pass "ci vault: the warned sync still publishes the mirror (warn, not refuse)"
else
  fail "ci vault: the warned sync must still publish"
fi

out=$(BRAIN_ROOT="$LOCALV" REPOS_DIR="$TMPROOT/repos" bash "$SYNC" --no-commit 2>&1)
assert_not_contains "local vault: no churn warning" "$out" "$WARN"

make_vault "$TMPROOT/ci-vault-2" 1
out=$(BRAIN_ROOT="$TMPROOT/ci-vault-2" REPOS_DIR="$TMPROOT/repos" BRAIN_MIRRORS_BUILDER=ci bash "$SYNC" --no-commit 2>&1)
assert_not_contains "ci builder: the CI run itself is not warned" "$out" "$WARN"

echo
echo "ci-built-mirrors: $PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
