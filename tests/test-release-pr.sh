#!/usr/bin/env bash
# test-release-pr.sh — tools/release-pr.sh turns pending .bumps/ fragments into
# one release PR per plugin (INNOV-330).
#
# Each case runs in a scratch repo with a bare `origin` and a stub `gh` on PATH
# that logs its arguments; `gh pr list` answers with $GH_OPEN_PR. Pins: no
# fragments -> no push and no gh call (the guard that skips the release PR's
# own merge); a fragment -> release/<plugin> = main + one bump commit and a PR;
# a rerun with the PR open -> branch rebuilt, PR edited, never a second PR.
#
# Run:  bash tests/test-release-pr.sh   (from anywhere)
# No network. Requires a real `node` on PATH (bump-version.mjs is node).
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

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
assert_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]" "actual:   [$3]"; fi
}
assert_contains() { # name haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to contain: [$3]" "actual: [$2]"; fi
}

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: no node on PATH — bump-version.mjs is node." >&2
  exit 0
fi

# Stub gh: log every call, answer `pr list` with $GH_OPEN_PR (empty = no PR).
STUB="$TMPROOT/bin"
mkdir -p "$STUB"
cat >"$STUB/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "pr list") printf '%s\n' "${GH_OPEN_PR:-}" ;;
esac
exit 0
EOF
chmod +x "$STUB/gh"

# A scratch repo on main with brain 0.3.8 and wave 0.1.1, pushed to a bare origin.
new_sandbox() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  ORIGIN="$BOX.git"
  git init -q --bare "$ORIGIN"
  git -C "$BOX" init -q -b main
  git -C "$BOX" config user.email t@t.t
  git -C "$BOX" config user.name t
  git -C "$BOX" config core.autocrlf false
  git -C "$BOX" remote add origin "$ORIGIN"
  mkdir -p "$BOX/tools" "$BOX/brain/.claude-plugin" "$BOX/wave/.claude-plugin"
  cp "$REPO_ROOT/tools/release-pr.sh" "$REPO_ROOT/tools/bump-version.mjs" \
     "$REPO_ROOT/tools/generate-host-manifests.mjs" "$BOX/tools/"
  printf '{"name":"brain","version":"0.3.8","author":{"name":"t"}}\n' >"$BOX/brain/.claude-plugin/plugin.json"
  printf '{"name":"wave","version":"0.1.1"}\n' >"$BOX/wave/.claude-plugin/plugin.json"
  (cd "$BOX" && node tools/generate-host-manifests.mjs) >/dev/null
  git -C "$BOX" add -A
  git -C "$BOX" commit -q -m "initial"
  GH_LOG="$BOX.ghlog"
  : >"$GH_LOG"
}
add_fragment() { # plugin name content — lands on main, as a merged PR would
  git -C "$BOX" checkout -q main
  mkdir -p "$BOX/.bumps/$1"
  printf "$3" >"$BOX/.bumps/$1/$2"
  git -C "$BOX" add -A
  git -C "$BOX" commit -q -m "fragment $1/$2"
}
run_release() { # -> sets OUT, ST
  git -C "$BOX" push -q -f origin main
  OUT="$(cd "$BOX" && PATH="$STUB:$PATH" GH_LOG="$GH_LOG" GH_OPEN_PR="${GH_OPEN_PR:-}" \
    bash tools/release-pr.sh 2>&1)"
  ST=$?
}
remote_version() { # branch plugin [manifest-dir]
  git -C "$ORIGIN" show "$1:$2/${3:-.claude-plugin}/plugin.json" 2>/dev/null \
    | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).version)'
}
has_branch() { git -C "$ORIGIN" rev-parse -q --verify "refs/heads/$1" >/dev/null && echo yes || echo no; }

echo "--- 1. no fragments: nothing pushed, gh never called ---"
new_sandbox
GH_OPEN_PR=""
run_release
assert_eq "none/exit-0" "0" "$ST"
assert_contains "none/says-so" "$OUT" "no pending fragments"
assert_eq "none/no-brain-branch" "no" "$(has_branch release/brain)"
assert_eq "none/no-wave-branch" "no" "$(has_branch release/wave)"
assert_eq "none/no-gh-calls" "" "$(cat "$GH_LOG")"

echo "--- 2. a brain fragment: release/brain = main + one bump commit, one PR ---"
new_sandbox
add_fragment brain INNOV-1 'patch\n'
GH_OPEN_PR=""
run_release
assert_eq "brain/exit-0" "0" "$ST"
assert_eq "brain/branch-pushed" "yes" "$(has_branch release/brain)"
assert_eq "brain/version-bumped" "0.3.9" "$(remote_version release/brain brain)"
assert_eq "brain/codex-manifest-follows" "0.3.9" "$(remote_version release/brain brain .codex-plugin)"
assert_eq "brain/parent-is-main" "$(git -C "$BOX" rev-parse main)" "$(git -C "$ORIGIN" rev-parse release/brain^)"
assert_eq "brain/fragment-consumed" "" "$(git -C "$ORIGIN" ls-tree --name-only release/brain .bumps/brain/)"
assert_eq "brain/main-untouched" "0.3.8" "$(remote_version main brain)"
assert_eq "brain/no-wave-branch" "no" "$(has_branch release/wave)"
log="$(cat "$GH_LOG")"
assert_contains "brain/pr-created" "$log" "pr create"
assert_contains "brain/pr-title-has-version" "$log" "0.3.9"
assert_contains "brain/pr-body-names-fragment" "$log" "INNOV-1"
assert_eq "brain/one-create" "1" "$(grep -c '^pr create' "$GH_LOG")"
assert_contains "brain/pr-body-links-ci-runs" "$log" "actions/workflows/ci.yml?query=branch%3Arelease%2Fbrain"
# INNOV-385: GitHub does create the pull_request run; it waits in action_required.
assert_contains "brain/pr-body-names-pending-run" "$log" "action_required"
assert_eq "brain/pr-body-no-false-claim" "0" "$(grep -c 'starts no' "$GH_LOG")"
# A fork PR whose head is also named release/brain must never be adopted.
assert_contains "brain/pr-lookup-skips-forks" "$log" "select(.isCrossRepository | not)"
assert_contains "brain/pr-body-names-release-sha" "$log" "$(git -C "$ORIGIN" rev-parse release/brain)"
assert_eq "brain/ci-dispatched" "1" "$(grep -c '^workflow run ci.yml --ref release/brain' "$GH_LOG")"

echo "--- 3. rerun with the PR open: branch rebuilt on new main, PR edited, no second PR ---"
add_fragment brain INNOV-2 'minor\n'
: >"$GH_LOG"
GH_OPEN_PR="7"
run_release
assert_eq "rerun/exit-0" "0" "$ST"
assert_eq "rerun/version-reflects-new-fragment" "0.4.0" "$(remote_version release/brain brain)"
assert_eq "rerun/parent-is-new-main" "$(git -C "$BOX" rev-parse main)" "$(git -C "$ORIGIN" rev-parse release/brain^)"
assert_eq "rerun/no-create" "0" "$(grep -c '^pr create' "$GH_LOG")"
assert_contains "rerun/pr-edited" "$(cat "$GH_LOG")" "pr edit 7"
assert_contains "rerun/edit-title-has-version" "$(cat "$GH_LOG")" "0.4.0"
assert_eq "rerun/ci-dispatched" "1" "$(grep -c '^workflow run ci.yml --ref release/brain' "$GH_LOG")"

echo "--- 4. only a wave fragment: only release/wave is pushed ---"
new_sandbox
add_fragment wave INNOV-3 'patch\n'
GH_OPEN_PR=""
run_release
assert_eq "wave/exit-0" "0" "$ST"
assert_eq "wave/branch-pushed" "yes" "$(has_branch release/wave)"
assert_eq "wave/version-bumped" "0.1.2" "$(remote_version release/wave wave)"
assert_eq "wave/no-brain-branch" "no" "$(has_branch release/brain)"
assert_eq "wave/brain-untouched-on-release-branch" "0.3.8" "$(remote_version release/wave brain)"

echo "--- 5. both plugins: one branch each, neither carries the other's bump ---"
new_sandbox
add_fragment brain INNOV-4 'patch\n'
add_fragment wave INNOV-5 'patch\n'
GH_OPEN_PR=""
run_release
assert_eq "both/exit-0" "0" "$ST"
assert_eq "both/brain-bumped" "0.3.9" "$(remote_version release/brain brain)"
assert_eq "both/brain-branch-keeps-wave" "0.1.1" "$(remote_version release/brain wave)"
assert_eq "both/brain-branch-keeps-wave-fragment" ".bumps/wave/INNOV-5" "$(git -C "$ORIGIN" ls-tree -r --name-only release/brain .bumps/)"
assert_eq "both/wave-bumped" "0.1.2" "$(remote_version release/wave wave)"
assert_eq "both/wave-branch-keeps-brain" "0.3.8" "$(remote_version release/wave brain)"
assert_eq "both/two-creates" "2" "$(grep -c '^pr create' "$GH_LOG")"
assert_eq "both/two-dispatches" "2" "$(grep -c '^workflow run ci.yml' "$GH_LOG")"

echo "--- 6. a CRLF fragment (autocrlf vault checkout) is read as its kind ---"
new_sandbox
add_fragment brain INNOV-6 'minor\r\n'
GH_OPEN_PR=""
run_release
assert_eq "crlf/exit-0" "0" "$ST"
assert_eq "crlf/minor" "0.4.0" "$(remote_version release/brain brain)"

echo "--- 7. a failing bump fails the run and pushes nothing ---"
new_sandbox
add_fragment brain INNOV-7 'bogus\n'
GH_OPEN_PR=""
run_release
assert_eq "bad-fragment/exit-nonzero" "yes" "$([ "$ST" -ne 0 ] && echo yes || echo no)"
assert_eq "bad-fragment/no-branch" "no" "$(has_branch release/brain)"
assert_eq "bad-fragment/no-gh-calls" "" "$(cat "$GH_LOG")"

echo "--- 8. valid brain + invalid wave: nothing is pushed for either ---"
# All release commits are built before the first push; a late failure must not
# strand an already-published release/brain.
new_sandbox
add_fragment brain INNOV-8 'patch
'
add_fragment wave INNOV-9 'bogus
'
GH_OPEN_PR=""
run_release
assert_eq "partial/exit-nonzero" "yes" "$([ "$ST" -ne 0 ] && echo yes || echo no)"
assert_eq "partial/no-brain-branch" "no" "$(has_branch release/brain)"
assert_eq "partial/no-wave-branch" "no" "$(has_branch release/wave)"
assert_eq "partial/no-gh-calls" "" "$(cat "$GH_LOG")"

echo "--- 9. a fragment dir with no plugin (typo) fails loudly, not green ---"
new_sandbox
add_fragment brian INNOV-10 'patch
'
GH_OPEN_PR=""
run_release
assert_eq "orphan/exit-1" "1" "$ST"
assert_contains "orphan/names-dir" "$OUT" ".bumps/brian"
assert_eq "orphan/no-gh-calls" "" "$(cat "$GH_LOG")"

echo "--- 10. a bump that leaves the version unchanged fails before pushing ---"
# Duplicate key: JSON.parse reads the last, bump-version.mjs rewrites the first,
# so the fragments are consumed while the effective version stays put.
new_sandbox
printf '{"name":"brain","version":"0.3.8","author":{"name":"t"},"version":"0.3.8"}
' >"$BOX/brain/.claude-plugin/plugin.json"
add_fragment brain INNOV-11 'patch
'
GH_OPEN_PR=""
run_release
assert_eq "unmoved/exit-1" "1" "$ST"
assert_contains "unmoved/says-so" "$OUT" "did not change"
assert_eq "unmoved/no-branch" "no" "$(has_branch release/brain)"
assert_eq "unmoved/no-gh-calls" "" "$(cat "$GH_LOG")"

echo "--- 11. a run whose commit is no longer the tip of origin/main publishes nothing ---"
# A queued older run, or a re-run of an old job, must not rebuild release/<p>
# from a stale main (and so resurrect a fragment a later commit withdrew).
new_sandbox
add_fragment brain INNOV-12 'patch
'
git -C "$BOX" push -q -f origin main
stale="$(git -C "$BOX" rev-parse main)"
git -C "$BOX" rm -q ".bumps/brain/INNOV-12"
git -C "$BOX" commit -q -m "withdraw fragment"
git -C "$BOX" push -q origin main
git -C "$BOX" checkout -q --detach "$stale"
OUT="$(cd "$BOX" && PATH="$STUB:$PATH" GH_LOG="$GH_LOG" GH_OPEN_PR="" bash tools/release-pr.sh 2>&1)"
ST=$?
assert_eq "stale/exit-0" "0" "$ST"
assert_contains "stale/says-so" "$OUT" "no longer the tip of origin/main"
assert_eq "stale/no-branch" "no" "$(has_branch release/brain)"
assert_eq "stale/no-gh-calls" "" "$(cat "$GH_LOG")"

echo "--- 12. workflows: CI is dispatchable; every main push queues a release run ---"
CI="$REPO_ROOT/.github/workflows/ci.yml"
REL="$REPO_ROOT/.github/workflows/release-pr.yml"
assert_eq "ci/workflow-dispatch" "1" "$(grep -c '^  workflow_dispatch:' "$CI")"
# Case 11's guard defers to the run for the newer commit; a paths filter would
# mean that run never starts after a docs-only push.
assert_eq "release/no-paths-filter" "0" "$(grep -c '^ *paths' "$REL")"
# A manual dispatch from a feature branch must not publish that branch as a release.
assert_eq "release/main-only" "1" "$(grep -c "github.ref == 'refs/heads/main'" "$REL")"
# The vendsy/agent-infra mirror receives this file on every ff-push and has
# Actions on with PR creation allowed; it must never open a release there.
assert_eq "release/source-repo-only" "1" "$(grep -c "if: github.repository == 'karch4162/agent-infra' && github.ref" "$REL")"
assert_eq "release/runs-script" "1" "$(grep -c 'bash tools/release-pr.sh' "$REL")"

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
