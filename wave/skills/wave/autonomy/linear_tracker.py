"""Linear write adapter for coordinator.sh, through `orca linear` (INNOV-463).

Only the two writes the coordinator makes: set_status and comment, the same surface as
JiraTrackerAdapter and ClickUpTrackerAdapter. It has no fetch_queue or get, so it is not
in jira_tracker.tracker_for: the tick and backlog-watch still do no Linear picking.
"""
from __future__ import annotations

import shutil
import subprocess
from typing import Callable

RunFn = Callable[[list[str]], subprocess.CompletedProcess]


class LinearError(RuntimeError):
    pass


def _run(args: list[str]) -> subprocess.CompletedProcess:
    exe = shutil.which("orca") or "orca"
    return subprocess.run([exe, *args], capture_output=True, text=True, encoding="utf-8", errors="replace")


class LinearTrackerAdapter:
    def __init__(self, *, run: RunFn | None = None):
        self._run = run or _run

    def _ok(self, args: list[str]) -> None:
        p = self._run(args)
        if p.returncode != 0:
            raise LinearError(f"orca {' '.join(args[:3])} failed ({p.returncode}): {(p.stderr or p.stdout)[-300:]}")

    def set_status(self, key: str, state: str) -> None:
        self._ok(["linear", "status", "set", key, "--to", state, "--json"])

    def comment(self, key: str, body: str) -> None:
        self._ok(["linear", "comment", "add", key, "--body", body, "--json"])
