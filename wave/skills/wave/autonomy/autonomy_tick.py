#!/usr/bin/env python
"""One tick of wave autonomy: the loop that joins the gates into a pipeline.

  python "$WAVE_HOME/autonomy/autonomy_tick.py"            # dry run: report only
  python "$WAVE_HOME/autonomy/autonomy_tick.py" --execute  # act
  python "$WAVE_HOME/autonomy/autonomy_tick.py" --execute --loop 600

Every stage already existed as a tested function; before this file nothing called
them in sequence, so a scheduled backlog_watch counted tickets against the daily
cap and spawned nothing. One tick, in order, idempotent, resumable from the
status.json files:

  1. reconcile  running workers whose PID is gone -> exited; exited -> PR lookup
                (gh pr list --head <branch>) -> pr_open, or held when no PR
  2. ci         pr_open -> ci_wait.poll_once -> ci_green | held
  3. challenge  ci_green -> Grok challenge in the surviving worktree -> challenged
  4. merge      challenged -> merge_policy via auto_merge -> done_merged | done_held
                | still pending; tracker status + comment on both outcomes
  5. spawn      backlog_watch picks -> plan loop when thin -> DirectWorkerRuntime
                (daily cap counted only after the spawn succeeded)
  6. closeout   WAVE_CLOSEOUT_CMD once nothing is live and something merged
                (a held PR a human merges later counts: reconcile re-checks done_held)
  7. sweep      remove merged worktrees once closeout no longer needs them

Stops and leaves a note under autonomy/ for a human on: risky tickets, a plan that
needs a human, a held PR, a failed closeout.

This is the ONE engine for anything unattended (scheduled, control repo; INNOV-444),
on either runtime. coordinator.sh is only for waves a person starts and watches.
Automatic picking is wired for ClickUp and Jira (acli); Linear is not yet.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ci_wait  # noqa: E402
from auto_merge import evaluate_and_maybe_merge, record_closeout  # noqa: E402
from autonomy_config import load_autonomy_config, repo_root, wave_dir as _wave_dir  # noqa: E402
from backlog_watch import run_watch  # noqa: E402
from daily_cap import ET, RunLock, record_start  # noqa: E402
from grok_challenge import run_grok_challenge  # noqa: E402
from plan_step import run_plan_loop, write_plan_artifacts  # noqa: E402
from worker_runtime import DirectWorkerRuntime, OrcaWorkerRuntime, WorkerError, codex_inherits_all, orca_worker_state, _orca, build_claude_reviewer_cmd, build_codex_reviewer_cmd, _resolve_agent_bin, pid_alive  # noqa: E402

LIVE = {"running", "starting"}
IDLE_NOTICE_S = 20 * 60  # an Orca worker silent this long may be waiting at a prompt
PENDING_NAME = "closeout-pending.json"  # merges whose closeout has not finished (INNOV-447)


def _now() -> str:
    return datetime.now(ET).isoformat()


def _read(p: Path) -> dict[str, Any]:
    try:
        return json.loads(p.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return {}


def _write(p: Path, d: dict[str, Any]) -> None:
    d["updated_at"] = _now()
    p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def _bash() -> str:
    """The bash that can see this repo. On Windows a bare `bash` on PATH is often
    WSL's (System32), whose filesystem is a different machine; Git's bash is the one
    the plugin scripts were written for. WAVE_BASH overrides."""
    import shutil

    override = os.environ.get("WAVE_BASH", "").strip()
    if override:
        return override
    if os.name != "nt":
        return "bash"
    git = shutil.which("git")
    if git:
        # <Git>/{cmd,bin}/git.exe is two levels up; <Git>/{ucrt64,mingw64}/bin/git.exe is three
        for root in Path(git).resolve().parents[1:3]:
            for cand in (root / "bin" / "bash.exe", root / "usr" / "bin" / "bash.exe"):
                if cand.exists():
                    return str(cand)
    found = shutil.which("bash")
    if found and "system32" not in found.lower():
        return found
    raise SystemExit("wave: no Git bash found (set WAVE_BASH)")


def _posix(path: Path) -> str:
    """A path the chosen bash accepts: ask its own cygpath on Windows."""
    if os.name == "nt":
        cygpath = Path(_bash()).parent / "cygpath.exe"
        if not cygpath.exists():
            cygpath = Path(_bash()).parent.parent / "usr" / "bin" / "cygpath.exe"
        if cygpath.exists():
            p = subprocess.run([str(cygpath), "-u", str(path)], capture_output=True, text=True)
            if p.returncode == 0 and p.stdout.strip():
                return p.stdout.strip()
    return path.as_posix()


def _sh(args: list[str], cwd: Path, timeout: int = 180, input_text: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=str(cwd), capture_output=True, text=True, encoding="utf-8",
                          errors="replace", timeout=timeout, input=input_text)


def _grok_on_path() -> None:
    """A scheduled tick's PATH often lacks the per-user Grok install; workers and the
    review scripts call bare `grok`, so put its folder on PATH for every child."""
    import shutil

    home_bin = Path.home() / ".grok" / "bin"
    if not shutil.which("grok") and home_bin.is_dir():
        os.environ["PATH"] = str(home_bin) + os.pathsep + os.environ.get("PATH", "")


def sync_base(repo: Path, base_ref: str, must_contain: list[str]) -> str | None:
    """Bring `repo` to the tip of `base_ref` (e.g. origin/development) before closeout,
    so it tests what was just merged. Returns None when ready, else why not.

    Never switches branches: the checkout is shared with a human, so a different
    branch checked out is a failure to report, not something to change."""
    remote, _, branch = base_ref.partition("/") if "/" in base_ref else ("origin", "", base_ref)

    def git(*a: str) -> subprocess.CompletedProcess:
        return _sh(["git", *a], repo)

    if branch == "HEAD":  # the WAVE_BASE default: resolve the remote's default branch
        branch = git("symbolic-ref", "--short", f"refs/remotes/{remote}/HEAD").stdout.strip().partition("/")[2]
        if not branch:
            return f"cannot resolve {remote}/HEAD to a branch; set WAVE_BASE to {remote}/<branch>"
    p = git("fetch", remote, branch)
    if p.returncode != 0:
        return f"git fetch {remote} {branch} failed: {p.stderr.strip()[-300:]}"
    cur = git("branch", "--show-current").stdout.strip()
    if cur != branch:
        return f"closeout needs {branch} checked out in {repo}; it has {cur or 'a detached HEAD'}"
    p = git("merge", "--ff-only", f"{remote}/{branch}")
    if p.returncode != 0:
        return f"{branch} cannot fast-forward to {remote}/{branch}: {p.stderr.strip()[-300:]}"
    for sha in must_contain:
        if git("merge-base", "--is-ancestor", sha, "HEAD").returncode != 0:
            return f"HEAD {git('rev-parse', '--short', 'HEAD').stdout.strip()} does not contain merged commit {sha[:10]}"
    return None


class Tick:
    def __init__(self, *, repo: Path, execute: bool, log) -> None:
        _grok_on_path()
        self.repo = repo
        # Every no-arg load_autonomy_config() downstream (auto_merge, clickup CLI)
        # resolves the repo from cwd; pin it so --repo from anywhere reads this config.
        os.environ["WAVE_REPO"] = str(repo)
        self.wave_dir = _wave_dir(repo)
        self.cfg = load_autonomy_config(self.wave_dir / "config.env")
        # The worker runtimes read the prefix from the env; the tick does not source config.env.
        os.environ["WAVE_BRANCH_PREFIX"] = self.cfg.branch_prefix
        self.execute = execute
        self.log = log
        self.runs = self.wave_dir / "runs"
        self.auto = self.wave_dir / "autonomy"
        self.auto.mkdir(parents=True, exist_ok=True)
        self.report: dict[str, Any] = {"ts": _now(), "execute": execute, "events": [], "notices": []}
        self._slug: str | None = None
        self._tracker = None
        self.merged_this_tick: list[str] = []
        self.merged_shas: list[str] = []
        self.closeout_ok: bool | None = None  # None: closeout did not run this tick

    # ---- helpers -------------------------------------------------------------
    def ev(self, ticket: str, what: str, **kw: Any) -> None:
        row = {"ticket": ticket, "event": what, **kw}
        self.report["events"].append(row)
        self.log(f"{ticket}: {what} " + " ".join(f"{k}={v}" for k, v in kw.items()))

    def notice(self, text: str, file: str = "human_notice.md") -> None:
        self.report["notices"].append(text)
        self.log("NOTICE " + text)
        if self.execute:
            with (self.auto / file).open("a", encoding="utf-8") as f:
                f.write(f"- {_now()} {text}\n")

    def closeout_pending(self, ticket: str, sha: str) -> None:
        """Record a merge as owed a closeout, at merge time. The merging tick can die before
        closeout runs (or defer it to live workers); a later tick that merged nothing still
        finds the marker and runs it. Only a finished closeout command clears it (INNOV-447)."""
        if ticket not in self.merged_this_tick:
            self.merged_this_tick.append(ticket)
        if sha and sha not in self.merged_shas:
            self.merged_shas.append(sha)
        if not self.execute or not self.cfg.closeout_cmd:  # no closeout configured: nothing would clear it
            return
        pend = _read(self.auto / PENDING_NAME)
        tickets, shas = list(pend.get("tickets") or []), list(pend.get("shas") or [])
        if ticket not in tickets:
            tickets.append(ticket)
        if sha and sha not in shas:
            shas.append(sha)
        pend.update(tickets=tickets, shas=shas, since=pend.get("since") or _now())
        self._write_pending(pend)

    def _write_pending(self, pend: dict[str, Any]) -> None:
        path = self.auto / PENDING_NAME
        tmp = path.with_suffix(".tmp")  # a tick killed mid-write must not leave a truncated marker
        tmp.write_text(json.dumps(pend, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp, path)

    def repo_slug(self) -> str:
        if self._slug is None:
            p = _sh(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], self.repo)
            self._slug = (p.stdout or "").strip()
            if not self._slug:
                raise SystemExit(f"gh repo view failed in {self.repo}: {p.stderr[-300:]}")
        return self._slug

    def tracker(self):
        if self._tracker is None:
            from jira_tracker import tracker_for

            try:
                self._tracker = tracker_for(self.cfg)
            except Exception as e:  # noqa: BLE001 - a missing token/JQL must not kill the tick; state lives in status.json
                self.ev("-", "tracker_error", error=str(e)[:200])
        return self._tracker

    def track(self, ticket: str, *, status: str | None = None, comment: str | None = None) -> None:
        if not self.execute:
            return
        t = self.tracker()
        if t is None:
            return
        try:
            if status:
                t.set_status(ticket, status)
            if comment:
                t.comment(ticket, comment)
        except Exception as e:  # noqa: BLE001 - tracker is best-effort; state lives in status.json
            self.ev(ticket, "tracker_error", error=str(e)[:200])

    def statuses(self) -> list[tuple[Path, dict[str, Any]]]:
        out = []
        for p in sorted(self.runs.glob("*/status.json")):
            # Walker runs (walk_spawn.py, ticket_id=walk-<date>) share runs/ but are not tickets:
            # no PR, no CI, no merge. The closeout reads their summaries itself (INNOV-446).
            if p.parent.name.startswith("walk-"):
                continue
            st = _read(p)
            if st:
                out.append((p, st))
        return out

    def runtime(self):
        """WAVE_RUNTIME=orca puts each worker in a visible Orca terminal. The tick runs when no
        one is at the IDE, so an unreachable Orca falls back to the direct runtime, with a notice."""
        if self.cfg.runtime == "orca":
            try:
                rt = OrcaWorkerRuntime(repo_path=str(self.repo), base_branch=self.cfg.wave_base)
                rt.repo_id()
                return rt
            except WorkerError as e:
                self.notice(f"Orca runtime unavailable, spawning direct: {e}")
        return DirectWorkerRuntime(repo_path=str(self.repo), base_branch=self.cfg.wave_base)

    def alive(self, path: Path, st: dict[str, Any]) -> bool:
        """A direct worker is alive while its process is; an Orca worker until it writes
        summary.md or its terminal closes. A long-silent Orca worker gets one notice, not a kill."""
        if st.get("runtime") != "orca":
            return pid_alive(int(st.get("pid") or 0))
        alive, idle = orca_worker_state(st, path.parent)
        if alive and idle and idle > IDLE_NOTICE_S and not st.get("idle_noticed"):
            ticket = st.get("ticket_id") or path.parent.name
            self.notice(f"{ticket}: Orca worker silent for {int(idle // 60)} min; it may be waiting at a prompt")
            st["idle_noticed"] = _now()
            if self.execute:
                _write(path, st)
        return alive

    def find_pr(self, branch: str) -> dict[str, Any] | None:
        p = _sh(["gh", "pr", "list", "--repo", self.repo_slug(), "--head", branch, "--state", "all",
                 "--json", "number,url,state,mergedAt", "--limit", "1"], self.repo)
        try:
            items = json.loads(p.stdout or "[]")
        except ValueError:
            return None
        return items[0] if items else None

    # ---- 1. reconcile ----------------------------------------------------------
    def reconcile(self) -> None:
        for path, st in self.statuses():
            ticket = st.get("ticket_id") or path.parent.name
            state = st.get("state")
            if state in LIVE and not self.alive(path, st):
                st["state"] = state = "exited"
                self.ev(ticket, "exited")
                if self.execute:
                    _write(path, st)
            if state == "exited" and not st.get("pr"):
                pr = self.find_pr(st.get("branch", ""))
                if pr:
                    st.update(pr=pr["url"], pr_number=pr["number"], state="pr_open")
                    if pr.get("state") == "MERGED":
                        st["state"] = "done_merged"
                        st["note"] = "merged outside the tick"
                    self.ev(ticket, "pr_found", pr=pr["number"], state=st["state"])
                else:
                    summary = (path.parent / "summary.md")
                    why = "worker exited without a PR"
                    if summary.exists() and "NO PR" in summary.read_text(encoding="utf-8", errors="replace"):
                        why = "worker ended with NO PR (see summary.md)"
                    st.update(state="done_held", hold_reason=why)
                    self.ev(ticket, "held", reason=why)
                    self.notice(f"{ticket}: {why}", "human_held.md")
                    self.track(ticket, comment=f"wave: held — {why}")
                if self.execute:
                    _write(path, st)
            if state == "done_held" and st.get("pr_number") and not st.get("pr_closed"):
                self.recheck_held(path, st, ticket)

    def recheck_held(self, path: Path, st: dict[str, Any], ticket: str) -> None:
        """A held PR is the human's to merge. Once they do, the tick takes the run back so
        closeout and the sweep run for it; a closed PR stops being checked."""
        p = _sh(["gh", "pr", "view", str(st["pr_number"]), "--repo", self.repo_slug(),
                 "--json", "state,mergeCommit"], self.repo)
        try:
            pr = json.loads(p.stdout or "{}")
        except ValueError:
            return
        if pr.get("state") == "MERGED":
            sha = (pr.get("mergeCommit") or {}).get("oid") or ""
            st.update(state="done_merged", note="merged by a human after the hold", merge_sha=sha)
            self.closeout_pending(ticket, sha)
            self.ev(ticket, "merged_by_human", pr=st["pr_number"])
            self.track(ticket, comment=f"wave: {st.get('pr')} merged; closeout and sweep follow")
        elif pr.get("state") == "CLOSED":
            st["pr_closed"] = True
            self.ev(ticket, "pr_closed", pr=st["pr_number"])
        else:
            return
        if self.execute:
            _write(path, st)

    # ---- 2. ci ----------------------------------------------------------------
    def ci(self) -> None:
        for path, st in self.statuses():
            if st.get("state") != "pr_open":
                continue
            ticket = path.parent.name
            cp = ci_wait.poll_once(self.repo_slug(), int(st["pr_number"]), path.parent / "ci.json")
            if cp.state == "green":
                st["state"] = "ci_green"
            elif cp.state == "failed":
                st.update(state="done_held", hold_reason=f"CI failed: {cp.checks}")
                self.notice(f"{ticket}: CI failed on PR #{st['pr_number']}", "human_held.md")
                self.track(ticket, comment=f"wave: held — CI failed on {st['pr']}")
            self.ev(ticket, "ci", result=cp.state)
            if self.execute:
                _write(path, st)

    # ---- 3. challenge -----------------------------------------------------------
    def challenge(self) -> None:
        for path, st in self.statuses():
            if st.get("state") != "ci_green":
                continue
            ticket = path.parent.name
            if not self.cfg.grok_challenge:
                st.update(challenge={"ran": False}, state="challenged")
            elif self.execute:
                wt = Path(st.get("path") or "")
                if not wt.exists():
                    st.update(state="done_held", hold_reason="worktree gone before challenge")
                    self.notice(f"{ticket}: worktree gone before the Grok challenge", "human_held.md")
                else:
                    r = run_grok_challenge(worktree=wt, wave_dir=self.wave_dir, ticket_id=ticket, base=self.cfg.wave_base)
                    st.update(challenge=r.to_challenge_dict(), state="challenged")
                    (path.parent / "challenge-grok.log").write_text(r.out or "", encoding="utf-8")
            self.ev(ticket, "challenge", verdict=(st.get("challenge") or {}).get("verdict"), state=st["state"])
            if self.execute:
                _write(path, st)

    # ---- 4. merge ----------------------------------------------------------------
    def merge(self) -> None:
        for path, st in self.statuses():
            if st.get("state") != "challenged":
                continue
            ticket = path.parent.name
            res = evaluate_and_maybe_merge(
                repo=self.repo_slug(), pr=int(st["pr_number"]), rating=st.get("rating") or "",
                primary_review="", primary_verdict="", challenge=st.get("challenge"),
                require_challenge=self.cfg.grok_challenge, dry_run=not self.execute)
            self.ev(ticket, "merge", action=res.action, decision=res.decision)
            if res.action == "merged":
                st.update(state="done_merged", note=res.decision)
                p = _sh(["gh", "pr", "view", str(st["pr_number"]), "--repo", self.repo_slug(),
                         "--json", "mergeCommit", "-q", ".mergeCommit.oid"], self.repo)
                if p.stdout.strip():
                    st["merge_sha"] = p.stdout.strip()
                self.closeout_pending(ticket, st.get("merge_sha") or "")
                self.track(ticket, status=self.cfg.state_done or None,
                           comment=f"wave: merged {st['pr']} ({res.decision})")
            elif res.action in {"held", "conflict_held"}:
                st.update(state="done_held", hold_reason=res.decision)
                self.notice(f"{ticket}: {res.decision} ({st['pr']})", "human_held.md")
                self.track(ticket, comment=f"wave: held — {res.decision} ({st['pr']})")
            if self.execute:
                _write(path, st)

    # ---- 5. spawn ----------------------------------------------------------------
    def _prompt_for(self, ticket: str, tier: str) -> str:
        """The worker contract is spawn.sh's prompt; render it, never a second copy."""
        home = Path(os.environ.get("WAVE_HOME") or Path(__file__).resolve().parent.parent)
        env = dict(os.environ, DRY_RUN="1", WAVE_RUNTIME="direct", TIER=tier)
        p = subprocess.run([_bash(), _posix(home / "spawn.sh"), ticket], cwd=str(self.repo), env=env,
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
        if p.returncode != 0:
            raise WorkerError(f"spawn.sh DRY_RUN failed: {p.stderr[-400:]}")
        return p.stdout

    def _planner(self, ticket: str, title: str, body: str):
        claude = build_claude_reviewer_cmd(_resolve_agent_bin("claude"))

        def plan(plan_md: str) -> str:
            prompt = (f"You are planning ticket {ticket}: {title}\n\nTicket body:\n{body[:6000]}\n\n"
                      "Fill in this plan (keep the ## Files, ## Approach, ## Tests, ## Risks headings; "
                      "cite file:line premises from this repo; no code). Output only the markdown.\n\n" + plan_md)
            p = _sh(claude + [prompt, "--allowedTools", "Read,Grep,Glob"], self.repo, timeout=900)
            if p.returncode != 0 or not p.stdout.strip():
                raise WorkerError(f"planner failed ({p.returncode}): {p.stderr[-400:]}")
            return p.stdout.strip()
        return plan

    def _plan_reviewer(self, ticket: str, title: str, body: str):
        codex = build_codex_reviewer_cmd(_resolve_agent_bin("codex"), read_only=True)

        def review(plan_md: str) -> str:
            # codex exec ignores stdin when given a positional prompt, so plan and ticket travel on stdin via "-"
            prompt = (f"Review this implementation plan for ticket {ticket}: {title}\n\nTicket body:\n{body[:6000]}\n\n"
                      "The plan is below. Check it against the ticket and the repository files it cites; you may read "
                      "repository files. Report only high-confidence problems; on FAIL say what is missing. End with exactly:\n"
                      "PLAN_REVIEW_RESULT:\n  decision: PASS|FAIL|NEEDS_HUMAN\n  summary: <one line>\n\n" + plan_md)
            p = _sh(codex + ["-"], self.repo, timeout=900, input_text=prompt)
            if p.returncode != 0 or not p.stdout.strip():
                raise WorkerError(f"plan reviewer failed ({p.returncode}): {p.stderr[-400:]}")
            return p.stdout
        return review

    def spawn(self, lock: RunLock) -> None:
        # wave_run passes the firing's trigger; only "owner" lifts the scheduled limits.
        trigger = "owner" if os.environ.get("WAVE_TRIGGER") == "owner" else "scheduled"
        rep = run_watch(wave_dir=self.wave_dir, dry_run=not self.execute, execute=self.execute,
                        lock=lock, record_starts=False, trigger=trigger)
        self.report["watch"] = rep.to_dict()
        for n in rep.notices:
            self.log("watch: " + n)
        if rep.flagged_risky:
            self.notice(f"risky tickets waiting for a human: {[r['id'] for r in rep.flagged_risky]}", "human_risky.md")
        if not rep.picks:
            return
        rt = self.runtime()
        for pick in rep.picks:
            tier = "quick" if pick.rating == "low" else "normal"
            agent = (pick.roles or {}).get("implementer", "claude")
            model = (pick.roles or {}).get("implementer_model")
            if not self.execute:
                self.ev(pick.ticket_id, "would_spawn", action=pick.action, agent=agent, tier=tier, runtime=self.cfg.runtime)
                continue
            try:
                prompt = self._prompt_for(pick.ticket_id, tier)
                if pick.action == "plan_first":
                    t = self.tracker()
                    body = t.get(pick.ticket_id).text if t else ""
                    out = run_plan_loop(ticket_id=pick.ticket_id, title=pick.title, body=body, plan_needed=True,
                                        max_rounds=self.cfg.plan_rounds_cap,
                                        planner=self._planner(pick.ticket_id, pick.title, body),
                                        reviewer=self._plan_reviewer(pick.ticket_id, pick.title, body))
                    write_plan_artifacts(self.runs / pick.ticket_id.lower(), out)
                    if not out.approved:
                        self.ev(pick.ticket_id, "plan_held", reason=out.hold_reason)
                        self.notice(f"{pick.ticket_id}: {out.hold_reason}", "human_held.md")
                        self.track(pick.ticket_id, comment=f"wave: not started — {out.hold_reason}")
                        continue
                    self.track(pick.ticket_id, comment="wave: approved plan\n\n" + (out.plan_md or ""))
                    prompt += "\n\nAPPROVED PLAN (reviewed before code; follow it):\n" + (out.plan_md or "")
                use = rt
                if isinstance(rt, OrcaWorkerRuntime) and agent == "codex" and not codex_inherits_all():
                    use = DirectWorkerRuntime(repo_path=str(self.repo), base_branch=self.cfg.wave_base)
                    self.notice(f"{pick.ticket_id}: Codex worker spawned direct: Orca cannot pass it CLICKUP_*/WAVE_*; "
                                "set shell_environment_policy.inherit = \"all\" in ~/.codex/config.toml to run it in Orca")
                rec = use.spawn(ticket_id=pick.ticket_id, prompt=prompt, agent=agent, model=model)
            except WorkerError as e:
                self.ev(pick.ticket_id, "spawn_failed", error=str(e)[:300])
                self.notice(f"{pick.ticket_id}: spawn failed: {str(e)[:200]}")
                continue
            record_start(pick.ticket_id, self.wave_dir)  # counted only now: the worker exists
            st = _read(Path(rec.status_path))
            st.update(rating=pick.rating, roles=pick.roles, tier=tier)
            _write(Path(rec.status_path), st)
            self.ev(pick.ticket_id, "spawned", agent=agent, pid=rec.pid, branch=rec.branch)
            self.track(pick.ticket_id, status=self.cfg.state_start or None,
                       comment=f"wave: worker started ({agent}{' ' + model if model else ''}, tier {tier}, {rec.mode}) on {rec.branch}")

    # ---- 6. closeout -----------------------------------------------------------------
    def closeout(self) -> None:
        """Runs for every merge still in the pending marker, not only this tick's: the tick
        that merged may have died or deferred (INNOV-447)."""
        pend = _read(self.auto / PENDING_NAME)
        tickets = list(dict.fromkeys([*(pend.get("tickets") or []), *self.merged_this_tick]))
        shas = list(dict.fromkeys([*(pend.get("shas") or []), *self.merged_shas]))
        if not tickets or not self.cfg.closeout_cmd:
            return
        if any(st.get("state") in LIVE and self.alive(p, st) for p, st in self.statuses()):
            self.log("closeout deferred: workers still live")
            return
        if not self.execute:
            self.ev("-", "would_closeout", cmd=self.cfg.closeout_cmd)
            return
        why = sync_base(self.repo, self.cfg.wave_base, shas)
        pend.update(tickets=tickets, shas=shas, since=pend.get("since") or _now())
        if why:  # the command never ran: the marker stays, so the next tick tries again
            self.ev("-", "closeout_skipped", reason=why)
            if pend.get("skip_reason") != why:  # once per reason, not once per tick
                self.notice(f"closeout not run after merging {tickets}: {why}")
            self._write_pending({**pend, "skip_reason": why})
            self.closeout_ok = False
            return
        attempts = int(pend.get("attempts") or 0)
        if attempts:
            self.notice(f"closeout for {tickets}: {attempts} earlier attempt(s) never finished "
                        "(tick killed or timed out mid-closeout); retrying")
        pend.pop("skip_reason", None)
        self._write_pending({**pend, "attempts": attempts + 1})
        p = subprocess.run([_bash(), "-lc", self.cfg.closeout_cmd], cwd=str(self.repo), capture_output=True,
                           text=True, encoding="utf-8", errors="replace", timeout=3600)
        (self.auto / "closeout-last.log").write_text((p.stdout or "") + (p.stderr or ""), encoding="utf-8")
        self.closeout_ok = p.returncode == 0
        streak = record_closeout(self.wave_dir, self.closeout_ok)
        (self.auto / PENDING_NAME).unlink(missing_ok=True)  # finished, pass or fail: owed no longer
        self.ev("-", "closeout", rc=p.returncode, clean_streak=streak)
        if p.returncode != 0:
            self.notice(f"closeout failed (rc={p.returncode}) after merging {tickets}; see autonomy/closeout-last.log. "
                        "Clean-wave streak reset to 0: medium auto-merge is suspended until it is rebuilt.")
        elif streak == self.cfg.clean_waves_for_medium and not self.cfg.auto_merge_medium:
            self.notice(f"{streak} clean waves in a row: medium auto-merge may be turned on (WAVE_AUTO_MERGE_MEDIUM=1). Owner's call.")

    # ---- 7. sweep --------------------------------------------------------------------
    def sweep(self) -> None:
        """Remove merged worktrees. The attended coordinator sweeps its own; unattended, nothing
        else would. A failed closeout keeps them for debugging; a dirty one stays, with a notice.
        Other workers still running do not hold it back: a merged ticket's worktree is its own,
        and only closeout (which tests the merged base) has to wait for them."""
        if self.closeout_ok is False:
            return
        for path, st in self.statuses():
            if st.get("state") != "done_merged" or st.get("swept") or not st.get("path"):
                continue
            ticket = st.get("ticket_id") or path.parent.name
            wt = Path(st["path"])
            if not self.execute:
                self.ev(ticket, "would_sweep", path=str(wt))
                continue
            if wt.exists():
                if _sh(["git", "status", "--porcelain"], wt).stdout.strip():
                    if not st.get("sweep_blocked"):
                        self.notice(f"{ticket}: merged worktree has uncommitted changes, not swept: {wt}")
                        st["sweep_blocked"] = _now()
                        _write(path, st)
                    continue
                if st.get("runtime") == "orca":
                    p = _orca(["worktree", "rm", "--worktree", f"name:{wt.name}", "--force", "--delete-branch", "--json"])
                else:
                    p = _sh(["git", "worktree", "remove", "--force", str(wt)], self.repo)
                if p.returncode != 0:
                    self.notice(f"{ticket}: sweep failed: {(p.stderr or p.stdout or '')[-200:]}")
                    continue
            st["swept"] = _now()
            self.ev(ticket, "swept", path=str(wt))
            _write(path, st)

    # ---- run -------------------------------------------------------------------------
    def run(self) -> dict[str, Any]:
        lock = RunLock(self.wave_dir)
        got, why = lock.acquire("autonomy_tick")
        if not got:
            self.report["notices"].append(f"run lock: {why}")
            return self.report
        try:
            self.reconcile()
            self.ci()
            self.challenge()
            self.merge()
            self.spawn(lock)
            self.closeout()
            self.sweep()
        finally:
            lock.release("autonomy_tick")
            (self.auto / "tick-last.json").write_text(json.dumps(self.report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return self.report


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="one wave autonomy tick")
    ap.add_argument("--execute", action="store_true", help="act; default is a dry run that only reports")
    ap.add_argument("--loop", type=int, default=0, metavar="SECONDS", help="repeat every N seconds")
    ap.add_argument("--repo", default=None)
    a = ap.parse_args(argv)
    repo = Path(a.repo).resolve() if a.repo else repo_root()

    def log(msg: str) -> None:
        print(time.strftime("%H:%M:%S"), msg, flush=True)

    while True:
        rep = Tick(repo=repo, execute=a.execute, log=log).run()
        if not a.loop:
            print(json.dumps({k: rep[k] for k in ("ts", "execute", "notices")}, indent=2))
            return 0
        time.sleep(a.loop)


if __name__ == "__main__":
    raise SystemExit(main())
