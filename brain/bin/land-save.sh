#!/usr/bin/env bash
# land-save.sh — push, open and merge this save's PR, so a save ends ON the
# default branch with no human step (INNOV-389). /brain:save step 6a.
#
# WHY. Step 6 commits onto brain/save-<date> and stopped there: every user
# pushed, opened and merged the PR by hand, and that is where saves stalled —
# on conflicts in the few shared files every save rewrites (wiki/log.md,
# wiki/hot.md, graphify-out/). Save PRs got no real review anyway (57 of 60
# self-merged within minutes on one team vault). Trusted-knowledge PRs keep
# their human gate: only brain/save-* branches are landed, and only when every
# path they carry is on origin's committed .saveinclude.
#
# WHAT IT NEVER TOUCHES. The checkout: not HEAD, not the index, not the working
# tree, not the local branch ref. A save routinely leaves trusted notes dirty
# (step 5b; they are not on the allowlist), and the index is shared with every
# session in the tree. So a needed merge is built with plumbing — `git
# merge-tree --write-tree` plus a private index, like vault-commit.sh — and the
# result is pushed by sha. Never a force-push, and never the default branch.
#
# WHY --merge, NOT --squash. A squash commit does not contain the branch, so
# reap-branches.sh (merge-base --is-ancestor, then `branch -d`) would keep every
# landed branch forever. A merge commit makes this branch's tip an ancestor of
# the default branch, and step 6b reaps it exactly as it reaps any merged branch.
#
# CONFLICTS. Resolved mechanically, and only on these paths:
#   wiki/log.md      union of both sides (append-only, so nothing is lost)
#   graphify-out/*   origin's WHOLE build, which already landed; the next save's
#                    concept-graph check counts the drift and step 5c regenerates.
#                    A save's own build is never assumed to be the newer one.
#   wiki/hot.md      never dropped. LAND: HOT, nothing pushed; the agent folds
#                    origin's version in through write-hot.sh, commits, re-runs.
#                    .brain/land-hot records which origin blob was handed over,
#                    so a hot.md that moved AGAIN is handed over again — a
#                    compare-and-swap, like write-hot.sh's own pin.
# Any other conflicted path (logs/, graphify/, a trusted note) leaves the PR
# open and the default branch untouched.
#
# Usage:
#   BRAIN_ROOT=<vault> bash land-save.sh [--title "save: <date> — <slug>"]
#
# Contract (the /brain:save skill and tests depend on exactly this). Always exit
# 0 — landing is never allowed to fail a save; exit 1 is a usage error only.
# The first line on stdout is one of:
#   LAND: MERGED #<n>
#   LAND: LEFT OPEN [#<n>] - <reason>
#   LAND: SKIPPED - <reason>          (nothing was pushed)
#   LAND: HOT - <what to do>          (nothing was pushed)
# LAND_MERGE_RETRY_SECS (default 2) spaces the merge retries.
set -uo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/branch.sh
. "$BIN_DIR/lib/branch.sh"
# shellcheck source=lib/allowlist.sh
. "$BIN_DIR/lib/allowlist.sh"
# shellcheck source=lib/index-sync.sh
. "$BIN_DIR/lib/index-sync.sh"

TITLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="${2:-}"; shift 2 || shift ;;
    *) echo "land-save: unknown argument '$1'" >&2
       echo "  Usage: BRAIN_ROOT=<vault> bash land-save.sh [--title TITLE]" >&2
       exit 1 ;;
  esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { # verdict, then extra lines; ends the run with exit 0
  echo "LAND: $1"
  shift
  local line
  for line in "$@"; do echo "$line"; done
  exit 0
}
skip() { local why="$1"; shift; say "SKIPPED - $why" "$@"; }
first_line() { printf '%s\n' "$1" | sed -n '/./{p;q;}' | tr -d '\r'; }
g() { git -C "$VAULT" "$@"; }

# --- 1. guards: each one skips before any network write -----------------------
g rev-parse --git-dir >/dev/null 2>&1 || skip "'$VAULT' is not a git repo"
BRANCH="$(g symbolic-ref -q --short HEAD 2>/dev/null)" ||
  skip "the vault is on a detached HEAD; there is no save branch to land"
case "$BRANCH" in
  brain/save-*) ;;
  *) skip "'$BRANCH' is not a /brain:save branch (brain/save-*)" \
       "  Only save PRs land automatically. Promote, ingest, verify, tidy and revise" \
       "  PRs carry trusted knowledge, and their review is the governance gate." ;;
esac
g remote get-url origin >/dev/null 2>&1 ||
  skip "no 'origin' remote; the save stays a local commit on '$BRANCH'"
command -v gh >/dev/null 2>&1 ||
  skip "gh is not installed; the save stays a local commit on '$BRANCH'"
(cd "$VAULT" && gh auth status >/dev/null 2>&1) ||
  skip "gh is not authenticated (gh auth status); the save stays a local commit on '$BRANCH'"

# The ticket's own incident: a post-commit index sync that did not land. Never
# publish on top of it, and never run the reset here — it is safe only for the
# paths the commit wrote, and only a human can tell those from staged work.
if ! g diff --cached --quiet HEAD 2>/dev/null; then
  stale_index_paths
  if [[ ${#STALE[@]} -gt 0 ]]; then
    skip "shared index out of sync (${#STALE[@]} stale path(s))" \
      "  vault-commit.sh's post-commit index sync did not land (usually a held index.lock):" \
      "  the index still holds the pre-commit versions of paths HEAD's commit wrote." \
      "  Nothing was pushed. Unless you staged a revert of these on purpose, run, then" \
      "  re-run land-save:" \
      "$(stale_index_remedy)"
  fi
  skip "shared index out of sync (0 stale, $(g diff --cached --name-only HEAD | grep -c .) other staged path(s))" \
    "  Something is staged that HEAD's commit did not write, so it is somebody's work:" \
    "  nothing was reset and nothing was pushed. Commit or unstage it, then re-run."
fi

# --- 2. where are we landing? -------------------------------------------------
g fetch -q origin 2>/dev/null ||
  skip "could not fetch origin (offline?); the save stays a local commit on '$BRANCH'"
DEFAULT="$(detect_default_branch)"
if [[ -z "$DEFAULT" ]]; then
  for cand in main master; do
    if g rev-parse -q --verify "refs/remotes/origin/$cand" >/dev/null 2>&1; then DEFAULT="$cand"; break; fi
  done
fi
[[ -n "$DEFAULT" ]] && g rev-parse -q --verify "refs/remotes/origin/$DEFAULT" >/dev/null 2>&1 ||
  skip "could not resolve origin's default branch"
BASE="refs/remotes/origin/$DEFAULT"
HEAD_SHA="$(g rev-parse HEAD)"
[[ "$(g rev-list --count "$BASE..HEAD" 2>/dev/null)" -gt 0 ]] ||
  skip "nothing to land: '$BRANCH' has no commit that origin/$DEFAULT lacks"

# --- 3. scope: origin's committed .saveinclude is the publish policy ----------
# Not the working tree's copy: a locally widened allowlist must not become a
# release policy just because a commit got through. ls-tree + cat-file, not
# `rev:path`, which Git Bash's path conversion mangles.
blob_at() { g ls-tree "$1" -- "$2" 2>/dev/null | awk '{print $3; exit}'; }
policy="$(blob_at "$BASE" .saveinclude)"
[[ -n "$policy" ]] || skip "origin/$DEFAULT has no committed .saveinclude, so nothing may be published"
g cat-file blob "$policy" >"$TMP/policy" 2>/dev/null
allowlist_load "$TMP/policy" && [[ ${#ALLOW[@]} -gt 0 ]] ||
  skip "origin/$DEFAULT's .saveinclude has no entries, so nothing may be published"
outside_scope() { # tip — prints each changed path the policy does not allow
  local p
  while IFS= read -r -d '' p; do
    path_is_allowed "$p" || printf '%s\n' "$p"
  done < <(g diff -z --name-only --no-renames "$BASE...$1" 2>/dev/null)
}
bad="$(outside_scope HEAD)"
[[ -z "$bad" ]] ||
  skip "'$BRANCH' carries path(s) outside origin/$DEFAULT's .saveinclude: $(printf '%s' "$bad" | tr '\n' ' ')" \
    "  Nothing was pushed. Session output lands automatically; anything else goes" \
    "  through a reviewed PR ([[promote]])."

# --- 4. merge, if origin moved ------------------------------------------------
open_pr() {
  (cd "$VAULT" && gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null) |
    tr -dc '0-9'
}
push_tip() { # sha — never forced: a rejection means someone else moved the branch
  local err
  err="$(g push -q origin "$1:refs/heads/$BRANCH" 2>&1)" && return 0
  PR="$(open_pr)"
  say "LEFT OPEN${PR:+ #$PR} - push rejected: origin's '$BRANCH' moved, and nothing was overwritten" \
    "  git said: $(first_line "$err")"
}
ensure_pr() {
  local out body
  PR="$(open_pr)"
  [[ -n "$PR" ]] && return 0
  [[ -n "$TITLE" ]] || TITLE="$(g log --reverse --no-merges --format=%s "$BASE..$HEAD_SHA" | sed -n 1p)"
  TITLE="${TITLE/ session — / — }"
  body="Session output from /brain:save, landed by land-save.sh (INNOV-389). Every path is on origin/$DEFAULT's .saveinclude."
  if ! out="$(cd "$VAULT" && gh pr create --base "$DEFAULT" --head "$BRANCH" --title "$TITLE" --body "$body" 2>&1)"; then
    say "LEFT OPEN - gh pr create failed: $(first_line "$out")" \
      "  '$BRANCH' is pushed; open the PR by hand."
  fi
  PR="$(printf '%s\n' "$out" | grep -o 'pull/[0-9]*' | tail -n 1 | tr -dc '0-9')"
}

TIP="$HEAD_SHA"
RESOLVED=""
if ! g merge-base --is-ancestor "$BASE" HEAD; then
  g merge-tree --write-tree -z HEAD "$BASE" >"$TMP/mt" 2>"$TMP/mt.err"
  mt_rc=$?
  if [[ $mt_rc -gt 1 ]]; then
    skip "git $(g version | awk '{print $3}') could not run merge-tree --write-tree (needs 2.38+)" \
      "  $(first_line "$(cat "$TMP/mt.err")")"
  fi
  if [[ $mt_rc -eq 1 ]]; then
    # -z output: the tree, then "<mode> <oid> <stage>\t<path>" records up to an
    # empty one. Stage 2 is HEAD (this save), stage 3 is origin.
    CONFLICTED=$'\n'
    UNKNOWN=""
    LOG1=""; LOG2=""; LOG3=""; HOT2=""; HOT_MODE=""
    {
      IFS= read -r -d '' MT_TREE
      while IFS= read -r -d '' rec && [[ -n "$rec" ]]; do
        path="${rec#*$'\t'}"
        read -r mode oid stage <<<"${rec%%$'\t'*}"
        case "$path:$stage" in
          wiki/log.md:1) LOG1="$oid" ;;
          wiki/log.md:2) LOG2="$oid" ;;
          wiki/log.md:3) LOG3="$oid" ;;
          wiki/hot.md:2) HOT2="$oid"; HOT_MODE="$mode" ;;
        esac
        [[ "$CONFLICTED" == *$'\n'"$path"$'\n'* ]] && continue
        CONFLICTED="$CONFLICTED$path"$'\n'
        case "$path" in
          wiki/log.md|wiki/hot.md|graphify-out/*) ;;
          *) UNKNOWN="$UNKNOWN $path" ;;
        esac
      done
    } <"$TMP/mt"

    if [[ -n "$UNKNOWN" ]]; then
      push_tip "$HEAD_SHA"
      ensure_pr
      say "LEFT OPEN #$PR - conflicts outside the known paths:$UNKNOWN" \
        "  origin/$DEFAULT is untouched. These need a person: resolve on '$BRANCH' and merge," \
        "  or close the PR. /brain:resume lists it until then."
    fi

    ACK="$VAULT/.brain/land-hot"
    if [[ "$CONFLICTED" == *$'\n'wiki/hot.md$'\n'* ]]; then
      origin_hot="$(blob_at "$BASE" wiki/hot.md)"
      if [[ -n "$HOT2" && -f "$ACK" && "$(tr -d '\r\n' <"$ACK")" == "$origin_hot" ]]; then
        RESOLVED="$RESOLVED wiki/hot.md (this save's fold of origin's version)"
      else
        mkdir -p "$VAULT/.brain" && printf '%s\n' "$origin_hot" >"$ACK"
        say "HOT - wiki/hot.md changed on origin/$DEFAULT since this save branched; nothing was pushed" \
          "  hot.md is rewritten wholesale, so taking either side would discard a session's" \
          "  curation. Fold origin's version into this save's, then re-run land-save:" \
          "    1. read origin's:  bash \"$BIN_DIR/resume-brief.sh\" --cat wiki/hot.md" \
          "    2. write-hot.sh --pin, then --write the folded file; check-hot-budget.sh" \
          "    3. commit it (save step 6), then: bash \"$BIN_DIR/land-save.sh\"" \
          "  If origin's hot.md moves again before then, this hands it over again."
      fi
    fi

    # Resolve into a private index; the shared one is never touched.
    export GIT_INDEX_FILE="$TMP/index"
    g read-tree "$MT_TREE"
    if [[ "$CONFLICTED" == *$'\n'wiki/log.md$'\n'* ]]; then
      for s in 1 2 3; do
        eval "oid=\$LOG$s"
        if [[ -n "$oid" ]]; then g cat-file blob "$oid" >"$TMP/log$s"; else : >"$TMP/log$s"; fi
      done
      # origin's lines first: they landed first.
      git merge-file -p --union "$TMP/log3" "$TMP/log1" "$TMP/log2" >"$TMP/log.merged"
      g update-index --add --cacheinfo "100644,$(g hash-object -w --no-filters "$TMP/log.merged"),wiki/log.md"
      RESOLVED="$RESOLVED wiki/log.md (union)"
    fi
    if [[ -n "$HOT2" && "$RESOLVED" == *wiki/hot.md* ]]; then
      g update-index --add --cacheinfo "${HOT_MODE:-100644},$HOT2,wiki/hot.md"
    fi
    if [[ "$CONFLICTED" == *$'\n'graphify-out/* ]]; then
      g ls-files -z -- graphify-out | g update-index -z --force-remove --stdin
      graph_tree="$(g ls-tree -d "$BASE" -- graphify-out | awk '{print $3; exit}')"
      [[ -z "$graph_tree" ]] || g read-tree --prefix=graphify-out/ "$graph_tree"
      RESOLVED="$RESOLVED graphify-out/ (origin's build kept; the next save's step 5c regenerates)"
    fi
    TREE="$(g write-tree)"
    unset GIT_INDEX_FILE
    SIGN=""
    [[ "$(g config --type=bool commit.gpgsign 2>/dev/null)" == true ]] && SIGN="-S"
    TIP="$(g commit-tree ${SIGN:+"$SIGN"} "$TREE" -p "$HEAD_SHA" -p "$BASE" \
      -m "Merge origin/$DEFAULT into $BRANCH" -m "land-save.sh resolved:$RESOLVED")" ||
      skip "could not create the merge commit; nothing was pushed"
  fi
fi

# --- 5. push, PR, re-verify, merge --------------------------------------------
push_tip "$TIP"
ensure_pr
g fetch -q origin "refs/heads/$BRANCH" 2>/dev/null
pushed="$(g rev-parse -q --verify FETCH_HEAD 2>/dev/null)"
bad="$(outside_scope "${pushed:-$TIP}")"
[[ -z "$bad" ]] || say "LEFT OPEN #$PR - the pushed branch carries path(s) outside the policy: $bad"

tries=0
while :; do
  merge_err="$(cd "$VAULT" && gh pr merge "$PR" --merge --match-head-commit "${pushed:-$TIP}" 2>&1 >/dev/null)" && break
  tries=$((tries + 1))
  case "$merge_err" in
    *review*|*approv*|*protect*|*rule*|*permission*|*"not authorized"*)
      say "LEFT OPEN #$PR - merge blocked: $(first_line "$merge_err")" \
        "  origin/$DEFAULT requires something this account cannot give (a review, a" \
        "  ruleset bypass). The PR is open; merge it the usual way." ;;
  esac
  [[ $tries -lt 3 ]] || say "LEFT OPEN #$PR - gh pr merge failed: $(first_line "$merge_err")"
  # GitHub computes mergeability asynchronously; a PR opened a moment ago can
  # briefly read as not mergeable.
  sleep "${LAND_MERGE_RETRY_SECS:-2}"
done

rm -f "$VAULT/.brain/land-hot"
notes=()
if ! g push -q origin --delete "$BRANCH" >/dev/null 2>&1; then
  notes+=("  NOTE: could not delete origin's '$BRANCH'; delete it by hand (it is merged).")
fi
g fetch -q origin 2>/dev/null
echo "LAND: MERGED #$PR"
echo "  '$BRANCH' is merged into $DEFAULT (a merge commit), so step 6b reaps it."
[[ -z "$RESOLVED" ]] || echo "  resolved:$RESOLVED"
[[ ${#notes[@]} -eq 0 ]] || printf '%s\n' "${notes[@]}"
exit 0
