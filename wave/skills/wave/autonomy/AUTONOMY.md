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

**Trackers the picker reads.** ClickUp (`WAVE_CLICKUP_LIST`, token in `CLICKUP_API_TOKEN`) and
Jira through the Atlassian CLI (`acli`, its own login): the picker runs the repo's
`WAVE_QUEUE` JQL verbatim, so put status, `agent-ready` and `assignee IS EMPTY` in it.
Linear is not wired for automatic picking yet.

**One engine for unattended runs (INNOV-444).** Anything scheduled (Task Scheduler,
cron, an Orca automation, the control repo) runs `autonomy_tick.py`, never
`coordinator.sh`. The tick is resumable from the status files, so a missed firing or
a crash loses nothing. `coordinator.sh` is a long-lived loop for a wave a person starts
and watches (SKILL.md, "Supervised wave"); do not schedule it.

## Scheduled waves across repos (`wave_run.py`, INNOV-443)

One control folder (default `~/Projects/wave-control`; `--control` or `WAVE_CONTROL_DIR`)
holds only `config.env` (repo allowlist, machine-wide caps, schedule, stop file) and `state/`
(audit log, last run, escalations, cooldowns, lock). One scheduler automation runs:

```bash
python <control>/bin/wave_run.py precheck --trigger scheduled   # gates only; exit 3 = skip (cheap Orca precheck)
python <control>/bin/wave_run.py run --trigger intake|scheduled|owner
python <control>/bin/wave_run.py status
```

`bin/wave_run.py` is a small launcher that finds this plugin (`WAVE_HOME`, else the newest
installed version) and runs `autonomy/wave_run.py`. Each firing takes the machine lock and
runs **one tick per repo** with the caps the machine has left (`MAX_WORKERS`,
`DAILY_TICKET_CAP`, `BUDGET_PER_DAY`, `CLAUDE_PAUSE_PCT`) handed to it as env overrides.
Gates: stop file, trigger, empty `SCHEDULE_WAVE`, `MAX_WAVES_PER_DAY`, per-repo cooldown
after a failed tick. Exit codes: 0 ok, 1 a repo failed (escalated), 2 config error, 3 skipped.

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
| closeout | `WAVE_CLOSEOUT_CMD` when `autonomy/closeout-pending.json` lists a merge and nothing is live; a merge writes the marker at once, so a later tick runs the closeout a killed or deferred tick owed. The marker records the closeout's pid: while it is alive no second closeout starts (one notice past the 60-min timeout), and a merge sha gh did not report is looked up again before closeout runs | `autonomy/closeout-last.log`; the marker is cleared once the command finishes, pass or fail |

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
| Auto-merge at all | `WAVE_AUTO_MERGE=1` (0 holds every PR; the old `WAVE_AUTO_MERGE_LOW_MEDIUM=0` still means off) |
| Auto-merge medium | `WAVE_AUTO_MERGE_MEDIUM=0`: owner-only, and it also needs `WAVE_CLEAN_WAVES_FOR_MEDIUM=3` green closeouts in a row (`autonomy/clean-waves.json`); a red closeout resets the streak and suspends it |
| Picking by rating | the tick (scheduled) takes `rating:low` only; `backlog_watch.py --trigger owner` also takes medium. Unrated tickets are never picked |
| Spend cap per day | `WAVE_BUDGET_PER_DAY_USD` (empty = none): today's runs at Claude API prices, from `worker.log` (direct) or the worktree's session logs (Orca, ~20% low). A start that would cross it, at today's mean per run, is refused. Codex runs are unpriced. Written to each run's `usage.json` (`cost_usd_last`, `cost_source`) |
| Budget pause | `WAVE_BUDGET_GUARD=1` (reads `WAVE_CLAUDE_WEEKLY_PCT`, Codex preflight) |
| Grok challenge | `WAVE_GROK_CHALLENGE=1` (`autonomy/grok_calls.jsonl` counts calls) |

## Model roles

- medium: Opus implements, Codex reviews, Grok challenges.
- low: Codex may implement, Opus reviews, Grok challenges.
- Rating comes from the ticket tags `rating:low|medium|risky` (default medium).

## Tests

`bash tests/test-wave-autonomy.sh` (CI), or in the plugin dir
`python test_wave_autonomy.py` and `python test_wave_infra_blockers.py`.
