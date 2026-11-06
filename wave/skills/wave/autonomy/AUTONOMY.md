# Wave autonomy (direct runtime + backlog-watch)

The direct runtime runs waves without Orca: `git worktree` + `claude -p` /
`codex exec`, one dir per ticket under `<repo>/.claude/wave/runs/<ticket>/`
(`status.json`, `worker.pid`, `worker.log`, `prompt.txt`, `summary.md`, `usage.json`).
On top of it, backlog-watch picks agent-ready tickets and `autonomy_tick.py` runs
the whole pipeline. **Both are opt-in per repo** in `.claude/wave/config.env`:

```
WAVE_RUNTIME=direct        # spawn.sh / status.sh / cost.sh use the direct runtime; orca: tick workers in Orca terminals
WAVE_BACKLOG_WATCH=1       # the tick may pick and spawn; keep 0 until you turn it on
```

Every command runs from inside the target repo with
`WAVE="${CLAUDE_PLUGIN_ROOT}/skills/wave"`.

## One tick

```bash
python "$WAVE/autonomy/autonomy_tick.py"                 # dry run: report, change nothing
python "$WAVE/autonomy/autonomy_tick.py" --execute       # act once
python "$WAVE/autonomy/autonomy_tick.py" --execute --loop 600   # every 10 min, own terminal
```

Each tick, idempotent, resumable from the status files:

| stage | reads | writes |
|---|---|---|
| reconcile | `status.json` + real PID (Orca: `summary.md` or the terminal), `gh pr list --head <branch>` | `exited`, `pr_open`, or `done_held` (no PR) |
| ci | `gh pr view --json statusCheckRollup` (every check counts; empty is pending) | `ci_green` or `done_held` |
| challenge | Grok in the surviving worktree, read-only, diff written for it | `challenged` + verdict |
| merge | `merge_policy.decide` over the PR body's `## Wave` block + checks + challenge | `done_merged` or `done_held`; tracker status + comment |
| spawn | `backlog_watch` (cap, slots, rating, sufficiency), plan loop when thin | a worker; daily cap counted only after the spawn succeeded |
| closeout | `WAVE_CLOSEOUT_CMD` when something merged and nothing is live | `autonomy/closeout-last.log` |

## Watching workers in Orca

`WAVE_RUNTIME=orca` keeps the tick and the run folders exactly as above but starts
each worker as an interactive agent in its own Orca terminal (`orca worktree create
--agent … --surface terminal`), so you can watch it and type into it.

- Orca's per-agent launch settings decide the permission flags; unattended runs need
  Claude's `--dangerously-skip-permissions` and Codex's sandbox bypass set there.
- An interactive agent does not exit when it finishes. The tick counts it done when
  it writes `summary.md` (the contract's last step, after the PR) or its terminal
  closes. A worker silent for 20 minutes gets one notice, never a kill. Terminals
  are left open; the sweep removes the worktrees.
- Orca not running, or the repo not registered with Orca: the tick spawns direct
  and leaves a notice, since it runs when no one is at the IDE.
- Codex workers need `CLICKUP_*`/`WAVE_*` in their commands. The direct runtime
  forces that per launch; Orca cannot, so a Codex worker spawns direct (with a
  notice) unless `~/.codex/config.toml` has `[shell_environment_policy]`
  `inherit = "all"`.
- No `worker.log`: tokens come from the agents' own session logs, so the control
  center's Claude cost-per-merge is empty for Orca runs.

A scheduled task (Task Scheduler / cron) runs the `--execute` form with
`CLICKUP_API_TOKEN` in its environment, never on the command line.
On Windows the tick renders the worker prompt through Git's bash (found next to
`git`; `WAVE_BASH` overrides). A bare `bash` on PATH is often WSL's, which cannot
see this filesystem, so it is never used.

## What it never does

- start a `rating:risky` ticket (flagged in `autonomy/human_risky.md`)
- merge without CI green, a primary `REVIEW VERDICT: YES`, and a challenge with
  no unresolved blocker; a fallback reviewer, a tie-break, a timed-out challenge,
  `MIGRATION` other than `no`/additive, or a second conflict all hold
- force-push, or retry a rebase more than once
- write anything to the tracker in a dry run

Everything it stops on lands in `autonomy/human_*.md`; `wave_status.py` (or
`status.sh` in direct mode) shows every run with the live PID, last step, PR and cost.

## Caps and knobs (config.env)

| Guard | Default |
|---|---|
| Daily ticket starts | `WAVE_DAILY_TICKET_CAP=3` |
| Concurrent implementers | `WAVE_MAX_IMPLEMENT_WORKERS=3` |
| Plan revise rounds | `WAVE_PLAN_ROUNDS_CAP=2` |
| Auto-merge low/medium | `WAVE_AUTO_MERGE_LOW_MEDIUM=1` |
| Budget pause | `WAVE_BUDGET_GUARD=1` (reads `WAVE_CLAUDE_WEEKLY_PCT`, Codex preflight) |
| Grok challenge | `WAVE_GROK_CHALLENGE=1` (`autonomy/grok_calls.jsonl` counts calls) |

## Model roles

- medium: Opus implements, Codex reviews, Grok challenges.
- low: Codex may implement, Opus reviews, Grok challenges.
- Rating comes from the ticket tags `rating:low|medium|risky` (default medium).

## Tests

`bash tests/test-wave-autonomy.sh` (CI), or in the plugin dir
`python test_wave_autonomy.py` and `python test_wave_infra_blockers.py`.
