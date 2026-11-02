#!/usr/bin/env python3
"""Orchestrated spawn entrypoint — DirectWorkerRuntime only (no Orca, no Unstoppable)."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from worker_runtime import DirectWorkerRuntime, WorkerError


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ticket", required=True)
    ap.add_argument("--agent", required=True, choices=["claude", "codex"])
    ap.add_argument("--prompt-file", required=True)
    ap.add_argument("--repo", default=None, help="main checkout (default: this repo)")
    ap.add_argument("--base", default=None, help="base ref (default: WAVE_BASE or origin/HEAD)")
    ap.add_argument("--model", default=None)
    args = ap.parse_args()
    prompt = Path(args.prompt_file).read_text(encoding="utf-8")
    from autonomy_config import repo_root

    repo = args.repo or str(repo_root())
    base = args.base or os.environ.get("WAVE_BASE") or "origin/HEAD"
    rt = DirectWorkerRuntime(repo_path=repo, base_branch=base)
    try:
        rec = rt.spawn(ticket_id=args.ticket, prompt=prompt, agent=args.agent, model=args.model)
    except WorkerError as e:
        print(json.dumps({"ok": False, "error": str(e)}), file=sys.stderr)
        return 1
    print(json.dumps({
        "ok": True,
        "ticket_id": rec.ticket_id,
        "agent": rec.agent,
        "branch": rec.branch,
        "path": rec.path,
        "pid": rec.pid,
        "status_path": rec.status_path,
        "runtime": "direct",
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
