#!/usr/bin/env bash
# changed-wiki-notes.sh — list the wiki/ notes that ACTUALLY changed, per git.
#
# /brain:save step 5c refreshes the wiki concept graph by dispatching one subagent
# per changed note. Deciding "changed" from graphify's manifest.json massively
# over-reports (a recorded incident flagged 375 wiki files when 10 had really
# changed — ~16 wasted subagents on a routine save), so this script asks git
# instead: uncommitted changes (staged + unstaged) plus, with --since, everything
# that moved between <ref> and HEAD. That workaround was a documented vault gotcha;
# this is the enforcement.
#
# The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
# falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in the
# plugin, NOT inside the vault, so it cannot derive the vault from its own location.
#
# Read-only: no fetch, no add, no commit, no checkout. Nothing changed (or not a git
# repo) is a clean no-op — empty stdout, exit 0 — so a save never crashes on it.
#
# Usage:
#   BRAIN_ROOT=<vault> bash changed-wiki-notes.sh              # uncommitted changes only
#   bash changed-wiki-notes.sh --since <ref>                   # + everything since <ref>
#   bash changed-wiki-notes.sh --porcelain                     # count on line 1, then paths
#   bash changed-wiki-notes.sh --deleted [--since <ref>]       # deleted notes instead
#
# Prints one vault-relative wiki/**/*.md path per line, sorted and de-duplicated.
# Default: added and modified files only — deletions are excluded (nothing left to
# re-extract; this is /brain:save 5c's work list, one subagent per path).
# --deleted: the other stream (INNOV-292) — only notes deleted relative to HEAD (or
# <ref>) and absent on disk. check-concept-graph.sh sums both streams, since a
# deleted note leaves a phantom node in the graph. The two streams never overlap:
# a rename is its new path in the default stream and never a deletion here.
# Neither stream lists the meta notes (log.md, hot.md, index.md; INNOV-408): they
# are never extracted, so they are never work and never staleness.
set -euo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

usage() {
  cat >&2 <<'USAGE'
usage: changed-wiki-notes.sh [--since <ref>] [--porcelain] [--deleted]
  --since <ref>   also include wiki notes changed between <ref> and HEAD
  --porcelain     print the count as the first line, then the paths
  --deleted       list deleted wiki notes instead of added/modified ones
USAGE
}

SINCE=""
PORCELAIN=0
DELETED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      if [[ $# -lt 2 ]]; then
        echo "error: --since requires a <ref>" >&2
        usage
        exit 2
      fi
      SINCE="$2"
      shift 2
      ;;
    --since=*)
      SINCE="${1#--since=}"
      shift
      ;;
    --porcelain)
      PORCELAIN=1
      shift
      ;;
    --deleted)
      DELETED=1
      shift
      ;;
    -h|--help)
      usage
      exit 2
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage
      exit 2
      ;;
  esac
done

# Not a git repo → nothing we can say about what changed. Note it and no-op.
if ! git -C "$VAULT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "note: '$VAULT' is not a git repo — no change list available, treating as nothing to do." >&2
  exit 0
fi

# git reports paths relative to the REPO root; the vault may sit in a subdirectory,
# so strip that prefix to get vault-relative paths. Empty when vault == repo root.
PREFIX="$(git -C "$VAULT" rev-parse --show-prefix 2>/dev/null || true)"

# Emits a path if it is a wiki/*.md under the vault that still exists on disk —
# or, with --deleted, that no longer does. The existence test is what excludes
# deletions (staged, unstaged, or "AD"-style combinations) from the default stream
# without having to enumerate every status-code pair.
emit() {
  local p="$1"
  # When the vault is a subdirectory of the repo, anything outside it (including a
  # second wiki/ at the repo root) is not ours — drop it, then make the path
  # vault-relative.
  if [[ -n "$PREFIX" ]]; then
    [[ "$p" == "$PREFIX"* ]] || return 0
    p="${p#"$PREFIX"}"
  fi
  [[ "$p" == wiki/*.md ]] || return 0
  # Meta notes never enter the concept graph (INNOV-408), so they are neither 5c
  # work nor staleness. Mirrors META_NOTES in wiki-meta.mjs (basename, any depth);
  # tests/test-changed-wiki-notes.sh fails if the two drift.
  case "${p##*/}" in index.md|hot.md|log.md) return 0 ;; esac
  if [[ $DELETED -eq 1 ]]; then
    [[ -f "$VAULT/$p" ]] && return 0
  else
    [[ -f "$VAULT/$p" ]] || return 0
  fi
  printf '%s\n' "$p"
}

collect() {
  local x y path

  # --porcelain -z: NUL-terminated records, and -z disables git's C-style quoting
  # of paths with spaces/non-ASCII entirely — no unquoting to get wrong. Each record
  # is "XY <path>"; for a rename/copy (X is R or C) the record holds the NEW path and
  # the OLD path follows as its own NUL-terminated field, which we read and discard
  # so only the new path is emitted. -uall lists untracked FILES individually — the
  # default collapses a brand-new directory to one "wiki/newdir/" entry and would
  # hide every new note inside it.
  while IFS= read -r -d '' path; do
    x="${path:0:1}"
    y="${path:1:1}"
    path="${path:3}"
    if [[ "$x" == "R" || "$x" == "C" ]]; then
      IFS= read -r -d '' _old || true   # consume + drop the source path
    fi
    if [[ $DELETED -eq 1 ]]; then
      # Deleted relative to HEAD: staged (D?), or unstaged from a tracked file
      # ( D / MD). An RD rename's SOURCE was in HEAD and has no successor on disk,
      # so the source is the deletion. AD/RD/CD record paths were never in HEAD.
      if [[ "$x" == "R" && "$y" == "D" ]]; then
        emit "$_old"
        continue
      fi
      [[ "$x" == "D" || ( "$y" == "D" && ( "$x" == " " || "$x" == "M" ) ) ]] || continue
    else
      [[ "$x" == "D" || "$y" == "D" ]] && continue
    fi
    emit "$path"
  done < <(git -C "$VAULT" -c status.renames=true status --porcelain -z -uall 2>/dev/null || true)

  # Committed range. --diff-filter=d drops deletions (D keeps only them); -z again
  # means unquoted paths. -M forces rename detection whatever diff.renames says, so
  # a committed rename is R — its new path in the default stream, never a D here.
  local filter=d
  [[ $DELETED -eq 1 ]] && filter=D
  if [[ -n "$SINCE" ]]; then
    if git -C "$VAULT" rev-parse --verify --quiet "$SINCE^{commit}" >/dev/null 2>&1 \
       && git -C "$VAULT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
      while IFS= read -r -d '' path; do
        emit "$path"
      done < <(git -C "$VAULT" diff --name-only -z -M --diff-filter="$filter" "$SINCE" HEAD 2>/dev/null || true)
    else
      echo "note: ref '$SINCE' not resolvable in '$VAULT' — reporting uncommitted changes only." >&2
    fi
  fi
}

RESULT="$(collect | LC_ALL=C sort -u || true)"

if [[ $PORCELAIN -eq 1 ]]; then
  if [[ -z "$RESULT" ]]; then
    echo 0
  else
    printf '%s\n' "$RESULT" | wc -l | tr -d ' '
    printf '%s\n' "$RESULT"
  fi
  exit 0
fi

[[ -n "$RESULT" ]] && printf '%s\n' "$RESULT"
exit 0
