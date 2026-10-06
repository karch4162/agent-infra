#!/usr/bin/env bash
# check-version-bump.sh — fail if a plugin dir (brain/, wave/, ...) changed but its version did not.
#
# A feature branch satisfies the gate by ADDING a bump fragment,
# .bumps/<dir>/<name> (content patch|minor|major, empty = patch);
# tools/bump-version.mjs turns fragments into one version at release time.
# Editing the version literal on every branch made each pair of parallel PRs
# conflict (INNOV-311), so a direct bump is now only the release PR's job.
#
# Usage: check-version-bump.sh [base-ref]   (default: origin/main)
#
# Compares HEAD against the merge-base with <base-ref>, mirroring what
# `git diff base...HEAD` shows on a PR. Must run on bash 3.2 (macOS) —
# no bash-4 builtins, no associative arrays (INNOV-284).
set -uo pipefail

BASE="${1:-origin/main}"

MB="$(git merge-base "$BASE" HEAD)" || {
  echo "check-version-bump: cannot find merge-base of '$BASE' and HEAD" >&2
  exit 1
}

CHANGED="$(git diff --name-only "$MB" HEAD)"
ADDED="$(git diff --name-only --diff-filter=A "$MB" HEAD)"

extract_version() { # ref path
  git show "$1:$2" 2>/dev/null     | node -e 'const s=require("fs").readFileSync(0,"utf8");process.stdout.write(String(JSON.parse(s).version))' 2>/dev/null
}

# Every top-level plugin dir (<dir>/.claude-plugin/plugin.json) is gated on its own.
status=0
checked=0
for PLUGIN_JSON in */.claude-plugin/plugin.json; do
  [ -f "$PLUGIN_JSON" ] || continue
  DIR="${PLUGIN_JSON%%/*}"
  # Pending fragments count as plugin state: dropping one un-owes a bump.
  printf '%s\n' "$CHANGED" | grep -q -e "^$DIR/" -e "^\.bumps/$DIR/" || continue
  checked=$((checked + 1))

  BASE_VERSION="$(extract_version "$MB" "$PLUGIN_JSON")"
  HEAD_VERSION="$(extract_version HEAD "$PLUGIN_JSON")"

  # File absent at base (new plugin) — nothing to compare against.
  if [ -z "$BASE_VERSION" ]; then
    echo "check-version-bump: $PLUGIN_JSON absent or unreadable at base — skipping."
  elif [ "$BASE_VERSION" != "$HEAD_VERSION" ]; then
    echo "check-version-bump: OK — $DIR version bumped $BASE_VERSION -> $HEAD_VERSION."
  elif printf '%s\n' "$ADDED" | grep -q "^\.bumps/$DIR/[^/][^/]*$"; then
    echo "check-version-bump: OK — $DIR bump declared in .bumps/$DIR/ (applied at release)."
  else
    echo "check-version-bump: FAIL — files under $DIR/ changed but no bump was declared." >&2
    echo "  Add a fragment: printf 'patch\\n' > .bumps/$DIR/<ticket>   (patch|minor|major)" >&2
    echo "  Do not edit the version in $PLUGIN_JSON on a feature branch — parallel" >&2
    echo "  branches collide on it. Releases run: node tools/bump-version.mjs $DIR" >&2
    status=1
  fi
done

[ "$checked" -gt 0 ] || echo "check-version-bump: no plugin dir changed — no bump required."
exit $status
