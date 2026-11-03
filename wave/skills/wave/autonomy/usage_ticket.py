"""Per-ticket usage rollup: Claude tokens, Codex tokens, Grok call counts.

Wraps usage_log.parse_worker_log and grok_calls.jsonl.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import usage_log


def ticket_usage(wave_dir: Path, ticket_id: str) -> dict[str, Any]:
    run_dir = wave_dir / "runs" / ticket_id.lower()
    base = usage_log.write_usage(run_dir) if run_dir.exists() else {
        "ticket": ticket_id,
        "log_present": False,
    }
    # Prefer agent hint from status.json
    agent = None
    st = run_dir / "status.json"
    if st.exists():
        try:
            agent = json.loads(st.read_text(encoding="utf-8")).get("agent")
        except (OSError, json.JSONDecodeError):
            agent = None

    claude_tokens = None
    codex_tokens = None
    tokens = base.get("tokens_sum") or base.get("tokens_last")
    if agent == "claude":
        claude_tokens = tokens
    elif agent == "codex":
        codex_tokens = tokens

    grok_n = 0
    grok_path = wave_dir / "autonomy" / "grok_calls.jsonl"
    if grok_path.exists():
        for line in grok_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if str(row.get("ticket", "")).lower() == ticket_id.lower():
                grok_n += 1

    out = {
        **base,
        "agent": agent,
        "claude_tokens": claude_tokens,
        "codex_tokens": codex_tokens,
        "grok_calls": grok_n,
    }
    dest = run_dir / "usage_ticket.json"
    if run_dir.exists():
        dest.write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    return out
