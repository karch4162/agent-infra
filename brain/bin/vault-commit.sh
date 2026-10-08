#!/usr/bin/env bash
# vault-commit.sh — THE single guarded commit path into a brain vault.
#
# Every command that commits to the vault goes through here: /brain:save step 6,
# bin/sync-graph.sh, and anything added later. Nothing else may run `git commit`
# against a vault.
#
# WHY THIS EXISTS (INNOV-275). The guards were on the wrong side. sync-graph.sh
# carried six references' worth of protected-branch and HEAD-pin checking, while
# /brain:save step 6 — the path that actually put a commit on a protected `main`
# on 2026-08-05 — ran raw `git add` / `git commit` with no guard at all. Re-run
# that incident against the hardened helper and the helper refuses, then the
# agent commits to `main` by hand one step later. Hardening a helper does not
# harden the vault; hardening the ONLY commit path does. This is the INNOV-274
# pattern — one rule, one implementation, every caller — applied to commits.
#
# The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
# falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in
# the plugin, NOT inside the vault, so it cannot derive the vault from its own
# location.
#
# Usage:
#   BRAIN_ROOT=<vault> bash vault-commit.sh -m "msg"                  # stage the whole allowlist, commit
#   BRAIN_ROOT=<vault> bash vault-commit.sh -m "msg" logs/ wiki/log.md   # stage a SUBSET of it
#   BRAIN_ROOT=<vault> bash vault-commit.sh -m "msg" --pin "main:abc123" # verify HEAD hasn't moved
#   BRAIN_ROOT=<vault> bash vault-commit.sh -m "msg" --force-commit      # commit onto a branch with an open PR
#   BRAIN_ROOT=<vault> bash vault-commit.sh --print-allowlist            # what would be staged, one per line
#   BRAIN_ROOT=<vault> bash vault-commit.sh -m "msg" --pin "br:sha" --pr-paths wiki/a/x.md wiki/index.md
#                                                                         # PR-bound commit of named paths
#
#   -m, --message MSG   commit message (required unless --print-allowlist)
#   --pin BRANCH:SHA    the vault's branch + SHA as the CALLER saw them at start.
#                       Refuses if either moved. See "HEAD PIN" below.
#   --force-commit      overrides the OPEN-PR guard ONLY. It does NOT override the
#                       protected-branch guard or the HEAD pin — see below.
#   --print-allowlist   print THIS VAULT's resolved allowlist entries and exit 0.
#   --pr-paths          the path arguments are paths OUTSIDE the allowlist, named
#                       one by one, for a commit that ships as a PR. See
#                       "PR-BOUND COMMITS" below. Requires --pin.
#   --print-required    print the paths shipped brain commands commit, TSV
#                       "<path>\t<which command needs it>", and exit 0. Needs no
#                       vault — it is a property of the plugin, not of a vault.
#
# THE REQUIRED SET (INNOV-278). A vault whose .saveinclude omits a path that a
# shipped command commits is broken in a quiet way: the command does its file
# work, then this script refuses to commit it. That is exactly what the 0.2.22
# upgrade did to every vault created before it — `graphify/` had never needed to
# be allowlisted, because sync-graph.sh used to run its own `git add`.
#
# So the required set lives HERE, next to the enforcement, and `/brain:doctor`
# reads it rather than keeping its own copy. A second list in the doctor skill
# is the INNOV-274 defect — one rule, two implementations, drifting apart — and
# it would drift in the most useless direction possible: the checker would go
# stale exactly when a new committed path made the check matter.
#
# Adding a path a shipped command commits? Add it here. tests/test-vault-commit.sh
# asserts that every path sync-graph.sh passes to this script appears below, so
# forgetting fails the suite rather than shipping a checker that cannot see it.
#
# Contract (callers and tests depend on exactly this):
#   exit 0  => committed, or there was nothing to commit (both say which on stdout)
#   exit 1  => REFUSED, nothing was committed and nothing this run staged is left
#              staged (see "NOTHING IS STAGED ON A REFUSAL" for the limits)
# The FIRST line of output always starts with "VAULT-COMMIT: OK" (stdout) or
# "VAULT-COMMIT: REFUSED" (stderr), so a caller can branch on it without parsing
# prose.
#
# THE ALLOWLIST. `.saveinclude` at the vault root is the whole permission model:
# one path or glob per line, `#` comments and blanks ignored. Two things happen
# with it, and the second is the one that matters:
#   1. Staging  — only allowlisted entries are staged (never `git add -A`).
#   2. VERIFICATION — before staging and again after, every path in the index is
#      checked against the allowlist, and a single path outside it REFUSES.
# Step 2 is not redundant with step 1. The git index is GLOBAL to the checkout:
# a concurrent session, an aborted merge, or a human running `git add` can leave
# anything at all staged, and step 1 alone would happily sweep it into this
# commit. Verifying the index is what makes "no command commits anything outside
# .saveinclude" a property of the tool rather than an intention.
#
# NO .saveinclude => REFUSE. A vault without an allowlist has no permission model,
# and defaulting to "commit everything" in that case would publish `chats/` the
# first time someone forgot the file. Fail closed; the remedy is one file and the
# refusal prints it.
#
# PROTECTED-BRANCH GUARD: never commits onto the repo's default/protected branch.
# The default branch is detected from origin/HEAD, then `gh repo view`, and
# finally by treating the literal names main/master as protected — the last one
# is the safety net, so a vault with no remote and no `gh` still refuses.
# THIS GUARD HAS NO OVERRIDE. sync-graph.sh's --force-commit used to bypass it;
# INNOV-275 retires that. "I want to commit straight onto main" is not a thing
# the tooling should offer a flag for — a human who genuinely means it can run
# git by hand and own it, which is a different act from a script doing it.
#
# OPEN-PR GUARD: if the vault's current branch has an open PR (per `gh`), the
# commit is refused rather than piling onto a branch under review (a prior run
# put 607 files onto a branch mid-review). --force-commit overrides this one:
# unlike the two below, "yes, add to my own open PR" is a coherent intent. If
# `gh` is missing, unauthenticated, or errors, the guard is skipped and the
# commit proceeds — a vault with no GitHub remote keeps working.
#
# HEAD PIN: a caller that did work before committing passes the branch + SHA it
# saw when it started. If either moved, the commit is refused — a moved HEAD
# means a concurrent session checked out or merged something underneath the run,
# so the commit would land on a branch its author never selected. That is exactly
# the 2026-08-05 incident. --force-commit does NOT override this: --force-commit
# means "I know about the open PR and want it anyway", but a moved HEAD makes the
# caller's intent genuinely unknown — there is nothing to force.
#
# PR-BOUND COMMITS (--pr-paths, INNOV-363). Trusted notes (wiki/<area>/*.md) are
# off .saveinclude by design: they reach the vault's default branch only through
# a reviewed PR. /brain:promote, /brain:tidy and /brain:verify commit them onto a
# working branch for that PR, and before this mode they did it with raw git and
# re-implemented the guards in prose — the INNOV-274 shape again. --pr-paths
# swaps the allowlist for the caller's explicit list and keeps every other guard:
#   - --pin is REQUIRED, and the protected-branch guard applies unchanged. Neither
#     has an override; the open-PR guard is exactly as above.
#   - the index must be EMPTY before anything is staged: the commit carries what
#     the caller named and nothing another session left in the shared index.
#   - each named path must be one literal FILE (no glob, no directory), inside
#     the vault, not under chats/, not gitignored (tracked or not), and either
#     present or tracked, so a named deletion (a dropped or moved draft) stages.
#   - after staging, every path in the index must be one of the named paths.
#   - named paths with no change REFUSE (exit 1), unlike the default mode's
#     "nothing to commit" exit 0: the caller is about to open a PR for them.
#
# NOTHING IS STAGED ON A REFUSAL (INNOV-375). The shared index is never written
# before the commit lands. The run copies it to a private index under the vault's
# .git/ and checks what is already staged there (the refusals above), then resets
# that copy to HEAD, stages into it, and commits the verified TREE OBJECT with
# `git commit-tree`. The commit is exactly the tree that was checked: HEAD plus
# what this run staged from the working tree. Nothing from the shared index, a
# path another session stages mid-run or a stale entry, can reach it. The branch
# moves by compare-and-swap (`git update-ref <ref> <new> <old>`), after a last
# check that HEAD still points at that ref, so a moved HEAD refuses. Every
# refusal leaves the shared index as it was.
# After the ref moves, the committed paths are reset to the new commit in the
# shared index; every other staged path is left alone. The limits:
#   - a path another session pre-staged is committed only if it falls under an
#     entry this run stages, and then with its working-tree content. Before
#     INNOV-375 `git commit` swept in every pre-staged allowlisted path.
#   - a branch checkout between the last HEAD check and `update-ref` (a few
#     milliseconds) still lands the commit on the ref the run was pinned to.
#   - a committed path another session re-stages before the sync is reset to
#     the committed version. The sync is skipped once HEAD moves past this
#     commit; a commit landing in the milliseconds between that check and the
#     reset still gets a staged revert of its paths.
#   - if the sync cannot take the index lock within ~15 s, the commit stands, and
#     the output's last lines print the runnable command that brings the shared
#     index back in line (reap-branches.sh prints it too if the switch refuses).
# `commit-tree` runs no hooks and signs only with -S, so step 8 runs the
# pre-commit and commit-msg hooks itself (a secret scanner on core.hooksPath
# must still see the commit) and passes commit.gpgsign on by hand.
set -uo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# detect_default_branch() and branch_is_protected() live in lib/branch.sh, shared
# verbatim with bin/session.sh — which applies the same protected-branch rule at
# command START, so the work happens on a working branch from the first file write
# instead of being discovered here an hour of edits later. Two copies of this rule
# would be the INNOV-274 defect: a start-time check and a commit-time check that
# disagree about "protected" means a command that starts somewhere it can never
# commit from. The path is resolved from this script's own location, so it works
# from any cwd. The lib reads $VAULT, which is why it is sourced after it is set.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/branch.sh
. "$BIN_DIR/lib/branch.sh"
# shellcheck source=lib/allowlist.sh
. "$BIN_DIR/lib/allowlist.sh"

MESSAGE=""
unset PIN   # unset = no --pin; set-but-empty (--pin "") is malformed, never "unpinned"
FORCE_COMMIT=0
PR_MODE=0
PRINT_ALLOWLIST=0
PRINT_REQUIRED=0
PATHS=()

# The paths shipped brain commands commit — the single source of truth, read by
# /brain:doctor's allowlist check. See "THE REQUIRED SET" in the header before
# editing. Format: "<path>\t<which command needs it, and why>".
REQUIRED=(
  $'logs/\t/brain:save — the dated session log'
  $'wiki/hot.md\t/brain:save — the rolling session cache'
  $'wiki/log.md\t/brain:save and bin/sync-graph.sh — the append-only operation log'
  $'graphify/\tbin/sync-graph.sh — the mirrored code graphs, one folder per covered repo'
  $'graphify-out/graph.json\t/brain:save step 5c — the vault-s own wiki concept graph'
  $'graphify-out/GRAPH_REPORT.md\t/brain:save step 5c — the wiki graph report'
  $'graphify-out/communities/\t/brain:save step 5c — wiki graph community stubs'
)

refuse() { # reason-line, then extra lines
  {
    echo "VAULT-COMMIT: REFUSED - $1"
    shift
    local line
    for line in "$@"; do echo "$line"; done
  } >&2
  exit 1
}

# --- 0. arguments -----------------------------------------------------------
# Flags may appear anywhere, including after the path arguments, because callers
# build these argv lists programmatically and argument order is a silly thing to
# have to get right. `--` explicitly ends flag parsing.
END_OF_FLAGS=0
while [[ $# -gt 0 ]]; do
  if [[ $END_OF_FLAGS -eq 1 ]]; then PATHS+=("$1"); shift; continue; fi
  case "$1" in
    -m|--message)      MESSAGE="${2:-}"; shift 2 || refuse "--message needs a value" ;;
    --message=*)       MESSAGE="${1#*=}"; shift ;;
    --pin)             PIN="${2:-}"; shift 2 || refuse "--pin needs a value" ;;
    --pin=*)           PIN="${1#*=}"; shift ;;
    --force-commit)    FORCE_COMMIT=1; shift ;;
    --pr-paths)        PR_MODE=1; shift ;;
    --print-allowlist) PRINT_ALLOWLIST=1; shift ;;
    --print-required)  PRINT_REQUIRED=1; shift ;;
    --)                END_OF_FLAGS=1; shift ;;
    -*)                refuse "unknown flag '$1'" "  See the usage block at the top of vault-commit.sh." ;;
    *)                 PATHS+=("$1"); shift ;;
  esac
done

# --print-required is answered BEFORE any vault check: it describes the plugin,
# not a vault, so /brain:doctor can ask what the required set is on a machine
# with no vault bound at all — which is precisely the machine most likely to be
# misconfigured.
if [[ $PRINT_REQUIRED -eq 1 ]]; then
  printf '%s\n' "${REQUIRED[@]}"
  exit 0
fi

if [[ $PRINT_ALLOWLIST -eq 0 && -z "$MESSAGE" ]]; then
  refuse "no commit message" "  Pass -m \"<message>\"."
fi

# --- 1. is this a vault, and is it a git repo? ------------------------------
if [[ ! -d "$VAULT/graphify" && ! -d "$VAULT/wiki" ]]; then
  refuse "'$VAULT' doesn't look like a brain vault (no graphify/ or wiki/)" \
    "  Set BRAIN_ROOT to the vault root."
fi
if ! git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
  refuse "'$VAULT' is not a git repo, so there is nothing to commit to" \
    "  Set BRAIN_ROOT to the vault root, or run 'git init' there."
fi

# --- 2. the allowlist -------------------------------------------------------
# Missing or empty => REFUSE. See the header: a vault with no allowlist has no
# permission model, and there is no safe default to fall back to.
SAVEINCLUDE="$VAULT/.saveinclude"
# allowlist_load (lib/allowlist.sh) is the one parse, shared with land-save.sh.
if ! allowlist_load "$SAVEINCLUDE"; then
  refuse "no readable .saveinclude at '$SAVEINCLUDE'" \
    "  .saveinclude is the vault's whole permission model: it is the list of paths" \
    "  a command may commit. Without it there is no safe default — committing" \
    "  everything would publish private content (chats/), committing nothing would" \
    "  make every save a silent no-op. So this is a refusal, not a fallback." \
    "  Remedy: copy the template into the vault root:" \
    "    cp \"\${CLAUDE_PLUGIN_ROOT}/templates/saveinclude\" \"$SAVEINCLUDE\""
fi

if [[ ${#ALLOW[@]} -eq 0 ]]; then
  refuse "'.saveinclude' has no entries (only comments/blank lines)" \
    "  An empty allowlist permits nothing, so every commit through this path would" \
    "  be a no-op. List the paths /brain:save may commit, one per line."
fi

if [[ $PRINT_ALLOWLIST -eq 1 ]]; then
  printf '%s\n' "${ALLOW[@]}"
  exit 0
fi

# path_is_allowed / path_is_allowed_by come from lib/allowlist.sh.

# --- 3. what are we staging? ------------------------------------------------
# --pr-paths: the caller's named list replaces the allowlist, and is checked here
# before any guard or git write. '..' is refused outright, or wiki/../chats/x
# would walk past the chats/ check.
if [[ $PR_MODE -eq 1 ]]; then
  [[ -n "${PIN+set}" ]] || refuse "--pr-paths needs --pin BRANCH:SHA"     "  A PR-bound commit is always pinned: pass session.sh --start's pin: value."
  [[ ${#PATHS[@]} -gt 0 ]] || refuse "--pr-paths names no path"     "  Name each path to commit. --pr-paths never falls back to the allowlist."
  bad=()
  for i in "${!PATHS[@]}"; do
    p="${PATHS[$i]#./}"; p="${p%/}"; PATHS[$i]="$p"
    case "/$p/" in
      //|/./|*/../*|/chats/*) bad+=("$p (outside the vault, or under chats/)"); continue ;;
    esac
    [[ "$p" == /* || "$p" == [A-Za-z]:* ]] && { bad+=("$p (absolute)"); continue; }
    # One literal file each: a glob or a directory would sweep unnamed edits
    # (unreviewed drafts, repos.json) into the PR and still pass step 6.
    case "$p" in *[\*\?\[]*|:*) bad+=("$p (a pattern, not a file)"); continue ;; esac
    [[ -d "$VAULT/$p" ]] && { bad+=("$p (a directory, not a file)"); continue; }
    # A path that neither exists nor is tracked is a typo. Catch it here, or
    # step 5 fails midway and leaves the earlier paths staged.
    [[ -e "$VAULT/$p" ]] || git -C "$VAULT" ls-files --error-unmatch -- ":(literal)$p" >/dev/null 2>&1 ||
      { bad+=("$p (no such file, and not tracked)"); continue; }
    # --no-index: a tracked file under a newer ignore rule is still private.
    git -C "$VAULT" check-ignore -q --no-index -- "$p" 2>/dev/null && bad+=("$p (gitignored)")
  done
  if [[ ${#bad[@]} -gt 0 ]]; then
    refuse "--pr-paths names path(s) a vault commit may never carry"       "$(printf '    %s
' "${bad[@]}")"       "  Name each file literally. chats/ and gitignored paths are private by"       "  design. Nothing was staged."
  fi
  ALLOW=("${PATHS[@]}")   # from here on, "allowed" means "named by the caller"
# No path arguments => the whole allowlist. Path arguments => a SUBSET of it, and
# each one must itself be covered by the allowlist. A caller asking to stage a
# path the vault does not permit is a bug in the caller, not a thing to silently
# drop: dropping it would make the caller's commit quietly incomplete.
elif [[ ${#PATHS[@]} -eq 0 ]]; then
  PATHS=("${ALLOW[@]}")
else
  outside=()
  for p in "${PATHS[@]}"; do
    p="${p#./}"; p="${p%/}"
    path_is_allowed "$p" || path_is_allowed "$p/" || outside+=("$p")
  done
  if [[ ${#outside[@]} -gt 0 ]]; then
    refuse "asked to stage path(s) that '.saveinclude' does not allow: ${outside[*]}" \
      "  The caller requested these explicitly, so they are not silently skipped." \
      "  Either add them to $SAVEINCLUDE, or fix the caller." \
      "  Allowed: ${ALLOW[*]}"
  fi
fi

# --- 4. branch guards (ALL of them run before anything is staged) -----------
# REF is the ref the commit moves, and the branch and SHA every guard below
# judges are both derived from it, in one snapshot. Not `HEAD`: update-ref HEAD
# follows whatever HEAD points at by then, so a checkout during the guards (the
# `gh` call takes seconds) would move a branch none of them evaluated.
REF="$(git -C "$VAULT" symbolic-ref -q HEAD 2>/dev/null || echo HEAD)"
CUR_BRANCH="${REF#refs/heads/}"
CUR_SHA="$(git -C "$VAULT" rev-parse -q --verify "$REF^{commit}" 2>/dev/null || true)"

# HEAD PIN. Format BRANCH:SHA, as the caller saw it before it started working.
# A malformed pin is a REFUSAL, not an ignored argument — a caller that meant to
# pin and typo'd the format must not silently get an unpinned commit.
if [[ -n "${PIN+set}" ]]; then
  pin_branch="${PIN%%:*}"
  pin_sha="${PIN#*:}"
  # Whitespace can't appear in a ref or a sha, so it means the caller passed more
  # than the pin — e.g. session.sh --print-pin's whole banner (INNOV-315), whose
  # colons slip past *:* and would otherwise be misreported as a moved HEAD.
  if [[ "$PIN" != *:* || -z "$pin_branch" || -z "$pin_sha" || "$PIN" == *[[:space:]]* ]]; then
    refuse "--pin '$PIN' is not in BRANCH:SHA form" \
      "  A pin that cannot be parsed is treated as a failure, never as 'unpinned'." \
      "  From session.sh --print-pin, pass only the value of its '  pin:' line."
  fi
  if [[ "$pin_branch" != "$CUR_BRANCH" || "$pin_sha" != "$CUR_SHA" ]]; then
    refuse "the vault's HEAD moved while this command was running" \
      "  branch then: ${pin_branch:-?}   branch now: ${CUR_BRANCH:-?}" \
      "  sha then:    ${pin_sha:-?}   sha now:    ${CUR_SHA:-?}" \
      "  Another session changed branches or merged underneath this run, so the" \
      "  commit would land somewhere its author never selected. Nothing was staged." \
      "  Re-check the branch, then re-run the command." \
      "  --force-commit does NOT override this guard: a moved HEAD makes your" \
      "  intent unknown rather than forceable."
  fi
fi

# branch_is_protected() comes from lib/branch.sh, sourced at the top.
if branch_is_protected "$CUR_BRANCH"; then
  refuse "'$CUR_BRANCH' is the protected/default branch" \
    "  Nothing was staged and nothing was committed." \
    "  Create a working branch first, then re-run:" \
    "    git -C \"$VAULT\" checkout -b brain/<what-this-is>" \
    "  Or start the command through bin/session.sh --start, which picks a working" \
    "  branch up front so this never comes up at commit time." \
    "  There is no flag to override this. If you genuinely mean to commit straight" \
    "  onto '$CUR_BRANCH', do it with git by hand — that is a human decision, not" \
    "  something the tooling should offer."
fi

# Prints the number of the open PR whose head is the vault's CURRENT branch, or
# nothing at all when there is no such PR *or* when we simply cannot tell (gh
# missing, unauthenticated, no remote, API error). This is a safety net, not a
# hard dependency: "unknown" must look exactly like "no PR" so a vault with no
# GitHub remote keeps committing as it always has.
open_pr_for_current_branch() {
  local pr
  command -v gh >/dev/null 2>&1 || return 0
  [[ -n "$CUR_BRANCH" && "$CUR_BRANCH" != "HEAD" ]] || return 0
  pr="$(cd "$VAULT" 2>/dev/null && gh pr list --state open --head "$CUR_BRANCH" \
        --json number --jq '.[0].number' 2>/dev/null || true)"
  pr="${pr//[^0-9]/}"
  [[ -n "$pr" ]] && echo "$pr"
  return 0
}

if [[ $FORCE_COMMIT -eq 0 ]]; then
  OPEN_PR="$(open_pr_for_current_branch)"
  if [[ -n "$OPEN_PR" ]]; then
    refuse "branch '$CUR_BRANCH' has open PR #$OPEN_PR" \
      "  Nothing was staged and nothing was committed." \
      "  Piling a mechanical commit onto a branch under review makes the review" \
      "  meaningless. Either merge the PR first, or re-run with --force-commit if" \
      "  you deliberately want this in that PR."
  fi
fi

[[ -n "$CUR_SHA" ]] || refuse "'${CUR_BRANCH:-HEAD}' has no commit yet" \
  "  /brain:init commits the vault scaffold first; commit that by hand, then re-run."

# --- 5. the private index ---------------------------------------------------
# See "NOTHING IS STAGED ON A REFUSAL" in the header. Under .git/ so it is on the
# same filesystem and never in the working tree; removed on every exit path.
GIT_DIR_ABS="$(git -C "$VAULT" rev-parse --absolute-git-dir)" ||
  refuse "could not resolve the vault's .git directory"
PRIVATE_INDEX="$(mktemp "$GIT_DIR_ABS/vault-commit-index.XXXXXX")" ||
  refuse "could not create a private index under '$GIT_DIR_ABS'"
trap 'rm -f "$PRIVATE_INDEX" "$PRIVATE_INDEX.lock" "$PRIVATE_INDEX.msg"' EXIT
git_private() { GIT_INDEX_FILE="$PRIVATE_INDEX" git -C "$VAULT" "$@"; }
UNTOUCHED="  Nothing was committed, and the shared index was not touched."
if [[ -f "$GIT_DIR_ABS/index" ]]; then
  cp "$GIT_DIR_ABS/index" "$PRIVATE_INDEX" || refuse "could not copy the shared index"
else # a zero-byte file is a corrupt index, not an empty one
  rm -f "$PRIVATE_INDEX"
  git_private read-tree HEAD || refuse "could not read HEAD into a private index"
fi

# Every path staged in the private index, NUL-separated so a non-ASCII name comes
# back verbatim rather than octal-quoted. --no-renames: a staged rename lists its
# source too, or a rename out of chats/ reads as its allowlisted destination alone.
# Fills the array named by $1, bash 3.2 style.
read_index() { # array-name
  local _p
  eval "$1=()"
  while IFS= read -r -d '' _p; do
    eval "$1+=(\"\$_p\")"
  done < <(git_private diff --cached --name-only --no-renames -z 2>/dev/null)
}

refuse_foreign() { # last line, then the paths
  local last="$1"; shift
  refuse "the index contains $# path(s) that '.saveinclude' does not allow" \
    "$(printf '    %s\n' "$@")" \
    "  These were already staged before this command ran — the git index is shared" \
    "  by every session using this checkout, so another session (or a stray" \
    "  'git add') can put anything in it. Committing now would publish them." \
    "  Nothing was committed, and nothing of theirs was unstaged: unstaging another" \
    "  session's work would be its own kind of damage." \
    "$last" \
    "  Remedy: review them, then either" \
    "    git -C \"$VAULT\" restore --staged <path>      # drop from the index" \
    "  or add the path to $SAVEINCLUDE if it belongs in vault commits."
}

# The copy is checked BEFORE staging (INNOV-369), so a refusal names what was
# already staged rather than what this run added. PR mode: it must be empty.
# Default mode: it may hold only allowlisted paths, the rule step 7 applies.
PRE_STAGED=()
read_index PRE_STAGED
if [[ $PR_MODE -eq 1 && ${#PRE_STAGED[@]} -gt 0 ]]; then
  refuse "the shared index already holds staged paths" \
    "$(printf '    %s\n' "${PRE_STAGED[@]}")" \
    "  A PR-bound commit carries only the paths it names. Nothing was staged," \
    "  and nothing was unstaged: that work belongs to whoever staged it."
fi
foreign=()
for p in "${PRE_STAGED[@]:-}"; do
  [[ -n "$p" ]] && ! path_is_allowed "$p" && foreign+=("$p")
done
if [[ ${#foreign[@]} -gt 0 ]]; then
  refuse_foreign "  This run staged nothing: the check runs before the first 'git add'." "${foreign[@]}"
fi
# Now base the private index on HEAD, so the commit is HEAD plus what this run
# stages and nothing from the shared index, stale or not, can reach it. A
# pathspec reset keeps the stat cache for unchanged entries; `read-tree -m`
# would too, but refuses a stale entry ("not uptodate") and wedge every save.
if ! reset_err="$(git_private reset -q "$CUR_SHA" -- . 2>&1)"; then
  refuse "could not reset the private index to HEAD" "$(printf '    %s\n' "$reset_err")" "$UNTOUCHED"
fi

# --- 6. stage, into the private index ---------------------------------------
# Entries that match nothing in the working tree are skipped rather than passed
# to `git add` (which errors on a pathspec that matches no file). An allowlist
# naming a path the vault does not have yet is normal — a fresh vault has no
# graphify-out/ — and must not fail a save.
#
# `compgen -G` alone is NOT an existence test: with no glob metacharacters it
# falls back to word expansion and echoes the entry back verbatim, so every
# plain path "matches". Hence the -e filter over its results, which is the real
# test and also handles the glob case correctly.
entry_exists() { # vault-relative entry
  local entry="${1%/}" m
  # shellcheck disable=SC2206  # deliberate glob expansion of the entry
  local matches=( $(cd "$VAULT" 2>/dev/null && compgen -G "$entry" 2>/dev/null) )
  for m in "${matches[@]:-}"; do
    [[ -n "$m" && -e "$VAULT/$m" ]] && return 0
  done
  return 1
}

staged_any=0
for entry in "${PATHS[@]}"; do
  # PR mode stages a named deletion too; git add refuses a path that never existed.
  [[ $PR_MODE -eq 1 ]] || entry_exists "$entry" || continue
  spec="$entry"; [[ $PR_MODE -eq 1 ]] && spec=":(literal)$entry"
  if ! add_err="$(git_private add -- "$spec" 2>&1)"; then
    refuse "'git add -- $entry' failed" \
      "$(printf '    %s\n' "$add_err")" \
      "  Common cause: every file under that path is gitignored." \
      "$UNTOUCHED"
  fi
  staged_any=1
done

# --- 7. pre-commit, then VERIFY THE TREE ------------------------------------
# Hooks run as `git commit` runs them: from the vault root, against the index
# being committed (here the private one). core.hooksPath is honoured through
# --git-path. Called directly rather than via `git hook run` (git 2.36+).
# pre-commit runs BEFORE write-tree, so what it stages is in the tree verified
# below, and a path it stages outside the allowlist is refused there.
HOOKS_DIR="$(cd "$VAULT" && cd "$(git rev-parse --git-path hooks)" 2>/dev/null && pwd)"
run_hook() { # name [args...]
  local hook="$HOOKS_DIR/$1" out; shift
  [[ -n "$HOOKS_DIR" && -x "$hook" ]] || return 0
  if ! out="$(cd "$VAULT" && GIT_INDEX_FILE="$PRIVATE_INDEX" "$hook" "$@" 2>&1)"; then
    refuse "the $(basename "$hook") hook rejected the commit" "$(printf '    %s\n' "$out")" "$UNTOUCHED"
  fi
}
[[ $staged_any -eq 1 ]] && run_hook pre-commit

# The tree object is what step 8 commits, byte for byte, so this checks the
# commit itself rather than an index another process can still change.
if ! TREE="$(git_private write-tree 2>&1)"; then
  refuse "git write-tree failed" "$(printf '    %s\n' "$TREE")" "$UNTOUCHED"
fi
STAGED=()
while IFS= read -r -d '' p; do
  STAGED+=("$p")
done < <(git -C "$VAULT" diff-tree -r -z --name-only --no-renames "$CUR_SHA" "$TREE" 2>/dev/null)

if [[ ${#STAGED[@]} -eq 0 ]]; then
  # PR mode: the caller named edits it expects to ship. Exit 0 here would let it
  # push and open a PR without them.
  [[ $PR_MODE -eq 1 ]] && refuse "the named path(s) have no changes to commit: ${PATHS[*]}"     "  Nothing was staged and nothing was committed. Check the edits landed."
  if [[ $staged_any -eq 0 ]]; then
    echo "VAULT-COMMIT: OK - nothing to commit (no allowlisted path has changes)"
  else
    echo "VAULT-COMMIT: OK - nothing to commit (allowlisted paths are unchanged)"
  fi
  exit 0
fi

violations=()
for path in "${STAGED[@]}"; do
  path_is_allowed "$path" || violations+=("$path")
done
# The copy was checked before staging, so a hit here came in through staging.
if [[ ${#violations[@]} -gt 0 ]]; then
  refuse_foreign "$UNTOUCHED" "${violations[@]}"
fi

# --- 7b. governance: brain.json's area tiers and denied patterns (INNOV-297) --
# The allowlist above says which PATHS may be committed; this says whether their
# CONTENT belongs in this vault. Judged on the same tree object, against the
# stricter of the parent's and the tree's brain.json. Its OK line is swallowed so
# this script's first line stays VAULT-COMMIT; any failure to run it refuses.
if ! gov_out="$(printf '%s\0' "${STAGED[@]}" |
     BRAIN_ROOT="$VAULT" node "$BIN_DIR/check-governance.mjs" --policy "$CUR_SHA" --tree "$TREE" 2>&1)"; then
  refuse "brain.json's governance policy refuses this commit" \
    "$(printf '%s\n' "$gov_out" | sed 's/^/    /')" "$UNTOUCHED"
fi

# --- 8. commit, then move the branch by compare-and-swap --------------------
# `git commit -m` cleans whitespace; commit-tree takes the message verbatim.
printf '%s\n' "$MESSAGE" >"$PRIVATE_INDEX.msg"
run_hook commit-msg "$PRIVATE_INDEX.msg"
MESSAGE="$(git stripspace <"$PRIVATE_INDEX.msg")"
[[ -n "$MESSAGE" ]] || refuse "the commit message is only whitespace"
# commit-tree signs only when asked, so carry commit.gpgsign over by hand: a
# vault that requires signed commits must refuse, as `git commit` does.
SIGN=""
[[ "$(git -C "$VAULT" config --type=bool commit.gpgsign 2>/dev/null)" == true ]] && SIGN="-S"
if ! NEW="$(git -C "$VAULT" commit-tree ${SIGN:+"$SIGN"} "$TREE" -p "$CUR_SHA" -m "$MESSAGE" 2>&1)"; then
  refuse "git commit-tree failed" "$(printf '    %s\n' "$NEW")" "$UNTOUCHED"
fi
# The CAS below checks the ref, not where HEAD points. A checkout to another
# branch at the same SHA would pass it and land this commit on a branch the
# checkout already left, so re-check HEAD as late as possible.
if [[ "$(git -C "$VAULT" symbolic-ref -q HEAD 2>/dev/null || echo HEAD)" != "$REF" ]]; then
  refuse "the vault's HEAD moved while this command was running" \
    "  HEAD was $REF, and is now $(git -C "$VAULT" symbolic-ref -q HEAD 2>/dev/null || echo 'detached')." \
    "  Another session changed branches underneath this run." \
    "$UNTOUCHED" \
    "  Re-check the branch, then re-run the command."
fi
if ! cas_err="$(git -C "$VAULT" update-ref -m "commit: ${MESSAGE%%$'\n'*}" "$REF" "$NEW" "$CUR_SHA" 2>&1)"; then
  refuse "the vault's HEAD moved while this command was running" \
    "  ref: $REF" \
    "  sha then: $CUR_SHA   sha now: $(git -C "$VAULT" rev-parse -q --verify "$REF" 2>/dev/null || echo '?')" \
    "$(printf '    %s\n' "$cas_err")" \
    "  Another session committed to or reset the branch underneath this run." \
    "$UNTOUCHED" \
    "  Re-check the branch, then re-run the command."
fi

echo "VAULT-COMMIT: OK - committed ${#STAGED[@]} path(s) on '$CUR_BRANCH'"
printf '  %s\n' "${STAGED[@]}"

# --- 9. bring the shared index in line, for the committed paths only --------
# Until this runs, the shared index holds the pre-commit blobs for them, so
# `git status` shows them as staged reverts. No vault commit can carry those
# (step 5 bases on HEAD), but a raw `git commit` would. Retried for ~15 s: the
# lock is usually held for milliseconds, but an editor's git watcher can hold it
# for seconds right after a commit, and 0/1/2 s lost to one (INNOV-377). Each
# try first checks that HEAD is still this
# commit: once another commit lands on top, resetting to this one would stage a
# revert of it, and that commit's own sync owns the index.
# Returns 0 synced, 1 failed (lock), 2 skipped (HEAD is no longer this commit).
# A failure keeps git's stderr in SYNC_ERR for the WARNING below: discarded, a
# held index.lock could not be told from anything else (INNOV-389).
SYNC_ERR=""
sync_index() {
  [[ "$(git -C "$VAULT" symbolic-ref -q HEAD 2>/dev/null || echo HEAD)" == "$REF" &&
     "$(git -C "$VAULT" rev-parse -q --verify HEAD 2>/dev/null)" == "$NEW" ]] || return 2
  SYNC_ERR="$(printf '%s\0' "${STAGED[@]}" | git --literal-pathspecs -C "$VAULT" \
    reset -q "$NEW" --pathspec-from-file=- --pathspec-file-nul 2>&1 >/dev/null)" || return 1
}
# Short polls, not long sleeps: the lock is not held between tries, and every
# gap is a window in which a raw `git commit` would record the staged revert.
# At least 6 tries even when each git call is slow (Windows process spawn).
tries=0
sync_until=$((SECONDS + 15))
while :; do
  sync_index; sync_rc=$?
  tries=$((tries + 1))
  [[ $sync_rc -eq 1 && ( $tries -lt 6 || $SECONDS -lt $sync_until ) ]] || break
  sleep 0.5
done
[[ $sync_rc -eq 2 ]] &&
  echo "  NOTE: HEAD moved past this commit before the index sync; the index was left alone."

# --- 10. the session's recorded pin follows this commit (INNOV-380) ---------
# This commit is the session's own HEAD move, exactly like check-freshness.sh's
# merge (INNOV-285), so a later --print-pin must return $NEW, or a second commit
# in the same save is refused as "HEAD moved". session.sh --repin rewrites the
# pin only when it still records $CUR_SHA, so a foreign move is never adopted.
# Only with an explicit session id: without one session.sh falls back to the
# last-started id, which may be another session that started on the same sha.
# Same precedence as session.sh, whose sanitize_id empties a value with no
# [A-Za-z0-9._] character — and an emptied id falls back the same way.
# Not once the sync saw HEAD move past this commit (sync_rc 2): the pin stays at
# the pre-commit sha, so the next pinned commit refuses that foreign move, and a
# caller repinning before -> HEAD itself (runtime.mjs) is not refused.
sid="${BRAIN_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [[ $sync_rc -ne 2 && "$sid" =~ [A-Za-z0-9._] && -f "$VAULT/.brain/session.json" ]] &&
   ! BRAIN_ROOT="$VAULT" bash "$BIN_DIR/session.sh" --repin "$CUR_SHA" "$NEW" >/dev/null 2>&1; then
  echo "  NOTE: the session pin was NOT updated to this commit (it did not record the"
  echo "        pre-commit sha); a later --print-pin commit will be refused as HEAD moved."
fi
echo "  Push when ready: git -C \"$VAULT\" push"
# Last, so a caller reading only the head or the tail of the output still sees
# it: printed before "Push when ready" it was missed, and the next symptom was
# reap-branches.sh refusing to switch with an unrelated-looking git error.
if [[ $sync_rc -eq 1 ]]; then
  echo "  WARNING: the shared index is locked and still holds the pre-commit versions"
  echo "  of the paths above (shown as staged reverts in git status)."
  echo "  git said: $(printf '%s\n' "$SYNC_ERR" | sed -n '/./{p;q;}' | tr -d '\r')"
  echo "  Run:"
  printf '    git --literal-pathspecs -C %q reset -q HEAD --' "$VAULT"
  printf ' %q' "${STAGED[@]}"
  echo
fi
exit 0
