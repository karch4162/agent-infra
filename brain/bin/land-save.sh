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
#                    The git dir's brain-land-hot records which origin blob was
#                    handed over, on which branch, at which tip; only a later
#                    hot.md commit on that branch counts as the fold, and a
#                    hot.md that moved AGAIN is handed over again — a
#                    compare-and-swap, like write-hot.sh's own pin.
# Any other conflicted path (logs/, graphify/, a trusted note) leaves the PR
# open and the default branch untouched.
#
# NO ORIGIN (INNOV-411). A local-only vault has nowhere to push and no PR, so the
# save lands by fast-forwarding the local default branch to this branch's tip —
# the same .saveinclude and brain.json gates, judged against that branch's
# committed copies. Only the ref moves (update-ref, compare-and-swap): no commit
# lands on the default branch, which is never the checked-out branch here. A
# default branch this save does not contain is SKIPPED, never merged.
#
# Usage:
#   BRAIN_ROOT=<vault> bash land-save.sh [--title "save: <date> — <slug>"]
#
# Contract (the /brain:save skill and tests depend on exactly this). Always exit
# 0 — landing is never allowed to fail a save; exit 1 is a usage error only.
# The first line on stdout is one of:
#   LAND: MERGED #<n>
#   LAND: MERGED (local) - <what moved>  (no origin: the default branch was fast-forwarded)
#   LAND: MERGED (fast-forward) - <what moved>  (origin is not GitHub, or gh cannot drive a PR:
#                                   the branch was pushed onto the default branch, INNOV-416)
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
  brain/save-*|brain/session-*) ;;
  *) skip "'$BRANCH' is not a /brain:save branch (brain/save-*)" \
       "  Only save PRs land automatically. Promote, ingest, verify, tidy and revise" \
       "  PRs carry trusted knowledge, and their review is the governance gate." ;;
esac
LOCAL=""
FF=""  # INNOV-416: set to the reason when the landing is a fast-forward push, not a PR
if ! g remote get-url origin >/dev/null 2>&1; then
  LOCAL=1
else
  # The remote is the setting (no init question, no config key): a GitHub origin lands
  # through a PR; any other origin (a local bare repo, GitLab, a file share) or a
  # machine where gh cannot drive the PR lands by a non-forced fast-forward push.
  # LAND_GITHUB_HOSTS (space-separated substrings, default github.com) names GHE hosts.
  ORIGIN_URL="$(g remote get-url origin)"
  is_github=""
  for h in ${LAND_GITHUB_HOSTS:-github.com}; do [[ "$ORIGIN_URL" == *"$h"* ]] && is_github=1; done
  if [[ -z "$is_github" ]]; then FF="origin is not a GitHub remote"
  elif ! command -v gh >/dev/null 2>&1; then FF="gh is not installed"
  elif ! (cd "$VAULT" && gh auth status >/dev/null 2>&1); then FF="gh is not authenticated"
  fi
fi

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
# ON names the base in messages: origin/<default>, or '<default>' with no origin.
if [[ -n "$LOCAL" ]]; then
  # The same answer reap-branches.sh (step 6b) gives: detection, then main/master.
  DEFAULT="$(detect_default_branch)"
  if [[ -z "$DEFAULT" ]]; then
    for cand in main master; do
      if g show-ref --verify --quiet "refs/heads/$cand"; then DEFAULT="$cand"; break; fi
    done
  fi
  [[ -n "$DEFAULT" ]] && g show-ref --verify --quiet "refs/heads/$DEFAULT" ||
    skip "no 'origin' remote, and no local default branch (main/master); the save stays a local commit on '$BRANCH'"
  BASE="refs/heads/$DEFAULT"
  ON="'$DEFAULT'"
else
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
  ON="origin/$DEFAULT"
fi
HEAD_SHA="$(g rev-parse HEAD)"
ACK="$(g rev-parse --path-format=absolute --git-path brain-land-hot)"
[[ "$(g rev-list --count "$BASE..HEAD" 2>/dev/null)" -gt 0 ]] ||
  skip "nothing to land: '$BRANCH' has no commit that $ON lacks"

# --- 3. scope: origin's committed .saveinclude is the publish policy ----------
# Not the working tree's copy: a locally widened allowlist must not become a
# release policy just because a commit got through. ls-tree + cat-file, not
# `rev:path`, which Git Bash's path conversion mangles.
blob_at() { g ls-tree "$1" -- "$2" 2>/dev/null | awk '{print $3; exit}'; }
load_policy() { # loads ALLOW from origin/<default>'s .saveinclude as fetched NOW
  local policy
  policy="$(blob_at "$BASE" .saveinclude)"
  [[ -n "$policy" ]] && g cat-file blob "$policy" >"$TMP/policy" 2>/dev/null &&
    allowlist_load "$TMP/policy" && [[ ${#ALLOW[@]} -gt 0 ]]
}
load_policy ||
  skip "$ON has no committed .saveinclude with entries, so nothing may be published"
outside_scope() { # tip — prints each changed path the policy does not allow
  local p
  while IFS= read -r -d '' p; do
    path_is_allowed "$p" || printf '%s\n' "$p"
  done < <(g diff -z --name-only --no-renames "$BASE...$1" 2>/dev/null)
}
bad="$(outside_scope HEAD)"
[[ -z "$bad" ]] ||
  skip "'$BRANCH' carries path(s) outside $ON's .saveinclude: $(printf '%s' "$bad" | tr '\n' ' ')" \
    "  Nothing was pushed. Session output lands automatically; anything else goes" \
    "  through a reviewed PR ([[promote]])."
# The content gate vault-commit.sh applied at commit time (INNOV-297), re-run
# against origin's brain.json: a save that branched before the policy tightened,
# or log.md's union blob below, was never judged by the policy on main now.
# The merge publishes every commit on the branch, not only the tip's tree, so a
# blob a later commit removed is still judged: each non-merge commit's own
# changes in its own tree, then the tip's whole diff (log.md's union is a merge).
governance() { # tip — check-governance.mjs's output; non-zero when it refuses
  local c out
  for c in $(g rev-list --no-merges "$BASE..$1" 2>/dev/null); do
    out="$(g diff-tree -r -z --name-only --no-renames --root "$c" 2>/dev/null |
      BRAIN_ROOT="$VAULT" node "$BIN_DIR/check-governance.mjs" --policy "$BASE" --tree "$c" 2>&1)" ||
      { printf '%s\n' "$out" "  (in commit ${c:0:12})"; return 1; }
  done
  g diff -z --name-only --no-renames "$BASE...$1" 2>/dev/null |
    BRAIN_ROOT="$VAULT" node "$BIN_DIR/check-governance.mjs" --policy "$BASE" --tree "$1" 2>&1
}
gov="$(governance HEAD)" ||
  skip "'$BRANCH' breaks $ON's brain.json policy" \
    "$(printf '%s\n' "$gov" | sed 's/^/    /')" \
    "  Nothing was pushed."

# --- 4. no origin: fast-forward the local default branch, and stop -----------
if [[ -n "$LOCAL" ]]; then
  OLD="$(g rev-parse "$BASE")"
  g merge-base --is-ancestor "$OLD" HEAD ||
    skip "no 'origin' remote, and '$DEFAULT' has commit(s) '$BRANCH' lacks; nothing was moved"       "  Something landed on '$DEFAULT' since this save branched. Reconcile by hand"       "  (merge '$DEFAULT' into '$BRANCH'), then re-run land-save."
  # A branch checked out in another worktree must not move under that worktree. The
  # base checkout of a portable session always holds it (INNOV-416): fast-forward it
  # there, and only while that checkout is clean.
  wt="$(g worktree list --porcelain 2>/dev/null | awk -v b="branch $BASE" '/^worktree /{p=substr($0,10)} $0==b{print p; exit}')"
  if [[ -n "$wt" ]]; then
    [[ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]] ||
      skip "'$DEFAULT' is checked out at '$wt' with uncommitted work; nothing was moved"
    git -C "$wt" merge -q --ff-only "$HEAD_SHA" >/dev/null 2>&1 ||
      skip "could not fast-forward '$DEFAULT' at '$wt'; nothing was moved"
  else
    g update-ref -m "land-save: fast-forward to $BRANCH" "$BASE" "$HEAD_SHA" "$OLD" 2>/dev/null ||
      skip "could not fast-forward '$DEFAULT' (it moved meanwhile?); nothing was moved"
  fi
  rm -f "$ACK"
  say "MERGED (local) - fast-forwarded '$DEFAULT' to '$BRANCH'"     "  No 'origin' remote, so nothing was pushed; '$BRANCH' is now in '$DEFAULT', so step 6b reaps it."
fi

# --- 4b. merge, if origin moved -----------------------------------------------
open_pr() {
  [[ -z "$FF" ]] || return 0
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
  [[ -z "$FF" ]] || { PR=""; return 0; }
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
      say "LEFT OPEN${PR:+ #$PR} - conflicts outside the known paths:$UNKNOWN" \
        "  origin/$DEFAULT is untouched. These need a person: resolve on '$BRANCH' and merge," \
        "  or close the PR. /brain:resume lists it until then."
    fi

    # The hand-over record: "<origin hot.md blob> <branch> <tip when handed over>".
    # It counts as a fold only for THIS branch, and only once a later commit on it
    # changed hot.md — so a stale record (a HOT never folded, another save) never
    # lets a save take its own side. Kept in the git dir, not the working tree.
    if [[ "$CONFLICTED" == *$'\n'wiki/hot.md$'\n'* ]]; then
      origin_hot="$(blob_at "$BASE" wiki/hot.md)"
      read -r ack_blob ack_branch ack_tip _ 2>/dev/null <"$ACK" || ack_blob=""
      if [[ -n "$HOT2" && -n "$ack_blob" && "$ack_blob" == "$origin_hot" && "$ack_branch" == "$BRANCH" &&
            "$ack_tip" != "$HEAD_SHA" ]] &&
         g merge-base --is-ancestor "$ack_tip" HEAD 2>/dev/null &&
         ! g diff --quiet "$ack_tip" HEAD -- wiki/hot.md 2>/dev/null; then
        RESOLVED="$RESOLVED wiki/hot.md (this save's fold of origin's version)"
      else
        printf '%s %s %s\n' "$origin_hot" "$BRANCH" "$HEAD_SHA" >"$ACK"
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
# The merge above can write a blob no commit was ever judged on (log.md's union),
# so the tip is checked before it leaves this machine, not only after.
if [[ "$TIP" != "$HEAD_SHA" ]]; then
  gov="$(governance "$TIP")" ||
    skip "the merge of origin/$DEFAULT into '$BRANCH' breaks origin/$DEFAULT's brain.json policy" \
      "$(printf '%s\n' "$gov" | sed 's/^/    /')" \
      "  Nothing was pushed."
fi
push_tip "$TIP"
ensure_pr
g fetch -q origin "refs/heads/$BRANCH" 2>/dev/null
pushed="$(g rev-parse -q --verify FETCH_HEAD 2>/dev/null)"
# Re-read the policy too: the default branch may have narrowed .saveinclude since
# step 3, and the merge publishes against the default branch as it is now.
g fetch -q origin 2>/dev/null
load_policy || say "LEFT OPEN${PR:+ #$PR} - origin/$DEFAULT no longer has a .saveinclude with entries"
bad="$(outside_scope "${pushed:-$TIP}")"
[[ -z "$bad" ]] || say "LEFT OPEN${PR:+ #$PR} - the pushed branch carries path(s) outside origin/$DEFAULT's .saveinclude: $(printf '%s' "$bad" | tr '\n' ' ')"
gov="$(governance "${pushed:-$TIP}")" ||
  say "LEFT OPEN${PR:+ #$PR} - the pushed branch breaks origin/$DEFAULT's brain.json policy" \
    "$(printf '%s\n' "$gov" | sed 's/^/    /')"

if [[ -n "$FF" ]]; then
  # The fast-forward push IS the merge. Never forced: a rejection means the default
  # branch moved since the fetch above (re-run: the merge step folds it in) or is
  # protected (then the host's own review path applies).
  if ! err="$(g push -q origin "${pushed:-$TIP}:refs/heads/$DEFAULT" 2>&1)"; then
    say "LEFT OPEN - push to origin/$DEFAULT rejected: $(first_line "$err")" \
      "  '$BRANCH' is pushed and origin/$DEFAULT is untouched. If $DEFAULT moved, re-run" \
      "  land-save (it merges origin in first); if it is protected, merge the branch your host's way."
  fi
  rm -f "$ACK"
  notes=()
  g push -q origin --delete "$BRANCH" >/dev/null 2>&1 ||
    notes+=("  NOTE: could not delete origin's '$BRANCH'; delete it by hand (it is merged).")
  g fetch -q origin 2>/dev/null
  echo "LAND: MERGED (fast-forward) - pushed '$BRANCH' to origin/$DEFAULT"
  echo "  $FF, so no PR: the fast-forward push is the merge; step 6b reaps it."
  [[ -z "$RESOLVED" ]] || echo "  resolved:$RESOLVED"
  [[ ${#notes[@]} -eq 0 ]] || printf '%s\n' "${notes[@]}"
  exit 0
fi

tries=0
while :; do
  merge_err="$(cd "$VAULT" && gh pr merge "$PR" --merge --match-head-commit "${pushed:-$TIP}" 2>&1 >/dev/null)" && break
  tries=$((tries + 1))
  case "$merge_err" in
    *review*|*approv*|*protect*|*rule*|*permission*|*"not authorized"*)
      say "LEFT OPEN${PR:+ #$PR} - merge blocked: $(first_line "$merge_err")" \
        "  origin/$DEFAULT requires something this account cannot give (a review, a" \
        "  ruleset bypass). The PR is open; merge it the usual way." ;;
  esac
  [[ $tries -lt 3 ]] || say "LEFT OPEN${PR:+ #$PR} - gh pr merge failed: $(first_line "$merge_err")"
  # GitHub computes mergeability asynchronously; a PR opened a moment ago can
  # briefly read as not mergeable.
  sleep "${LAND_MERGE_RETRY_SECS:-2}"
done

rm -f "$ACK"
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
