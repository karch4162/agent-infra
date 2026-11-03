"""Flaky-test logging: record re-runs; post ClickUp comment/ticket; never silent retry (t24u)."""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class FlakyEvent:
    ts: str
    test_id: str
    attempt: int
    outcome: str  # pass|fail
    command: str
    log_excerpt: str = ""
    ticket_id: str | None = None


@dataclass
class FlakyLog:
    events: list[FlakyEvent] = field(default_factory=list)

    def add(self, ev: FlakyEvent) -> None:
        self.events.append(ev)

    def to_dict(self) -> dict[str, Any]:
        return {"events": [asdict(e) for e in self.events]}


def append_event(path: Path, ev: FlakyEvent) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(asdict(ev), ensure_ascii=False) + "\n")


def format_comment(events: list[FlakyEvent]) -> str:
    lines = ["WAVE-FLAKY-TEST-LOG", f"count={len(events)}", ""]
    for e in events:
        lines.append(f"- {e.ts} test=`{e.test_id}` attempt={e.attempt} outcome={e.outcome}")
        if e.log_excerpt:
            lines.append(f"  excerpt: {e.log_excerpt[:300]}")
    lines.append("")
    lines.append("Policy: re-runs are recorded; silent retries are forbidden.")
    return "\n".join(lines)


def _clickup_request(method: str, path: str, token: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        f"https://api.clickup.com/api/v2{path}",
        data=data,
        headers={"Authorization": token, "Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read().decode("utf-8")
        return json.loads(raw) if raw else {}


def post_to_clickup(
    *,
    token: str,
    task_id: str | None,
    list_id: str | None,
    events: list[FlakyEvent],
    dry_run: bool = False,
) -> dict[str, Any]:
    comment = format_comment(events)
    if dry_run:
        return {"dry_run": True, "would_comment_on": task_id, "would_create_in_list": list_id, "comment": comment}
    if task_id:
        _clickup_request("POST", f"/task/{task_id}/comment", token, {"comment_text": comment})
        return {"posted": "comment", "task_id": task_id}
    if list_id:
        created = _clickup_request(
            "POST",
            f"/list/{list_id}/task",
            token,
            {
                "name": f"[WAVE-FLAKY] {events[-1].test_id if events else 'unknown'}",
                "description": comment,
                "tags": ["wave-flaky", "wave-infra-test"],
            },
        )
        return {"posted": "task", "task_id": created.get("id"), "url": created.get("url")}
    raise RuntimeError("need task_id or list_id")


def main(argv: list[str] | None = None) -> int:
    argv = list(argv or sys.argv[1:])
    # flaky_test_log.py record <log.jsonl> --test id --attempt N --outcome pass|fail --cmd '...'
    if not argv or argv[0] not in {"record", "post"}:
        print("usage: flaky_test_log.py record|post ...", file=sys.stderr)
        return 2
    if argv[0] == "record":
        log_path = Path(argv[1])
        # naive argv parse
        kv = {}
        i = 2
        while i < len(argv):
            if argv[i].startswith("--") and i + 1 < len(argv):
                kv[argv[i][2:]] = argv[i + 1]
                i += 2
            else:
                i += 1
        ev = FlakyEvent(
            ts=_now(),
            test_id=kv.get("test", "unknown"),
            attempt=int(kv.get("attempt", "1")),
            outcome=kv.get("outcome", "fail"),
            command=kv.get("cmd", ""),
            log_excerpt=kv.get("excerpt", ""),
            ticket_id=kv.get("ticket"),
        )
        append_event(log_path, ev)
        print(json.dumps(asdict(ev), indent=2))
        return 0
    # post
    log_path = Path(argv[1])
    dry = "--dry-run" in argv
    token = os.environ.get("CLICKUP_API_TOKEN", "")
    task_id = None
    list_id = None
    i = 2
    while i < len(argv):
        if argv[i] == "--task" and i + 1 < len(argv):
            task_id = argv[i + 1]
            i += 2
        elif argv[i] == "--list" and i + 1 < len(argv):
            list_id = argv[i + 1]
            i += 2
        else:
            i += 1
    events = []
    if log_path.exists():
        for line in log_path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                events.append(FlakyEvent(**json.loads(line)))
    result = post_to_clickup(token=token, task_id=task_id, list_id=list_id, events=events, dry_run=dry or not token)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())