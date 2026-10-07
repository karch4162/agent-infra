#!/usr/bin/env bash
# Required fresh correctness review for a Claude wave worker.
#
#   bash "$WAVE/review.sh" INNOV-309
#   RISK_REVIEW=1 bash "$WAVE/review.sh" INNOV-309
#
# Codex Terra is the one correctness reviewer. Grok is added only for a defined
# architecture risk. A failed Codex verdict is never retried elsewhere; only Codex
# quota exhaustion falls back (grok, then sonnet), and the REVIEWER line says so.
# Every attempt leaves .wave-review.<name>.log/.err in the worktree. Every reviewer is
# read-only: Codex and Sonnet by flags, Grok by guard_readonly (lib.sh).
set -uo pipefail

ISSUE="${1:-}"
RISK_REVIEW="${RISK_REVIEW:-0}"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DIFF_FILE="$ROOT/.wave-review.diff"

wave_exclude '.wave-review.*'
wave_exclude '.wave-plan*'   # a risk-tier plan is scratch, never part of the reviewed diff
{
  git diff --merge-base $WAVE_BASE
  git ls-files --others --exclude-standard -z | xargs -0 -r -I{} git diff --no-index -- /dev/null {}
} > "$DIFF_FILE"
[ -s "$DIFF_FILE" ] || { echo "NO CODEX REVIEW: empty diff against $WAVE_BASE"; exit 1; }

correctness_prompt="Review the unified diff supplied on stdin. It is this worktree's complete change against $WAVE_BASE, including untracked files. Report only high-confidence findings, most severe first, each with file:line. Check correctness, CLAUDE.md rules, security boundaries, and whether each changed test asserts behavior rather than only execution. No style nits or summary. End with TEST VERDICT: followed by either none, or one bullet per changed test naming behavior or execution."

architecture_prompt="Act as an adversarial architecture reviewer. This worktree's complete change against $WAVE_BASE, including untracked files, is the unified diff in .wave-review.diff at the repo root: read it first. You are read-only: do not edit, create, or delete any file. Look only for high-confidence failures in trust boundaries, tenant isolation, API contracts, concurrency, recovery, or operational behavior. Cite file:line. Do not repeat ordinary correctness findings or make style comments. End with ARCHITECTURE VERDICT: PASS, FINDINGS, or NEEDS HUMAN."

# `codex review` treats --base, --uncommitted, and a custom prompt as alternative
# review inputs. Feed our saved complete diff to `exec` instead so Terra receives
# the exact same scope that the worker must gate, including untracked test files.
codex_out="$(cat "$DIFF_FILE" | timeout 900 codex exec -s read-only --model gpt-5.6-terra "$correctness_prompt" 2>"$ROOT/.wave-review.codex-terra.err")"
printf '%s\n' "$codex_out" > "$ROOT/.wave-review.codex-terra.log"
if verdict_ok 'TEST VERDICT:' "$codex_out"; then
  printf '%s\nREVIEWER: codex-terra\n' "$codex_out"
elif grep -qiE 'usage limit|usage_limit_exceeded|rate limit' "$ROOT/.wave-review.codex-terra.err"; then
  # Quota exhaustion only. A bad or missing verdict from a working Codex is never
  # retried elsewhere. Grok first (different family from the Claude worker), then
  # Sonnet. The REVIEWER line names the fallback so human review sees the weaker gate.
  fallback_prompt="${correctness_prompt/supplied on stdin/in the file .wave-review.diff at the repo root (read it first; you are read-only, edit nothing)}"
  name=grok-fallback
  run_grok "$fallback_prompt" "$ROOT/.wave-review.$name.err"
  fb_out="$GROK_OUT"
  if [ "$GROK_RC" -eq 3 ]; then
    echo "NO CODEX REVIEW: the grok fallback modified the worktree; inspect git status before anything else"
    exit 1
  fi
  printf '%s\n' "$fb_out" > "$ROOT/.wave-review.$name.log"
  if ! verdict_ok 'TEST VERDICT:' "$fb_out"; then
    name=sonnet-fallback
    fb_out="$(timeout 900 claude -p --model sonnet --allowedTools Read Grep Glob "$fallback_prompt" 2>"$ROOT/.wave-review.$name.err")"
    printf '%s\n' "$fb_out" > "$ROOT/.wave-review.$name.log"
  fi
  if ! verdict_ok 'TEST VERDICT:' "$fb_out"; then
    echo "NO CODEX REVIEW: Codex quota exhausted and no fallback returned a complete TEST VERDICT (grok: $GROK_WHY); see .wave-review.*-fallback.log/.err"
    exit 1
  fi
  printf '%s\nREVIEWER: %s (codex quota exhausted)\n' "$fb_out" "$name"
else
  echo "NO CODEX REVIEW: Codex Terra did not return a complete TEST VERDICT; see .wave-review.codex-terra.log/.err"
  exit 1
fi

if [ "$RISK_REVIEW" != "1" ]; then
  exit 0
fi

# Grok's CLI requires bypassPermissions to complete this read-only review in the
# current local setup. The prompt confines its role and guard_readonly enforces it.
run_grok "$architecture_prompt" "$ROOT/.wave-review.grok.err"
grok_out="$GROK_OUT"
if [ "$GROK_RC" -eq 3 ]; then
  echo "NO GROK ARCHITECTURE REVIEW: grok modified the worktree; inspect git status before anything else"
  exit 1
fi
printf '%s\n' "$grok_out" > "$ROOT/.wave-review.grok.log"
if [ "$GROK_RC" -eq 124 ]; then
  # Reviewer wall-clock alone never blocks a PR (INNOV-391): like Codex quota, the
  # marker names the missing gate so the human reads that diff themselves.
  printf 'Grok %s; see .wave-review.grok.log/.err\nARCHITECTURE REVIEWER: grok-timeout (fallback)\n' "$GROK_WHY"
  exit 0
fi
if ! verdict_ok 'ARCHITECTURE VERDICT:' "$grok_out"; then
  echo "NO GROK ARCHITECTURE REVIEW: $GROK_WHY; see .wave-review.grok.log/.err"
  exit 1
fi

printf '%s\nARCHITECTURE REVIEWER: grok\n' "$grok_out"
