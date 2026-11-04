"""ClickUp TrackerAdapter — all tracker calls go through this module.

Token from process.env.CLICKUP_API_TOKEN only. Never print the token.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Iterable

API = "https://api.clickup.com/api/v2"


class ClickUpError(RuntimeError):
    pass


@dataclass
class Ticket:
    id: str
    name: str
    status: str
    tags: list[str]
    url: str
    text: str
    assignees: list[str] = field(default_factory=list)
    raw: dict[str, Any] = field(default_factory=dict)


class ClickUpTrackerAdapter:
    def __init__(
        self,
        *,
        list_id: str,
        token: str | None = None,
        space_id: str | None = None,
        team_id: str | None = None,
    ):
        self.list_id = list_id
        self.space_id = space_id
        self.team_id = team_id
        self._token = token if token is not None else os.environ.get("CLICKUP_API_TOKEN", "")
        if not self._token:
            raise ClickUpError("CLICKUP_API_TOKEN is not set")
        # Free plan: 100 requests/minute. Sliding window + 429 backoff.
        self._rpm_limit = int(os.environ.get("CLICKUP_RPM_LIMIT", "100"))
        self._req_times: list[float] = []

    def _throttle(self) -> None:
        """Block until this process is under CLICKUP_RPM_LIMIT requests/minute."""
        now = time.monotonic()
        window = 60.0
        self._req_times = [t for t in self._req_times if now - t < window]
        if len(self._req_times) >= self._rpm_limit:
            sleep_for = window - (now - self._req_times[0]) + 0.05
            if sleep_for > 0:
                time.sleep(sleep_for)
            now = time.monotonic()
            self._req_times = [t for t in self._req_times if now - t < window]
        self._req_times.append(time.monotonic())

    def _request(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
        retries: int = 5,
    ) -> dict[str, Any]:
        q = f"?{urllib.parse.urlencode(query)}" if query else ""
        url = f"{API}{path}{q}"
        data = None if body is None else json.dumps(body).encode("utf-8")
        headers = {
            "Authorization": self._token,
            "Content-Type": "application/json",
        }
        last_err: Exception | None = None
        for attempt in range(retries):
            self._throttle()
            req = urllib.request.Request(url, data=data, headers=headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    raw = resp.read().decode("utf-8")
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as e:
                last_err = e
                if e.code == 429 and attempt < retries - 1:
                    # Honor Retry-After when present; else exponential backoff.
                    retry_after = e.headers.get("Retry-After") if e.headers else None
                    try:
                        wait = float(retry_after) if retry_after else (2.0 ** attempt)
                    except ValueError:
                        wait = 2.0 ** attempt
                    wait = min(max(wait, 1.0), 60.0)
                    time.sleep(wait)
                    continue
                detail = e.read().decode("utf-8", errors="replace")[:500]
                raise ClickUpError(f"{method} {path} -> HTTP {e.code}: {detail}") from e
            except Exception as e:  # noqa: BLE001
                last_err = e
                if attempt < retries - 1:
                    time.sleep(0.5 * (attempt + 1))
                    continue
                raise
        raise ClickUpError(str(last_err))

    @staticmethod
    def _to_ticket(t: dict[str, Any]) -> Ticket:
        return Ticket(
            id=t["id"],
            name=t.get("name") or "",
            status=((t.get("status") or {}).get("status") or ""),
            tags=[tg.get("name") for tg in (t.get("tags") or []) if tg.get("name")],
            url=t.get("url") or f"https://app.clickup.com/t/{t['id']}",
            text=t.get("text_content") or t.get("description") or "",
            assignees=[a.get("username") for a in (t.get("assignees") or []) if a.get("username")],
            raw=t,
        )

    def fetch_queue(
        self,
        *,
        statuses: Iterable[str] | None = None,
        exclude_tags: Iterable[str] | None = None,
        require_tags: Iterable[str] | None = None,
        include_closed: bool = False,
    ) -> list[Ticket]:
        """List open tasks on the configured list (paginated)."""
        exclude = set(exclude_tags or [])
        require = set(require_tags or [])
        want_status = {s.lower() for s in statuses} if statuses else None
        out: list[Ticket] = []
        page = 0
        while True:
            data = self._request(
                "GET",
                f"/list/{self.list_id}/task",
                query={
                    "archived": "false",
                    "include_closed": "true" if include_closed else "false",
                    "subtasks": "true",
                    "page": page,
                },
            )
            tasks = data.get("tasks") or []
            for t in tasks:
                ticket = self._to_ticket(t)
                st = ticket.status.lower()
                if want_status is not None and st not in want_status:
                    continue
                tagset = set(ticket.tags)
                if exclude and tagset & exclude:
                    continue
                if require and not require.issubset(tagset):
                    continue
                out.append(ticket)
            if data.get("last_page") is True or not tasks:
                break
            page += 1
            if page > 50:
                break
            time.sleep(0.15)
        return out

    def get(self, task_id: str) -> Ticket:
        data = self._request("GET", f"/task/{task_id}")
        return self._to_ticket(data)

    def set_labels(self, task_id: str, add: Iterable[str], remove: Iterable[str] = ()) -> None:
        """Add/remove tags. ClickUp replaces the full tag list on PUT /task/{id}."""
        ticket = self.get(task_id)
        tags = set(ticket.tags)
        for r in remove:
            tags.discard(r)
        for a in add:
            tags.add(a)
        # ClickUp expects tags as objects with name
        body = {"tags": [{"name": n} for n in sorted(tags)]}
        # Actually ClickUp task update uses "tags" as array of tag names in some versions;
        # the documented field is tags: [{name}]. Prefer dedicated tag endpoints when available.
        # Public API: POST /task/{id}/tag/{tag_name} and DELETE /task/{id}/tag/{tag_name}
        current = set(ticket.tags)
        for name in add:
            if name not in current:
                self._ensure_tag(name)
                self._request("POST", f"/task/{task_id}/tag/{urllib.parse.quote(name, safe='')}")
                time.sleep(0.1)
        for name in remove:
            if name in current:
                try:
                    self._request(
                        "DELETE",
                        f"/task/{task_id}/tag/{urllib.parse.quote(name, safe='')}",
                    )
                except ClickUpError:
                    # tag may already be gone
                    pass
                time.sleep(0.1)

    def _ensure_tag(self, name: str) -> None:
        """Create space tag if missing (best-effort)."""
        if not self.space_id:
            return
        try:
            self._request(
                "POST",
                f"/space/{self.space_id}/tag",
                body={"tag": {"name": name, "tag_fg": "#FFFFFF", "tag_bg": "#667085"}},
            )
        except ClickUpError as e:
            # already exists is fine
            if "already" in str(e).lower() or "TAG_EXISTS" in str(e) or "409" in str(e):
                return
            # ClickUp often returns 400 if exists — ignore soft failures
            return

    def set_status(self, task_id: str, state: str) -> None:
        self._request("PUT", f"/task/{task_id}", body={"status": state})

    def comment(self, task_id: str, body: str) -> None:
        self._request("POST", f"/task/{task_id}/comment", body={"comment_text": body})

    def file_followup(self, fields: dict[str, Any]) -> Ticket:
        """Create a backlog task; never auto-add agent-ready unless caller re-triages."""
        name = fields["name"]
        description = fields.get("description") or fields.get("body") or ""
        tags = [{"name": n} for n in fields.get("tags", []) if n != "agent-ready"]
        data = self._request(
            "POST",
            f"/list/{self.list_id}/task",
            body={
                "name": name,
                "description": description,
                "tags": [t["name"] for t in tags],
                "status": fields.get("status") or "backlog",
            },
        )
        return self._to_ticket(data)


def _adapter_from_env() -> "ClickUpTrackerAdapter":
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from autonomy_config import load_autonomy_config

    cfg = load_autonomy_config()
    if not cfg.clickup_list:
        raise ClickUpError("WAVE_CLICKUP_LIST is not set (config.env or env)")
    return ClickUpTrackerAdapter(
        list_id=cfg.clickup_list, space_id=cfg.clickup_space or None, team_id=cfg.clickup_team or None
    )


def main(argv: list[str] | None = None) -> int:
    """CLI so a worker prompt and lib.sh have a shell verb per tracker op.

      clickup_tracker.py get <id>                  -> {identifier,title,description,tags,status,url}
      clickup_tracker.py status <id> <state>
      clickup_tracker.py comment <id> <text|->      (- reads stdin)
      clickup_tracker.py queue [--status S] [--tag T ...]
      clickup_tracker.py followup <name> [--description D|-] [--tag T ...]
    The token is CLICKUP_API_TOKEN in the environment; it is never printed.
    """
    sys.stdout.reconfigure(encoding="utf-8")  # task text is not cp1252-safe on a Windows console
    import argparse

    ap = argparse.ArgumentParser(prog="clickup_tracker.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("get")
    g.add_argument("id")
    s = sub.add_parser("status")
    s.add_argument("id")
    s.add_argument("state")
    c = sub.add_parser("comment")
    c.add_argument("id")
    c.add_argument("text")
    q = sub.add_parser("queue")
    q.add_argument("--status", default="backlog")
    q.add_argument("--tag", action="append", default=[])
    f = sub.add_parser("followup")
    f.add_argument("name")
    f.add_argument("--description", default="")
    f.add_argument("--tag", action="append", default=[])
    a = ap.parse_args(argv)
    ad = _adapter_from_env()

    def dump(t: Ticket) -> dict[str, Any]:
        return {"identifier": t.id, "title": t.name, "description": t.text,
                "tags": t.tags, "status": t.status, "url": t.url}

    if a.cmd == "get":
        print(json.dumps(dump(ad.get(a.id)), ensure_ascii=False, indent=2))
    elif a.cmd == "status":
        ad.set_status(a.id, a.state)
        print(json.dumps({"ok": True, "id": a.id, "status": a.state}))
    elif a.cmd == "comment":
        text = sys.stdin.read() if a.text == "-" else a.text
        ad.comment(a.id, text)
        print(json.dumps({"ok": True, "id": a.id}))
    elif a.cmd == "queue":
        tix = ad.fetch_queue(statuses=[a.status], require_tags=a.tag or None)
        print(json.dumps([dump(t) for t in tix], ensure_ascii=False, indent=2))
    elif a.cmd == "followup":
        desc = sys.stdin.read() if a.description == "-" else a.description
        t = ad.file_followup({"name": a.name, "description": desc, "tags": a.tag})
        print(json.dumps(dump(t), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
