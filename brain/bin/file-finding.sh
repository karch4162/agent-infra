#!/usr/bin/env bash
# file-finding.sh — queue a plugin defect for automatic tracker filing.
#
# When a guard detects a condition it cannot self-heal (shrink-guard/label
# refusal, unresolvable source: anchor, mis-scoped graph, label-count
# regression), it calls this script instead of failing silently — and so does
# an agent that hits a plugin bug (templates/CLAUDE.brain.md says so). Agents
# kept logging these bugs in random places; this makes the path mechanical.
#
# QUEUE + DRAIN (INNOV-262): scripts have NO tracker credentials, so this
# script never talks to a tracker. It ALWAYS writes the finding to a local queue:
#
#   <vault>/.brain/findings-queue.jsonl     (one JSON object per line)
#
# The skill layer (an agent with tracker MCP access) drains the queue to the
# tracker committed in <vault>/brain.json — see the "Drain the findings queue"
# section in skills/save/SKILL.md. Dedup is by a
# stable fingerprint: sha over defect-class + repo + NORMALIZED evidence
# (lowercased, digits stripped, whitespace collapsed — so "3 vs 12" and
# "5 vs 12" are the same recurring defect). A repeat finding bumps `count`
# on the existing queue line instead of adding a new one; the fingerprint
# doubles as the Jira label (brain-fp-<12hex>) the drain searches before
# creating a ticket.
#
# Usage:
#   BRAIN_ROOT=<vault> bash file-finding.sh <defect-class> <repo> <evidence...>
#
# defect-class: kebab-case, e.g. shrink-guard-refusal, unresolvable-source-anchor,
#               mis-scoped-graph, label-count-regression (free-form; those four
#               are the documented ones).
# evidence:     remaining args, joined — paths, counts, identifiers ONLY.
#               NEVER pass secrets or file contents; this script stores its
#               args verbatim and reads no vault files — only its own
#               ../.claude-plugin/plugin.json, for the plugin_version stamp
#               ("unknown" when unreadable; INNOV-404).
#
# Contract:
#   ALWAYS exits 0 — a bug-filing helper must never break the calling command.
#   first line:  FINDING: QUEUED ...   (stdout — tells the user a ticket is coming)
#             or FINDING: SKIPPED ...  (stderr — queue unwritable / bad args; the
#                                       calling command proceeds untouched)
set -uo pipefail

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
QUEUE_DIR="$VAULT/.brain"
QUEUE="$QUEUE_DIR/findings-queue.jsonl"

skip() { echo "FINDING: SKIPPED — $1 (nothing queued; the calling command is unaffected)" >&2; exit 0; }

[[ $# -ge 3 ]] || skip "usage: file-finding.sh <defect-class> <repo> <evidence...>"
CLASS="$1"; REPO="$2"; shift 2
EVIDENCE="$*"

# --- fingerprint: class + repo + normalized evidence -------------------------
# Normalization is for the KEY only; the queue stores the evidence verbatim.
norm="$(printf '%s' "$EVIDENCE" | tr '[:upper:]' '[:lower:]' | tr -d '0-9' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
key="$CLASS|$REPO|$norm"
# macOS has no sha256sum; cksum is POSIX and good enough as a last resort.
if command -v sha256sum >/dev/null 2>&1; then
  hash="$(printf '%s' "$key" | sha256sum | cut -c1-12)"
elif command -v shasum >/dev/null 2>&1; then
  hash="$(printf '%s' "$key" | shasum -a 256 | cut -c1-12)"
else
  hash="$(printf '%s' "$key" | cksum | tr -s ' ' | tr ' ' '-' | cut -c1-12)"
fi
FP="brain-fp-$hash"

# --- queue write (graceful: any failure is a SKIP, never an error) ----------
mkdir -p "$QUEUE_DIR" 2>/dev/null || skip "queue dir $QUEUE_DIR is not writable"
[[ -d "$QUEUE_DIR" && -w "$QUEUE_DIR" ]] || skip "queue dir $QUEUE_DIR is not writable"

json_escape() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
NOW="$(date -u +%FT%TZ 2>/dev/null || date +%F)"

count=1
if [[ -f "$QUEUE" ]] && grep -qF "\"fingerprint\":\"$FP\"" "$QUEUE" 2>/dev/null; then
  # Repeat finding: bump count + last_seen on the existing line, in place.
  # ponytail: read-modify-write with no lock; concurrent syncs of one vault are
  # already guarded upstream (session.sh) — add flock here if that ever changes.
  prev="$(grep -F "\"fingerprint\":\"$FP\"" "$QUEUE" | head -1 | sed -n 's/.*"count":\([0-9][0-9]*\).*/\1/p')"
  [[ "$prev" =~ ^[0-9]+$ ]] || prev=1
  count=$((prev + 1))
  tmp="$QUEUE.tmp.$$"
  if awk -v fp="\"fingerprint\":\"$FP\"" -v c="$count" -v now="$NOW" '
        index($0, fp) { sub(/"count":[0-9]+/, "\"count\":" c); sub(/"last_seen":"[^"]*"/, "\"last_seen\":\"" now "\"") }
        { print }' "$QUEUE" >"$tmp" 2>/dev/null && mv "$tmp" "$QUEUE" 2>/dev/null; then :; else
    rm -f "$tmp" 2>/dev/null
    skip "queue $QUEUE could not be rewritten"
  fi
else
  # INNOV-404: stamp the queuing install's version so triage can tell a finding
  # from a pre-fix install. A repeat keeps the first stamp (the awk above never
  # touches it).
  PJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../.claude-plugin/plugin.json"
  VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PJ" 2>/dev/null | head -1)"
  line="{\"fingerprint\":\"$FP\",\"class\":\"$(json_escape "$CLASS")\",\"repo\":\"$(json_escape "$REPO")\",\"evidence\":\"$(json_escape "$EVIDENCE")\",\"count\":1,\"first_seen\":\"$NOW\",\"last_seen\":\"$NOW\",\"plugin_version\":\"$(json_escape "${VER:-unknown}")\"}"
  printf '%s\n' "$line" >>"$QUEUE" 2>/dev/null || skip "queue $QUEUE is not writable"
fi

# Tracker-blind on purpose: the drain resolves the destination from the vault's
# committed brain.json, so this message must not name a board.
echo "FINDING: QUEUED $CLASS for $REPO ($FP, seen ${count}x) — it will be filed to this vault's tracker (brain.json) at the next /brain:save drain; you do not need to file it."
exit 0
