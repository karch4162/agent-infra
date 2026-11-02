"""brain:save consumer for the required aggregate wave report (Mason t24u).

Usage:
  python brain_save_consume_report.py <wave-report.md> [--json SIDECAR] [--copy-to HOT_APPEND]

Exits 1 if the report is missing or empty, the sidecar JSON (--json, else the
sibling .json) is missing, unreadable or not `"ok": true`, or any worker summary
is missing or empty.
Never invents thin orchestrator-only bullets in place of the report.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("report_md", type=Path)
    ap.add_argument("--json", type=Path, default=None, help="sidecar JSON from aggregate_wave_report")
    ap.add_argument("--copy-to", type=Path, default=None, help="optional path to append/copy report body")
    args = ap.parse_args(argv)

    if not args.report_md.exists():
        print(f"FAIL: aggregate report missing: {args.report_md}", file=sys.stderr)
        print("Run aggregate_wave_report.py before brain:save.", file=sys.stderr)
        return 1

    body = args.report_md.read_text(encoding="utf-8")
    if not body.strip():
        print(f"FAIL: aggregate report is empty: {args.report_md}", file=sys.stderr)
        return 1

    sidecar = args.json or args.report_md.with_suffix(".json")
    if not sidecar.exists():
        print(f"FAIL: aggregate sidecar JSON missing: {sidecar}", file=sys.stderr)
        return 1
    try:
        data = json.loads(sidecar.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        print(f"FAIL: aggregate sidecar JSON unreadable: {sidecar}: {e}", file=sys.stderr)
        return 1
    if not isinstance(data, dict):
        print(f"FAIL: aggregate sidecar is not a JSON object: {sidecar}", file=sys.stderr)
        return 1

    missing = list(data.get("missing") or [])
    if not missing and ("**MISSING summary.md**" in body or "**EMPTY summary.md**" in body):
        missing = ["(see markdown)"]
    if data.get("ok") is not True or missing:
        print(json.dumps({"ok": False, "missing": missing, "path": str(args.report_md)}, indent=2))
        print("FAIL: aggregate report incomplete; refuse thin brain:save.", file=sys.stderr)
        return 1

    if args.copy_to:
        args.copy_to.parent.mkdir(parents=True, exist_ok=True)
        with args.copy_to.open("a", encoding="utf-8") as f:
            f.write("\n")
            f.write(body)
            if not body.endswith("\n"):
                f.write("\n")

    print(json.dumps({"ok": True, "path": str(args.report_md), "bytes": len(body.encode("utf-8"))}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())