"""What a wave run cost, in USD at Claude API prices (INNOV-441).

One number per run, from one source:
  - worker.log's totalCostUSD (direct Claude workers): Claude Code's own figure, which
    also counts its background calls;
  - otherwise the Claude session logs of the run's worktree (Orca workers), priced with
    the table below. Those logs miss Claude Code's background calls, so this reads
    about 20% low; set caps with that headroom.
  - Codex runs are not priced (subscription quota, not dollars; budget_guard covers quota).

The price table and cache-write formula are ported from agent-control-center's server.js
(claudeUsd), verified to the cent against Claude's own modelUsage. The plugin is now the
source: the dashboard should read these numbers, not re-derive them.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any

from daily_cap import load_daily
from usage_log import write_usage

# (model pattern, input, output, cache read) in $ per million tokens. Order matters:
# the first match wins, so the 5.1 rows sit above the 5 rows.
CLAUDE_PRICES = [
    (r"fable-5-1|mythos-5-1", 10, 50, 0.25), (r"fable-5|mythos-5", 10, 50, 1),
    (r"opus-5-5", 4, 20, 0.2), (r"opus-(5|4-[678])", 5, 25, 0.5),
    (r"sonnet-5", 2, 10, 0.2), (r"sonnet-4-6", 3, 15, 0.3),
    (r"haiku-5-5", 0.1, 0.5, 0.01), (r"haiku-4-5", 1, 5, 0.1),
]


def claude_usd(model: str, u: dict[str, Any]) -> float | None:
    """USD for one message's usage block, or None for a model not in the table."""
    row = next((r for r in CLAUDE_PRICES if re.search(r[0], model or "")), None)
    if row is None:
        return None
    _, inp, out, read = row
    hour = (u.get("cache_creation") or {}).get("ephemeral_1h_input_tokens") or 0
    write = (u.get("cache_creation_input_tokens") or 0) - hour   # 5-minute writes: 1.25x input; 1-hour: 2x
    return ((u.get("input_tokens") or 0) * inp + (u.get("output_tokens") or 0) * out
            + (u.get("cache_read_input_tokens") or 0) * read + write * inp * 1.25 + hour * inp * 2) / 1e6


def projects_dir(worktree: str, home: Path | None = None) -> Path:
    """Claude Code's transcript folder for a cwd: every non-alphanumeric character becomes '-'."""
    return (home or Path(os.path.expanduser("~"))) / ".claude" / "projects" / re.sub(r"[^A-Za-z0-9]", "-", worktree)


def session_usd(worktree: str, home: Path | None = None) -> float | None:
    """Priced sum of the worktree's Claude session logs; None when there are none."""
    d = projects_dir(worktree, home)
    if not d.is_dir():
        return None
    seen: dict[str, float] = {}
    for f in d.glob("*.jsonl"):
        with f.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                m = o.get("message") or {}
                u = m.get("usage")
                if o.get("type") != "assistant" or not u or not m.get("id") or m.get("model") == "<synthetic>":
                    continue
                usd = claude_usd(m.get("model"), u)
                if usd is not None:   # a streamed turn repeats its usage under one id: count it once
                    seen[m["id"] + (o.get("requestId") or "")] = usd
    return round(sum(seen.values()), 6) if seen else None


def spend_usd(run_dir: Path, home: Path | None = None) -> tuple[float | None, str]:
    """(USD, source) for one run. Writes the figure into usage.json's cost_usd_last, where
    wave_status and the aggregate report already read it."""
    usage_path = run_dir / "usage.json"
    if (run_dir / "worker.log").exists():   # direct runtime: Claude Code's own total wins
        usage = write_usage(run_dir)
        if usage.get("cost_usd_last") is not None:
            usage["cost_source"] = "worker.log"
            usage_path.write_text(json.dumps(usage, indent=2) + "\n", encoding="utf-8")
            return usage["cost_usd_last"], "worker.log"
    try:
        usage = json.loads(usage_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        usage = {}
    try:
        st = json.loads((run_dir / "status.json").read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None, "no status"
    if (st.get("agent") or "claude") != "claude":
        usd, src = None, f"unpriced ({st.get('agent')})"
    else:
        usd, src = session_usd(st.get("path") or "", home), "session logs"
    usage.update(cost_usd_last=usd, cost_source=src)
    run_dir.mkdir(parents=True, exist_ok=True)
    usage_path.write_text(json.dumps(usage, indent=2) + "\n", encoding="utf-8")
    return usd, src


def spend_for_runs(run_dirs: list[Path], home: Path | None = None) -> float:
    """Sum of the priced runs (unpriced count as 0). The control repo sums these across repos."""
    return round(sum(spend_usd(d, home)[0] or 0 for d in run_dirs), 6)


def runs_started_today(wave_dir: Path) -> list[Path]:
    """Run dirs of the tickets started today (ET), by the same day boundary as the daily cap."""
    return [wave_dir / "runs" / t.lower() for t in load_daily(wave_dir).started]


def spend_today(wave_dir: Path, home: Path | None = None) -> float:
    return spend_for_runs(runs_started_today(wave_dir), home)
