"""Jira tracker adapter for the tick and backlog-watch, through the Atlassian CLI (INNOV-440).

Same surface the tick uses on ClickUpTrackerAdapter: fetch_queue, get, set_status,
comment. The queue is the repo's WAVE_QUEUE JQL, verbatim. Labels come back as tags,
so rating:* and agent-ready work unchanged; assignees come back as display names
(never emails), so backlog_watch's assignee guard applies.

acli carries its own OAuth login (`acli jira auth status`); nothing here holds a token.
"""
from __future__ import annotations

import json
import shutil
import subprocess
from typing import Any, Callable, Iterable

from clickup_tracker import Ticket

FIELDS = "key,summary,status,labels,assignee,description"
RunFn = Callable[[list[str]], subprocess.CompletedProcess]


class JiraError(RuntimeError):
    pass


def _run(args: list[str]) -> subprocess.CompletedProcess:
    exe = shutil.which("acli") or "acli"
    return subprocess.run([exe, *args], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)


def adf_text(node: Any) -> str:
    """Plain text of an Atlassian Document Format body (descriptions arrive as ADF)."""
    if isinstance(node, str):
        return node
    if not isinstance(node, dict):
        return ""
    if node.get("type") == "text":
        return node.get("text") or ""
    text = "".join(adf_text(c) for c in node.get("content") or [])
    # Block nodes end their own line; containers (doc, lists, quotes) just concatenate.
    return text + ("\n" if node.get("type") in {"paragraph", "heading", "codeBlock"} else "")


class JiraTrackerAdapter:
    def __init__(self, *, queue: str, site: str = "", run: RunFn | None = None):
        if not queue:
            raise JiraError("WAVE_QUEUE (the JQL) is not set")
        self.queue, self.site, self._run = queue, site, run or _run

    def _json(self, *args: str) -> Any:
        p = self._run([*args, "--json"])
        if p.returncode != 0:
            raise JiraError(f"acli {' '.join(args[:3])} failed ({p.returncode}): {(p.stderr or p.stdout)[-300:]}")
        try:
            return json.loads(p.stdout)
        except ValueError as e:
            raise JiraError(f"acli {' '.join(args[:3])}: unreadable output ({e})") from e

    def _to_ticket(self, item: dict[str, Any]) -> Ticket:
        f = item.get("fields") or {}
        key = item.get("key") or ""
        who = f.get("assignee") or {}
        return Ticket(
            id=key,
            name=f.get("summary") or "",
            status=(f.get("status") or {}).get("name") or "",
            tags=list(f.get("labels") or []),
            url=f"https://{self.site}/browse/{key}" if self.site else key,
            text=adf_text(f.get("description")).strip(),
            assignees=[who.get("displayName") or who.get("accountId")] if who else [],
            raw=item,
        )

    def fetch_queue(self, *, require_tags: Iterable[str] | None = None, **_ignored: Any) -> list[Ticket]:
        """Every ticket the repo's WAVE_QUEUE JQL returns. Status and assignee filtering
        belong in the JQL; require_tags is applied on top (agent-ready)."""
        need = set(require_tags or [])
        items = self._json("jira", "workitem", "search", "--jql", self.queue, "--fields", FIELDS, "--paginate")
        out = [self._to_ticket(i) for i in items or []]
        return [t for t in out if need.issubset(t.tags)]

    def get(self, key: str) -> Ticket:
        return self._to_ticket(self._json("jira", "workitem", "view", key, "--fields", FIELDS))

    def set_status(self, key: str, state: str) -> None:
        self._json("jira", "workitem", "transition", "--key", key, "--status", state, "--yes")

    def comment(self, key: str, body: str) -> None:
        p = self._run(["jira", "workitem", "comment", "create", "--key", key, "--body", body])
        if p.returncode != 0:
            raise JiraError(f"acli comment on {key} failed ({p.returncode}): {(p.stderr or p.stdout)[-300:]}")


def tracker_for(cfg) -> Any:
    """The tracker adapter for this repo's config, or None when picking isn't wired for it."""
    if cfg.tracker == "clickup":
        from clickup_tracker import ClickUpTrackerAdapter
        return ClickUpTrackerAdapter(list_id=cfg.clickup_list, space_id=cfg.clickup_space or None,
                                     team_id=cfg.clickup_team or None)
    if cfg.tracker == "jira":
        return JiraTrackerAdapter(queue=cfg.queue, site=cfg.jira_site)
    return None  # ponytail: linear picking not wired; add an adapter with this surface when a Linear repo needs it
