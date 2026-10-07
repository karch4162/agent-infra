---
name: wave
description: Start a wave of unsupervised Orca workers on agent-ready tracker issues (Linear or Jira, configured per repo), and run the fresh-session checklist around it (leftovers, brain save, worktree sweep, queue check). Use when the user says "/wave", "spin up N workers", "start a wave", "run the loop", or opens a session wanting agents working the backlog.
---

# /wave — run a wave of Orca workers

Each worker takes one issue in its own Orca worktree, ships a PR, and writes a summary
into its worktree comment. A successor wave is opt-in (`AUTO_SUCCESSOR=1`), not
automatic; the human reviews between ordinary waves.

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
| `quick` | renames, copy/UI tweaks, boilerplate, a one-function bug with a named `file:line` | one Codex Terra round, no loop. A diff that hits a risk trigger escalates itself to `normal`'s risk review. |
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
- **`.claude/wave/config.env`** (required) — tracker (`linear`|`jira`), the agent-ready
  queue query, workflow state names, where follow-ups get filed. Every script refuses
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

Tracker access: Linear goes through `orca linear`; Jira through the Atlassian MCP,
which has no shell CLI — so for Jira the host session does the queue query and
`triage.sh` reads issues from saved JSON.

## Fresh session checklist

Run these in order. Steps 1–3 clear yesterday; 4 is the only one needing judgment.

**1. See what's left over.** `bash "$WAVE/status.sh"`
Anything `in-review` with an open PR still needs your review. Anything `in-progress`
with no PR either died or is still working — check its terminal before assuming.

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
pre-PR review (step 4.5):
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
never fixes: the PRs are merged. Time-box ~15 min and report "walked N, M findings" —
an empty report means it did not run. Repos with no UI (plugins, libraries) skip this.

**4. Check the queue — the only step that needs you.** Run the config's `WAVE_QUEUE`
against the tracker (Linear: `orca linear`; Jira: the Atlassian MCP JQL search).
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

**5. Spawn the wave**, one issue per worker, each with its tier (see "Pick the tier"):
```bash
TIER=quick bash "$WAVE/spawn.sh" INNOV-309
bash "$WAVE/spawn.sh" INNOV-301              # normal
TIER=risk  bash "$WAVE/spawn.sh" INNOV-305
```
Pick issues that touch **different areas** — two workers in the same files produce
conflicting PRs. Three is a comfortable width on one machine; the ceiling is usually
concurrent builds, not agents.

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
