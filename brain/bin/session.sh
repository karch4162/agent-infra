#!/usr/bin/env bash
# session.sh — register a brain command as a SESSION, and put it on a branch it is
# allowed to commit from, BEFORE it writes its first file.
#
# WHY THIS EXISTS (INNOV-275, PR 2). On 2026-08-05 two agent sessions shared one
# vault checkout. Session B ran /brain:init, a PR merged, HEAD moved to `main`
# underneath session A, and session A committed onto protected `main` believing it
# was still on its feature branch. It was not wrong about what it had done — it was
# wrong about where it was, because HEAD and the git index are GLOBAL to a
# checkout and nothing told it they had changed.
#
# PR 1 fixed the commit: vault-commit.sh refuses a protected branch and refuses a
# moved HEAD. That is the backstop, and a backstop that fires at the END of a
# command is expensive — an hour of edits discovers at commit time that it was
# never on a committable branch. PR 2 fixes the START: pick the branch up front,
# notice the other session up front, and hand the caller the pin that PR 1 checks.
#
# WHY A FILE AND NOT A VARIABLE. A skill is not a process. "Which branch am I on"
# has to survive dozens of tool calls, each its own shell, with another agent's
# tool calls interleaved between them — there is nowhere in memory for that to
# live. It has to be persisted, and it has to be persisted somewhere BOTH sessions
# can see, which is what makes concurrency detectable at all. Hence a state file
# that is READ BEFORE IT IS WRITTEN; a write-only log would detect nothing.
#
# The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
# falling back to $CLAUDE_PROJECT_DIR then the current dir — identical to
# vault-commit.sh. The script lives in the plugin, NOT inside the vault, so it
# cannot derive the vault from its own location.
#
# Usage:
#   BRAIN_ROOT=<vault> bash session.sh --start <command-name>  # register + branch policy
#   BRAIN_ROOT=<vault> bash session.sh --status                # report, mutate nothing
#   BRAIN_ROOT=<vault> bash session.sh --end                   # deregister THIS session, drop its hot-<id>.pin
#   BRAIN_ROOT=<vault> bash session.sh --print-pin             # banner; its "  pin:" line is BRANCH:SHA for vault-commit.sh
#   BRAIN_ROOT=<vault> bash session.sh --repin <old> <new>     # check-freshness.sh and vault-commit.sh ONLY, see below
#
# Contract (callers and tests depend on exactly this):
#   exit 0, stdout first line `SESSION: OK - <reason>`      => proceed
#   exit 0, stdout first line `SESSION: WARN - <reason>`    => proceed; a concurrent
#                                                              session exists (or the
#                                                              state file was unreadable)
#   exit 1, stderr first line `SESSION: REFUSED - <reason>` => the caller must stop
#
# THE PIN LINE. On a successful --start (OK *or* WARN — WARN is a success), the
# SECOND line of stdout is exactly:
#     pin: <branch>:<sha>
# The caller passes that value straight to `vault-commit.sh --pin`. That is how the
# two halves of INNOV-275 compose without vault-commit.sh learning anything about
# sessions: this script decides where the work happens, vault-commit.sh verifies
# nothing moved in between. When --start CREATES a branch, the pin names the NEW
# branch — pinning the branch you were on before the checkout would refuse your own
# first commit.
#
# WHO IS "THIS SESSION". A skill is not a process — see above — and it is not the
# process that invoked this script either. Under the Claude Code harness EVERY Bash
# tool call is a detached shell reparented to init, so $PPID is literally 1 for
# every call of every session forever. An earlier version of this script used
# $PPID; the result was that two different agent sessions both recorded pid 1, each
# read the other's record as its own, no session ever saw a concurrent session, and
# the protected-branch REFUSAL below — the entire point of INNOV-275 ask 4 — was
# dead code in the only runtime that matters. Identity is therefore EXPLICIT, never
# derived from a process:
#     SELF_ID = $BRAIN_SESSION_ID              (set by a caller or a human)
#            or $CLAUDE_CODE_SESSION_ID        (ambient in the Claude Code harness,
#                                               stable for the whole agent session)
#            or a random token generated at --start and persisted in
#               <vault>/.brain/session.id      (the honest fallback, see below)
#
# THE FALLBACK IS DEGRADED, AND SAYS SO. With neither env var there is nothing in
# the environment that distinguishes two sessions sharing one checkout, so:
#   - Each --start MINTS A NEW id. Two --start calls that cannot be told apart are
#     assumed to be two sessions, which keeps the REFUSAL alive (fail safe) at the
#     cost of treating one session's second --start as a second session.
#   - --print-pin / --end then read the LAST id written to .brain/session.id. That
#     is LAST-STARTED-WINS, and it is NOT SOLVED: if two id-less sessions share a
#     checkout, the one that started first will get the other's pin back. Every
#     command that resolves identity this way says so in its output and prints the
#     id with an `export BRAIN_SESSION_ID=<id>` hint, which is the actual remedy.
# Degraded and loud beats silent and wrong; under the harness (or with
# BRAIN_SESSION_ID exported) none of this applies.
#
# THE STATE FILE: <vault>/.brain/session.json — a JSON array of
# {session_id, pid, host, branch, sha, started_at, command}. `session_id` is the
# ONLY identity: `pid` and `host` are recorded for a human reading the file and for
# the best-effort reap below, and are never compared to decide whose record this
# is. Machine-local, per-checkout, gitignored
# by the vault template (.brain/), and deliberately NOT in .saveinclude or
# vault-commit.sh's REQUIRED set: committing it would sync one machine's process
# table into everybody else's vault.
#   - READ BEFORE WRITE. Reading the existing array is the entire concurrency
#     mechanism; without it every session would think it was alone.
#   - PRUNED ON EVERY WRITE, so an abandoned session cannot block the vault forever
#     and the file cannot grow without bound.
#   - WRITTEN ATOMICALLY (temp file in the same directory, then mv), so a crashed
#     run cannot leave a truncated array behind.
#   - A CORRUPT FILE IS A WARNING, NOT A FAILURE. It is treated as "no live
#     sessions" and named in the WARN. A broken machine-local state file must never
#     wedge every command in the vault — that would turn a convenience into an
#     outage, and the remedy (delete one gitignored file) is not worth blocking on.
#
# LIVENESS IS THE TIMESTAMP. A session is not a process, so there is no process to
# ask. The PRIMARY and load-bearing rule is:
#     live  <=>  (now - started_at) < BRAIN_SESSION_STALE_SECS   (default 3600)
# BRAIN_SESSION_STALE_SECS is env-overridable, so tests force both branches without
# sleeping and a human can shorten it in a fast-moving vault.
#
# The pid check that remains is a best-effort REAP and nothing else: it may only
# ever turn a fresh record DEAD, never keep a stale record alive. It fires only when
# all of these hold — a pid we could actually see, on this machine, on a platform
# where the answer means something:
#     platform is not MINGW/MSYS/CYGWIN (Git Bash cannot see native Windows pids,
#         so a failing `kill -0` there proves nothing — indeed `kill -0 1` fails)
#     AND the recorded pid is numeric and is not 1 (1 is init, and it is also what
#         a $PPID-based writer recorded for everything; it identifies nothing)
#     AND the recorded host is this host (a pid from another machine names a
#         completely unrelated process here)
#     AND `kill -0 <pid>` fails.
# Everything else is "cannot tell", which resolves to LIVE while the timestamp is
# fresh, because the two mistakes are not symmetric: treating a live session as
# dead reproduces the 2026-08-05 bug, while treating a dead session as live costs
# one wait until the record goes stale.
#
# BRANCH POLICY ON --start. This is the whole point of doing it here:
#   - not on a protected branch          -> register. WARN if another session is live.
#   - on the protected/default branch, alone
#                                        -> `git checkout -b brain/<command>-<date>`
#                                           (-2, -3 ... on collision), then register.
#   - on the protected/default branch, someone else is live
#                                        -> REFUSE. `git checkout -b` switches the
#                                           branch for EVERY session sharing the
#                                           working tree, so auto-creating here
#                                           would move the other session's HEAD out
#                                           from under it — the exact 2026-08-05
#                                           incident, caused this time by the fix.
#   - detached HEAD                      -> REFUSE. There is no branch to record,
#                                           and a commit here is lost by default.
#
# WHAT THIS IS NOT. It is not a lock. It cannot stop a second session from starting
# work, and it does not try to — it makes the collision VISIBLE at the moment it
# becomes cheap to resolve, and refuses only the one action (auto-checkout) that
# would actively damage the other session.
set -uo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# The protected-branch rule is shared verbatim with vault-commit.sh — see
# lib/branch.sh. Resolved from this script's own location so it works from any cwd,
# and sourced after $VAULT is set because the functions read it.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/branch.sh
. "$BIN_DIR/lib/branch.sh"

STATE_DIR="$VAULT/.brain"
STATE_FILE="$STATE_DIR/session.json"
ID_FILE="$STATE_DIR/session.id"
STALE_SECS="${BRAIN_SESSION_STALE_SECS:-3600}"

# Diagnostic only — NEVER identity. See the header: $PPID is 1 for every call under
# the harness. It is recorded so a human reading session.json has something to look
# up, and so the best-effort reap has a pid to try on platforms where that means
# something.
SELF_PID="$PPID"
SELF_HOST="$( { hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown; } | tr -d '[:space:]' )"
[[ -n "$SELF_HOST" ]] || SELF_HOST="unknown"

# Identity characters are restricted because the ids round-trip through this
# script's own grep/sed JSON reader, which reads a string value up to the next
# quote: an id containing a quote or a backslash would come back as a different id.
sanitize_id() { printf '%s' "${1:-}" | sed -e 's#[^A-Za-z0-9._-]#-#g' -e 's#^-*##' -e 's#-*$##'; }

# A token with no meaning except that it is not any other token.
generate_id() {
  local r
  r="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  [[ -n "$r" ]] || r="$$-$RANDOM$RANDOM"
  printf 'anon-%s-%s' "$(date -u +%s 2>/dev/null || echo 0)" "$r"
}

SELF_ID=""
ID_SOURCE=""
if [[ -n "${BRAIN_SESSION_ID:-}" ]]; then
  SELF_ID="$(sanitize_id "$BRAIN_SESSION_ID")"; ID_SOURCE="BRAIN_SESSION_ID"
elif [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
  SELF_ID="$(sanitize_id "$CLAUDE_CODE_SESSION_ID")"; ID_SOURCE="CLAUDE_CODE_SESSION_ID"
fi

refuse() { # reason-line, then extra lines
  {
    echo "SESSION: REFUSED - $1"
    shift
    local line
    for line in "$@"; do echo "$line"; done
  } >&2
  exit 1
}

# --- 0. arguments -----------------------------------------------------------
MODE=""
COMMAND_NAME=""
REPIN_OLD=""
REPIN_NEW=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start)      MODE="start"; COMMAND_NAME="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
    --start=*)    MODE="start"; COMMAND_NAME="${1#*=}"; shift ;;
    --status)     MODE="status"; shift ;;
    --end)        MODE="end"; shift ;;
    --print-pin)  MODE="print-pin"; shift ;;
    --repin)      MODE="repin"; REPIN_OLD="${2:-}"; REPIN_NEW="${3:-}"
                  shift; [[ $# -gt 0 ]] && shift; [[ $# -gt 0 ]] && shift ;;
    *)            refuse "unknown argument '$1'" \
                    "  Usage: session.sh --start <command-name> | --status | --end | --print-pin | --repin <old-sha> <new-sha>" ;;
  esac
done

if [[ -z "$MODE" ]]; then
  refuse "no mode given" \
    "  Usage: session.sh --start <command-name> | --status | --end | --print-pin | --repin <old-sha> <new-sha>"
fi
if [[ "$MODE" == "repin" && ( -z "$REPIN_OLD" || -z "$REPIN_NEW" ) ]]; then
  refuse "--repin needs the pre-move and post-move shas" \
    "  Usage: session.sh --repin <old-sha> <new-sha>" \
    "  It is called by check-freshness.sh after ITS OWN fast-forward/merge. A repin" \
    "  that cannot name both shas cannot prove the move was its own, so it refuses."
fi
if [[ "$MODE" == "start" && -z "$COMMAND_NAME" ]]; then
  refuse "--start needs the name of the command starting the session" \
    "  It is recorded in the session file and used to name any branch this creates," \
    "  so a concurrent session can tell WHO is holding the working tree." \
    "  Example: bash session.sh --start brain:save"
fi

# --- 1. is this a vault we can actually work in? ----------------------------
# Same preconditions vault-commit.sh checks, applied at the START of the command
# instead of after all the work: a vault that cannot be committed to is worth
# saying so before an hour of edits, not after.
if [[ ! -d "$VAULT/graphify" && ! -d "$VAULT/wiki" ]]; then
  refuse "'$VAULT' doesn't look like a brain vault (no graphify/ or wiki/)" \
    "  Set BRAIN_ROOT to the vault root."
fi
if ! git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
  refuse "'$VAULT' is not a git repo, so a session has no branch to hold" \
    "  Set BRAIN_ROOT to the vault root, or run 'git init' there."
fi
if [[ ! -f "$VAULT/.saveinclude" || ! -r "$VAULT/.saveinclude" ]]; then
  refuse "no readable .saveinclude at '$VAULT/.saveinclude'" \
    "  .saveinclude is the vault's whole permission model — the list of paths a" \
    "  command may commit — and without it vault-commit.sh refuses every commit." \
    "  Starting a session here would mean doing the work and then being unable to" \
    "  save it, so this refuses now rather than later." \
    "  Remedy: copy the template into the vault root:" \
    "    cp \"\${CLAUDE_PLUGIN_ROOT}/templates/saveinclude\" \"$VAULT/.saveinclude\""
fi

# --- 1b. identity, when the environment did not supply one ------------------
# Resolved AFTER the vault preconditions, because the fallback lives in the vault's
# .brain/ and there is no point minting an id for a vault we are about to refuse.
# Nothing is WRITTEN here: --start persists its id only once it has actually
# registered, and --status must be able to answer without changing the answer.
ID_DEGRADED=0
if [[ -z "$SELF_ID" ]]; then
  ID_DEGRADED=1
  if [[ "$MODE" == "start" ]]; then
    # A NEW id per --start. Two --starts we cannot tell apart are assumed to be two
    # sessions: that keeps the protected-branch refusal alive, which is the mistake
    # that costs a wait rather than the one that corrupts somebody's branch.
    SELF_ID="$(generate_id)"; ID_SOURCE="generated"
  else
    # --status/--end/--print-pin: whoever started last. Honest, and stated in the
    # output — see the header, this is last-started-wins and it is not solved.
    if [[ -r "$ID_FILE" ]]; then
      SELF_ID="$(sanitize_id "$(head -n 1 "$ID_FILE" 2>/dev/null | tr -d '\r')")"
      ID_SOURCE="file"
    fi
    if [[ -z "$SELF_ID" ]]; then
      # Nothing to go on. Use a token that cannot match any record, so --end and
      # --print-pin say "no session registered" instead of adopting a stranger's.
      SELF_ID="$(generate_id)"; ID_SOURCE="unresolved"
    fi
  fi
fi

# How this run learned who it is, for the trailing note on degraded runs.
id_note() {
  case "$ID_SOURCE" in
    generated)
      echo "  session id: $SELF_ID (generated — neither BRAIN_SESSION_ID nor CLAUDE_CODE_SESSION_ID is set)"
      echo "    Export it so --print-pin and --end find THIS session, not the last one to start:"
      echo "      export BRAIN_SESSION_ID=\"$SELF_ID\"" ;;
    file)
      echo "  session id: $SELF_ID (read from '$ID_FILE' — the session that started LAST in this"
      echo "    checkout; if another session with no BRAIN_SESSION_ID has started since, this is its"
      echo "    identity and not yours. Export BRAIN_SESSION_ID at --start to make it unambiguous.)" ;;
    unresolved)
      echo "  session id: unresolved — no BRAIN_SESSION_ID, no CLAUDE_CODE_SESSION_ID and no" \
           "'$ID_FILE'" ;;
  esac
}

# --- 2. the state file ------------------------------------------------------
# Parsed with grep/sed on purpose: this script both writes and reads the file, the
# format is one record per line, and adding a jq dependency to the START of every
# brain command would make jq's absence an outage.
REC_ID=(); REC_PID=(); REC_HOST=(); REC_BRANCH=(); REC_SHA=(); REC_AT=(); REC_CMD=()
STATE_CORRUPT=0

# Extracts "<key>": "<value>" or "<key>": <number> from one record line.
json_field() { # line key
  local line="$1" key="$2" v
  v="$(printf '%s' "$line" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")"
  if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
  v="$(printf '%s' "$line" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p")"
  printf '%s' "$v"
  [[ -n "$v" ]]
}

# Fills REC_* from the state file. Anything it cannot make sense of sets
# STATE_CORRUPT=1 and yields ZERO records — see the header: a broken machine-local
# file degrades to "nobody else is here", loudly, rather than blocking the vault.
read_state() {
  REC_ID=(); REC_PID=(); REC_HOST=(); REC_BRANCH=(); REC_SHA=(); REC_AT=(); REC_CMD=()
  STATE_CORRUPT=0
  [[ -f "$STATE_FILE" ]] || return 0
  if [[ ! -r "$STATE_FILE" ]]; then STATE_CORRUPT=1; return 0; fi

  local body line trimmed
  body="$(tr -d '\r' <"$STATE_FILE" 2>/dev/null)"
  trimmed="$(printf '%s' "$body" | tr -d '[:space:]')"
  [[ -z "$trimmed" ]] && return 0                       # empty file: no sessions, not corrupt
  if [[ "$trimmed" != \[* || "$trimmed" != *\] ]]; then STATE_CORRUPT=1; return 0; fi
  [[ "$trimmed" == "[]" ]] && return 0

  local id p h b s a c
  while IFS= read -r line; do
    [[ "$line" == *"{"* ]] || continue
    id="$(json_field "$line" session_id)"
    p="$(json_field "$line" pid)"
    h="$(json_field "$line" host)"
    b="$(json_field "$line" branch)"
    s="$(json_field "$line" sha)"
    a="$(json_field "$line" started_at)"
    c="$(json_field "$line" command)"
    # A record written by the pre-identity version of this script has a pid and no
    # session_id. Give it a synthetic id that cannot collide with a real one, so it
    # is neither adopted as ours nor dropped: an unrecognised record with a fresh
    # timestamp is SOMEBODY, and the safe reading of somebody is "not me".
    if [[ -z "$id" && -n "$p" ]]; then id="legacy-pid-$p"; fi
    id="$(sanitize_id "$id")"
    if [[ -z "$id" || -z "$b" || -z "$s" || -z "$a" ]]; then
      STATE_CORRUPT=1
      REC_ID=(); REC_PID=(); REC_HOST=(); REC_BRANCH=(); REC_SHA=(); REC_AT=(); REC_CMD=()
      return 0
    fi
    REC_ID+=("$id"); REC_PID+=("${p:-0}"); REC_HOST+=("${h:-unknown}")
    REC_BRANCH+=("$b"); REC_SHA+=("$s"); REC_AT+=("$a"); REC_CMD+=("${c:-?}")
  done <<<"$body"
  return 0
}

now_epoch() { date -u +%s 2>/dev/null || echo 0; }

# Seconds since an ISO-8601 UTC stamp, or nothing when it cannot be parsed.
age_of() { # started_at
  local then now
  then="$(date -u -d "$1" +%s 2>/dev/null || true)"
  [[ -n "$then" ]] || return 1
  now="$(now_epoch)"
  echo $(( now - then ))
}

# Best-effort REAP, per the LIVENESS section of the header. It can only ever turn a
# fresh record dead; it never keeps a stale one alive. Every guard below is a case
# where the pid answer would be meaningless rather than merely unavailable.
pid_proven_gone() { # pid host
  local pid="${1:-}" host="${2:-}" uname_s
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  # 1 is init. It is also what a $PPID-based writer recorded for every session in
  # the harness, so it names nobody — and `kill -0 1` fails on Git Bash anyway,
  # which would have reaped every record on sight.
  [[ "$pid" == "1" || "$pid" == "0" ]] && return 1
  # A pid from another machine refers to some unrelated local process, or nothing.
  [[ -n "$host" && "$host" != "unknown" && "$host" == "$SELF_HOST" ]] || return 1
  uname_s="$(uname -s 2>/dev/null || echo unknown)"
  case "$uname_s" in
    MINGW*|MSYS*|CYGWIN*|unknown) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}

# live <=> fresh timestamp (the primary rule), minus anything the best-effort reap
# can positively disprove. An unparseable timestamp counts as stale: it cannot be
# shown to be fresh, and a record we cannot date would otherwise be immortal.
record_is_live() { # index
  local i="$1" age
  age="$(age_of "${REC_AT[$i]}")" || return 1
  [[ "$age" =~ ^-?[0-9]+$ ]] || return 1
  (( age < STALE_SECS )) || return 1
  pid_proven_gone "${REC_PID[$i]}" "${REC_HOST[$i]}" && return 1
  return 0
}

json_escape() { # string
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Rewrites the state file as: every live record whose session_id is not ours, plus
# (optionally) one new record for us. Dead and stale records are dropped here —
# pruning on write is what keeps the file bounded without a reaper process.
# Atomic: temp file inside .brain/ (same filesystem, so mv is a rename), then mv.
write_state() { # [branch sha started_at command]  (omit all four to just deregister)
  local nb="${1:-}" ns="${2:-}" na="${3:-}" nc="${4:-}"
  if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    refuse "could not create '$STATE_DIR' to hold the session file" \
      "  It is machine-local state (.gitignored); it needs a writable vault."
  fi
  local tmp="$STATE_DIR/.session.json.$$"
  local i first=1
  {
    echo "["
    for i in "${!REC_ID[@]}"; do
      [[ "${REC_ID[$i]}" == "$SELF_ID" ]] && continue
      record_is_live "$i" || continue
      [[ $first -eq 1 ]] || echo ","
      first=0
      printf '  {"session_id": "%s", "pid": %s, "host": "%s", "branch": "%s", "sha": "%s", "started_at": "%s", "command": "%s"}' \
        "$(json_escape "${REC_ID[$i]}")" "${REC_PID[$i]}" "$(json_escape "${REC_HOST[$i]}")" \
        "$(json_escape "${REC_BRANCH[$i]}")" "$(json_escape "${REC_SHA[$i]}")" \
        "$(json_escape "${REC_AT[$i]}")" "$(json_escape "${REC_CMD[$i]}")"
    done
    if [[ -n "$nb" ]]; then
      [[ $first -eq 1 ]] || echo ","
      first=0
      printf '  {"session_id": "%s", "pid": %s, "host": "%s", "branch": "%s", "sha": "%s", "started_at": "%s", "command": "%s"}' \
        "$(json_escape "$SELF_ID")" "$SELF_PID" "$(json_escape "$SELF_HOST")" \
        "$(json_escape "$nb")" "$(json_escape "$ns")" \
        "$(json_escape "$na")" "$(json_escape "$nc")"
    fi
    [[ $first -eq 1 ]] || echo
    echo "]"
  } >"$tmp" 2>/dev/null
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp" 2>/dev/null || true
    refuse "could not write the session file at '$STATE_FILE'"
  fi
  if ! mv "$tmp" "$STATE_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    refuse "could not install the session file at '$STATE_FILE'" \
      "  The previous session file is untouched."
  fi
}

# --- 3. where are we? -------------------------------------------------------
CUR_BRANCH="$(git -C "$VAULT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
CUR_SHA="$(git -C "$VAULT" rev-parse HEAD 2>/dev/null || true)"

read_state

# Indices of OTHER sessions that are live. "Other" is by session_id: a second
# --start under the SAME id is the same session re-entering, and replaces its own
# record rather than colliding with itself. It is emphatically NOT by pid — see the
# header; every session in this harness has the same pid.
FOREIGN=()
for i in "${!REC_ID[@]}"; do
  [[ "${REC_ID[$i]}" == "$SELF_ID" ]] && continue
  record_is_live "$i" && FOREIGN+=("$i")
done

WARNINGS=()
if [[ $STATE_CORRUPT -eq 1 ]]; then
  WARNINGS+=("could not parse '$STATE_FILE' — treating it as no live sessions")
fi

# --- --status ---------------------------------------------------------------
# Reports and returns. It creates no directory, prunes nothing and writes nothing:
# a read-only question must never be the thing that changes the answer.
if [[ "$MODE" == "status" ]]; then
  live_total=0
  for i in "${!REC_ID[@]}"; do record_is_live "$i" && live_total=$((live_total + 1)); done
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo "SESSION: WARN - ${WARNINGS[0]}"
  else
    echo "SESSION: OK - $live_total live session(s) in '$VAULT'"
  fi
  for i in "${!REC_ID[@]}"; do
    if record_is_live "$i"; then state="live"; else state="stale"; fi
    mine=""
    [[ "${REC_ID[$i]}" == "$SELF_ID" ]] && mine=" (this session)"
    echo "  $state  session ${REC_ID[$i]}  branch '${REC_BRANCH[$i]}'  ${REC_CMD[$i]}  started ${REC_AT[$i]}$mine"
    echo "         (diagnostic only: pid ${REC_PID[$i]} on host ${REC_HOST[$i]})"
  done
  echo "  vault HEAD: ${CUR_BRANCH:-?} @ ${CUR_SHA:0:12}"
  echo "  stale after: ${STALE_SECS}s"
  echo "  this session: $SELF_ID (from ${ID_SOURCE:-none})"
  [[ $ID_DEGRADED -eq 1 ]] && id_note
  exit 0
fi

# --- --end ------------------------------------------------------------------
if [[ "$MODE" == "end" ]]; then
  had_mine=0
  for i in "${!REC_ID[@]}"; do
    [[ "${REC_ID[$i]}" == "$SELF_ID" ]] && had_mine=1
  done
  # write_state with no new record drops ours and prunes the dead, keeping every
  # other live session exactly as it was — ending my session must never end yours.
  write_state
  # write-hot.sh's per-session pin is spent once the session ends (INNOV-321); it
  # keeps it after --write on purpose, so nothing else removes it. The id is
  # derived exactly as write-hot.sh derives it, NOT from SELF_ID: SELF_ID ignores
  # GROK_SESSION_ID and can fall back to session.id, i.e. someone else's session.
  HOT_PIN_ID="${BRAIN_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${GROK_SESSION_ID:-}}}"
  case "$HOT_PIN_ID" in
    ""|*[!A-Za-z0-9._-]*) ;;
    *) rm -f "$STATE_DIR/hot-$HOT_PIN_ID.pin" 2>/dev/null || true ;;
  esac
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    # A corrupt file is still only a warning here: --end has just replaced it with
    # a well-formed array, so the vault is repaired, but the caller is told that
    # whatever WAS in there could not be read and is therefore gone.
    echo "SESSION: WARN - ${WARNINGS[0]}; session $SELF_ID deregistered and the file rewritten"
  elif [[ $had_mine -eq 1 ]]; then
    echo "SESSION: OK - session $SELF_ID deregistered (${#FOREIGN[@]} other live session(s) left registered)"
  else
    echo "SESSION: OK - no session was registered for id $SELF_ID (nothing to do)"
  fi
  [[ $ID_DEGRADED -eq 1 ]] && id_note
  exit 0
fi

# --- --print-pin ------------------------------------------------------------
# The pin is the branch + sha AS THIS SESSION SAW THEM AT --start (updated only by
# --repin, i.e. by this session's own freshness step moving HEAD), not as they are
# now. Reading them fresh would defeat the entire purpose: a HEAD that moved would
# be re-pinned to its new value and vault-commit.sh would happily commit wherever
# the other session left us.
if [[ "$MODE" == "print-pin" ]]; then
  for i in "${!REC_ID[@]}"; do
    if [[ "${REC_ID[$i]}" == "$SELF_ID" ]]; then
      echo "SESSION: OK - pin for session $SELF_ID as recorded"
      echo "  pin: ${REC_BRANCH[$i]}:${REC_SHA[$i]}"
      [[ $ID_DEGRADED -eq 1 ]] && id_note
      exit 0
    fi
  done
  pin_extra=""
  [[ $STATE_CORRUPT -eq 1 ]] && pin_extra="  ('$STATE_FILE' could not be parsed, so any record it held was unreadable.)"
  pin_id_note=""
  [[ $ID_DEGRADED -eq 1 ]] && pin_id_note="$(id_note)"
  refuse "no session is registered for id $SELF_ID, so there is no pin to print" \
    "${pin_extra:-  (The session file holds no record for this session id.)}" \
    "  The pin is the branch and sha recorded at --start; it cannot be reconstructed" \
    "  afterwards, because the whole point is to know where HEAD was THEN." \
    "${pin_id_note:-  (Identity came from \$$ID_SOURCE.)}" \
    "  Remedy: BRAIN_ROOT=\"$VAULT\" bash session.sh --start <command-name>"
fi

# --- --repin ----------------------------------------------------------------
# INNOV-285. Called by check-freshness.sh after it has ITSELF fast-forwarded
# or merged the vault branch: that move is part of this session's own save, so the
# pin recorded at --start must follow it — otherwise vault-commit.sh --pin refuses
# every stale-branch save on the strength of a move the session made deliberately.
# Both shas are the CALLER'S observations: <old-sha> is HEAD as it saw it before
# its merge, <new-sha> is HEAD as it saw it after. The recorded pin is rewritten to
# <new-sha> only when it matches <old-sha> exactly and the branch is unchanged.
# That is what keeps the moved-HEAD guard intact: a HEAD moved by ANOTHER session
# leaves the recorded pin pointing at a sha the caller never saw, the match fails,
# nothing is rewritten, and vault-commit.sh still refuses. And because <new-sha> is
# recorded verbatim rather than re-read from HEAD here, a foreign move in the
# window between the caller's merge and this call is not laundered into the pin —
# it too surfaces as a refusal at commit time.
if [[ "$MODE" == "repin" ]]; then
  for i in "${!REC_ID[@]}"; do
    if [[ "${REC_ID[$i]}" == "$SELF_ID" ]]; then
      if [[ "${REC_BRANCH[$i]}" != "${CUR_BRANCH:-}" ]]; then
        refuse "session $SELF_ID is pinned to branch '${REC_BRANCH[$i]}' but HEAD is on '${CUR_BRANCH:-?}'" \
          "  A repin may only follow a fast-forward/merge the caller made on the pinned" \
          "  branch; a branch switch is never that. The recorded pin is unchanged."
      fi
      if [[ "${REC_SHA[$i]}" != "$REPIN_OLD" ]]; then
        refuse "recorded pin sha '${REC_SHA[$i]}' does not match the pre-move sha '$REPIN_OLD'" \
          "  HEAD was moved by something OTHER than the caller's own freshness step" \
          "  (another session committed, merged or switched in between). The recorded" \
          "  pin is unchanged, so vault-commit.sh will refuse it — which is the" \
          "  moved-HEAD guard working, not a bug."
      fi
      # Keep the pid --start recorded: ours is the caller's short-lived shell, and
      # the best-effort reap would read it as a dead session (INNOV-380).
      SELF_PID="${REC_PID[$i]}"
      write_state "${REC_BRANCH[$i]}" "$REPIN_NEW" "${REC_AT[$i]}" "${REC_CMD[$i]}"
      echo "SESSION: OK - pin for session $SELF_ID updated after its own freshness merge"
      echo "  pin: ${REC_BRANCH[$i]}:$REPIN_NEW"
      [[ $ID_DEGRADED -eq 1 ]] && id_note
      exit 0
    fi
  done
  # No record for this id: check-freshness.sh also runs outside /brain:save, where
  # there is no pin to maintain. Nothing to update is a success, not a failure.
  echo "SESSION: OK - no session is registered for id $SELF_ID; nothing to repin"
  [[ $ID_DEGRADED -eq 1 ]] && id_note
  exit 0
fi

# --- --start ----------------------------------------------------------------

# A one-line description of a foreign session, for messages. It names the BRANCH
# first — that is INNOV-275's acceptance text and the thing a human can act on: go
# look at that branch, or wait for it. The command, the start time and the id
# follow, so the reader can also find the session itself.
foreign_desc() { # index
  local i="$1"
  echo "branch '${REC_BRANCH[$i]}' (${REC_CMD[$i]}, started ${REC_AT[$i]}, session ${REC_ID[$i]})"
}

# Detached HEAD first: there is no branch name to record, `git checkout -b` from
# here would silently adopt whatever commit we happen to be sitting on, and a
# commit made here is unreachable the moment anything else checks out a branch.
if [[ -z "$CUR_BRANCH" || "$CUR_BRANCH" == "HEAD" ]]; then
  refuse "the vault is in DETACHED HEAD state, which is not a place to start a session" \
    "  There is no branch to record, and any commit made here becomes unreachable as" \
    "  soon as anything else in this shared checkout switches branches." \
    "  Remedy: git -C \"$VAULT\" checkout <branch>   (or checkout -b <new-branch>)"
fi

# Sanitised for use in a git ref: the command name arrives as '/brain:save' or
# similar, and ':' is not legal in a branch name.
SLUG="$(printf '%s' "$COMMAND_NAME" | sed -e 's#^/##' -e 's#[^A-Za-z0-9._-]#-#g' -e 's#^-*##' -e 's#-*$##')"
[[ -n "$SLUG" ]] || SLUG="session"

if branch_is_protected "$CUR_BRANCH"; then
  # THE REFUSAL THIS WHOLE SCRIPT IS FOR. `git checkout -b` is not a per-session
  # act: it moves HEAD for every session sharing this working tree. Auto-creating a
  # branch while somebody else is mid-command would yank their branch out from
  # under them — which is the 2026-08-05 incident exactly, only this time caused by
  # the fix for it. So when we are not alone, the answer is no.
  if [[ ${#FOREIGN[@]} -gt 0 ]]; then
    other="${FOREIGN[0]}"
    refuse "'$CUR_BRANCH' is the protected/default branch and another session is live: $(foreign_desc "$other")" \
      "  Normally this command would run 'git checkout -b brain/$SLUG-$(date -u +%F)' for" \
      "  you. It will not while somebody else is working here, because 'git checkout -b'" \
      "  switches the branch for EVERY session sharing this working tree — HEAD and the" \
      "  git index are properties of the checkout, not of a session." \
      "  Doing it anyway would move branch '${REC_BRANCH[$other]}' out from under session" \
      "  ${REC_ID[$other]} mid-command, which is precisely the 2026-08-05 incident this" \
      "  guard exists to prevent, reproduced by its own fix." \
      "  Remedies, in order of preference:" \
      "    1. Wait for the session on '${REC_BRANCH[$other]}' (${REC_CMD[$other]}) to finish, then re-run." \
      "    2. Give this session its own working tree, which is the real fix:" \
      "         git -C \"$VAULT\" worktree add ../vault-$SLUG -b brain/$SLUG-$(date -u +%F)" \
      "       then re-run with BRAIN_ROOT pointing at that worktree." \
      "    3. If session ${REC_ID[$other]} is genuinely gone, its record expires after" \
      "       ${STALE_SECS}s (BRAIN_SESSION_STALE_SECS), or delete '$STATE_FILE'." \
      "  Nothing was changed: the branch was not switched and no session was registered."
  fi

  # Alone on a protected branch: create the working branch NOW, so every file this
  # command writes is written on a branch it can actually commit from.
  DATE_TAG="$(date -u +%F 2>/dev/null || echo undated)"
  NEW_BRANCH="brain/$SLUG-$DATE_TAG"
  n=2
  # A name taken only on origin is taken too: it is another author's PR branch, and
  # reusing it pushes onto their PR (INNOV-333). refs/remotes is only as fresh as the
  # last fetch, and /brain:save starts before check-freshness fetches (INNOV-410), so
  # ask origin itself. Offline or no origin falls back to the local refs;
  # vault-commit's open-PR guard is the backstop.
  REMOTE_HEADS="$(GIT_TERMINAL_PROMPT=0 git -C "$VAULT" ls-remote --heads origin 2>/dev/null | cut -f2)"
  while git -C "$VAULT" rev-parse --verify --quiet "refs/heads/$NEW_BRANCH" >/dev/null 2>&1 ||
    git -C "$VAULT" rev-parse --verify --quiet "refs/remotes/origin/$NEW_BRANCH" >/dev/null 2>&1 ||
    printf '%s\n' "$REMOTE_HEADS" | grep -qxF "refs/heads/$NEW_BRANCH"; do
    NEW_BRANCH="brain/$SLUG-$DATE_TAG-$n"
    n=$((n + 1))
  done
  if ! co_err="$(git -C "$VAULT" checkout -b "$NEW_BRANCH" 2>&1)"; then
    refuse "could not create working branch '$NEW_BRANCH'" \
      "$(printf '    %s\n' "$co_err")" \
      "  The vault is still on '$CUR_BRANCH' and no session was registered."
  fi
  PROTECTED_FROM="$CUR_BRANCH"
  CUR_BRANCH="$NEW_BRANCH"
  CUR_SHA="$(git -C "$VAULT" rev-parse HEAD 2>/dev/null || true)"
  CREATED="$NEW_BRANCH"
else
  CREATED=""
  PROTECTED_FROM=""
  if [[ ${#FOREIGN[@]} -gt 0 ]]; then
    other="${FOREIGN[0]}"
    WARNINGS+=("another session is live: $(foreign_desc "$other")")
  fi
fi

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
write_state "$CUR_BRANCH" "$CUR_SHA" "$STARTED_AT" "$COMMAND_NAME"

# Only NOW, once this session is actually registered, does a generated id get
# persisted — a refusal must leave the checkout exactly as it found it. Best-effort:
# failing to remember the id costs a later --print-pin, not this command.
if [[ "$ID_SOURCE" == "generated" ]]; then
  printf '%s\n' "$SELF_ID" >"$ID_FILE" 2>/dev/null || true
fi

# The verdict line, then the pin line — in that order, always, on stdout. WARN is a
# success: the caller proceeds, it just now knows it is not alone. That is why the
# pin is printed on both, and why a caller can read line 2 without branching first.
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  reason="${WARNINGS[0]}"
  for w in "${WARNINGS[@]:1}"; do reason="$reason; $w"; done
  [[ -n "$CREATED" ]] && reason="$reason; created and switched to branch '$CREATED'"
  echo "SESSION: WARN - $reason"
else
  if [[ -n "$CREATED" ]]; then
    echo "SESSION: OK - created and checked out branch '$CREATED' ('$PROTECTED_FROM' is protected)"
  else
    echo "SESSION: OK - registered session $SELF_ID on branch '$CUR_BRANCH'"
  fi
fi
echo "  pin: $CUR_BRANCH:$CUR_SHA"
echo "  session $SELF_ID ($COMMAND_NAME) recorded in '$STATE_FILE' at $STARTED_AT"
[[ $ID_DEGRADED -eq 1 ]] && id_note
if [[ ${#FOREIGN[@]} -gt 0 ]]; then
  echo "  Concurrent sessions share this checkout: do not 'git checkout' or 'git add -A'."
fi
echo "  Pass the pin through when you commit:"
echo "    bash \"\$BIN/vault-commit.sh\" -m \"<msg>\" --pin \"$CUR_BRANCH:$CUR_SHA\""
echo "  End the session when done: bash session.sh --end"
exit 0
