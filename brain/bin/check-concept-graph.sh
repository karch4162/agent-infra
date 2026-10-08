#!/usr/bin/env bash
# check-concept-graph.sh — surface TOTAL wiki concept-graph staleness (INNOV-286).
#
# /brain:save step 5c gates the wiki concept-graph refresh on notes changed THIS
# session (changed-wiki-notes.sh). Staleness accumulated across prior sessions is
# invisible to that gate: a recorded incident had 2 session-changed notes while
# the concept graph was 517 documents behind — and the step reported green. Same
# false-green class as INNOV-279. This script measures the TOTAL: every wiki note
# added/modified/deleted since the graph was last built, whichever session did it.
#
# "Last built" is approximated as the last commit that touched the vault's own
# graphify-out/graph.json — an uncommitted rebuild can therefore over-report
# until step 6 commits it, which WARN polarity makes harmless. The changed-note
# set is computed by changed-wiki-notes.sh --since <that commit> (uncommitted +
# committed-since, added/modified) plus its --deleted stream, counted 1:1: a deleted
# note leaves a phantom node (INNOV-292). It is NEVER computed from graphify-out
# manifest.json — INNOV-271 documents that list over-reporting hundreds of notes
# when ten changed.
#
# WARN polarity: exit 1 makes the staleness VISIBLE, it never blocks anything.
# /brain:save step 5c answers STALE by running the refresh; a decline needs a
# stated reason (INNOV-300). The STALE line also carries M, the count at the last
# save (the last commit touching logs/), so a skip that became routine shows its
# compounding: "N behind, was M at last save".
#
# The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
# falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in
# the plugin, NOT inside the vault, so it cannot derive the vault from its own
# location.
#
# Usage:
#   BRAIN_ROOT=<vault> bash check-concept-graph.sh                       # threshold 25
#   BRAIN_ROOT=<vault> CONCEPT_GRAPH_THRESHOLD=5 bash check-concept-graph.sh
#
#   CONCEPT_GRAPH_THRESHOLD — WARN when the count EXCEEDS this, default 25.
#                             Must be a non-negative integer; anything else is
#                             ignored (with a stderr note) and 25 is used, so a
#                             typo'd threshold cannot silently disable the gate.
#
# Contract (the /brain:save and /brain:doctor skills and the tests depend on it):
#   exit 0  => first line "CONCEPT-GRAPH: OK"      (stdout) — at/under threshold,
#           or first line "CONCEPT-GRAPH: SKIPPED" (stdout) — not measurable:
#              no graphify-out/graph.json, not a git repo, or graph.json exists
#              but has never been committed (no last-built point to diff from —
#              said outright rather than guessed at).
#   exit 1  => first line "CONCEPT-GRAPH: STALE - N document(s) behind, was M
#              at last save" (stderr; "no prior save" when logs/ was never committed).
#              WARN only: the caller relays the line; nothing is blocked.
# Both OK and STALE carry the count and the threshold, so the trend is visible
# before it becomes a violation (same stance as check-hot-budget.sh).
set -uo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_THRESHOLD=25
THRESHOLD="${CONCEPT_GRAPH_THRESHOLD:-$DEFAULT_THRESHOLD}"
if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then
  echo "  note: CONCEPT_GRAPH_THRESHOLD='$THRESHOLD' is not a non-negative integer; using $DEFAULT_THRESHOLD." >&2
  THRESHOLD=$DEFAULT_THRESHOLD
fi

# --- 0. not measurable => SKIPPED, exit 0 (a guard, not a precondition) ------
if [[ ! -f "$VAULT/graphify-out/graph.json" ]]; then
  echo "CONCEPT-GRAPH: SKIPPED - no graphify-out/graph.json under '$VAULT' (no wiki graph built yet), staleness not measurable"
  exit 0
fi

if ! git -C "$VAULT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "CONCEPT-GRAPH: SKIPPED - '$VAULT' is not a git repo, staleness not measurable"
  exit 0
fi

# The pathspec is resolved relative to the -C cwd, so no --show-prefix juggling
# here — that only matters for git's OUTPUT paths (changed-wiki-notes.sh's job).
LAST="$(git -C "$VAULT" log -1 --format=%H -- graphify-out/graph.json 2>/dev/null | tr -d ' \r')"
if [[ -z "$LAST" ]]; then
  echo "CONCEPT-GRAPH: SKIPPED - graphify-out/graph.json exists but has never been committed; last-built point unknown, staleness not measurable"
  exit 0
fi

# --- 1. measure: wiki notes added/modified/deleted since the graph's last commit
# A broken measurement must land on SKIPPED, never on "OK - 0" — that would be
# this ticket's false green wearing a different hat (a stale install really has
# shipped without sibling scripts before; see doctor check 7).
if [[ ! -f "$SCRIPT_DIR/changed-wiki-notes.sh" ]]; then
  echo "CONCEPT-GRAPH: SKIPPED - changed-wiki-notes.sh not found beside this script ($SCRIPT_DIR), staleness not measurable"
  exit 0
fi
STALE_LIST="$(BRAIN_ROOT="$VAULT" bash "$SCRIPT_DIR/changed-wiki-notes.sh" --since "$LAST" 2>/dev/null)"
CWN_STATUS=$?
if [[ "$CWN_STATUS" -ne 0 ]]; then
  echo "CONCEPT-GRAPH: SKIPPED - changed-wiki-notes.sh failed (exit $CWN_STATUS), staleness not measurable"
  exit 0
fi
DELETED_LIST="$(BRAIN_ROOT="$VAULT" bash "$SCRIPT_DIR/changed-wiki-notes.sh" --since "$LAST" --deleted 2>/dev/null)"
CWN_STATUS=$?
if [[ "$CWN_STATUS" -ne 0 ]]; then
  echo "CONCEPT-GRAPH: SKIPPED - changed-wiki-notes.sh --deleted failed (exit $CWN_STATUS), staleness not measurable"
  exit 0
fi
# The streams are disjoint by construction, so summing them never double-counts.
N="$(printf '%s\n%s\n' "$STALE_LIST" "$DELETED_LIST" | grep -c . | tr -d ' \r')"
D="$(printf '%s\n' "$DELETED_LIST" | grep -c . | tr -d ' \r')"

# --- 2. verdict — the count is printed on BOTH paths ------------------------
if [[ "$N" -le "$THRESHOLD" ]]; then
  echo "CONCEPT-GRAPH: OK - $N document(s) behind the wiki graph's last commit (threshold $THRESHOLD)"
  exit 0
fi

# M: the same count as of the last save — the last commit touching logs/, which
# every /brain:save makes. A graph committed at or after that save means the
# clock was reset since, so M is 0. Committed history only: one diff, adds,
# modifies, renames (new path) and deletions each one entry, as N counts them.
# The `-- wiki` pathspec resolves from the vault dir, so it already scopes the
# diff to this vault's wiki/ even when the vault is a repo subdirectory.
SAVE="$(git -C "$VAULT" log -1 --format=%H -- logs 2>/dev/null | tr -d '[:space:]')"
if [[ -z "$SAVE" ]]; then
  WAS="no prior save"
elif git -C "$VAULT" merge-base --is-ancestor "$SAVE" "$LAST" 2>/dev/null; then
  WAS="was 0 at last save"
else
  M="$(git -C "$VAULT" -c core.quotepath=false diff --name-only -M "$LAST" "$SAVE" -- wiki 2>/dev/null \
    | grep -c '\.md$' | tr -d '[:space:]')"
  WAS="was ${M:-0} at last save"
fi

{
  echo "CONCEPT-GRAPH: STALE - $N document(s) behind, $WAS (threshold $THRESHOLD); wiki graph last committed at ${LAST:0:12}"
  echo "  $N wiki note(s) were added/modified/deleted since the concept graph was last built,"
  echo "  across ALL sessions — the session-changed list alone cannot see this."
  echo "  /brain:save runs the refresh on this verdict; declining needs a stated reason,"
  echo "  recorded with this line."
  if [[ "$D" -gt 0 ]]; then
    # INNOV-351, measured on graphify 0.8.46: --update prunes the deleted notes'
    # nodes in memory, then the #479 shrink guard refuses to write the smaller
    # graph.json, and the update has already saved a manifest without them, so a
    # re-run reports nothing to update. The phantom nodes survive for good.
    # Re-measured on 0.9.79 (INNOV-393): same outcome, the update's to_json
    # refuses 4 < 7 nodes and the next detect_incremental lists no deletions.
    echo "  $D of them are deleted notes. An incremental wiki --update cannot drop their"
    echo "  nodes: graphify's shrink guard (#479) refuses the smaller graph, and the update"
    echo "  has already forgotten the deletions. Remedy: rm graphify-out/graph.json, then"
    echo "  run /brain:save step 5c's full build (skill, wiki, no --update; git keeps the"
    echo "  old graph), then commit graphify-out/, and re-run:"
  else
    echo "  Remedy: run /brain:save step 5c's graphify refresh (skill, wiki --update),"
    echo "  then commit graphify-out/, and re-run:"
  fi
  echo "    BRAIN_ROOT=\"$VAULT\" bash check-concept-graph.sh"
} >&2
exit 1
