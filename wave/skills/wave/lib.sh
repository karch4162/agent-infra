#!/usr/bin/env bash
# Sourced by every wave script. Loads the target repo's wave config and derives
# what the repo already knows (main checkout, base ref, Orca repo id).
#
# Per-project config lives in the TARGET repo, committed:
#   .claude/wave/config.env   required - tracker + queue (see config.example.env)
#   .claude/wave/notes.md     optional - project rules appended to the worker prompt
# Bash 3.2-safe (INNOV-284): see tests/test-bash32-portability.sh.

WAVE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel)" || { echo "wave: not inside a git repo" >&2; exit 1; }
# The common dir is the main checkout's .git, even from inside a worktree.
MAIN_CHECKOUT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
WAVE_CONFIG="$ROOT/.claude/wave/config.env"
WAVE_NOTES_FILE="$ROOT/.claude/wave/notes.md"

[ -f "$WAVE_CONFIG" ] || {
  echo "wave: no $WAVE_CONFIG - write one with: bash $WAVE_HOME/bootstrap.sh --label <repo-label>" >&2
  exit 1
}
# shellcheck disable=SC1090
. "$WAVE_CONFIG"

for v in WAVE_TRACKER WAVE_QUEUE WAVE_STATE_START WAVE_STATE_DONE WAVE_FILE_TO; do
  eval "[ -n \"\${$v:-}\" ]" || { echo "wave: $v is not set in $WAVE_CONFIG" >&2; exit 1; }
done

case "$WAVE_TRACKER" in
  linear)
    TRACKER_NAME="Linear"
    TRACKER_OPS="\`orca linear\`"
    TRACKER_ATTACH="attach it with \`orca linear attach\`" ;;
  jira)
    TRACKER_NAME="Jira"
    TRACKER_OPS="the Atlassian MCP Jira tools (site ${WAVE_JIRA_SITE:?set WAVE_JIRA_SITE in $WAVE_CONFIG})"
    TRACKER_ATTACH="add the PR URL to the issue as a comment" ;;
  *) echo "wave: WAVE_TRACKER must be linear or jira, got '$WAVE_TRACKER'" >&2; exit 1 ;;
esac

# Base ref: explicit override, else whatever origin/HEAD points at.
if [ -z "${WAVE_BASE:-}" ]; then
  WAVE_BASE="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" || {
    echo "wave: origin/HEAD is unset - run 'git remote set-head origin -a' or set WAVE_BASE" >&2
    exit 1
  }
fi
BASE_BRANCH="${WAVE_BASE#origin/}"

WAVE_NOTES=""
[ -f "$WAVE_NOTES_FILE" ] && WAVE_NOTES="$(cat "$WAVE_NOTES_FILE")"

# Orca's repo id for this checkout. Called lazily - DRY_RUN and tests never need Orca.
orca_repo_id() {
  orca repo list --json | python -c "
import sys, json, os
want = os.path.normcase(os.path.realpath(sys.argv[1]))
for r in json.load(sys.stdin)['result']['repos']:
    if os.path.normcase(os.path.realpath(r['path'])) == want: print(r['id']); break
" "$(cygpath -m "$MAIN_CHECKOUT" 2>/dev/null || echo "$MAIN_CHECKOUT")"   # Windows python cannot read /c/...
}

# Keep a wave scratch file out of git and out of review diffs (review.sh diffs
# untracked files too). Goes in the common dir's exclude, so every worktree sees it.
wave_exclude() {  # $1 = gitignore pattern
  local exclude
  exclude="$(git rev-parse --git-common-dir)/info/exclude"
  grep -qxF "$1" "$exclude" 2>/dev/null || echo "$1" >> "$exclude"
}

# True when $2 contains a line starting with marker $1 and nothing but bullets after
# it, i.e. the reviewer finished. Shared by review.sh and plan-review.sh.
verdict_ok() {  # $1 = marker, $2 = reviewer output
  sed '/^[[:space:]]*$/d' <<< "$2" | awk -v marker="$1" '
    index($0, marker) == 1 { seen = 1; ok = 1; next }
    seen && !/^[-*] / { ok = 0 }
    END { exit !(seen && ok) }'
}

# Hash of everything a reviewer could change in this worktree: index and tracked
# edits plus untracked (non-excluded) file contents. wave_exclude'd scratch files
# are deliberately outside it, so a reviewer's own log does not count as an edit.
worktree_fingerprint() {
  {
    git status --porcelain=v1 -uall
    git diff HEAD 2>/dev/null
    git ls-files --others --exclude-standard -z | xargs -0 -r git hash-object --
  } | git hash-object --stdin
}

# Reviewers are read-only. Codex and Claude are sandboxed by flags; Grok's CLI needs
# bypassPermissions, so its read-only role is enforced here instead: run it and fail
# with status 3 if the worktree changed underneath it.
#   out="$(guard_readonly timeout 900 grok ... 2>"$ERR")"; rc=$?
guard_readonly() {
  local before rc
  before="$(worktree_fingerprint)"
  "$@"; rc=$?
  [ "$before" = "$(worktree_fingerprint)" ] || return 3
  return "$rc"
}

# Git Bash exports SYSTEMDRIVE/SYSTEMROOT upper-cased; Grok looks them up by their
# Windows spelling, misses, and writes a literal %SystemDrive%/ tree into cwd
# (INNOV-392). Give it the exact names. No-op off Windows (no cygpath).
grok_env() {
  command -v cygpath >/dev/null 2>&1 || return 0
  local root="${SystemRoot:-${SYSTEMROOT:-$(cygpath -w -W)}}"
  export SystemRoot="$root"
  export SystemDrive="${SystemDrive:-${SYSTEMDRIVE:-${root%%:*}:}}"
  export ProgramData="${ProgramData:-${PROGRAMDATA:-$(cygpath -w -F 35)}}"
}

# One read-only Grok run, retried once with 1.5x the limit if `timeout` killed it
# (exit 124); any other result is final (INNOV-391). Sets GROK_OUT, GROK_RC
# (3 = edited the worktree, 124 = timed out twice) and GROK_WHY for a NO line.
#   run_grok "$prompt" "$ERRFILE"
run_grok() {
  local limit=900 attempt
  : >"$2"
  for attempt in 1 2; do
    GROK_OUT="$(grok_env; guard_readonly timeout "$limit" grok --permission-mode bypassPermissions -p "$1" 2>>"$2")"
    GROK_RC=$?
    [ "$GROK_RC" -eq 124 ] || break
    [ "$attempt" -eq 2 ] || limit=$((limit * 3 / 2))
  done
  if [ "$GROK_RC" -eq 124 ]; then
    GROK_WHY="timeout twice, last after ${limit}s (exit 124)"
  else
    GROK_WHY="incomplete verdict (exit $GROK_RC)"
  fi
}
