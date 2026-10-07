#!/usr/bin/env bash
# release-pr.sh — open (or refresh) one release PR per plugin with pending bump
# fragments (INNOV-330). Run by .github/workflows/release-pr.yml on push to main.
#
# For each .bumps/<plugin>/ holding a fragment, rebuild release/<plugin> from
# the current HEAD plus one commit that runs tools/bump-version.mjs, force-push
# it, create the PR (or edit the open one), and dispatch ci.yml on the branch:
# a GITHUB_TOKEN push or PR starts no push/pull_request workflows, but a
# workflow_dispatch does, so the release SHA is tested before merge. A
# dispatched run does not show in the PR's checks, so the body links to it.
#
# The branch name carries no version: a later minor fragment changes the
# version, and a versioned name would open a second PR. No fragments: exit 0
# untouched, which is also how the merge of a release PR (it deletes the
# fragments) skips itself. Every release commit is built before the first
# push, so one bad plugin never strands another's half-published release.
#
# Merging stays a human click. Tagging the merge commit, pushing the mirror and
# the GitHub Release follow from that push: release-publish.yml (INNOV-387).
# Needs: git with an `origin`, node, gh (GH_TOKEN). Bash 3.2 (INNOV-284).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
BASE="$(git rev-parse HEAD)"

plugins=""
for d in .bumps/*/; do
  [ -d "$d" ] || continue
  p="$(basename "$d")"
  # Direct-child files only, matching bump-version.mjs and check-version-bump.sh.
  [ -n "$(find "$d" -mindepth 1 -maxdepth 1 -type f | head -n 1)" ] || continue
  if [ ! -f "$p/.claude-plugin/plugin.json" ]; then
    echo "release-pr: .bumps/$p/ has fragments but $p/.claude-plugin/plugin.json does not exist." >&2
    exit 1
  fi
  plugins="$plugins $p"
done

if [ -z "$plugins" ]; then
  echo "release-pr: no pending fragments — nothing to release."
  exit 0
fi

version_of() { node -p 'require(process.argv[1]).version' "$PWD/$1/.claude-plugin/plugin.json"; }

# Phase 1: build every release commit locally. Any failure exits before a push.
for p in $plugins; do
  git checkout -q -B "release/$p" "$BASE"
  old="$(version_of "$p")"
  node tools/bump-version.mjs "$p"
  new="$(version_of "$p")"
  if [ "$new" = "$old" ]; then
    echo "release-pr: $p version did not change ($old) after bump-version.mjs — refusing to release." >&2
    exit 1
  fi
  git add -A
  git commit -q -m "release($p): $old -> $new"
done
git checkout -q --detach "$BASE"

# A queued older run, or a re-run of an old job, must not publish from a main
# that has moved on: it could resurrect a fragment a later commit withdrew.
git fetch -q origin main
if [ "$(git rev-parse FETCH_HEAD)" != "$BASE" ]; then
  echo "release-pr: $BASE is no longer the tip of origin/main — the run for the newer commit releases it."
  exit 0
fi

# Phase 2: publish.
for p in $plugins; do
  branch="release/$p"
  title="$(git log -1 --format=%s "$branch")"
  frags="$(git diff --name-only --diff-filter=D "$BASE" "$branch" -- ".bumps/$p/" | sed "s|^\.bumps/$p/||")"
  sha="$(git rev-parse "$branch")"
  git push -q --force origin "$branch:refs/heads/$branch"
  runs="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/workflows/ci.yml?query=branch%3Arelease%2F$p"

  body="$(cat <<EOF
Automated by \`.github/workflows/release-pr.yml\` (INNOV-330): \`node tools/bump-version.mjs $p\` applied these pending fragments:

$(printf '%s\n' "$frags" | sed 's/^/- /')

**Checks are not on this PR.** A \`GITHUB_TOKEN\` PR starts no \`pull_request\` run, so CI is dispatched on the branch instead, and a dispatched run does not attach to the PR. Merge once the \`tests\` run for release commit \`$sha\` is green on both runners: $runs. The branch is force-pushed on every rebuild, so a green run for an older commit does not count.

Merging is the last manual step: \`.github/workflows/release-publish.yml\` then tags the merge commit, fast-forwards the \`vendsy/agent-infra\` mirror and creates its GitHub Release. Check that run after merging.

This branch is rebuilt from \`main\` on every push there, so hand edits here are overwritten. To hold a release, leave this PR open. Closing it opens a fresh one on the next push to \`main\`.
EOF
)"
  # --head matches the branch name only; a fork can open a PR from its own
  # release/<plugin>, so take only a PR from this repo.
  open="$(gh pr list --head "$branch" --base main --state open --json number,isCrossRepository --jq '[.[] | select(.isCrossRepository | not)][0].number // empty')"
  if [ -n "$open" ]; then
    gh pr edit "$open" --title "$title" --body "$body"
    echo "release-pr: $title, updated PR #$open."
  else
    gh pr create --base main --head "$branch" --title "$title" --body "$body"
    echo "release-pr: $title, opened a PR."
  fi
  gh workflow run ci.yml --ref "$branch"
done
