#!/usr/bin/env bash
# check-egress.sh — does any shipped code path invoke a graphify LLM subcommand?
# (INNOV-390, /brain:doctor check 14; CI gate: tests/test-egress-gate.sh)
#
# WHY THIS EXISTS. POC §7's `egress` is which LLM backend graphify ships vault
# content to. The brain is egress-off by construction: the only graphify
# subcommand it runs is `graphify wiki` (local modules only). `extract`,
# `cluster-only`, `provider` and `label` import graphify.llm and can reach a
# remote backend, so one new line in sync-graph.sh could turn egress on.
#
# Not an env-key scan: graphify's claude-cli backend authenticates through the
# local `claude` CLI with no API key, so a credential scan would pass while
# content leaves. This asserts WHICH SUBCOMMAND RUNS.
#
# Scans every .sh, .mjs and .md code fence under the given dirs (default: this
# plugin's own root), skipping comment lines (#, //, /*, *) and .md prose, so
# text that names a subcommand to forbid it (label-communities.mjs, label/
# SKILL.md) does not trip. CRLF-safe.
# ponytail: static grep, misses an invocation built from a variable
# (`$G extract`); widen the pattern if such a call site ever appears.
#
# Usage:  bash check-egress.sh [dir ...]
# Contract:
#   exit 0  => "EGRESS: OK - scanned N file(s) ..."
#   exit 1  => "EGRESS: WARN <file:line>: <line>", one per invocation
set -uo pipefail

if [[ $# -eq 0 ]]; then
  set -- "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

files=()
while IFS= read -r f; do files+=("$f"); done < <(find "$@" -type f \( -name '*.sh' -o -name '*.mjs' -o -name '*.md' \) 2>/dev/null | sort)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "EGRESS: OK - scanned 0 file(s) under $*"
  exit 0
fi

# graphify, an optional quote and an optional `, [` (execFile argv form), then
# an LLM subcommand as a whole word. `graphify-out` and `graphify wiki` miss.
# One awk over every file: a process per file costs ~1 s each on Windows.
# A SKILL.md is agent-executed too, but only its code fences: prose there names
# subcommands to forbid them (label/SKILL.md), so .md lines outside a fence skip.
hits="$(awk '{
  sub(/\r$/, "")
  if (FNR == 1) { md = (FILENAME ~ /\.md$/); fence = 0 }
  l = $0
  sub(/^[ \t]+/, "", l)
  if (md && l ~ /^(```|~~~)/) { fence = !fence; next }
  if (md && !fence) next
  if (l ~ /^(#|\/\/|\/\*|\*)/) next
  if (l ~ /graphify["\047`]?[ \t]*(,[ \t]*[[]?[ \t]*)?["\047`]?(extract|cluster-only|provider|label)([^A-Za-z0-9_-]|$)/)
    print FILENAME ":" FNR ": " l
}' "${files[@]}")"

if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits" | sed 's/^/EGRESS: WARN /'
  echo "  These graphify subcommands can send vault content to a remote LLM; the brain" >&2
  echo "  runs only 'graphify wiki'. Remove the call or route it through the host session." >&2
  exit 1
fi
echo "EGRESS: OK - scanned ${#files[@]} file(s), no graphify LLM subcommand invoked"
