"""One view of every direct-runtime worker: state, liveness, step, PR, last activity, cost.

  python "$WAVE_HOME/autonomy/wave_status.py" [--runs DIR] [--json] [--sweep]

The data already exists under <repo>/.claude/wave/runs/<ticket>/ (status.json,
worker.log, usage.json); this joins it and corrects "running" against the real
PID, which is what an IDE pane would otherwise do for you. --sweep prints the
`git worktree remove` commands for merged tickets (read, then pipe to bash).
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from worker_runtime import pid_alive  # noqa: E402

TERMINAL = {"done_merged", "done_held", "done_held_review_no", "stopped", "removed"}


def _last_activity(log: Path) -> tuple[str, str]:
    """(age like '3m', one-line description of the newest event)."""
    if not log.exists():
        return "-", "no log"
    age_s = max(0, time.time() - log.stat().st_mtime)
    if age_s >= 3600:
        age = f"{age_s / 3600:.1f}h"
    elif age_s >= 60:
        age = f"{int(age_s // 60)}m"
    else:
        age = f"{int(age_s)}s"
    tail = log.read_bytes()[-200_000:].decode("utf-8", errors="replace").splitlines()
    for line in reversed(tail):
        line = line.strip()
        if not line:
            continue
        if line.startswith("{"):
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            t = ev.get("type")
            if t == "result":
                return age, f"result cost=${ev.get('total_cost_usd', ev.get('totalCostUSD', '?'))}"
            msg = ev.get("message") or {}
            for part in reversed(msg.get("content") or []):
                if part.get("type") == "tool_use":
                    inp = part.get("input") or {}
                    hint = inp.get("file_path") or inp.get("command") or inp.get("pattern") or ""
                    return age, f"{part.get('name')} {str(hint)[:60]}"
                if part.get("type") == "text" and part.get("text"):
                    return age, str(part["text"]).strip().splitlines()[0][:70]
            continue
        return age, line[:70]
    return age, "(empty)"


def collect(runs: Path) -> list[dict]:
    rows = []
    for st_path in sorted(runs.glob("*/status.json")):
        try:
            st = json.loads(st_path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        run_dir = st_path.parent
        pid = int(st.get("pid") or 0)
        alive = pid_alive(pid)
        state = st.get("state", "?")
        if state in {"running", "starting"} and not alive:
            state = "exited"
        usage = {}
        if (run_dir / "usage.json").exists():
            try:
                usage = json.loads((run_dir / "usage.json").read_text(encoding="utf-8"))
            except (OSError, ValueError):
                usage = {}
        age, last = _last_activity(run_dir / "worker.log")
        rows.append({
            "ticket": run_dir.name,
            "agent": st.get("agent"),
            "state": state,
            "alive": alive,
            "step": st.get("step"),
            "pr": st.get("pr") or "",
            "branch": st.get("branch"),
            "path": st.get("path"),
            "age": age,
            "last": last,
            "cost_usd": usage.get("cost_usd_last"),
            "note": st.get("note") or st.get("hold_reason") or "",
        })
    return rows


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--sweep", action="store_true")
    a = ap.parse_args(argv)
    if a.runs:
        runs = Path(a.runs)
    else:
        from autonomy_config import wave_dir

        runs = wave_dir() / "runs"
    rows = collect(runs)
    if a.sweep:
        for r in rows:
            if r["state"] == "done_merged" and r["path"]:
                print(f'git worktree remove --force "{r["path"]}"')
        return 0
    if a.json:
        print(json.dumps(rows, indent=2))
        return 0
    if not rows:
        print(f"no runs under {runs}")
        return 0
    hdr = f"{'ticket':<12} {'agent':<7} {'state':<16} {'step':<10} {'age':<5} {'pr':<6} last"
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        pr = str(r["pr"]).rsplit("/", 1)[-1] if r["pr"] else "-"
        print(f"{r['ticket']:<12} {str(r['agent'] or '-'):<7} {r['state']:<16} {str(r['step'] or '-'):<10} "
              f"{r['age']:<5} {pr:<6} {r['last']}")
        if r["note"] and r["state"] in TERMINAL:
            print(f"{'':<12} note: {r['note'][:90]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
