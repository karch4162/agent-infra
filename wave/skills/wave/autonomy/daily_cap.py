"""Daily ticket start counter + run lock for backlog-watch.

Persists under .claude/wave/autonomy/ so a scheduled run and a chat kickoff share state.
"""
from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from typing import Any

def et_zone():
    """America/New_York; the one copy every autonomy module imports.

    Needs the tzdata wheel on Windows (pip install tzdata). The fixed-offset
    fallback has no DST, so warn: the daily-cap day boundary is off by an hour
    March-November without it.
    """
    try:
        from zoneinfo import ZoneInfo

        return ZoneInfo("America/New_York")
    except Exception:
        import sys
        from datetime import timedelta, timezone

        print("wave: tzdata missing; using fixed UTC-5 (pip install tzdata)", file=sys.stderr)
        return timezone(timedelta(hours=-5), name="America/New_York")

ET = et_zone()


def autonomy_dir(wave_dir: Path | None = None) -> Path:
    base = wave_dir or Path(__file__).resolve().parent
    d = base / "autonomy"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _today_et() -> str:
    return datetime.now(ET).date().isoformat()


@dataclass
class DailyCapState:
    day: str
    started: list[str]
    paused_reason: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "day": self.day,
            "started": list(self.started),
            "paused_reason": self.paused_reason,
            "count": len(self.started),
        }


def load_daily(wave_dir: Path | None = None) -> DailyCapState:
    path = autonomy_dir(wave_dir) / "daily_cap.json"
    today = _today_et()
    if not path.exists():
        return DailyCapState(day=today, started=[])
    raw = json.loads(path.read_text(encoding="utf-8"))
    if raw.get("day") != today:
        return DailyCapState(day=today, started=[], paused_reason=None)
    return DailyCapState(
        day=today,
        started=list(raw.get("started") or []),
        paused_reason=raw.get("paused_reason"),
    )


def save_daily(state: DailyCapState, wave_dir: Path | None = None) -> Path:
    path = autonomy_dir(wave_dir) / "daily_cap.json"
    path.write_text(json.dumps(state.to_dict(), indent=2) + "\n", encoding="utf-8")
    return path


def can_start(ticket_id: str, cap: int, wave_dir: Path | None = None) -> tuple[bool, str]:
    state = load_daily(wave_dir)
    if state.paused_reason:
        return False, f"paused: {state.paused_reason}"
    if ticket_id in state.started:
        return False, f"already counted today: {ticket_id}"
    if len(state.started) >= cap:
        return False, f"daily cap reached ({cap})"
    return True, "ok"


def record_start(ticket_id: str, wave_dir: Path | None = None) -> DailyCapState:
    state = load_daily(wave_dir)
    if ticket_id not in state.started:
        state.started.append(ticket_id)
        save_daily(state, wave_dir)
    return state


def pause_for_day(reason: str, wave_dir: Path | None = None) -> DailyCapState:
    state = load_daily(wave_dir)
    state.paused_reason = reason
    save_daily(state, wave_dir)
    notice = autonomy_dir(wave_dir) / "mason_notice.md"
    notice.write_text(
        f"# Backlog-watch paused\n\nDay: {state.day} (America/New_York)\n\nReason: {reason}\n",
        encoding="utf-8",
    )
    return state


class RunLock:
    """Exclusive run lock via OS advisory locking on a permanent file.

    The lock file is never deleted for ownership transfer. The OS releases the
    lock when the holding process exits (including crash), so there is no
    stale-steal / path-reuse race. Cross-platform: msvcrt on Windows, fcntl elsewhere.
    """

    def __init__(self, wave_dir: Path | None = None, *, stale_seconds: int = 6 * 3600):
        # stale_seconds kept for API compat; unused with advisory locks.
        self.path = autonomy_dir(wave_dir) / "run.lock"
        self.stale_seconds = stale_seconds
        self._fh = None
        self._holder: str | None = None

    def _ensure_lock_byte(self) -> None:
        """Guarantee byte 0 exists; leave file pointer at offset 0."""
        assert self._fh is not None
        self._fh.seek(0, os.SEEK_END)
        if self._fh.tell() < 1:
            self._fh.write(b"\0")
            self._fh.flush()
        self._fh.seek(0)

    def _try_lock_fd(self) -> bool:
        assert self._fh is not None
        try:
            if os.name == "nt":
                import msvcrt

                self._ensure_lock_byte()
                # Always lock byte 0 from offset 0 (msvcrt locks from current offset).
                msvcrt.locking(self._fh.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(self._fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            return False

    def _unlock_fd(self) -> None:
        if self._fh is None:
            return
        try:
            if os.name == "nt":
                import msvcrt

                self._fh.seek(0)
                try:
                    msvcrt.locking(self._fh.fileno(), msvcrt.LK_UNLCK, 1)
                except OSError:
                    pass
            else:
                import fcntl

                fcntl.flock(self._fh.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass

    def acquire(self, holder: str) -> tuple[bool, str]:
        if self._fh is not None:
            return False, "already held in this process"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            fh = open(self.path, "a+b")
        except OSError as e:
            return False, f"lock open failed: {e}"
        self._fh = fh
        if not self._try_lock_fd():
            try:
                fh.close()
            except OSError:
                pass
            self._fh = None
            return False, "held by peer"
        self._holder = holder
        meta = {
            "holder": holder,
            "pid": os.getpid(),
            "ts": time.time(),
        }
        try:
            # Best-effort metadata alongside the lock (not used for ownership).
            meta_path = self.path.with_suffix(".lock.meta.json")
            meta_path.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
        except OSError:
            pass
        return True, "acquired"

    def release(self, holder: str) -> None:
        if self._fh is None:
            return
        if self._holder is not None and self._holder != holder:
            return
        self._unlock_fd()
        try:
            self._fh.close()
        except OSError:
            pass
        self._fh = None
        self._holder = None


