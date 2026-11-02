"""Resumable CI waits: checkpoint and return; short polls (Mason t24u).

Never blocks for long wall-clock waits. Call poll_once / poll_until_budget,
persist checkpoint JSON, exit so the orchestrator can resume later.
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


# Every reported check counts (same rule as merge_policy). An allowlist of required
# names missed RLS Regression Tests, and adding it would park every PR that the
# path filter skips it on. Empty is pending: green nothing is not green.
FAIL_STATES = ("FAILURE", "FAILED", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class CiCheckpoint:
    pr: int
    repo: str
    state: str  # pending|green|failed|unknown
    checks: dict[str, str] = field(default_factory=dict)
    updated_at: str = ""
    polls: int = 0
    last_error: str | None = None

    def path_for(self, runs_dir: Path) -> Path:
        return runs_dir / f"ci-pr-{self.pr}.json"


def load_checkpoint(path: Path) -> CiCheckpoint | None:
    if not path.exists():
        return None
    d = json.loads(path.read_text(encoding="utf-8"))
    return CiCheckpoint(**{k: d[k] for k in ("pr", "repo", "state", "checks", "updated_at", "polls", "last_error") if k in d})


def save_checkpoint(cp: CiCheckpoint, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    cp.updated_at = _now()
    path.write_text(json.dumps(asdict(cp), indent=2) + "\n", encoding="utf-8")


def fetch_checks(repo: str, pr: int) -> dict[str, str]:
    proc = subprocess.run(
        ["gh", "pr", "view", str(pr), "--repo", repo, "--json", "statusCheckRollup"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=60,
    )
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or "gh failed")[-500:])
    data = json.loads(proc.stdout or "{}")
    out: dict[str, str] = {}
    for c in data.get("statusCheckRollup") or []:
        name = c.get("name") or c.get("context") or ""
        state = (c.get("conclusion") or c.get("state") or c.get("status") or "").upper()
        if name:
            out[name] = state
    return out


def classify(checks: dict[str, str]) -> str:
    if not checks:
        return "pending"
    vals = list(checks.values())
    if any(v in FAIL_STATES for v in vals):
        return "failed"
    if all(v in ("SUCCESS", "NEUTRAL", "SKIPPED") for v in vals):
        return "green"
    return "pending"


def poll_once(repo: str, pr: int, checkpoint_path: Path) -> CiCheckpoint:
    cp = load_checkpoint(checkpoint_path) or CiCheckpoint(pr=pr, repo=repo, state="unknown")
    cp.pr = pr
    cp.repo = repo
    try:
        cp.checks = fetch_checks(repo, pr)
        cp.state = classify(cp.checks)
        cp.last_error = None
    except Exception as e:  # noqa: BLE001
        cp.last_error = str(e)[:500]
        cp.state = "unknown"
    cp.polls += 1
    save_checkpoint(cp, checkpoint_path)
    return cp


def poll_until_budget(
    repo: str,
    pr: int,
    checkpoint_path: Path,
    *,
    max_polls: int = 3,
    interval_sec: float = 20.0,
) -> CiCheckpoint:
    """Short budget only — then return with checkpoint for later resume."""
    cp = None
    for i in range(max_polls):
        cp = poll_once(repo, pr, checkpoint_path)
        if cp.state in ("green", "failed"):
            return cp
        if i + 1 < max_polls:
            time.sleep(interval_sec)
    assert cp is not None
    return cp


def main(argv: list[str] | None = None) -> int:
    argv = list(argv or sys.argv[1:])
    if len(argv) < 2:
        print("usage: ci_wait.py <repo> <pr> [checkpoint_path] [--budget N]", file=sys.stderr)
        return 2
    repo, pr_s = argv[0], argv[1]
    pr = int(pr_s)
    budget = 3
    path = Path(f"ci-pr-{pr}.json")
    args = argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--budget" and i + 1 < len(args):
            budget = int(args[i + 1])
            i += 2
        else:
            path = Path(args[i])
            i += 1
    cp = poll_until_budget(repo, pr, path, max_polls=budget)
    print(json.dumps(asdict(cp), indent=2))
    # Non-zero only on definitive failure — pending returns 0 with state pending (resumable).
    if cp.state == "failed":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())