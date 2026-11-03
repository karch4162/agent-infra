"""Required aggregate wave report from each worker summary file (Mason t24u).

brain:save MUST consume the report (hot.md + log.md sections), not invent
thin orchestrator-only bullets.
"""
from __future__ import annotations

import json
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class WorkerSummary:
    ticket: str
    path: str
    present: bool
    body: str = ""
    usage: dict[str, Any] = field(default_factory=dict)


@dataclass
class WaveReport:
    wave_id: str
    ts: str
    workers: list[WorkerSummary]
    missing: list[str]
    markdown: str
    ok: bool


def load_worker_summary(run_dir: Path) -> WorkerSummary:
    ticket = run_dir.name
    summary = run_dir / "summary.md"
    usage_path = run_dir / "usage.json"
    usage = {}
    if usage_path.exists():
        try:
            usage = json.loads(usage_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            usage = {"error": "invalid usage.json"}
    body = summary.read_text(encoding="utf-8", errors="replace") if summary.exists() else ""
    return WorkerSummary(ticket=ticket, path=str(summary), present=bool(body.strip()), body=body, usage=usage)


def build_report(runs_dir: Path, wave_id: str) -> WaveReport:
    workers: list[WorkerSummary] = []
    for child in sorted(runs_dir.glob("*")):
        if not child.is_dir():
            continue
        # skip empty
        if not any(child.iterdir()):
            continue
        workers.append(load_worker_summary(child))
    missing = [w.ticket for w in workers if not w.present]
    lines = [
        f"# Wave report — {wave_id}",
        f"_Generated: {_now()}_",
        "",
        "## Per-worker summaries",
    ]
    for w in workers:
        lines.append(f"### {w.ticket}")
        if w.usage:
            lines.append(f"- usage: `{json.dumps(w.usage, sort_keys=True)}`")
        if w.present:
            lines.append("")
            lines.append(w.body.rstrip())
        elif Path(w.path).exists():
            lines.append("- **EMPTY summary.md** — worker wrote a blank summary file.")
        else:
            lines.append("- **MISSING summary.md** — worker did not write a summary file.")
        lines.append("")
    if missing:
        lines.append("## Missing summaries")
        for m in missing:
            lines.append(f"- {m}")
        lines.append("")
    lines.append("## brain:save contract")
    lines.append("Paste this report into wiki/hot.md (or attach path) during `/brain:save`. Do not replace it with orchestrator-only bullets.")
    md = "\n".join(lines) + "\n"
    return WaveReport(wave_id=wave_id, ts=_now(), workers=workers, missing=missing, markdown=md, ok=len(missing) == 0 and len(workers) > 0)


def write_report(report: WaveReport, out_md: Path, out_json: Path) -> None:
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(report.markdown, encoding="utf-8")
    payload = {
        "wave_id": report.wave_id,
        "ts": report.ts,
        "ok": report.ok,
        "missing": report.missing,
        "workers": [asdict(w) for w in report.workers],
        "markdown_path": str(out_md),
    }
    out_json.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    argv = list(argv or sys.argv[1:])
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from autonomy_config import wave_dir

    runs = Path(argv[0]) if argv else wave_dir() / "runs"
    wave_id = argv[1] if len(argv) > 1 else "wave"
    out_dir = Path(argv[2]) if len(argv) > 2 else wave_dir() / "reports"
    report = build_report(runs, wave_id)
    write_report(report, out_dir / f"{wave_id}-report.md", out_dir / f"{wave_id}-report.json")
    print(json.dumps({"ok": report.ok, "missing": report.missing, "workers": len(report.workers)}, indent=2))
    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())