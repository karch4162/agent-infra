#!/usr/bin/env bash
# Risk-tier plan review, BEFORE any code is written (spawn.sh TIER=risk, step 1.5).
#
#   bash "$WAVE/plan-review.sh" INNOV-309
#
# The worker writes its plan to .wave-plan.md at the worktree root. Codex Terra checks
# it for correctness (does it fix the cause, what does it break, what must be tested);
# Grok critiques it adversarially (assumptions, simpler alternatives, failure modes).
# The two run in parallel and read-only, and see the plan rather than discovering the
# repo from scratch. Logs: .wave-plan-review.<name>.log/.err. tiebreak.sh --plan reads
# them. A missing verdict blocks: the plan is the cheap place to stop.
set -uo pipefail

ISSUE="${1:-}"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PLAN="$ROOT/.wave-plan.md"
LOG="$ROOT/.wave-plan-review"

wave_exclude '.wave-plan*'
[ -s "$PLAN" ] || { echo "NO PLAN REVIEW: write the plan to .wave-plan.md at the worktree root first"; exit 1; }

technical_prompt="Review the implementation plan supplied on stdin for $TRACKER_NAME issue $ISSUE, before any code is written. You may read repository files at $WAVE_BASE to check it. Report only high-confidence problems, most severe first: a plan that treats a symptom instead of the cause, callers or contracts it would break, CLAUDE.md rules it would violate, security boundaries, and tests the plan must add but does not. No style comments or summary. End with PLAN VERDICT: APPROVE, REVISE, or NEEDS HUMAN."

critic_prompt="Act as an adversarial reviewer of the implementation plan in .wave-plan.md at the repo root, for $TRACKER_NAME issue $ISSUE. Read it first. You are read-only: do not edit, create, or delete any file. Challenge it: questionable assumptions, unnecessary complexity, a simpler alternative, hidden coupling, tenant or trust boundaries, concurrency, recovery and other failure modes. Cite file:line where the plan's premise lives. Do not repeat ordinary correctness review. End with PLAN VERDICT: APPROVE, REVISE, or NEEDS HUMAN."

# Codex is sandboxed by -s read-only, so it can run beside Grok's guarded run.
timeout 900 codex exec -s read-only --model gpt-5.6-terra "$technical_prompt" \
  < "$PLAN" > "$LOG.codex-terra.log" 2> "$LOG.codex-terra.err" &
codex_pid=$!

run_grok "$critic_prompt" "$LOG.grok.err"
grok_out="$GROK_OUT"
grok_rc="$GROK_RC"
printf '%s\n' "$grok_out" > "$LOG.grok.log"
wait "$codex_pid"
codex_out="$(cat "$LOG.codex-terra.log")"

status=0
if verdict_ok 'PLAN VERDICT:' "$codex_out"; then
  printf '%s\nPLAN REVIEWER: codex-terra\n\n' "$codex_out"
else
  echo "NO CODEX PLAN REVIEW: Codex Terra did not return a PLAN VERDICT; see .wave-plan-review.codex-terra.log/.err"
  status=1
fi
if [ "$grok_rc" -eq 3 ]; then
  echo "NO GROK PLAN REVIEW: grok modified the worktree; inspect git status before anything else"
  status=1
elif [ "$grok_rc" -eq 124 ]; then
  printf 'Grok %s; see .wave-plan-review.grok.log/.err\nPLAN CRITIC: grok-timeout (fallback)\n' "$GROK_WHY"
elif verdict_ok 'PLAN VERDICT:' "$grok_out"; then
  printf '%s\nPLAN CRITIC: grok\n' "$grok_out"
else
  echo "NO GROK PLAN REVIEW: $GROK_WHY; see .wave-plan-review.grok.log/.err"
  status=1
fi
exit "$status"
