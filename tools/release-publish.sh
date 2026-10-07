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
#   - the mirror's main fast-forwarded to that commit, so it ends on the NEWEST
#     release commit, never the tip: commits merged after it wait for the next
#     release;
#   - a GitHub Release on the mirror (`--generate-notes`).
# Releases publish one at a time, oldest first, and the run stops at the first
# failure. A version's tags are what end the walk, so they must never land
# before every older version is fully published.
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

  # items: one "commit tag origin-missing mirror-missing create" line per
  # walked release, the flags 0 or 1.
  local items="" target=""
  local d p c v t o m st om mm cr
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
        200) cr=0 ;;
        404) cr=1 ;;
        *) die "looking up the mirror's GitHub Release $t returned HTTP ${st:-no response}, not 200 or 404." ;;
      esac
      # The newest release across plugins is where the mirror's main ends.
      if [ -z "$target" ] || git merge-base --is-ancestor "$target" "$c"; then
        target="$c"
      fi
      om=1; [ -z "$o" ] || om=0
      mm=1; [ -z "$m" ] || mm=0
      items="$items$c $t $om $mm $cr
"
      if [ "$om$mm" = "00" ]; then break; fi
    done
  done

  local need_main=0
  if [ -n "$target" ] && [ "$target" != "$mirror_main" ]; then
    remote_git "$MIRROR_TOKEN" fetch -q "$MIRROR_URL" main
    if git merge-base --is-ancestor "$target" "$mirror_main"; then
      : # the mirror already holds the newest release
    elif git merge-base --is-ancestor "$mirror_main" "$target"; then
      need_main=1
    else
      die "the mirror's main ($mirror_main) is not an ancestor of release commit $target. It has diverged; fix it by hand. This never force-pushes."
    fi
  fi

  if [ "$need_main" = 0 ] && [ -z "$(printf '%s' "$items" | awk '$3 || $4 || $5')" ]; then
    echo "release-publish: every release is tagged, mirrored and released; nothing to publish."
    return 0
  fi

  # Write phase, oldest release first along main's first-parent line.
  local ordered refs published=""
  ordered="$(printf '%s' "$items" \
    | awk 'NR == FNR { pos[$1] = NR; next } { print pos[$1], $0 }' <(git rev-list --first-parent "$tip") - \
    | sort -k1,1nr | cut -d' ' -f2-)"
  while read -r c t om mm cr <&3; do
    [ -n "$c" ] || continue
    [ "$om" = 0 ] || remote_git "$origin_tok" push -q origin "$c:refs/tags/$t"
    refs=""
    [ "$mm" = 0 ] || refs="$c:refs/tags/$t"
    if [ "$need_main" = 1 ] && [ "$c" != "$mirror_main" ] && git merge-base --is-ancestor "$mirror_main" "$c"; then
      refs="$c:refs/heads/main $refs"
      mirror_main="$c"
    fi
    # shellcheck disable=SC2086 # refs is space-separated by construction
    [ -z "$refs" ] || remote_git "$MIRROR_TOKEN" push -q --atomic "$MIRROR_URL" $refs
    if [ "$cr" = 1 ]; then
      GH_TOKEN="$MIRROR_TOKEN" gh release create "$t" --repo "$MIRROR_REPO" --verify-tag --generate-notes \
        || die "gh release create $t failed. Its tags are pushed and newer releases are held back; a re-run continues from $t."
    fi
    [ "$om$mm$cr" = "000" ] || published="$published $t"
  done 3<<EOF
$ordered
EOF
  echo "release-publish: published${published:- nothing new}; mirror main at $mirror_main."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
