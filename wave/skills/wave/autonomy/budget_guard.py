"""Budget / quota guard before spawning implement workers.

Reads whatever local quota signals are available:
  - Codex: preflight / ~/.codex session limit lines when present
  - Claude: optional WAVE_CLAUDE_WEEKLY_PCT env (orchestrator fills from usage card)
  - Always honors an explicit pause file written by pause_for_day

Pure predicate: pause=True means headroom is low. The caller (backlog_watch, only
when executing) calls daily_cap.pause_for_day; a dry run must not write state.
Does not invent numbers — if unreadible, records unknown and continues unless
WAVE_BUDGET_REQUIRE_READABLE=1.
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from daily_cap import ET



CODEX_LIMIT_RE = re.compile(r"(?i)(usage limit|rate limit|you've hit|quota)")


@dataclass(frozen=True)
class BudgetSnapshot:
    ok: bool
    pause: bool
    reason: str | None
    codex: dict[str, Any]
    claude: dict[str, Any]
    grok_calls_today: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "pause": self.pause,
            "reason": self.reason,
            "codex": self.codex,
            "claude": self.claude,
            "grok_calls_today": self.grok_calls_today,
        }


def _codex_from_preflight(preflight_path: Path | None) -> dict[str, Any]:
    if not preflight_path or not preflight_path.exists():
        return {"readable": False, "ok": None}
    try:
        data = json.loads(preflight_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"readable": False, "ok": None}
    for check in data.get("checks") or []:
        name = (check.get("name") or "").lower()
        if "codex" in name or "quota" in name:
            return {
                "readable": True,
                "ok": bool(check.get("ok")),
                "detail": check.get("detail"),
                "name": check.get("name"),
            }
    return {"readable": False, "ok": None, "preflight_ok": data.get("ok")}


def _claude_from_env() -> dict[str, Any]:
    pct = os.environ.get("WAVE_CLAUDE_WEEKLY_PCT", "").strip()
    if not pct:
        return {"readable": False, "ok": None}
    try:
        value = float(pct)
    except ValueError:
        return {"readable": False, "ok": None, "raw": pct}
    # Pause when at/over 85% of weekly all-model headroom.
    threshold = float(os.environ.get("WAVE_CLAUDE_PAUSE_PCT", "85"))
    return {
        "readable": True,
        "ok": value < threshold,
        "weekly_pct": value,
        "threshold": threshold,
    }


def read_grok_calls_today(wave_dir: Path | None = None) -> int:
    base = wave_dir or Path(__file__).resolve().parent
    path = base / "autonomy" / "grok_calls.jsonl"
    if not path.exists():
        return 0
    from datetime import datetime

    today = datetime.now(ET).date().isoformat()
    n = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if str(row.get("day")) == today:
            n += 1
    return n


def check_budget(
    *,
    wave_dir: Path | None = None,
    preflight_path: Path | None = None,
    require_readable: bool | None = None,
) -> BudgetSnapshot:
    wave_dir = wave_dir or Path(__file__).resolve().parent
    if require_readable is None:
        require_readable = os.environ.get("WAVE_BUDGET_REQUIRE_READABLE") == "1"

    codex = _codex_from_preflight(preflight_path)
    claude = _claude_from_env()
    grok_n = read_grok_calls_today(wave_dir)

    reasons: list[str] = []
    if codex.get("readable") and codex.get("ok") is False:
        reasons.append(f"codex quota low: {codex.get('detail') or codex.get('name')}")
    if claude.get("readable") and claude.get("ok") is False:
        reasons.append(
            f"claude weekly pct {claude.get('weekly_pct')} >= {claude.get('threshold')}"
        )
    if require_readable:
        if not codex.get("readable"):
            reasons.append("codex quota unreadable")
        if not claude.get("readable"):
            reasons.append("claude quota unreadable")

    if reasons:
        reason = "; ".join(reasons)
        return BudgetSnapshot(
            ok=False,
            pause=True,
            reason=reason,
            codex=codex,
            claude=claude,
            grok_calls_today=grok_n,
        )

    return BudgetSnapshot(
        ok=True,
        pause=False,
        reason=None,
        codex=codex,
        claude=claude,
        grok_calls_today=grok_n,
    )
