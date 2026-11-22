---
name: wave
description: Start a supervised wave on agent-ready tracker issues (Linear, Jira or ClickUp, configured per repo) - `/wave <issues>` runs coordinator.sh, which spawns the workers, gates and merges or holds their PRs, updates the tickets, walks and sweeps; `/wave spawn <issue>` is the explicit unsupervised launch - run the fresh-session checklist around it (leftovers, brain save, worktree sweep, queue check), or run the autonomy tick that drives spawn, CI, challenge and merge without a session in the loop. Use when the user says "/wave", "spin up N workers", "start a wave", "run the loop", "wave status", "autonomy tick", or opens a session wanting agents working the backlog.
---

# /wave — run a wave of workers

Each worker takes one issue in its own worktree, ships a PR, and writes a summary
(an Orca worktree comment on the `orca` runtime; `runs/<ticket>/summary.md` on the
`direct` runtime; see "Runtime" below). A successor wave is opt-in (`AUTO_SUCCESSOR=1`), not
automatic; the human reviews between ordinary waves.

## Invocation

| You type | What runs |
|---|---|
| `/wave [tier:]ISSUE...` (e.g. `/wave INNOV-447 quick:INNOV-355`) | **Supervised** (the default): `coordinator.sh` with those args, as a background job of this session. See "Supervised wave" below. |
| `/wave resume run_<id>` | `coordinator.sh --resume run_<id>`, also in the background |
| `/wave spawn [tier:]ISSUE...` | **Unsupervised**: `spawn.sh` per issue (`TIER=<tier>`). Nothing gates, merges, updates the ticket, walks or sweeps these; you do, with the checklist below. |
| `/wave` alone, `/wave status` | the fresh-session checklist |

A manual wave means supervised. Fall back to `spawn` only when asked for it by name, or
when the repo runs `WAVE_RUNTIME=direct`: `coordinator.sh` needs Orca and refuses there
(the direct runtime's supervisor is `autonomy/autonomy_tick.py`), so say that and ask
before spawning unsupervised workers.

The scripts live next to this file. Every command below uses
```bash
WAVE="${CLAUDE_PLUGIN_ROOT}/skills/wave"
```
and runs from inside the target repo. `spawn.sh` holds the worker prompt — the contract,
edited there and never per-spawn. `review.sh` is the pre-PR Codex Terra review with an
optional Grok risk review; `plan-review.sh` the risk tier's pre-code plan review (Codex
Terra + Grok, in parallel); `tiebreak.sh` the Astra-only escalation; `triage.sh` the
step-4 labelling pre-grep; `status.sh` steps 1 and 3; `cost.sh` per-ticket token split.
`DRY_RUN=1 bash "$WAVE/spawn.sh" <ISSUE>` prints the prompt without spawning.

## Pick the tier

One primary implementer (the Claude worker) per issue, and review sized to the risk.
Other providers review; they never re-implement the same issue. Set `TIER` per spawn:

| `TIER` | For | Review |
|---|---|---|
| `quick` | renames, copy/UI tweaks, boilerplate, a one-function bug with a named `file:line` | one correctness round, no loop: Codex Terra, or Opus when Codex wrote the diff (low rating, direct runtime). A diff that hits a risk trigger escalates itself to `normal`'s risk review. |
| `normal` (default) | the everyday bounded feature or fix | Codex Terra, up to 3 rounds; Grok added only when the diff hits a risk trigger (auth, authorization incl. RLS, payments, public API contracts, concurrency, recovery, broad refactor) |
| `risk` | anything you already know hits a risk trigger, or an architectural change | the worker writes `.wave-plan.md` first; Codex Terra (technical) and Grok (adversarial) review the plan in parallel before code; then the diff review always includes Grok |

Astra (`tiebreak.sh`, `--plan` for the plan stage) is never a participant: at most one
call per worker, only when Codex and Grok directly conflict and code and tests cannot
settle it, and it gets the two verdicts plus the diff or plan, not the repo. Every
reviewer is read-only: Codex runs `-s read-only`, the Sonnet fallback has read tools
only, and Grok (whose CLI needs `bypassPermissions`) runs under `guard_readonly`, which
fails the review if the worktree changed while it ran.

A quick task you are present for does not need a wave at all: do it in your session.
`TIER=quick` is for small tickets you want worked unattended alongside the rest.

## Per-repo config

A repo opts in with two committed files:
- **`.claude/wave/config.env`** (required) — tracker (`linear`|`jira`|`clickup`), the
  agent-ready queue query, workflow state names, where follow-ups get filed, and
  optionally the runtime (`WAVE_RUNTIME=orca|direct`, default orca). Every script refuses
  to run without it. If it is missing, bootstrap it instead of copying
  `$WAVE/config.example.env` by hand:
  1. `bash "$WAVE/bootstrap.sh"`. It reads the tracker type, project (Jira) or team
     (Linear) and `site` from the vault's committed `brain.json` `tracker` (vault =
     `$BRAIN_ROOT`, else the repo's `.brain/config.json`), and prints one
     `NEED: <what> - <why>; pass --<flag>` line per gap, exit 2, writing nothing.
  2. Ask the user (`AskUserQuestion`) only for what it NEEDs: always the repo label that
     scopes the queue (e.g. `brain-plugin`), plus the tracker and project/team when
     there is no vault binding or no `tracker`, and the Jira site when `brain.json` has
     no `tracker.site`. Offer the default states (`In Progress` / `Validate` for Jira,
     `In Progress` / `In Review` for Linear; override with `--start` / `--done`).
  3. Re-run with those flags (`--label`, `--tracker`, `--project`, `--site`). It writes
     and prints the config. Tell the user to review and commit it, and **do not spawn in
     the same run**.

  An existing `config.env` is never touched. `brain.json` stays the source for tracker
  type and project; `config.env` for everything repo-specific.
- **`.claude/wave/notes.md`** (optional) — project rules appended to the worker prompt
  verbatim: shared databases, dev-server ports, env files to copy, current CI state.
  This is the only place project knowledge goes. Keep it current: a stale line
  there (e.g. "ignore red CI, billing is blocked" after billing is fixed) tells
  workers to ignore real failures, which is worse than no line.

The base ref comes from `origin/HEAD` (override with `WAVE_BASE`); the Orca repo is
matched by the main checkout's path.

Tracker access: Linear goes through `orca linear`; Jira through `acli` (signed in once
per machine with `acli jira auth login`; workers of every agent use it, since a Codex
worker has no Atlassian MCP), and `triage.sh` reads issues from saved JSON. ClickUp goes through
`autonomy/clickup_tracker.py` (`get`, `status`, `comment`, `queue`, `followup`), a
REST adapter that reads `CLICKUP_API_TOKEN` from the environment and throttles to the
free-plan rate; `triage.sh <id>` and `--all` work directly with it.

## Runtime: `orca` or `direct`

`WAVE_RUNTIME=orca` (default) is everything above: Orca worktrees, Orca Runs for the
supervised wave, `status.sh`/`cost.sh` asking Orca. `WAVE_RUNTIME=direct` keeps the
same worker contract and tracker config but needs no Orca: `spawn.sh` hands the
rendered prompt to `autonomy/spawn_direct.py`, which runs the preflight (`.git`
DENY-ACE scan, launch flags, optional Docker/Codex/ClickUp checks per config), creates
`git worktree add -b <WAVE_BRANCH_PREFIX><ISSUE>` and launches `claude -p` (Opus,
`stream-json` log) or `codex exec` with a PID and `status.json` under
`.claude/wave/runs/<ticket>/`. Workers commit per step with
`autonomy/worker_step_commit.py`, which is also their heartbeat. `status.sh` then shows
every run with the live PID, last step, last tool call and cost (`--sweep` prints the
`git worktree remove` commands), and `autonomy/aggregate_wave_report.py` builds the
`/brain:save` report from the summaries.

**Do not run a sandboxed Codex session in a wave repo's main checkout** (a plain
`codex` typed into a terminal, `workspace-write`): on Windows its elevated sandbox stamps
an explicit DENY for its own SID on `.git`, and every later spawn fails the preflight.
Launch Codex there with `--dangerously-bypass-approvals-and-sandbox` (Orca's agent
picker applies it from the Codex default Arguments). The preflight self-heals exactly
that case (an explicit `(OI)(CI)(DENY)(W,D,Rc,DC)` on `.git` for an unresolvable
`S-1-5-21-` SID that Codex's own `~/.codex/cap_sid` ledger lists, inherited by
everything under it, next to a `CodexSandboxUsers` ACE): it removes those rules, rescans, and passes with a
`NOTICE: git_deny_aces self-healed` line. Any other DENY ACE still fails the spawn.

On top of the direct runtime, **`autonomy/autonomy_tick.py`** is the loop that removes
the session from the merge path: one idempotent tick reconciles workers against their
PIDs, finds their PRs, polls CI, runs the Grok challenge in the surviving worktree,
merges through `merge_policy` (rating low, or medium once the owner sets
`WAVE_AUTO_MERGE_MEDIUM=1` and the clean-wave streak holds; CI green, `REVIEW VERDICT: YES`, no
challenge blocker, no fallback reviewer or tie-break, `MIGRATION: no`), picks the next
agent-ready `rating:low` tickets (never unrated, never assigned) under the daily and concurrency caps, plans the thin ones first, and
spawns. It is a dry run unless `--execute`, and it will not pick tickets until the
repo sets `WAVE_BACKLOG_WATCH=1`. Risky tickets, held PRs, plans that need a human and
a failed closeout all land in `.claude/wave/autonomy/human_*.md`. Details, caps and
model roles: `autonomy/AUTONOMY.md`.

## Fresh session checklist

Run these in order. Steps 1–3 clear yesterday; 4 is the only one needing judgment.

**1. See what's left over.** `bash "$WAVE/status.sh"`
Anything `in-review` with an open PR still needs your review. Anything `in-progress`
with no PR either died or is still working — check its terminal before assuming. On
the direct runtime the same command prints each run's real state (a dead PID shows as
`exited`, never `running`), last step, PR and cost.

**2. Batch the summaries into one `/brain:save`.** First bring the main checkout onto
the base branch, so the save builds its graph from the merged code and the merge
listing below sees every PR:
```bash
( . "$WAVE/lib.sh" && cd "$MAIN_CHECKOUT" && git fetch --prune origin \
    && git switch "$BASE_BRANCH" && git merge --ff-only "$WAVE_BASE" )
```
Fast-forward only. If git refuses (uncommitted changes, or the branch has diverged),
stop and resolve it by hand — never force it. `/brain:save` fast-forwards the *vault*,
not this repo.

Then read the full comments
(`orca worktree ps --json`) and, before sweeping, record the batch's cost split with
`bash "$WAVE/cost.sh" <ISSUE>...` (worker tokens vs each Codex call; it reads the
worktrees, so it must run before step 3). Run `/brain:save` **once** for the whole batch.
Never per worktree: `wiki/hot.md` is a single ≤500-word rolling cache, and three
near-duplicate entries crowd out everything else. Workers deliberately do not save.

Worktree comments are not the whole batch: PRs from people or agents outside Orca have
only a PR body. List every merge since the last save and read those bodies too:
```bash
git log --merges --format='%s' <last-save-sha>..HEAD | grep -o '#[0-9]*' | tr -d '#' | xargs -I{} gh pr view {} --json number,title,body
```

Lines to look for, from the plan review (`spawn.sh` step 1.5, risk tier) and the
pre-PR review (step 4.5). Since SPO-639 they are also the `## Wave` block at the end of
every worker PR body (step 5), so they outlive the sweep and `gh pr view --json body`
answers "how often did Grok or Astra change an outcome" without a worktree:
`TIER: <tier>` opens every summary; `TIER: quick -> normal` means a quick ticket hit a
risk trigger, so the label was too optimistic. `PLAN REVIEWER: codex-terra` and
`PLAN CRITIC: grok` confirm a risk-tier plan was reviewed before code; `PLAN DISMISSED:`
is a plan finding the worker rejected.
`REVIEWER: codex-terra` confirms the required correctness review;
`ARCHITECTURE REVIEWER: grok` means a named risk trigger called for an adversarial
review; `TIE-BREAKER: astra (plan|diff)` means those two reviews directly conflicted.
`REVIEWER DISMISSED:` is a finding the worker judged wrong — check whether it was.
`NOT FILED:` (PR body) is a real but never-observed gap the worker chose not to ticket —
file it yourself if you know of an instance. `REVIEW ROUNDS: 3` means findings were
still open when the review loop hit its cap.
Any `NO ... REVIEW:` marker blocks the PR and needs human review; it is not a reason to
try another provider. `REVIEWER: grok-fallback` or `sonnet-fallback (codex quota
exhausted)` means the gate ran on a weaker reviewer, so read that diff yourself.
`ARCHITECTURE REVIEWER: grok-timeout (fallback)` or `PLAN CRITIC: grok-timeout
(fallback)` means Grok was killed by `timeout` twice (900s, then 1350s): the PR opened
without that review, so read that diff (or plan) yourself.

**3. Sweep merged worktrees.** `bash "$WAVE/status.sh" --sweep` prints the commands;
read them, then pipe to `bash`. A worktree comment dies with its worktree — Orca keeps
no archive — so capture it for step 2 *before* sweeping. The PR body outlives it.
To free memory without losing a summary, stop the agent instead:
`orca terminal stop --worktree name:<slug>` keeps checkout, comment, and status.

**3.5 Verify the merged batch (only if the repo has a runtime surface).** This is the
only window where nothing else runs, so this session may own shared state. Walk
exactly what the summaries name (`NOT VERIFIED IN BROWSER: <route>`, anything needing a
write or a multi-step flow) — no exploratory clicking. Never against production; the
repo's `notes.md` says what is safe. Output is tracker issues filed to `WAVE_FILE_TO`,
never fixes: the PRs are merged. Time-box ~15 min and report "walked N, M findings", or
"BLOCKED - <why>" when it walked nothing (no browser, failed db reset): a walk that saw
nothing never reports a route count. An empty report means it did not run. Repos with no UI (plugins, libraries) skip this.

**4. Check the queue — the only step that needs you.** Run the config's `WAVE_QUEUE`
against the tracker (Linear: `orca linear`; Jira: `acli jira workitem search --jql '<WAVE_QUEUE>' --json`).
Choose the exact wave size before spawning. If the queue is thin, label first — see the
criteria below — starting with the pre-grep, which does the mechanical half:
```bash
bash "$WAVE/triage.sh" SPO-378                 # linear: selected candidates
bash "$WAVE/triage.sh" --all                   # linear: intentional full-backlog pass
bash "$WAVE/triage.sh" --json candidates.json  # jira: save the MCP search result first
```
For each issue it resolves every `file:line` the body cites against the base ref,
hands the ticket plus live excerpts to a cheap headless model (`TRIAGER=grok` default,
`agy`, `sonnet`), and prints `HOLDS`/`STALE`/`UNCLEAR` with the deciding line. The
verdict is a hint; the label is still yours. An issue citing no `file:line` is listed
but not judged, because that trait is what predicts a safe unsupervised run.

**5. Start the wave, supervised**, one issue per worker, each with its tier (see "Pick
the tier"): `/wave quick:INNOV-309 INNOV-301 risk:INNOV-305` runs
```bash
bash "$WAVE/coordinator.sh" quick:INNOV-309 INNOV-301 risk:INNOV-305
```
as a background job (see "Supervised wave"), which also does steps 1–3.5 for these
issues when they settle. Only on `/wave spawn` (or the direct runtime, after asking)
launch them unsupervised instead:
```bash
TIER=quick bash "$WAVE/spawn.sh" INNOV-309
bash "$WAVE/spawn.sh" INNOV-301              # normal
TIER=risk  bash "$WAVE/spawn.sh" INNOV-305
```
Pick issues that touch **different areas** — two workers in the same files produce
conflicting PRs. Three is a comfortable width on one machine; the ceiling is usually
concurrent builds, not agents.

## Supervised wave (`coordinator.sh`, SPO-640)

**Attended only.** Run it from a session someone is watching. Never schedule it:
unattended and scheduled waves use `autonomy/autonomy_tick.py` (INNOV-444), which
survives a crash or a missed firing; this loop does not.

Human PR review on quick/normal tiers caught nothing across the last waves, so the
coordinator takes the human out of that merge path. One command replaces steps 5, 1,
2 (merge listing + cost), 3 and 3.5 of the checklist:
```bash
bash "$WAVE/coordinator.sh" SPO-640 quick:SPO-641 risk:SPO-642   # tier:ISSUE, default normal
bash "$WAVE/coordinator.sh" --resume run_<id>                     # after a crash
```
It runs for the whole wave (hours). `/wave` starts it with the Bash tool's
`run_in_background` and the longest timeout (7200000 ms), so the session stays free.
Read the `RUN run_<id>` line from its output first and tell the user. If the job ends
before the wave does (the timeout, a crash, `exit 2` when something is still live), run
`/wave resume run_<id>`. When resume refuses because another loop on that Run is alive,
supervision is still going (the orphaned loop keeps gating); resume again once it
exits, so the walk, sweep and report run. From a plain terminal, give it its own. Each worker is spawned with
`WAVE_RUN` set, which makes `spawn.sh` launch it as a Dispatch in one Orca Run and tell
it to send `worker_done`. The coordinator blocks on those, and on each one runs
`gate.py` over the PR body's `## Wave` block (SPO-639) plus `gh pr checks`:

| Merged by the coordinator | Held for you (`wave-held` label, worktree kept) |
|---|---|
| Every tier on every `TIER` line `quick` or `normal` (the leading `a -> b` chain, so `quick -> normal` merges), `MIGRATION: no`, `REVIEWER: codex-terra`, `REVIEW VERDICT: YES` (every such line, exactly), no `TIE-BREAKER`, every required check green, mergeable | `risk` anywhere in a `TIER` chain (`normal -> risk`, `risk -> normal`) or no tier, `MIGRATION: yes`, a fallback reviewer, `REVIEW VERDICT` `NO` or missing, any `NO ... REVIEW`, a tie-break, a failed check, a worker question, an escalation other than a live worker's turn ending, a second conflict |

Orca escalates every time a worker's turn ends without `worker_done`, which includes a
Claude worker waiting on a background review or an advisor call. The coordinator checks
`orchestration worker-show`: while `liveness` is `live` (or `unverifiable`, or the call
fails) it keeps waiting. It holds at once on any other liveness (`exited`), and holds any
waiting worker that has not sent `worker_done` within `WAVE_TURN_END_GRACE_MIN` (default 60)
minutes of its first turn-end; parked workers are re-checked on every poll (INNOV-464).

A first conflict after a sibling merge gets one rebase on the same terminal. When
`worker-list` shows nothing live, the coordinator fast-forwards the main checkout,
comments each merged PR with its `cost.sh` split, builds the walk checklist from the
merged bodies' `NOT VERIFIED IN BROWSER` and `MIGRATION: yes` lines, runs the repo's
`.claude/wave/walk.sh` as a supervised worker (skipped when the file or the lines are
absent), sweeps merged worktrees, and prints one `WAVE ... merged N; held M; walk: ...`
line. Held PRs are not walked this wave.

The ticket follows the PR through the tick's tracker adapter (`jira_tracker.tracker_for`,
by `WAVE_TRACKER`; INNOV-463): a held PR moves its ticket back to `WAVE_STATE_HELD` (default
`WAVE_STATE_START`) with a comment giving the reason and PR, and a merge comments the PR
number and merge sha. Jira goes through `acli`, ClickUp through REST, Linear through
`orca linear` (`autonomy/linear_tracker.py`, write-only, coordinator-only). A PR the
coordinator finds already merged before its gate passed (a self-merge) is held, with
its ticket left as the worker set it; on `--resume`, a held PR you merged by hand has
its ticket set back to `WAVE_STATE_DONE` and stays listed as held. A tracker error is logged, never fatal. What is left for you: the held PRs, the
walker's tickets, and one `/brain:save`.

## What makes an issue `agent-ready`

The label is a human gate. Workers must never apply it, including to follow-ups they
file themselves (the prompt forbids it).

**Yes:** a reproducible defect or bounded change that names its own `file:line` or a
reference implementation to copy. That trait predicts a safe unsupervised run far
better than size does.

**No:**
- needs a write to shared state every worker sees (a shared dev DB, a migration) —
  one reset corrupts a sibling mid-run
- research, pricing, legal, or product-direction judgment
- large or mixed-scope diffs ("consolidate X and Y", "rename across 32 files")
- anything the repo's `notes.md` names as hand-maintained

## Things that bit us, so they live in the prompt

- **The claim lock is the Orca worktree, not the tracker assignee.** Every worker runs
  as the same user, so "confirm I'm the assignee" cannot tell self from sibling — two
  successors once both claimed one issue and shipped duplicate PRs. `spawn.sh` refuses
  an issue that already has a worktree in this repo.
- **`gate-loop` only on escalation** — after `/preflight` fails twice on the same
  command. Generators for a one-line diff are waste, and they overwrite test files.
- **Load timeouts are not a gate failure.** Three workers each running a test suite at
  full width oversubscribe the machine: unrelated tests time out, a different set each
  run, all passing alone (SPO waves 4–5, 2026-09-30). Workers re-run narrower instead
  of gate-looping; cap per-worker test parallelism in the repo's `notes.md`.
- **Workers never clean up their own worktree**, even when told the PR merged.
- **Gitignored files the build needs** (`.env.local` and the like): copy them in
  Orca's setup hook, and say so in `notes.md`, so agents stop improvising them.

## What Orca already remembers

Repo registration, the setup hook, and every worktree with its comment and status until
you remove it. `BRAIN_ROOT` in global Claude settings lets any worktree's agent find the
vault. None of the protocol above is stored by Orca — that is why it lives here.
