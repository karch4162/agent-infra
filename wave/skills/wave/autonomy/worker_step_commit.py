"""Workers commit after each completed step (Mason t24u).

Helper invoked from worker prompts / orchestrator after a discrete step
(plan|implement|test|review-fix). Creates an atomic commit in the worktree.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def commit_step(worktree: str, step: str, ticket_id: str, message: str | None = None) -> dict:
    cwd = str(Path(worktree).resolve())
    msg = message or f"wave({ticket_id}): complete step {step}"
    subprocess.run(["git", "add", "-A"], cwd=cwd, check=True, capture_output=True)
    # Allow empty? No — if nothing to commit, report cleanly.
    st = subprocess.run(["git", "status", "--porcelain"], cwd=cwd, capture_output=True, text=True, check=True)
    if not (st.stdout or "").strip():
        return {"committed": False, "reason": "clean", "step": step}
    subprocess.run(["git", "commit", "-m", msg], cwd=cwd, check=True, capture_output=True, text=True)
    sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()
    heartbeat(step, sha)
    return {"committed": True, "sha": sha, "step": step, "message": msg}


def heartbeat(step: str, sha: str | None = None) -> None:
    """Record the step in the run's status.json (WAVE_RUN_DIR is set by the
    runtime at spawn). Workers already call this per step, so it is the liveness
    signal a status view reads: no new step and no log growth for N minutes = stuck."""
    import json
    import os
    from datetime import datetime, timezone

    run_dir = os.environ.get("WAVE_RUN_DIR", "").strip()
    if not run_dir:
        return
    path = Path(run_dir) / "status.json"
    try:
        st = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    except (OSError, ValueError):
        st = {}
    st["step"] = step
    if sha:
        st["step_sha"] = sha
    st["step_at"] = datetime.now(timezone.utc).isoformat()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(st, indent=2) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    argv = list(argv or sys.argv[1:])
    if len(argv) < 3:
        print("usage: worker_step_commit.py <worktree> <ticket> <step> [message]", file=sys.stderr)
        return 2
    wt, ticket, step = argv[0], argv[1], argv[2]
    message = argv[3] if len(argv) > 3 else None
    import json

    print(json.dumps(commit_step(wt, step, ticket, message), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())