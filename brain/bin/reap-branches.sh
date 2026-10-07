#!/usr/bin/env bash
# reap-branches.sh — after a save has committed, leave the checkout on the default
# branch and delete the brain/* branches whose work has already landed.
# (INNOV-309 slice 1.)
#
# WHY THIS EXISTS. /brain:save commits onto a working branch and stops there. The
# branch is never pushed, merged or deleted, and the checkout is left sitting on
# it, so the NEXT session starts on a stale branch by construction. Measured on one
# vault, 2026-09-23: 29 local branches, 27 of them fully merged into main. One of
# those merged-and-forgotten branches — 74 commits behind main — is what briefed a
# session with stale context (INNOV-301).
#
# This is the gap between two guards. vault-commit.sh refuses to commit onto the
# default branch (INNOV-275, deliberately with no override), so the work is always
# forced onto a branch; the server-side rule that used to require a PR before merge
# has since been removed, so nothing requires anything to happen to that branch
# afterwards. Branches accumulate. This script closes the loop from the cleanup end.
#
# WHY IT IS NOT INSIDE vault-commit.sh. That script is THE single commit path, and
# bin/sync-graph.sh calls it standalone. A branch switch buried in the commit path
# would fire on a bare `sync-graph.sh` run, which has no business moving anyone's
# HEAD. Only /brain:save step 6b calls this, after its commit.
#
# WHAT IT WILL NOT DO (the properties that make it safe to run unattended):
#   - A branch is deleted only when `git merge-base --is-ancestor` says it is in
#     the default branch, and then with `git branch -d`, never -D. -d alone is not
#     enough: once a branch has an upstream (any `push -u`), git checks it against
#     origin/<branch>, which equals the branch right after a push, so -d deletes
#     pushed-but-unmerged work (INNOV-379). A kept branch is reported and stays.
#   - Never a forced checkout. If `git switch` will not proceed, git says so and we
#     stop, having changed nothing.
#   - Never runs while ANOTHER session is live in this checkout. HEAD and the index
#     belong to the working tree, not to a session: switching branches underneath a
#     concurrent command is the 2026-08-05 incident, and session.sh --start refuses
#     for exactly this reason.
#   - Only the brain/* namespace — the branches session.sh --start creates. A
#     human's own branches are not this script's business.
#
# Usage:
#   BRAIN_ROOT=<vault> bash reap-branches.sh
#
# Contract (the /brain:save skill and tests depend on exactly this):
#   exit 0  => first line "REAP: OK - <what happened>" on stdout
#   exit 1  => first line "REAP: REFUSED - <why>" on stderr; nothing was changed
# A refusal is never fatal to a save: the cost is branch litter, which is the
# status quo. The caller reports the line and carries on.
set -uo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# detect_default_branch() lives in lib/branch.sh, shared with vault-commit.sh and
# session.sh. It reads $VAULT, so it is sourced after that is set. Using anything
# else here would be a second answer to "which branch is the default" — the exact
# drift lib/branch.sh exists to prevent.
# shellcheck source=lib/branch.sh
. "$BIN_DIR/lib/branch.sh"
# shellcheck source=lib/index-sync.sh
. "$BIN_DIR/lib/index-sync.sh"

refuse() { # reason-line, then extra lines
  {
    echo "REAP: REFUSED - $1"
    shift
    local line
    for line in "$@"; do echo "$line"; done
  } >&2
  exit 1
}

[[ $# -eq 0 ]] || refuse "unknown argument '$1'" "  Usage: BRAIN_ROOT=<vault> bash reap-branches.sh"

# --- 1. is this a vault, and is it a git repo? ------------------------------
if [[ ! -d "$VAULT/graphify" && ! -d "$VAULT/wiki" ]]; then
  refuse "'$VAULT' doesn't look like a brain vault (no graphify/ or wiki/)" \
    "  Set BRAIN_ROOT to the vault root."
fi
if ! git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
  refuse "'$VAULT' is not a git repo" "  Set BRAIN_ROOT to the vault root."
fi

CUR_BRANCH="$(git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [[ -z "$CUR_BRANCH" || "$CUR_BRANCH" == "HEAD" ]]; then
  refuse "the vault is in DETACHED HEAD state" \
    "  There is no branch to leave and nothing safe to switch away from." \
    "  Remedy: git -C \"$VAULT\" checkout <branch>"
fi

# --- 2. is anyone else working in this checkout? ----------------------------
# Liveness is session.sh's to decide — this asks it rather than re-reading the
# state file, because two readers of that file would drift (INNOV-274). --status
# lists one indented line per record, "live"/"stale" first, and marks our own with
# "(this session)"; a live line without that marker is somebody else.
#
# CANNOT-TELL IS A REFUSAL. If session.sh is missing or its output cannot be read,
# we do not reap. Failing closed costs branch litter — which is the state this
# script is fixing, so the worst case is no worse than today — while failing open
# risks yanking HEAD from under a live command.
if [[ ! -f "$BIN_DIR/session.sh" ]]; then
  refuse "cannot find session.sh next to this script, so concurrent sessions cannot be ruled out" \
    "  Nothing was changed. Reaping while another session is live would move HEAD" \
    "  out from under it."
fi
status_out="$(BRAIN_ROOT="$VAULT" bash "$BIN_DIR/session.sh" --status 2>/dev/null || true)"
if [[ -z "$status_out" ]]; then
  refuse "session.sh --status produced no output, so concurrent sessions cannot be ruled out" \
    "  Nothing was changed."
fi
# tr -d '\r': a CRLF-normalising checkout can put a carriage return at end of
# line, and the "(this session)" anchor below is end-anchored — without this, our
# own record would read as somebody else's and every reap would refuse.
status_out="$(printf '%s\n' "$status_out" | tr -d '\r')"
foreign="$(printf '%s\n' "$status_out" | grep '^  live ' | grep -vc '(this session)$' || true)"
foreign="${foreign//[^0-9]/}"
if [[ -n "$foreign" && "$foreign" -gt 0 ]]; then
  refuse "$foreign other session(s) are live in this checkout" \
    "$(printf '%s\n' "$status_out" | grep '^  live ' | grep -v '(this session)$')" \
    "  HEAD and the git index belong to the working tree, not to a session, so" \
    "  switching branches now would move them out from under a running command." \
    "  Nothing was changed. Re-run once the other session has finished; its record" \
    "  also expires on its own (BRAIN_SESSION_STALE_SECS)."
fi

# --- 3. which branch are we going back to? ----------------------------------
DEFAULT="$(detect_default_branch)"
if [[ -z "$DEFAULT" ]]; then
  # Same main/master safety net branch_is_protected() falls back to, for the same
  # reason: a vault with no remote and no gh still has a default branch, we just
  # have to guess its name. Not a new detection method — the same two literals.
  for candidate in main master; do
    if git -C "$VAULT" show-ref --verify --quiet "refs/heads/$candidate"; then
      DEFAULT="$candidate"
      break
    fi
  done
fi
if [[ -z "$DEFAULT" ]]; then
  refuse "could not determine this vault's default branch" \
    "  Tried origin/HEAD, 'gh repo view', then the literal names main/master." \
    "  Nothing was changed."
fi
if ! git -C "$VAULT" show-ref --verify --quiet "refs/heads/$DEFAULT"; then
  refuse "the default branch '$DEFAULT' does not exist locally" \
    "  Nothing was changed. Remedy: git -C \"$VAULT\" fetch origin && git -C \"$VAULT\" checkout $DEFAULT"
fi

# --- 4. leave the save branch ------------------------------------------------
# Refs first, best-effort: a branch only becomes deletable once the merge that
# landed it is visible locally, and offline must never be an error (check-freshness
# fetches the same way). Then switch WITHOUT --force and let git be the authority
# on whether the tree allows it — a pre-flight dirtiness probe would be a second
# opinion that can disagree with the only one that matters.
git -C "$VAULT" fetch --prune origin >/dev/null 2>&1 || true

SWITCHED_FROM="$CUR_BRANCH"
if [[ "$CUR_BRANCH" != "$DEFAULT" ]]; then
  if ! sw_err="$(git -C "$VAULT" switch "$DEFAULT" 2>&1)"; then
    # A save whose post-commit index sync lost to a held lock (INNOV-377) leaves
    # the shared index at the pre-commit versions of the paths HEAD's commit
    # touched, and git's refusal then reads as unrelated, so name it and print
    # vault-commit.sh's own remedy. The rule is lib/index-sync.sh's.
    stale_index_paths
    if [[ ${#STALE[@]} -gt 0 ]]; then
      refuse "could not switch from '$CUR_BRANCH' to '$DEFAULT'" \
        "  The shared index still holds the pre-commit versions of ${#STALE[@]} path(s) the" \
        "  last commit on '$CUR_BRANCH' touched: vault-commit.sh's post-commit index sync" \
        "  did not land (usually a held index.lock). Nothing was changed. Unless you staged" \
        "  a revert of these paths on purpose (that looks the same), run, then re-run:" \
        "$(stale_index_remedy)" \
        "  git said:" \
        "$(printf '    %s\n' "$sw_err")"
    fi
    refuse "could not switch from '$CUR_BRANCH' to '$DEFAULT'" \
      "$(printf '    %s\n' "$sw_err")" \
      "  Nothing was changed, and nothing was forced: your work is still on" \
      "  '$CUR_BRANCH'. Usually this means local changes would be overwritten —" \
      "  commit or set them aside, then re-run."
  fi
fi

# Fast-forward only. A default branch that has diverged from its upstream is a
# human's problem, not something to resolve automatically at the end of a save.
FF_NOTE="already up to date"
if git -C "$VAULT" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT" >/dev/null 2>&1; then
  behind="$(git -C "$VAULT" rev-list --count "$DEFAULT..origin/$DEFAULT" 2>/dev/null || echo 0)"
  if [[ "${behind//[^0-9]/}" -gt 0 ]]; then
    if git -C "$VAULT" merge --ff-only "origin/$DEFAULT" >/dev/null 2>&1; then
      FF_NOTE="fast-forwarded $behind commit(s) from origin/$DEFAULT"
    else
      FF_NOTE="could NOT fast-forward from origin/$DEFAULT ($behind behind — it has diverged; an engineer needs to reconcile)"
    fi
  fi
fi

# --- 5. reap the merged brain/* branches ------------------------------------
# The ancestor check is the guard, against the default branch explicitly: -d
# compares against the branch's UPSTREAM when it has one, not HEAD (INNOV-379).
# -d, never -D, stays as the second lock.
DELETED=()
KEPT=()
while IFS= read -r branch; do
  [[ -n "$branch" && "$branch" != "$DEFAULT" ]] || continue
  if git -C "$VAULT" merge-base --is-ancestor "$branch" "$DEFAULT" 2>/dev/null &&
     git -C "$VAULT" branch -d "$branch" >/dev/null 2>&1; then
    DELETED+=("$branch")
  else
    KEPT+=("$branch")
  fi
done < <(git -C "$VAULT" for-each-ref --format='%(refname:short)' 'refs/heads/brain/*' 2>/dev/null)

# --- 6. report ---------------------------------------------------------------
summary="on '$DEFAULT' ($FF_NOTE); deleted ${#DELETED[@]} merged brain/* branch(es)"
[[ ${#KEPT[@]} -gt 0 ]] && summary="$summary, kept ${#KEPT[@]} unmerged"
echo "REAP: OK - $summary"
[[ "$SWITCHED_FROM" != "$DEFAULT" ]] && echo "  switched from '$SWITCHED_FROM'"
if [[ ${#DELETED[@]} -gt 0 ]]; then
  echo "  deleted (already merged into '$DEFAULT'):"
  printf '    %s\n' "${DELETED[@]}"
fi
if [[ ${#KEPT[@]} -gt 0 ]]; then
  echo "  KEPT — not merged into '$DEFAULT' (or 'git branch -d' refused), so the work is intact:"
  # One line per kept branch, so unmerged work is a finding rather than a name in a
  # list (INNOV-309: two kept branches in one vault held 9 trusted notes and a log
  # that had reached main by no other route, and nothing ever said so). "Absent"
  # means a path the branch changed does not exist on the default branch at all.
  # One absent path is enough to flag: the real case added new notes AND edited
  # wiki/index.md, which exists, so "all absent" would have missed it.
  for branch in "${KEPT[@]}"; do
    ahead="$(git -C "$VAULT" rev-list --count "$DEFAULT..$branch" 2>/dev/null || echo 0)"
    behind_b="$(git -C "$VAULT" rev-list --count "$branch..$DEFAULT" 2>/dev/null || echo 0)"
    total=0
    absent=0
    # quotepath=off: a quoted non-ASCII name would never match and read as absent.
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      total=$((total + 1))
      git -C "$VAULT" cat-file -e "$DEFAULT:$path" 2>/dev/null || absent=$((absent + 1))
    done < <(git -C "$VAULT" -c core.quotepath=off diff --name-only "$DEFAULT...$branch" 2>/dev/null)
    if [[ $total -eq 0 ]]; then
      paths="no changed paths"
    elif [[ $absent -eq 0 ]]; then
      paths="paths present on $DEFAULT"
    else
      paths="paths absent from $DEFAULT ($absent of $total)"
    fi
    line="    $branch: ${ahead//[^0-9]/} unmerged commit(s), ${behind_b//[^0-9]/} behind $DEFAULT, $paths"
    if [[ "$branch" == "$SWITCHED_FROM" ]]; then
      # This save's own branch is normally kept: its commit has not landed yet, and
      # its new log is always absent. Tagged, not flagged, or every save cries wolf.
      line="$line (this save's branch, not landed yet)"
    elif [[ $absent -gt 0 ]]; then
      line="$line — POSSIBLE LOST WORK: it reached '$DEFAULT' by no other route"
    fi
    # Pushed? Say where the work is. The PR lookup is best-effort: no gh, no auth,
    # offline or a non-GitHub remote all just drop the PR half of the note.
    upstream="$(git -C "$VAULT" for-each-ref --format='%(upstream:short)' "refs/heads/$branch" 2>/dev/null)"
    if [[ -n "$upstream" ]] && git -C "$VAULT" rev-parse --verify --quiet "refs/remotes/$upstream" >/dev/null 2>&1; then
      line="$line; pushed to $upstream"
      pr=""
      if command -v gh >/dev/null 2>&1; then
        pr="$(cd "$VAULT" 2>/dev/null && gh pr list --head "$branch" --state open               --json url --jq '.[0].url' 2>/dev/null || true)"
        pr="${pr//[[:space:]]/}"
      fi
      [[ -n "$pr" ]] && line="$line, open PR $pr"
    fi
    echo "$line"
  done
  echo "  Usually that means the branch is not fully merged yet; it also covers a"
  echo "  branch checked out in another worktree, which git will not delete either."
  echo "  Nothing was deleted from those branches. They land the usual way (a PR, or [[promote]])."
fi
exit 0
