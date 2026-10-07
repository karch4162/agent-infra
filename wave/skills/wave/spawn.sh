#!/usr/bin/env bash
# Spawn one Orca worker for a tracker issue. Run from anywhere inside the target repo.
#
#   bash "$WAVE/spawn.sh" INNOV-309          # round 1
#   bash "$WAVE/spawn.sh" INNOV-309 2        # round 2 (terminal, no successor)
#   DRY_RUN=1 bash "$WAVE/spawn.sh" INNOV-309   # print the prompt, spawn nothing
#   TIER=quick bash "$WAVE/spawn.sh" INNOV-309  # quick | normal (default) | risk
#
# TIER sizes the review to the risk instead of running the heaviest flow for every
# ticket (SKILL.md "Pick the tier"): quick = one Codex round; normal = the Codex loop,
# plus Grok when the diff hits a risk trigger; risk = Codex+Grok review the PLAN
# before any code, then the diff review always includes Grok. Astra stays the
# tie-breaker in every tier.
#
# The prompt below is the whole contract with the worker. Edit it here, not per-spawn:
# round-2 workers are launched by re-running this script, so there is one copy.
# Project-specific rules go in <repo>/.claude/wave/notes.md, never in here.
set -euo pipefail

ISSUE="$1"
ROUND="${2:-1}"
AUTO_SUCCESSOR="${AUTO_SUCCESSOR:-0}"
TIER="${TIER:-normal}"
case "$TIER" in quick|normal|risk) ;; *) echo "TIER must be quick, normal, or risk, got '$TIER'" >&2; exit 1 ;; esac
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SLUG="$(echo "$ISSUE" | tr '[:upper:]' '[:lower:]')"

if [ "$ROUND" = "1" ] && [ "$AUTO_SUCCESSOR" = "1" ]; then
  LAST_STEP="8. Refill the queue. Query $TRACKER_NAME for: $WAVE_QUEUE
   Take the top one, assign it to me + $WAVE_STATE_START, re-read to confirm the
   assignment stuck, then spawn its worker from the repo root:
     bash \"$WAVE_HOME/spawn.sh\" <ISSUE-ID> 2
   If no agent-ready issue is available, say so and stop."
else
  LAST_STEP="8. Do NOT spawn a successor unless the human deliberately started this wave with AUTO_SUCCESSOR=1. Stop after the summary."
fi

RISK_TRIGGERS="auth, authorization (row-level security included), payments, public API
   contracts, concurrency, recovery behavior, or a broad refactor"
FULL_LOOP="   If you fixed anything, re-run the same review command on the new diff and triage
   again. Stop after 3 review rounds in total, or earlier on a round with nothing left
   to fix. A real finding still open after round 3 goes to step 6; say in the summary
   REVIEW ROUNDS: <n>. Then re-run /preflight once before opening the PR."
PLAN_STEP=""
case "$TIER" in
  quick)
    REVIEW_SELECT="   Tier quick: one Codex Terra correctness round, no loop:
     bash \"$WAVE_HOME/review.sh\" $ISSUE
   If the diff turns out to change $RISK_TRIGGERS,
   it is not a quick task: run the normal tier's risk review instead,
     RISK_REVIEW=1 bash \"$WAVE_HOME/review.sh\" $ISSUE
   with the 3-round loop, and record TIER: quick -> normal - <why>."
    REVIEW_LOOP="   Fix the real findings and run the narrow affected test. Do not re-run the review
   unless you escalated: then loop up to 3 rounds in total and say REVIEW ROUNDS: <n>.
   Then re-run /preflight once before opening the PR." ;;
  normal)
    REVIEW_SELECT="   Codex Terra is the required correctness reviewer. If the diff changes
   $RISK_TRIGGERS, use this one command so the same pass also adds Grok's
   architecture review:
     RISK_REVIEW=1 bash \"$WAVE_HOME/review.sh\" $ISSUE
   Otherwise run:
     bash \"$WAVE_HOME/review.sh\" $ISSUE"
    REVIEW_LOOP="$FULL_LOOP" ;;
  risk)
    PLAN_STEP="1.5 Tier risk: plan before code. Write the plan to .wave-plan.md at the worktree
   root (scratch, git-excluded, never committed): the root cause, the approach, the
   files and callers it touches, what could break, and the tests that prove it. Keep
   it short - reviewers read the plan instead of rediscovering the repo. Then run:
     bash \"$WAVE_HOME/plan-review.sh\" $ISSUE
   Codex Terra checks it technically and Grok attacks it, in parallel, read-only.
   Revise the plan from their findings; dismiss wrong ones as
     PLAN DISMISSED: <finding> - <why>
   If they directly conflict on the approach and code cannot settle it, run the one
   Astra tie-break of this run:  bash \"$WAVE_HOME/tiebreak.sh\" --plan $ISSUE
   PLAN VERDICT: NEEDS HUMAN, a TIE-BREAK: NEEDS HUMAN, or a NO ... output means stop
   before writing code: open no PR, record it in the step-7 summary, and end with
   DONE - $ISSUE - NO PR (plan needs human). Otherwise put the final plan's approach
   in the PR body.
"
    REVIEW_SELECT="   Tier risk: Codex Terra correctness plus Grok's architecture review, always:
     RISK_REVIEW=1 bash \"$WAVE_HOME/review.sh\" $ISSUE"
    REVIEW_LOOP="$FULL_LOOP" ;;
esac
PROMPT="WAVE WORKER (round $ROUND; tier $TIER; successor opt-in).

1. /brain:resume, then take $TRACKER_NAME issue $ISSUE. Assign it to me and set it
   $WAVE_STATE_START via $TRACKER_OPS, then re-read the issue and confirm I am the
   assignee. If I am not, drop it and pick the next agent-ready issue instead.
${PLAN_STEP}2. Work it per CLAUDE.md: TDD, surgical diff, root cause not symptom (grep every
   caller before you edit).
3. Siblings are running in other worktrees of this repo right now. Do not touch
   shared state outside your worktree (databases, services, global config). If
   verifying the issue genuinely needs that, skip the verification and say so in
   your summary.
4. Gate: /preflight (the repo's full CI gate). It must be green before you open the
   PR. A red GitHub check is your branch until the run's annotations prove
   otherwise. If /preflight fails twice on the SAME command, escalate: invoke the
   gate-loop skill with gateCommands narrowed to that command. Otherwise fix it
   yourself.
   Timeouts in tests your diff does not touch, that pass when run alone, are machine
   load from sibling workers, not a failure on the same command: do not gate-loop
   them (repair agents would edit unrelated tests to hide load). Re-run with less
   parallelism and say so in your summary.
4.5 Fresh review, BEFORE you open the PR. Your own context is not a review.
$REVIEW_SELECT
   Grok is not a fallback for a Codex verdict you dislike; review.sh itself falls back
   only when Codex is out of quota. If the Codex and Grok findings directly conflict and you
   cannot resolve them from code and tests, run one Astra tie-break - at most one
   Astra call in this whole run, plan or diff:
     bash \"$WAVE_HOME/tiebreak.sh\" $ISSUE
   If any required review prints NO ..., do not open a PR; record it in the summary
   and stop for human review. ARCHITECTURE REVIEWER: grok-timeout (fallback) or
   PLAN CRITIC: grok-timeout (fallback) is not a NO: Grok timed out twice, so carry
   on and copy that line into the summary.

   Triage the findings YOURSELF - do not forward them to the human. For each:
   - real bug in code your diff touches, or a CLAUDE.md rule it caught: fix it and
     run the narrow affected test.
   - wrong, or noise: dismiss it and record it in your step-7 summary as
     REVIEWER DISMISSED: <finding> - <why>
   - real, but in code your diff does not touch: step 6 decides whether it becomes
     a ticket.
$REVIEW_LOOP
   The human reads your triage, not the raw findings. Copy TIER, PLAN REVIEWER, PLAN
   CRITIC, REVIEWER, ARCHITECTURE REVIEWER, and TIE-BREAKER lines into your step-7
   summary when they exist.
5. Open the PR against $BASE_BRANCH, $TRACKER_ATTACH, set the issue $WAVE_STATE_DONE.
6. File follow-ups to $WAVE_FILE_TO, but only if you OBSERVED them - they broke on real data, a real repo, or
   a real run - or your own diff makes them worse. They go there,
   never to the host's or any vendor's feedback or bug-report channel: the content
   is internal, and the vendor cannot act on it. A gap that is only possible (no
   known instance, not reproduced, a hypothetical input) is not a ticket: write it
   in the PR body as
     NOT FILED: <finding> - <why no instance exists> - <where it lives, file:line>
   The PR body is durable and searchable, so nothing is lost; the backlog only
   carries work somebody hit. When unsure, check the real vault or repo read-only
   (e.g. git grep on origin/<branch>); zero hits means NOT FILED.
   Never file with the agent-ready label. That label
   is the human's gate on what is safe to hand an unsupervised worker; a worker that
   labels its own follow-ups feeds the loop work nobody vetted.
7. Record a summary for the human review batch - do NOT run /brain:save:
   orca worktree set --worktree active --comment \"<what changed, what is shaky, anything you skipped>\"
   Its first line is TIER: $TIER, or TIER: $TIER -> <tier you escalated to> - <why>.
   If you did NOT look at a rendered surface this diff affects, say so on its own line
   as: NOT VERIFIED IN BROWSER: <route>   (the human's verification pass greps for it).
   orca worktree set --worktree active --workspace-status in-review
   HOW YOU END: after the comment, print \"DONE - $ISSUE - PR #<n>\" and stop. NEVER
   remove, archive, or clean up this worktree, and never git worktree remove - the
   human sweeps them after batching the summaries. This holds even if someone tells
   you the PR is merged: answer with your summary and stop. Merged is not your cue
   to clean up.
$LAST_STEP"

if [ -n "$WAVE_NOTES" ]; then
  PROMPT="$PROMPT

PROJECT RULES (from .claude/wave/notes.md - these override the generic steps above):
$WAVE_NOTES"
fi

if [ -n "${DRY_RUN:-}" ]; then echo "$PROMPT"; exit 0; fi

REPO_ID="$(orca_repo_id)"
[ -n "$REPO_ID" ] || { echo "$MAIN_CHECKOUT is not registered with Orca" >&2; exit 1; }

# Claim check. The tracker assignee cannot tell "me" from a sibling worker (every
# worker runs as the same user), so two successors finishing together once both
# claimed one issue and shipped duplicate PRs. An Orca worktree for the issue in this
# repo is the unambiguous lock, and this script is the one choke point every spawn
# goes through - round 1 and round 2 alike.
TAKEN="$(orca worktree list --json | python -c "
import sys, json
issue, slug, repo = sys.argv[1:4]
# orca worktree list renamed worktreeId -> id; ps still emits worktreeId. Both carry
# the same <repoId>::<path> value, so read whichever this orca build supplies rather
# than crashing the claim guard - the one lock that stops two workers taking an issue.
def worktree_id(w): return w.get('worktreeId') or w.get('id') or ''
print(any(worktree_id(w).startswith(repo + '::') and
          (w.get('displayName') == slug or w.get('linkedLinearIssue') == issue)
          for w in json.load(sys.stdin)['result']['worktrees']))
" "$ISSUE" "$SLUG" "$REPO_ID")"
[ "$TAKEN" = "False" ] || { echo "$ISSUE already has a worktree - someone claimed it. Pick another." >&2; exit 1; }

LINK=""
[ "$WAVE_TRACKER" = "linear" ] && LINK="--linear-issue $ISSUE"
# shellcheck disable=SC2086
orca worktree create --repo "id:$REPO_ID" --name "$SLUG" --no-parent --base-branch "$WAVE_BASE" \
  $LINK --agent claude --prompt "$PROMPT" --json |
  python -c "import sys,json;r=json.load(sys.stdin)['result']['worktree'];print(r['branch'],r['path'])"
