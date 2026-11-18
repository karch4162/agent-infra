#!/usr/bin/env python
"""Backlog-watch entrypoint for Sportify wave autonomy.

Scheduled / chat trigger:
  python .claude/wave/backlog_watch.py [--dry-run] [--force-enabled]

Default WAVE_BACKLOG_WATCH=0 (OFF). When enabled:
  - pick agent-ready low/medium from ClickUp list
  - never start risky (flag for Mason)
  - honor run lock + 3-worker cap + WAVE_DAILY_TICKET_CAP
  - plan step only when ticket is thin / PLAN_NEEDED
  - budget guard before spawn
  - stop-and-ask on questions / risky / cap / crash / closeout failure

This module selects and records what WOULD spawn. Actual WorkerRuntime.spawn
is invoked only when --execute is passed (and not dry-run).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from autonomy_config import load_autonomy_config
from budget_guard import check_budget
from daily_cap import ET, RunLock, can_start, load_daily, pause_for_day, record_start
from model_roles import assign_roles, rating_from_tags
from ticket_sufficiency import assess_ticket
from worker_runtime import run_alive


AUDIT_NAME = "wave-autonomy.jsonl"


@dataclass
class Pick:
    ticket_id: str
    title: str
    rating: str
    action: str  # spawn | plan_first | flag_risky | skip
    reason: str
    roles: dict[str, Any] | None = None
    sufficiency: dict[str, Any] | None = None


@dataclass
class WatchReport:
    ts: str
    enabled: bool
    dry_run: bool
    execute: bool
    picks: list[Pick] = field(default_factory=list)
    flagged_risky: list[dict[str, str]] = field(default_factory=list)
    skipped: list[dict[str, str]] = field(default_factory=list)
    budget: dict[str, Any] | None = None
    daily: dict[str, Any] | None = None
    notices: list[str] = field(default_factory=list)
    ok: bool = True

    def to_dict(self) -> dict[str, Any]:
        return {
            "ts": self.ts,
            "enabled": self.enabled,
            "dry_run": self.dry_run,
            "execute": self.execute,
            "ok": self.ok,
            "budget": self.budget,
            "daily": self.daily,
            "notices": self.notices,
            "flagged_risky": self.flagged_risky,
            "skipped": self.skipped,
            "picks": [asdict(p) for p in self.picks],
        }


def _default_wave_dir() -> Path:
    from autonomy_config import wave_dir as _wd

    return _wd()


def _append_audit(wave_dir: Path, row: dict[str, Any]) -> None:
    path = wave_dir / "autonomy" / AUDIT_NAME
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def _active_worker_count(runs_dir: Path, orca=None) -> int:
    n = 0
    if not runs_dir.exists():
        return 0
    for child in runs_dir.iterdir():
        if not child.is_dir():
            continue
        st_path = child / "status.json"
        if not st_path.exists():
            continue
        try:
            st = json.loads(st_path.read_text(encoding="utf-8-sig"))  # PowerShell writes a BOM
        except (OSError, json.JSONDecodeError):
            continue
        # File state alone leaked slots: a worker that died without status() being
        # called stayed "running" forever and autonomy stalled at zero free slots.
        # Orca workers have no PID; a PID check counted them as zero and over-spawned (INNOV-437).
        if st.get("state") in {"running", "starting"} and run_alive(st, child, orca):
            n += 1
    return n


def select_candidates(
    tickets: list[Any],
    *,
    cfg,
    wave_dir: Path,
    slots: int,
    trigger: str = "scheduled",
) -> tuple[list[Pick], list[dict[str, str]], list[dict[str, str]]]:
    picks: list[Pick] = []
    risky: list[dict[str, str]] = []
    skipped: list[dict[str, str]] = []
    # Implementer rotation: today's starts in this repo so far, so the share holds
    # across firings, not only within one (WAVE_CODEX_IMPLEMENT_EVERY).
    started_today = len(load_daily(wave_dir).started)

    for t in tickets:
        tid = getattr(t, "id", None) or t.get("id")
        title = getattr(t, "name", None) or t.get("name") or t.get("title") or ""
        tags = list(getattr(t, "tags", None) or t.get("tags") or [])
        body = getattr(t, "text", None) or t.get("text") or t.get("description") or ""
        rating = rating_from_tags(tags)

        if "agent-ready" not in {x.lower() for x in tags}:
            skipped.append({"id": tid, "reason": "missing agent-ready"})
            continue

        # agent-ready never overrides an owner: a ticket someone is assigned to is theirs (INNOV-438).
        owners = list(getattr(t, "assignees", None) or (t.get("assignees") if isinstance(t, dict) else None) or [])
        # Except the wave's own owner (WAVE_SELF): parking a ticket on yourself keeps people off it,
        # and it stays fair game for your own wave while it is agent-ready.
        others = [o for o in owners if str(o).strip().lower() not in cfg.self_names]
        if others:
            skipped.append({"id": tid, "reason": f"assigned to {', '.join(map(str, others))}"})
            continue

        if rating == "risky":
            risky.append({"id": tid, "title": title, "reason": "risky; needs Mason go"})
            continue

        # Never guess a rating: an unrated ticket is not READY (INNOV-439).
        if rating not in {"low", "medium"}:
            skipped.append({"id": tid, "reason": f"unrated: needs a rating tag (got {rating or 'none'})"})
            continue

        # Unattended (scheduled) waves take low only; medium waits for an owner wave.
        if rating == "medium" and trigger != "owner":
            skipped.append({"id": tid, "reason": "medium: owner waves only"})
            continue

        ok_cap, why = can_start(tid, cfg.daily_ticket_cap, wave_dir)
        if not ok_cap:
            skipped.append({"id": tid, "reason": why})
            continue

        if len(picks) >= slots:
            skipped.append({"id": tid, "reason": "worker slots full"})
            continue

        # Codex takes every Nth start of the day (the Nth, 2Nth, ...); Claude the rest.
        nth = started_today + len(picks) + 1
        codex_turn = cfg.codex_implements_low and nth % cfg.codex_implement_every == 0
        roles = assign_roles(rating, codex_implement_low=codex_turn).to_dict()
        suf = assess_ticket(title=title, body=body, tags=tags)
        if suf.plan_needed:
            picks.append(
                Pick(
                    ticket_id=tid,
                    title=title,
                    rating=rating,
                    action="plan_first",
                    reason="; ".join(suf.reasons) or "plan needed",
                    roles=roles,
                    sufficiency=suf.to_dict(),
                )
            )
        else:
            picks.append(
                Pick(
                    ticket_id=tid,
                    title=title,
                    rating=rating,
                    action="spawn",
                    reason="sufficient detail",
                    roles=roles,
                    sufficiency=suf.to_dict(),
                )
            )
    return picks, risky, skipped


def run_watch(
    *,
    wave_dir: Path | None = None,
    dry_run: bool = True,
    execute: bool = False,
    force_enabled: bool = False,
    tickets: list[Any] | None = None,
    preflight_path: Path | None = None,
    lock: RunLock | None = None,
    record_starts: bool = True,
    trigger: str = "scheduled",
) -> WatchReport:
    """Select (and with execute, queue) the next tickets.

    lock: a RunLock the caller already holds (the tick holds one for its whole
    pass; a second acquire in the same process fails). record_starts=False lets
    the caller count the ticket against the daily cap only after a spawn
    actually succeeded, so a preflight failure does not burn the slot.
    """
    wave_dir = wave_dir or _default_wave_dir()
    cfg = load_autonomy_config(wave_dir / "config.env")
    ts = datetime.now(ET).isoformat()
    want_execute = bool(execute and not dry_run)
    if want_execute and not cfg.enabled:
        report = WatchReport(
            ts=ts,
            enabled=False,
            dry_run=True,
            execute=False,
            ok=False,
            notices=[
                "refusing --execute while WAVE_BACKLOG_WATCH=0 "
                "(--force-enabled is dry-run/simulate only)"
            ],
        )
        return report
    report = WatchReport(
        ts=ts,
        enabled=cfg.enabled or force_enabled,
        dry_run=dry_run or not cfg.enabled,
        execute=want_execute and cfg.enabled,
    )

    if not report.enabled:
        report.notices.append("WAVE_BACKLOG_WATCH=0 (off); pass --force-enabled to simulate")
        report.ok = True
        return report

    own_lock = lock is None
    if own_lock:
        lock = RunLock(wave_dir)
        got, lock_why = lock.acquire("backlog_watch")
        if not got:
            report.ok = False
            report.notices.append(f"run lock: {lock_why}")
            return report

    try:
        if cfg.budget_guard:
            budget = check_budget(wave_dir=wave_dir, preflight_path=preflight_path)
            report.budget = budget.to_dict()
            if budget.pause:
                report.ok = False
                report.notices.append(f"budget pause: {budget.reason}")
                if report.execute:
                    pause_for_day(budget.reason or "budget", wave_dir)
                _append_audit(
                    wave_dir,
                    {
                        "ts": ts,
                        "stage": "budget",
                        "decision": "pause",
                        "reason": budget.reason,
                    },
                )
                return report

        daily = load_daily(wave_dir)
        report.daily = daily.to_dict()
        active = _active_worker_count(wave_dir / "runs")
        slots = max(0, cfg.max_implement_workers - active)
        # can_start reads the cap from disk per ticket and starts are recorded after
        # the loop, so one pass could pick past the cap; clamp to what is left today.
        slots = min(slots, max(0, cfg.daily_ticket_cap - len(daily.started)))
        if slots == 0:
            report.notices.append("no free slots (worker cap or daily cap)")
            return report

        # Spend cap (INNOV-441): today's runs at Claude API prices. A start is refused when
        # today's spend plus one more run (today's mean; 0 before the first) would cross it.
        if cfg.budget_per_day_usd is not None:
            from run_spend import runs_started_today, spend_for_runs, spend_usd

            runs = runs_started_today(wave_dir)
            spent = spend_for_runs(runs)
            priced = [u for u in (spend_usd(r)[0] for r in runs) if u is not None]
            est = sum(priced) / len(priced) if priced else 0.0
            report.budget = {**(report.budget or {}), "spend_today_usd": spent,
                             "cap_per_day_usd": cfg.budget_per_day_usd, "est_next_run_usd": round(est, 4)}
            fits = int((cfg.budget_per_day_usd - spent) // est) if est > 0 else (slots if spent < cfg.budget_per_day_usd else 0)
            if fits < slots:
                slots = max(0, fits)
                report.notices.append(f"spend cap: ${spent:.2f} of ${cfg.budget_per_day_usd:.2f} today "
                                      f"(~${est:.2f}/run): {slots} start(s) left")
            if slots == 0:
                return report

        if tickets is None:
            # Live fetch from the repo's tracker (ClickUp token / acli login stay out of logs).
            from jira_tracker import tracker_for

            adapter = tracker_for(cfg)
            if adapter is None:
                report.notices.append(f"automatic picking is not wired for tracker={cfg.tracker or 'unset'}")
                return report
            tickets = adapter.fetch_queue(
                statuses=[cfg.queue_status],
                require_tags=["agent-ready"],
            )

        picks, risky, skipped = select_candidates(
            tickets, cfg=cfg, wave_dir=wave_dir, slots=slots, trigger=trigger
        )
        report.picks = picks
        report.flagged_risky = risky
        report.skipped = skipped

        if risky:
            notice = wave_dir / "autonomy" / "mason_risky.md"
            notice.parent.mkdir(parents=True, exist_ok=True)
            lines = ["# Risky tickets flagged (not started)\n"]
            for r in risky:
                lines.append(f"- {r['id']}: {r.get('title','')} — {r['reason']}")
            notice.write_text("\n".join(lines) + "\n", encoding="utf-8")
            report.notices.append(f"flagged {len(risky)} risky ticket(s) for Mason")

        for p in picks:
            _append_audit(
                wave_dir,
                {
                    "ts": ts,
                    "stage": "backlog_watch",
                    "ticket": p.ticket_id,
                    "rating": p.rating,
                    "decision": p.action,
                    "reason": p.reason,
                    "dry_run": dry_run,
                    "execute": report.execute,
                },
            )
            if report.execute and p.action in {"spawn", "plan_first"}:
                if record_starts:
                    record_start(p.ticket_id, wave_dir)
                # Spawning / plan loop is orchestrator-owned; this entry records intent.
                # Wire DirectWorkerRuntime.spawn from the chat/controller layer.
                (wave_dir / "autonomy" / "pending_spawns.jsonl").parent.mkdir(
                    parents=True, exist_ok=True
                )
                with (wave_dir / "autonomy" / "pending_spawns.jsonl").open(
                    "a", encoding="utf-8"
                ) as f:
                    f.write(json.dumps(asdict(p), ensure_ascii=False) + "\n")

        report.daily = load_daily(wave_dir).to_dict()
        return report
    finally:
        if own_lock:
            lock.release("backlog_watch")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Sportify backlog-watch autonomy")
    ap.add_argument("--dry-run", action="store_true", default=False)
    ap.add_argument("--execute", action="store_true", default=False)
    ap.add_argument("--force-enabled", action="store_true", default=False)
    ap.add_argument("--out", default="", help="Write report JSON path")
    ap.add_argument("--trigger", choices=("scheduled", "owner"), default="scheduled",
                    help="scheduled (default) takes low only; owner also takes medium")
    args = ap.parse_args(argv)

    wave_dir = _default_wave_dir()
    dry = not args.execute or args.dry_run

    report = run_watch(
        wave_dir=wave_dir,
        dry_run=dry,
        execute=args.execute and not dry,
        force_enabled=args.force_enabled,
        trigger=args.trigger,
    )
    out = json.dumps(report.to_dict(), indent=2)
    print(out)
    if args.out:
        Path(args.out).write_text(out + "\n", encoding="utf-8")
    return 0 if report.ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
