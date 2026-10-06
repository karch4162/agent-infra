#!/usr/bin/env bash
# release-publish.sh — publish every merged plugin release (INNOV-387). Run by
# .github/workflows/release-publish.yml on push to main, after release-pr.sh's
# release PR merges.
#
# A release is a first-parent commit on origin/main where
# <plugin>/.claude-plugin/plugin.json's version differs from its first parent:
# the release PR's merge commit. For each plugin, walk those newest first and
# stop at the first one already tagged on both origin and the mirror, so a run
# that went red is finished by the next one. Each unpublished release gets:
#   - tag <plugin>--v<version> on that commit, on origin and on the mirror;
#   - the mirror's main fast-forwarded to the NEWEST release commit, never to
#     the tip: commits merged after it wait for the next release;
#   - a GitHub Release on the mirror (`--generate-notes`).
# Every check runs before the first push. A tag on another commit, a mirror
# main that is not an ancestor, or a Release lookup that is neither 200 nor
# 404 fails the run. Nothing is ever forced.
#
# Env: MIRROR_URL, MIRROR_REPO (owner/name), MIRROR_TOKEN (required: the
# mirror is private), ORIGIN_TOKEN (optional; the workflow passes
# github.token). Tokens reach git only as an http.extraheader in the
# environment of one command: never in argv, a URL, or the output.
# Needs: git, node, gh. Bash 3.2 (INNOV-284).
set -euo pipefail

die() { echo "release-publish: $*" >&2; exit 1; }

basic_auth() { printf 'x-access-token:%s' "$1" | base64 | tr -d '\n'; }

# remote_git TOKEN git-args... — git with exactly one Authorization header for
# github.com. The empty values reset inherited headers (an empty extraheader
# clears the list), so a checkout's credential never rides along to the mirror.
remote_git() {
  local tok="$1"
  shift
  if [ -z "$tok" ]; then
    git "$@"
    return
  fi
  GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0= \
    GIT_CONFIG_KEY_1=http.https://github.com/.extraheader GIT_CONFIG_VALUE_1= \
    GIT_CONFIG_KEY_2=http.https://github.com/.extraheader \
    GIT_CONFIG_VALUE_2="AUTHORIZATION: basic $(basic_auth "$tok")" \
    git "$@"
}

version_at() { # rev plugin -> version, empty when the file is absent
  git show "$1:$2/.claude-plugin/plugin.json" 2>/dev/null \
    | node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(0,"utf8")).version||""))}catch(e){}' \
    || true
}

tag_sha() { # ls-remote-output tag -> commit sha (peeled), empty when absent
  local peeled plain
  peeled="$(printf '%s\n' "$1" | awk -v r="refs/tags/$2^{}" '$2 == r { print $1 }')"
  plain="$(printf '%s\n' "$1" | awk -v r="refs/tags/$2" '$2 == r { print $1 }')"
  printf '%s' "${peeled:-$plain}"
}

release_status() { # tag -> HTTP status of the mirror's Release lookup
  local out
  out="$(GH_TOKEN="$MIRROR_TOKEN" gh api -i "repos/$MIRROR_REPO/releases/tags/$1" 2>/dev/null || true)"
  printf '%s\n' "$out" | head -n 1 | awk '{ print $2 }'
}

main() {
  [ -n "${MIRROR_TOKEN:-}" ] || die "MIRROR_TOKEN is empty. Set the MIRROR_TOKEN Actions secret (a fine-grained PAT for the mirror, Contents: read and write)."
  [ -n "${MIRROR_URL:-}" ] || die "MIRROR_URL is not set."
  [ -n "${MIRROR_REPO:-}" ] || die "MIRROR_REPO is not set."
  local origin_tok="${ORIGIN_TOKEN:-}"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::add-mask::$(basic_auth "$MIRROR_TOKEN")"
    [ -z "$origin_tok" ] || echo "::add-mask::$(basic_auth "$origin_tok")"
  fi

  cd "$(git rev-parse --show-toplevel)"

  # Read phase: nothing below pushes until every check has passed.
  remote_git "$origin_tok" fetch -q origin main
  local tip origin_refs mirror_refs mirror_main
  tip="$(git rev-parse FETCH_HEAD)"
  origin_refs="$(remote_git "$origin_tok" ls-remote origin 'refs/tags/*')"
  mirror_refs="$(remote_git "$MIRROR_TOKEN" ls-remote "$MIRROR_URL" refs/heads/main 'refs/tags/*')"
  mirror_main="$(printf '%s\n' "$mirror_refs" | awk '$2 == "refs/heads/main" { print $1 }')"
  [ -n "$mirror_main" ] || die "the mirror has no main branch."

  local origin_push="" mirror_tags="" creates="" target="" published=""
  local d p c v t o m st
  for d in $(git ls-tree -d --name-only "$tip"); do
    p="$d"
    git cat-file -e "$tip:$p/.claude-plugin/plugin.json" 2>/dev/null || continue
    for c in $(git rev-list --first-parent "$tip" -- "$p/.claude-plugin/plugin.json"); do
      v="$(version_at "$c" "$p")"
      [ -n "$v" ] || continue
      [ "$v" != "$(version_at "$c^1" "$p")" ] || continue
      t="$p--v$v"
      o="$(tag_sha "$origin_refs" "$t")"
      m="$(tag_sha "$mirror_refs" "$t")"
      [ -z "$o" ] || [ "$o" = "$c" ] || die "tag $t on origin points at $o, not at its release commit $c. Fix the tag by hand; this never moves a tag."
      [ -z "$m" ] || [ "$m" = "$c" ] || die "tag $t on the mirror points at $m, not at its release commit $c. Fix the tag by hand; this never moves a tag."
      st="$(release_status "$t")"
      case "$st" in
        200) ;;
        404) creates="$t $creates" ;; # oldest first
        *) die "looking up the mirror's GitHub Release $t returned HTTP ${st:-no response}, not 200 or 404." ;;
      esac
      # The newest release of each plugin is a candidate for the mirror's main.
      if [ -z "$target" ] || git merge-base --is-ancestor "$target" "$c"; then
        target="$c"
      fi
      [ -n "$o" ] || origin_push="$c:refs/tags/$t $origin_push"
      [ -n "$m" ] || mirror_tags="$c:refs/tags/$t $mirror_tags"
      [ -n "$o" ] && [ -n "$m" ] && break
      published="$published $t"
    done
  done

  local mirror_push="$mirror_tags"
  if [ -n "$target" ] && [ "$target" != "$mirror_main" ]; then
    remote_git "$MIRROR_TOKEN" fetch -q "$MIRROR_URL" main
    if git merge-base --is-ancestor "$target" "$mirror_main"; then
      : # the mirror already holds the newest release
    elif git merge-base --is-ancestor "$mirror_main" "$target"; then
      mirror_push="$target:refs/heads/main $mirror_push"
    else
      die "the mirror's main ($mirror_main) is not an ancestor of release commit $target. It has diverged; fix it by hand. This never force-pushes."
    fi
  fi

  if [ -z "$origin_push$mirror_push$creates" ]; then
    echo "release-publish: every release is tagged, mirrored and released; nothing to publish."
    return 0
  fi

  # Write phase.
  # shellcheck disable=SC2086 # refspec lists are space-separated by construction
  [ -z "$origin_push" ] || remote_git "$origin_tok" push -q --atomic origin $origin_push
  # shellcheck disable=SC2086
  [ -z "$mirror_push" ] || remote_git "$MIRROR_TOKEN" push -q --atomic "$MIRROR_URL" $mirror_push
  for t in $creates; do
    GH_TOKEN="$MIRROR_TOKEN" gh release create "$t" --repo "$MIRROR_REPO" --verify-tag --generate-notes \
      || die "gh release create $t failed; the tags and the mirror are pushed, so a re-run creates only the Release."
  done
  echo "release-publish: published${published:- (Releases only)}; mirror main at ${target:-unchanged}."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
