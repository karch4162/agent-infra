#!/usr/bin/env bash
# test-release-publish.sh — tools/release-publish.sh tags every unpublished
# plugin version on its release commit, fast-forwards the mirror to the newest
# release commit, and creates the mirror's GitHub Releases (INNOV-387).
#
# Each case runs in a scratch repo with a bare `origin`, a bare mirror and a
# stub `gh` on PATH. The stub answers `gh api -i .../releases/tags/<tag>` with
# 200 when <tag> is listed in $GH_RELEASES, $GH_API_STATUS when set, else 404,
# and `gh release create` appends the tag to $GH_RELEASES (or fails for the
# tag named in $GH_CREATE_FAIL).
#
# Run:  bash tests/test-release-publish.sh   (from anywhere)
# No network. Requires a real `node` on PATH (versions are read with node).
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
assert_not_contains() { # name haystack needle
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "expected NOT to contain: [$3]" "actual: [$2]"; fi
}

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: no node on PATH — versions are read with node." >&2
  exit 0
fi

STUB="$TMPROOT/bin"
mkdir -p "$STUB"
cat >"$STUB/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
if [ "$1" = "api" ]; then
  tag="${!#}"; tag="${tag##*/releases/tags/}"
  if grep -qxF "$tag" "$GH_RELEASES" 2>/dev/null; then
    printf 'HTTP/2.0 200 OK\n\n{}\n'; exit 0
  fi
  if [ -n "${GH_API_STATUS:-}" ]; then
    printf 'HTTP/2.0 %s Server Error\n\n{}\n' "$GH_API_STATUS"; echo "gh: Server Error (HTTP $GH_API_STATUS)" >&2; exit 1
  fi
  printf 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}\n'; echo "gh: Not Found (HTTP 404)" >&2; exit 1
fi
if [ "$1 $2" = "release create" ]; then
  [ "${GH_CREATE_FAIL:-}" != "$3" ] || { echo "gh: create failed" >&2; exit 1; }
  printf '%s\n' "$3" >>"$GH_RELEASES"
fi
exit 0
EOF
chmod +x "$STUB/gh"

SENTINEL="tok-SENTINEL-387"

# A scratch repo on main with brain 0.3.8 and wave 0.1.1, both already tagged
# and released everywhere: origin, mirror and mirror Releases all in sync.
new_sandbox() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  ORIGIN="$BOX.git"
  MIRROR="$BOX.mirror.git"
  git init -q --bare "$ORIGIN"
  git init -q --bare "$MIRROR"
  git -C "$BOX" init -q -b main
  git -C "$BOX" config user.email t@t.t
  git -C "$BOX" config user.name t
  git -C "$BOX" config core.autocrlf false
  git -C "$BOX" remote add origin "$ORIGIN"
  mkdir -p "$BOX/tools" "$BOX/brain/.claude-plugin" "$BOX/wave/.claude-plugin"
  cp "$REPO_ROOT/tools/release-publish.sh" "$BOX/tools/"
  printf '{"name":"brain","version":"0.3.8"}\n' >"$BOX/brain/.claude-plugin/plugin.json"
  printf '{"name":"wave","version":"0.1.1"}\n' >"$BOX/wave/.claude-plugin/plugin.json"
  git -C "$BOX" add -A
  git -C "$BOX" commit -q -m "initial"
  git -C "$BOX" tag brain--v0.3.8
  git -C "$BOX" tag wave--v0.1.1
  git -C "$BOX" push -q origin main brain--v0.3.8 wave--v0.1.1
  git -C "$BOX" push -q "$MIRROR" main brain--v0.3.8 wave--v0.1.1
  GH_LOG="$BOX.ghlog"
  GH_RELEASES="$BOX.releases"
  : >"$GH_LOG"
  printf 'brain--v0.3.8\nwave--v0.1.1\n' >"$GH_RELEASES"
}
# Merge a release/<plugin> branch that sets <version>, as the release PR merge does.
release_merge() { # plugin version [eol]
  git -C "$BOX" checkout -q -b "release/$1" main
  printf '{"name":"%s","version":"%s"}%b' "$1" "$2" "${3:-\n}" >"$BOX/$1/.claude-plugin/plugin.json"
  git -C "$BOX" commit -q -am "release($1): -> $2"
  git -C "$BOX" checkout -q main
  git -C "$BOX" merge -q --no-ff -m "Merge release/$1 $2" "release/$1"
  git -C "$BOX" branch -q -D "release/$1"
}
feature_commit() { # message
  printf '%s\n' "$1" >>"$BOX/README"
  git -C "$BOX" add -A
  git -C "$BOX" commit -q -m "$1"
}
run_publish() { # -> sets OUT, ST
  git -C "$BOX" push -q origin main
  OUT="$(cd "$BOX" && PATH="$STUB:$PATH" GH_LOG="$GH_LOG" GH_RELEASES="$GH_RELEASES" \
    MIRROR_URL="$MIRROR" MIRROR_REPO="vendsy/agent-infra" MIRROR_TOKEN="${MIRROR_TOKEN-$SENTINEL}" \
    bash tools/release-publish.sh 2>&1)"
  ST=$?
}
tag_at() { git -C "$1" rev-parse -q --verify "refs/tags/$2^{commit}" 2>/dev/null || echo none; }
head_of() { git -C "$1" rev-parse -q --verify refs/heads/main 2>/dev/null || echo none; }
creates() { grep -c '^release create' "$GH_LOG"; }

echo "--- 1. a release merge: tag on the merge commit in both repos, mirror ff'd, one Release ---"
new_sandbox
release_merge brain 0.3.9
merge="$(git -C "$BOX" rev-parse main)"
branch_commit="$(git -C "$BOX" rev-parse main^2)"
run_publish
assert_eq "merge/exit-0" "0" "$ST"
assert_eq "merge/origin-tag-on-merge-commit" "$merge" "$(tag_at "$ORIGIN" brain--v0.3.9)"
assert_eq "merge/not-on-branch-commit" "yes" "$([ "$(tag_at "$ORIGIN" brain--v0.3.9)" != "$branch_commit" ] && echo yes || echo no)"
assert_eq "merge/mirror-tag-on-merge-commit" "$merge" "$(tag_at "$MIRROR" brain--v0.3.9)"
assert_eq "merge/mirror-main-is-merge" "$merge" "$(head_of "$MIRROR")"
assert_eq "merge/one-create" "1" "$(creates)"
assert_contains "merge/create-args" "$(cat "$GH_LOG")" "release create brain--v0.3.9 --repo vendsy/agent-infra --verify-tag --generate-notes"
assert_eq "merge/wave-untouched" "none" "$(tag_at "$ORIGIN" wave--v0.1.2)"
assert_not_contains "merge/token-never-printed" "$OUT" "$SENTINEL"

echo "--- 2. rerun with nothing new: no push, no create, mirror not moved past the release ---"
feature_commit "docs only"
: >"$GH_LOG"
run_publish
assert_eq "noop/exit-0" "0" "$ST"
assert_eq "noop/mirror-stays-on-release" "$merge" "$(head_of "$MIRROR")"
assert_eq "noop/no-create" "0" "$(creates)"
assert_contains "noop/says-so" "$OUT" "nothing to publish"

echo "--- 3. a non-bump commit on top of an unpublished bump: mirror stops at the bump ---"
new_sandbox
release_merge wave 0.2.0
wmerge="$(git -C "$BOX" rev-parse main)"
feature_commit "landed 15s later"
run_publish
assert_eq "late/exit-0" "0" "$ST"
assert_eq "late/mirror-main-is-release" "$wmerge" "$(head_of "$MIRROR")"
assert_eq "late/tag-on-release" "$wmerge" "$(tag_at "$ORIGIN" wave--v0.2.0)"

echo "--- 4. brain then wave merged back to back: one run publishes both ---"
new_sandbox
release_merge brain 0.4.0
bmerge="$(git -C "$BOX" rev-parse main)"
release_merge wave 0.2.0
wmerge="$(git -C "$BOX" rev-parse main)"
run_publish
assert_eq "both/exit-0" "0" "$ST"
assert_eq "both/brain-tag" "$bmerge" "$(tag_at "$ORIGIN" brain--v0.4.0)"
assert_eq "both/wave-tag" "$wmerge" "$(tag_at "$ORIGIN" wave--v0.2.0)"
assert_eq "both/mirror-brain-tag" "$bmerge" "$(tag_at "$MIRROR" brain--v0.4.0)"
assert_eq "both/mirror-main-newest" "$wmerge" "$(head_of "$MIRROR")"
assert_eq "both/two-creates" "2" "$(creates)"
: >"$GH_LOG"
run_publish
assert_eq "both/second-run-noop" "0" "$(creates)"
assert_eq "both/second-run-exit-0" "0" "$ST"

echo "--- 5. wave then brain (other order) ---"
new_sandbox
release_merge wave 0.2.0
wmerge="$(git -C "$BOX" rev-parse main)"
release_merge brain 0.4.0
bmerge="$(git -C "$BOX" rev-parse main)"
run_publish
assert_eq "order/exit-0" "0" "$ST"
assert_eq "order/brain-tag" "$bmerge" "$(tag_at "$MIRROR" brain--v0.4.0)"
assert_eq "order/wave-tag" "$wmerge" "$(tag_at "$MIRROR" wave--v0.2.0)"
assert_eq "order/mirror-main-newest" "$bmerge" "$(head_of "$MIRROR")"

echo "--- 6. one plugin bumped twice before a green run: both versions published ---"
new_sandbox
release_merge brain 0.3.9
first="$(git -C "$BOX" rev-parse main)"
feature_commit "between releases"
release_merge brain 0.4.0
second="$(git -C "$BOX" rev-parse main)"
run_publish
assert_eq "twice/exit-0" "0" "$ST"
assert_eq "twice/older-tagged" "$first" "$(tag_at "$ORIGIN" brain--v0.3.9)"
assert_eq "twice/newer-tagged" "$second" "$(tag_at "$ORIGIN" brain--v0.4.0)"
assert_eq "twice/older-on-mirror" "$first" "$(tag_at "$MIRROR" brain--v0.3.9)"
assert_eq "twice/two-creates" "2" "$(creates)"
assert_eq "twice/older-released-first" "release create brain--v0.3.9" "$(grep '^release create' "$GH_LOG" | head -n 1 | cut -d' ' -f1-3)"

echo "--- 7. a tag already on another sha: red, nothing pushed anywhere ---"
new_sandbox
release_merge brain 0.3.9
git -C "$BOX" push -q origin "main^1:refs/tags/brain--v0.3.9"
mirror_before="$(head_of "$MIRROR")"
run_publish
assert_eq "clash/exit-1" "1" "$ST"
assert_contains "clash/names-tag" "$OUT" "brain--v0.3.9"
assert_eq "clash/mirror-unmoved" "$mirror_before" "$(head_of "$MIRROR")"
assert_eq "clash/no-mirror-tag" "none" "$(tag_at "$MIRROR" brain--v0.3.9)"
assert_eq "clash/no-create" "0" "$(creates)"

echo "--- 8. a tag already on the release commit (origin, by hand): no-op there, mirror finished ---"
new_sandbox
release_merge brain 0.3.9
merge="$(git -C "$BOX" rev-parse main)"
git -C "$BOX" push -q origin main "$merge:refs/tags/brain--v0.3.9"
run_publish
assert_eq "partial-origin/exit-0" "0" "$ST"
assert_eq "partial-origin/tag-kept" "$merge" "$(tag_at "$ORIGIN" brain--v0.3.9)"
assert_eq "partial-origin/mirror-tag" "$merge" "$(tag_at "$MIRROR" brain--v0.3.9)"
assert_eq "partial-origin/mirror-main" "$merge" "$(head_of "$MIRROR")"

echo "--- 9. mirror diverged: red, never forced, origin untouched ---"
new_sandbox
git -C "$BOX" checkout -q -b stray main
feature_commit "pushed straight to the mirror"
git -C "$BOX" push -q "$MIRROR" stray:main
stray="$(git -C "$BOX" rev-parse stray)"
git -C "$BOX" checkout -q main
release_merge brain 0.3.9
run_publish
assert_eq "diverged/exit-1" "1" "$ST"
assert_contains "diverged/says-so" "$OUT" "not an ancestor"
assert_eq "diverged/mirror-unmoved" "$stray" "$(head_of "$MIRROR")"
assert_eq "diverged/no-origin-tag" "none" "$(tag_at "$ORIGIN" brain--v0.3.9)"
assert_eq "diverged/no-create" "0" "$(creates)"

echo "--- 10. MIRROR_TOKEN unset: red naming the secret, nothing pushed ---"
new_sandbox
release_merge brain 0.3.9
MIRROR_TOKEN="" run_publish
assert_eq "notoken/exit-1" "1" "$ST"
assert_contains "notoken/names-secret" "$OUT" "MIRROR_TOKEN"
assert_eq "notoken/no-origin-tag" "none" "$(tag_at "$ORIGIN" brain--v0.3.9)"
assert_eq "notoken/no-gh-calls" "" "$(cat "$GH_LOG")"

echo "--- 11. release lookup fails with a non-404: red before any push ---"
new_sandbox
release_merge brain 0.3.9
mirror_before="$(head_of "$MIRROR")"
GH_API_STATUS=500 run_publish
assert_eq "api500/exit-1" "1" "$ST"
assert_contains "api500/names-status" "$OUT" "500"
assert_eq "api500/no-origin-tag" "none" "$(tag_at "$ORIGIN" brain--v0.3.9)"
assert_eq "api500/mirror-unmoved" "$mirror_before" "$(head_of "$MIRROR")"
assert_eq "api500/no-create" "0" "$(creates)"

echo "--- 12. Release create fails after the push: red; the rerun creates only the Release ---"
new_sandbox
release_merge brain 0.3.9
GH_CREATE_FAIL=brain--v0.3.9 run_publish
assert_eq "createfail/exit-1" "1" "$ST"
assert_eq "createfail/mirror-tag-pushed" "$(git -C "$BOX" rev-parse main)" "$(tag_at "$MIRROR" brain--v0.3.9)"
: >"$GH_LOG"
run_publish
assert_eq "createfail/rerun-exit-0" "0" "$ST"
assert_eq "createfail/rerun-creates-once" "1" "$(creates)"

echo "--- 12b. two versions of one plugin, the older Release create fails: the rerun creates both ---"
# Tags for the newer version must wait until the older one is fully
# published; otherwise the rerun stops at the fully tagged newer version and
# never sees the older one's missing Release.
new_sandbox
release_merge brain 0.3.9
first="$(git -C "$BOX" rev-parse main)"
release_merge brain 0.4.0
second="$(git -C "$BOX" rev-parse main)"
GH_CREATE_FAIL=brain--v0.3.9 run_publish
assert_eq "batchfail/exit-1" "1" "$ST"
assert_eq "batchfail/older-tagged" "$first" "$(tag_at "$MIRROR" brain--v0.3.9)"
assert_eq "batchfail/newer-held-back-origin" "none" "$(tag_at "$ORIGIN" brain--v0.4.0)"
assert_eq "batchfail/newer-held-back-mirror" "none" "$(tag_at "$MIRROR" brain--v0.4.0)"
assert_eq "batchfail/mirror-main-at-older" "$first" "$(head_of "$MIRROR")"
: >"$GH_LOG"
run_publish
assert_eq "batchfail/rerun-exit-0" "0" "$ST"
assert_eq "batchfail/rerun-creates-both" "2" "$(creates)"
assert_eq "batchfail/older-released" "1" "$(grep -cx 'brain--v0.3.9' "$GH_RELEASES")"
assert_eq "batchfail/newer-tagged" "$second" "$(tag_at "$MIRROR" brain--v0.4.0)"
assert_eq "batchfail/mirror-main-newest" "$second" "$(head_of "$MIRROR")"

echo "--- 13. a later plugin.json edit that keeps the version: tag stays on the bump commit ---"
new_sandbox
release_merge brain 0.3.9
merge="$(git -C "$BOX" rev-parse main)"
printf '{"name":"brain","description":"x","version":"0.3.9"}\n' >"$BOX/brain/.claude-plugin/plugin.json"
git -C "$BOX" commit -q -am "describe brain"
run_publish
assert_eq "edit/exit-0" "0" "$ST"
assert_eq "edit/tag-on-bump" "$merge" "$(tag_at "$ORIGIN" brain--v0.3.9)"
assert_eq "edit/mirror-main-on-bump" "$merge" "$(head_of "$MIRROR")"

echo "--- 14. a CRLF plugin.json (autocrlf checkout) reads the same version ---"
new_sandbox
release_merge brain 0.3.9 '\r\n'
run_publish
assert_eq "crlf/exit-0" "0" "$ST"
assert_eq "crlf/tagged" "$(git -C "$BOX" rev-parse main)" "$(tag_at "$ORIGIN" brain--v0.3.9)"

echo "--- 15. auth helper: one header for the token, inherited ones reset, token not in argv ---"
# The workflow checks out with persist-credentials: false; the helper still
# resets http.<github>.extraheader (git: an empty value clears the list) so a
# second Authorization header can never ride along to the mirror.
new_sandbox
vals="$(cd "$BOX" && source tools/release-publish.sh && remote_git "$SENTINEL" config --get-all http.https://github.com/.extraheader)"
first="$(printf '%s\n' "$vals" | head -n 1)"
last="$(printf '%s\n' "$vals" | tail -n 1)"
assert_eq "auth/reset-first" "" "$first"
assert_eq "auth/two-entries" "2" "$(printf '%s\n' "$vals" | wc -l | tr -d ' ')"
decoded="$(printf '%s' "${last#AUTHORIZATION: basic }" | base64 -d 2>/dev/null || printf '%s' "${last#AUTHORIZATION: basic }" | base64 -D)"
assert_eq "auth/header-decodes" "x-access-token:$SENTINEL" "$decoded"
assert_eq "auth/no-token-no-header" "" "$(cd "$BOX" && source tools/release-publish.sh && remote_git "" config --get-all http.https://github.com/.extraheader)"

echo "--- 16. workflow: push to main, source repo only, queued, no persisted credentials ---"
WF="$REPO_ROOT/.github/workflows/release-publish.yml"
assert_eq "wf/push-main" "1" "$(grep -c '^    branches: \[main\]' "$WF")"
assert_eq "wf/no-paths-filter" "0" "$(grep -c '^ *paths' "$WF")"
assert_eq "wf/guard" "1" "$(grep -c "if: github.repository == 'karch4162/agent-infra' && github.ref == 'refs/heads/main'" "$WF")"
assert_eq "wf/queued" "1" "$(grep -c 'cancel-in-progress: false' "$WF")"
assert_eq "wf/no-persisted-creds" "1" "$(grep -c 'persist-credentials: false' "$WF")"
assert_eq "wf/secret" "1" "$(grep -c 'MIRROR_TOKEN: \${{ secrets.MIRROR_TOKEN }}' "$WF")"
assert_eq "wf/runs-script" "1" "$(grep -c 'bash tools/release-publish.sh' "$WF")"

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
