#!/usr/bin/env bash
# check-hot-budget.sh — enforce the wiki/hot.md word budget MECHANICALLY.
#
# wiki/hot.md is the rolling session cache: /brain:resume reads it FIRST every
# session, and every save rewrites it. Every word over budget is therefore a tax
# on every future session. (5c no longer extracts it into the concept graph,
# INNOV-408.) The budget was documented as a HARD ~500 words and was
# enforced only by prose ("run wc -w after each edit and keep cutting") — it
# shipped at 709 words twice in a single session. Prose drifts; a script holds.
# So this script owns the budget: it measures, it REPORTS the number on every
# run, and it refuses when the file is over.
#
# It is deliberately dumb: one file, one `wc -w`, one verdict. It never edits
# hot.md, never commits, never touches git at all. brain/bin/freshness.mjs keeps
# its own 1.5x (~750 words) backstop for vaults nobody has saved in a while —
# that check fires far later and on purpose; this one is the gate.
#
# The VAULT is resolved from $BRAIN_ROOT (this plugin's neutral contract var),
# falling back to $CLAUDE_PROJECT_DIR then the current dir — the script lives in
# the plugin, NOT inside the vault, so it cannot derive the vault from its own
# location.
#
# Usage:
#   BRAIN_ROOT=<vault> bash check-hot-budget.sh                    # budget 500
#   BRAIN_ROOT=<vault> HOT_WORD_BUDGET=400 bash check-hot-budget.sh
#
#   HOT_WORD_BUDGET — word budget, default 500. Must be a non-negative integer;
#                     anything else is ignored (with a stderr note) and 500 is
#                     used, because a typo'd budget must not silently disable
#                     the gate.
#
# Contract (the /brain:save skill and its tests depend on exactly this):
#   exit 0  => at or under budget; proceed with the save.
#   exit 1  => OVER budget; do NOT proceed past step 3 until hot.md is cut down.
# The FIRST line of output always starts with "HOT-BUDGET: OK" (stdout) or
# "HOT-BUDGET: OVER" (stderr), so a caller can branch on it without parsing
# prose. BOTH verdict lines carry the actual word count, the budget and the
# overage — the number is reported whether or not anyone is over, so the trend
# is visible before it becomes a violation.
#
# Missing preconditions are never failures (same stance as check-freshness.sh):
# a vault mid-setup with no wiki/hot.md yet, a hot.md that is unreadable or not
# a regular file, or a `wc` that fails all report OK and exit 0. This is a guard
# against bloat, not a file-existence assertion — a save must not be blocked by
# a file that isn't there to be over budget.
set -uo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
HOT="$VAULT/wiki/hot.md"

DEFAULT_BUDGET=500
BUDGET="${HOT_WORD_BUDGET:-$DEFAULT_BUDGET}"
if ! [[ "$BUDGET" =~ ^[0-9]+$ ]]; then
  echo "  note: HOT_WORD_BUDGET='$BUDGET' is not a non-negative integer; using $DEFAULT_BUDGET." >&2
  BUDGET=$DEFAULT_BUDGET
fi

# --- 0. nothing to measure => OK (see header: missing inputs never fail) -----
if [[ ! -e "$HOT" ]]; then
  echo "HOT-BUDGET: OK - no wiki/hot.md under '$VAULT' yet (budget $BUDGET words), check skipped"
  echo "  hint: set BRAIN_ROOT to the vault if this was meant to be checked." >&2
  exit 0
fi

if [[ ! -f "$HOT" || ! -r "$HOT" ]]; then
  echo "HOT-BUDGET: OK - wiki/hot.md is not a readable regular file (budget $BUDGET words), check skipped"
  echo "  path: $HOT" >&2
  exit 0
fi

# --- 1. measure -------------------------------------------------------------
WORDS="$(wc -w <"$HOT" 2>/dev/null | tr -d ' \r')"
if ! [[ "$WORDS" =~ ^[0-9]+$ ]]; then
  echo "HOT-BUDGET: OK - could not count words in wiki/hot.md (budget $BUDGET words), check skipped"
  echo "  path: $HOT" >&2
  exit 0
fi

# --- 2. verdict — the count is printed on BOTH paths ------------------------
if (( WORDS <= BUDGET )); then
  echo "HOT-BUDGET: OK - wiki/hot.md is $WORDS words (budget $BUDGET, 0 over, $(( BUDGET - WORDS )) to spare)"
  exit 0
fi

OVER=$(( WORDS - BUDGET ))
{
  echo "HOT-BUDGET: OVER - wiki/hot.md is $WORDS words (budget $BUDGET, $OVER over)"
  echo "  wiki/hot.md is a rolling cache, not a log: /brain:resume reads it first every"
  echo "  session, so the overage is paid again and again."
  echo "  Remedy: delete the stalest bullets — anything that wouldn't change what the"
  echo "  next session does — then re-run:"
  echo "    BRAIN_ROOT=\"$VAULT\" bash check-hot-budget.sh"
  echo "  Cut at least $OVER words. The budget is met when this script says OK."
} >&2
exit 1
