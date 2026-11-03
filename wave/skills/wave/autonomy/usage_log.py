"""Per-worker token/cost logging from worker.log (Mason t24u)."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


TOKEN_RE = re.compile(r"tokens used\s*[\r\n]+\s*([\d,]+)", re.I)
COST_RE = re.compile(r'"totalCostUSD":\s*([0-9.]+)')


def parse_worker_log(text: str) -> dict[str, Any]:
    tokens = [int(m.replace(",", "")) for m in TOKEN_RE.findall(text)]
    costs = [float(m) for m in COST_RE.findall(text)]
    return {
        "token_events": tokens,
        "tokens_sum": sum(tokens) if tokens else None,
        "tokens_last": tokens[-1] if tokens else None,
        "cost_usd_events": costs,
        "cost_usd_last": costs[-1] if costs else None,
        "limit_hit": "hit your usage limit" in text.lower() or "you've hit your usage limit" in text.lower(),
    }


def write_usage(run_dir: Path) -> dict[str, Any]:
    log = run_dir / "worker.log"
    payload: dict[str, Any] = {"ticket": run_dir.name, "log_present": log.exists()}
    if log.exists():
        # Large logs: read tail only for cost-state; full regex on last 5MB
        data = log.read_bytes()
        if len(data) > 5_000_000:
            data = data[-5_000_000:]
        text = data.decode("utf-8", errors="replace")
        payload.update(parse_worker_log(text))
    out = run_dir / "usage.json"
    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return payload


def main(argv: list[str] | None = None) -> int:
    argv = list(argv or sys.argv[1:])
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from autonomy_config import wave_dir

    runs = Path(argv[0]) if argv else wave_dir() / "runs"
    results = []
    for child in sorted(runs.glob("*")):
        if child.is_dir():
            results.append(write_usage(child))
    print(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())