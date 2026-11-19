#!/usr/bin/env python
"""wave run: the control folder's one entrypoint (INNOV-443, Coding wave spec v2).

  python wave_run.py precheck --trigger intake|scheduled|owner   # gates only; exit 3 = skip
  python wave_run.py run      --trigger intake|scheduled|owner   # gates, then one tick per repo
  python wave_run.py status                                      # machine-wide counts, no changes

The control folder (--control, else WAVE_CONTROL_DIR, else ~/Projects/wave-control) holds
only config.env and state/. A scheduler (an Orca automation by default) calls this through
the folder's bin/wave_run.py launcher, which finds the installed wave plugin. Every gate
lives here, so a misconfigured scheduler cannot skip one:

  stop file -> config -> trigger allowed -> waves today -> machine lock -> per repo:
  cooldown -> machine-wide worker / start / spend caps (handed to the tick as env overrides)

Each firing is ONE tick per repo, never a whole wave: wave state lives in each repo's
.claude/wave/ between firings, so a missed or crashed firing loses nothing. intake = dry run
(report only). scheduled/owner = --execute, which still needs WAVE_BACKLOG_WATCH=1 in that
repo before it picks tickets. Scheduled picking takes rating:low only (INNOV-439).

Ported from the wave-control runner Duet wrote (2026-11-14); its workarounds for plugin
gaps are gone now that the plugin counts Orca workers (INNOV-437), skips assigned tickets
(438), auto-merges low only on schedule (439), reads Jira (440) and prices runs (441).

Exit codes: 0 ok, 1 a repo tick failed (escalated), 2 config error, 3 skipped by a gate.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from autonomy_config import load_config_env  # noqa: E402
from backlog_watch import _active_worker_count  # noqa: E402
from daily_cap import ET, RunLock, load_daily  # noqa: E402
from run_spend import spend_today  # noqa: E402

TRIGGERS = ("intake", "scheduled", "owner")
EXECUTING = ("scheduled", "owner")
EXIT_OK, EXIT_FAIL, EXIT_CONFIG, EXIT_SKIP = 0, 1, 2, 3
DEFAULTS = {
    "WAVE_CONTROL_REPOS": "",
    "SCHEDULE_INTAKE": "",
    "SCHEDULE_WAVE": "",
    "MAX_WORKERS": "3",
    "DAILY_TICKET_CAP": "3",
    "MAX_WAVES_PER_DAY": "4",
    "COOLDOWN_AFTER_FAIL_HOURS": "12",
    "BUDGET_PER_DAY": "",        # USD at Claude API prices, all repos; empty = no cap
    "CLAUDE_PAUSE_PCT": "85",    # stop new starts at this % of the subscription's 7-day limit
    "STOP_FILE": "STOP",
    "PYTHON": "",
    "TICK_TIMEOUT_MIN": "90",
}


def now() -> datetime:
    return datetime.now(ET)


def today() -> str:
    return now().date().isoformat()


def default_control() -> Path:
    return Path(os.environ.get("WAVE_CONTROL_DIR") or Path(os.path.expanduser("~")) / "Projects" / "wave-control")


class Config:
    def __init__(self, control: Path):
        self.control = control
        self.state = control / "state"
        self.path = control / "config.env"
        v = {**DEFAULTS, **load_config_env(self.path)}
        self.raw = v
        self.repos = [Path(os.path.expanduser(p.strip()))
                      for p in v["WAVE_CONTROL_REPOS"].replace(",", ";").split(";") if p.strip()]
        self.schedule_wave = v["SCHEDULE_WAVE"]
        self.max_workers = int(v["MAX_WORKERS"] or 0)
        self.daily_ticket_cap = int(v["DAILY_TICKET_CAP"] or 0)
        self.max_waves_per_day = int(v["MAX_WAVES_PER_DAY"] or 0)
        self.cooldown_h = float(v["COOLDOWN_AFTER_FAIL_HOURS"] or 0)
        self.budget = float(v["BUDGET_PER_DAY"]) if v["BUDGET_PER_DAY"] else None
        self.claude_pause_pct = v["CLAUDE_PAUSE_PCT"] or "85"
        self.stop_file = control / (v["STOP_FILE"] or "STOP")
        self.python = v["PYTHON"] or sys.executable
        self.tick_timeout_s = int(float(v["TICK_TIMEOUT_MIN"] or 90) * 60)

    def problems(self) -> list[str]:
        p = []
        if not self.path.exists():
            p.append(f"missing {self.path}")
        if not self.repos:
            p.append("WAVE_CONTROL_REPOS is empty")
        if self.max_workers < 1 or self.daily_ticket_cap < 0 or self.max_waves_per_day < 0:
            p.append("MAX_WORKERS must be >= 1; DAILY_TICKET_CAP and MAX_WAVES_PER_DAY >= 0")
        return p


class Control:
    """State under <control>/state/: audit.jsonl, waves.json, cooldown.json, escalations.md, last-run.md."""

    def __init__(self, cfg: Config, tick=None):
        self.cfg, self.state = cfg, cfg.state
        self.tick = tick or self._tick

    # ---- state ----
    def read(self, name: str, default: Any) -> Any:
        try:
            return json.loads((self.state / name).read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            return default

    def write(self, name: str, data: Any) -> None:
        self.state.mkdir(parents=True, exist_ok=True)
        tmp = self.state / (name + ".tmp")
        tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp, self.state / name)

    def audit(self, row: dict[str, Any]) -> None:
        self.state.mkdir(parents=True, exist_ok=True)
        with (self.state / "audit.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": now().isoformat(timespec="seconds"), **row}, ensure_ascii=False) + "\n")

    def waves_today(self) -> list[dict[str, Any]]:
        w = self.read("waves.json", {})
        return w.get("runs", []) if w.get("day") == today() else []

    def record_wave(self, run_id: str, trigger: str) -> None:
        self.write("waves.json", {"day": today(), "runs": [*self.waves_today(),
                                                           {"run_id": run_id, "trigger": trigger, "at": now().isoformat()}]})

    def in_cooldown(self, repo: Path) -> str | None:
        until = self.read("cooldown.json", {}).get(str(repo))
        return until if until and datetime.fromisoformat(until) > now() else None

    def set_cooldown(self, repo: Path) -> str:
        c = self.read("cooldown.json", {})
        c[str(repo)] = (now() + timedelta(hours=self.cfg.cooldown_h)).isoformat()
        self.write("cooldown.json", c)
        return c[str(repo)]

    def escalate(self, run_id: str, text: str) -> None:
        self.state.mkdir(parents=True, exist_ok=True)
        with (self.state / "escalations.md").open("a", encoding="utf-8") as f:
            f.write(f"- {now().isoformat(timespec='seconds')} [{run_id}] {text}\n")

    def lock(self) -> RunLock:
        return RunLock(self.state)   # OS advisory lock: a crashed holder releases it, so no stale lock

    # ---- machine-wide counts, from each repo's own wave state ----
    @staticmethod
    def wave_dir(repo: Path) -> Path:
        return repo / ".claude" / "wave"

    def live(self, repo: Path) -> int:
        return _active_worker_count(self.wave_dir(repo) / "runs")   # Orca-aware (INNOV-437)

    def starts(self, repo: Path) -> int:
        return len(load_daily(self.wave_dir(repo)).started) if (self.wave_dir(repo) / "config.env").exists() else 0

    def spent(self, repo: Path) -> float:
        return spend_today(self.wave_dir(repo)) if (self.wave_dir(repo) / "config.env").exists() else 0.0

    def repo_cap(self, repo: Path, key: str, default: int) -> int:
        v = load_config_env(self.wave_dir(repo) / "config.env").get(key, "")
        try:
            return int(v) if v else default
        except ValueError:
            return default

    def caps_for(self, repo: Path) -> dict[str, str]:
        """Env overrides that make this repo's tick take no more than the machine has left.
        The tick reads env before config.env and computes slots = cap - (its own count)."""
        cfg, repos = self.cfg, self.cfg.repos
        free_workers = max(0, cfg.max_workers - sum(self.live(r) for r in repos))
        free_starts = max(0, cfg.daily_ticket_cap - sum(self.starts(r) for r in repos))
        live, mine = self.live(repo), self.starts(repo)
        env = {
            "WAVE_MAX_IMPLEMENT_WORKERS": str(live + max(0, min(self.repo_cap(repo, "WAVE_MAX_IMPLEMENT_WORKERS", 3) - live, free_workers))),
            "WAVE_DAILY_TICKET_CAP": str(mine + max(0, min(self.repo_cap(repo, "WAVE_DAILY_TICKET_CAP", 3) - mine, free_starts))),
            "WAVE_CLAUDE_PAUSE_PCT": cfg.claude_pause_pct,
        }
        if cfg.budget is not None:   # the tick refuses a start that would cross spent-here + what's left
            left = max(0.0, cfg.budget - sum(self.spent(r) for r in repos))
            env["WAVE_BUDGET_PER_DAY_USD"] = f"{self.spent(repo) + left:.4f}"
        return env

    # ---- gates ----
    def gates(self, trigger: str) -> tuple[int, str]:
        cfg = self.cfg
        if trigger not in TRIGGERS:
            return EXIT_CONFIG, f"trigger '{trigger}' is not allowed ({', '.join(TRIGGERS)})"
        if cfg.stop_file.exists():
            return EXIT_SKIP, f"stop file present ({cfg.stop_file.name})"
        probs = cfg.problems()
        if probs:
            return EXIT_CONFIG, "; ".join(probs)
        if trigger == "scheduled" and not cfg.schedule_wave:
            return EXIT_SKIP, "SCHEDULE_WAVE is empty: scheduled waves are off"
        if trigger in EXECUTING and len(self.waves_today()) >= cfg.max_waves_per_day:
            return EXIT_SKIP, f"MAX_WAVES_PER_DAY reached ({cfg.max_waves_per_day})"
        return EXIT_OK, "ok"

    # ---- tick ----
    def _tick(self, repo: Path, trigger: str, env_over: dict[str, str]) -> tuple[int, list[str] | None, str]:
        args = [self.cfg.python, str(HERE / "autonomy_tick.py"), "--repo", str(repo)]
        if trigger in EXECUTING:
            args.append("--execute")
        try:
            # The tick reads WAVE_TRIGGER: without it an owner run picked like a scheduled one.
            p = subprocess.run(args, cwd=str(repo), env={**os.environ, **env_over, "WAVE_TRIGGER": trigger},
                               capture_output=True, text=True,
                               encoding="utf-8", errors="replace", timeout=self.cfg.tick_timeout_s)
        except subprocess.TimeoutExpired:
            return 124, None, f"tick timed out after {self.cfg.tick_timeout_s // 60} min"
        return p.returncode, tick_notices(p.stdout or ""), ((p.stdout or "") + (p.stderr or ""))[-1500:]

    # ---- commands ----
    def precheck(self, trigger: str) -> int:
        rc, why = self.gates(trigger)
        if rc == EXIT_OK:
            lock = self.lock()
            got, _ = lock.acquire("wave_run precheck")
            if got:
                lock.release("wave_run precheck")
            else:
                rc, why = EXIT_SKIP, "another wave run holds the machine lock"
        self.audit({"stage": "precheck", "trigger": trigger, "decision": "go" if rc == EXIT_OK else "skip", "reason": why, "rc": rc})
        print(f"precheck {trigger}: {'go' if rc == EXIT_OK else 'skip'} ({why})")
        return rc

    def run(self, trigger: str) -> int:
        cfg = self.cfg
        run_id = f"{now().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}"
        rc, why = self.gates(trigger)
        if rc != EXIT_OK:
            self.audit({"run_id": run_id, "stage": "gate", "trigger": trigger, "decision": "skip", "reason": why, "rc": rc})
            print(f"wave {trigger}: skipped ({why})")
            return rc
        lock = self.lock()
        got, _ = lock.acquire("wave_run")
        if not got:
            self.audit({"run_id": run_id, "stage": "lock", "trigger": trigger, "decision": "skip", "reason": "lock held"})
            print(f"wave {trigger}: skipped (another wave run holds the machine lock)")
            return EXIT_SKIP
        lines: list[str] = []
        failed = started = False
        try:
            self.audit({"run_id": run_id, "stage": "start", "trigger": trigger, "repos": [str(r) for r in cfg.repos]})
            for repo in cfg.repos:
                if cfg.stop_file.exists():
                    lines.append(f"- STOP file appeared: halted before {repo.name}; running workers are left to finish")
                    self.audit({"run_id": run_id, "stage": "stop", "repo": str(repo), "decision": "halt"})
                    break
                if not (self.wave_dir(repo) / "config.env").exists():
                    lines.append(f"- {repo.name}: skipped (no .claude/wave/config.env or repo missing)")
                    self.audit({"run_id": run_id, "stage": "repo", "repo": str(repo), "decision": "skip", "reason": "no config"})
                    continue
                until = self.in_cooldown(repo)
                if until and trigger == "scheduled":
                    lines.append(f"- {repo.name}: skipped (cooldown after a failed wave, until {until})")
                    self.audit({"run_id": run_id, "stage": "repo", "repo": str(repo), "decision": "skip", "reason": "cooldown", "until": until})
                    continue
                env_over = self.caps_for(repo)   # recounted per repo: the previous tick may have spawned
                t0 = time.time()
                trc, notices, tail = self.tick(repo, trigger, env_over)
                spawned = spawned_since(repo, t0)
                started = started or bool(spawned)
                if trc == 0 and notices is None:
                    trc, notices = 1, ["tick exited 0 but printed no report"]
                notices = notices or []
                # Every pick failing to spawn is a broken repo (a bad config.env broke spawn.sh on
                # each firing of the hub demo while the run said ok); one failure beside a started
                # worker stays a notice (INNOV-449).
                spawn_failed = [n for n in notices if ": spawn failed:" in n]
                bad = trc != 0 or any("closeout failed" in n for n in notices) or bool(spawn_failed and not spawned)
                self.audit({"run_id": run_id, "stage": "tick", "trigger": trigger, "repo": str(repo), "rc": trc,
                            "decision": "failed" if bad else "ok", "caps": env_over, "notices": notices[:20],
                            "spawned": spawned,
                            "seconds": round(time.time() - t0)})
                lines.append(f"- {repo.name}: {'FAILED' if bad else 'ok'} (caps: {env_over['WAVE_MAX_IMPLEMENT_WORKERS']} workers, "
                             f"{env_over['WAVE_DAILY_TICKET_CAP']} starts today"
                             + (f", ${float(env_over['WAVE_BUDGET_PER_DAY_USD']):.2f} spend" if "WAVE_BUDGET_PER_DAY_USD" in env_over else "") + ")")
                lines.extend(f"    notice: {n}" for n in notices[:10])
                if bad:
                    failed = True
                    why = (next((n for n in notices if "closeout failed" in n), None)
                           or (f"no worker started; {spawn_failed[0].strip()}" if spawn_failed and not spawned else None)
                           or (notices[-1] if notices else tail[-300:].strip()))
                    msg = f"{repo.name}: tick rc={trc}; {why}"
                    if trigger in EXECUTING and cfg.cooldown_h > 0:
                        msg += f"; cooldown until {self.set_cooldown(repo)}"
                    self.escalate(run_id, msg)
            # A wave is a firing that started workers. Ticks that only advance CI, review and
            # merge are not waves; counting them used up MAX_WAVES_PER_DAY in a few firings.
            if started:
                self.record_wave(run_id, trigger)
        finally:
            lock.release("wave_run")
        summary = "\n".join([f"WAVE {trigger} {run_id}: {'FAILED, see state/escalations.md' if failed else 'ok'}", *lines])
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / "last-run.md").write_text(summary + "\n", encoding="utf-8")
        self.audit({"run_id": run_id, "stage": "end", "trigger": trigger, "decision": "failed" if failed else "ok"})
        print(summary)
        return EXIT_FAIL if failed else EXIT_OK

    def status(self) -> int:
        cfg = self.cfg
        print(f"control: {cfg.control}")
        for p in cfg.problems():
            print(f"  problem: {p}")
        print(f"stop file: {'PRESENT' if cfg.stop_file.exists() else 'absent'}")
        print(f"waves today: {len(self.waves_today())}/{cfg.max_waves_per_day}")
        lock = self.lock()
        got, _ = lock.acquire("wave_run status")
        if got:
            lock.release("wave_run status")
        print(f"machine lock: {'free' if got else 'held'}")
        for r in cfg.repos:
            cd = self.in_cooldown(r)
            has = (self.wave_dir(r) / "config.env").exists()
            print(f"  {r}: {'config ok' if has else 'NO CONFIG'}, live {self.live(r)}, starts today {self.starts(r)}, "
                  f"spent today ${self.spent(r):.2f}{', cooldown until ' + cd if cd else ''}")
        return EXIT_OK


def spawned_since(repo: Path, t0: float) -> list[str]:
    """Tickets this repo's tick spawned, from the tick-last.json it wrote after t0."""
    try:
        last = json.loads((repo / ".claude" / "wave" / "autonomy" / "tick-last.json").read_text(encoding="utf-8"))
        if datetime.fromisoformat(last["ts"]).timestamp() < t0 - 1:
            return []   # stale: this tick wrote no report (its repo lock was held)
        return [e.get("ticket") for e in last.get("events") or [] if e.get("event") == "spawned"]
    except (OSError, ValueError, KeyError, TypeError):
        return []


def tick_notices(stdout: str) -> list[str] | None:
    """The tick ends by printing {"ts", "execute", "notices"} as indented JSON, even when the
    repo's own run lock is held and no tick-last.json is written."""
    lines = stdout.splitlines()
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].strip() == "{":
            try:
                return list(json.loads("\n".join(lines[i:])).get("notices") or [])
            except ValueError:
                return None
    return None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="wave run: the control folder's one entrypoint")
    ap.add_argument("command", choices=["precheck", "run", "status"])
    ap.add_argument("--trigger", choices=TRIGGERS)
    ap.add_argument("--control", default=None, help="control folder (default: WAVE_CONTROL_DIR or ~/Projects/wave-control)")
    a = ap.parse_args(argv)
    ctl = Control(Config(Path(a.control) if a.control else default_control()))
    if a.command == "status":
        return ctl.status()
    if not a.trigger:
        ap.error("--trigger is required for precheck and run")
    return ctl.precheck(a.trigger) if a.command == "precheck" else ctl.run(a.trigger)


if __name__ == "__main__":
    raise SystemExit(main())
