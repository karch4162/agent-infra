"""Grok challenge reviewer + call logging.

Reuses the agent-infra run_grok / guard_readonly idea behind WorkerRuntime:
  - invoke `grok --permission-mode bypassPermissions -p <prompt>`
  - fail if the worktree fingerprint changes (rc=3)
  - log every call to autonomy/grok_calls.jsonl (count only; no tokens)

Challenge is non-voting on the review-round cap. Unresolved blockers hold auto-merge.
Also used as Codex-quota fallback for primary correctness when configured.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from daily_cap import ET



CHALLENGE_PROMPT = """Act as an adversarial challenge reviewer. A primary reviewer already approved this change.
Read the unified diff in .wave-review.diff at the repo root first; it is already written for you.
You are read-only: do not edit, create, or delete any file.
Look only for high-confidence blockers the primary may have missed: trust boundaries, tenant isolation,
API contracts, concurrency, recovery, payments/refunds, RLS, or tests that assert execution not behavior.
Cite file:line. Do not repeat ordinary style nits.
End with CHALLENGE VERDICT: PASS, FINDINGS, or NEEDS HUMAN.
If FINDINGS, mark each as BLOCKER or NOTE.
"""


@dataclass
class GrokResult:
    ok: bool
    rc: int
    out: str
    why: str
    worktree_modified: bool
    verdict: str | None
    unresolved_blocker: bool
    timed_out: bool

    def to_challenge_dict(self) -> dict[str, Any]:
        return {
            "ran": True,
            "ok": self.ok,
            "verdict": self.verdict,
            "unresolved_blocker": self.unresolved_blocker,
            "worktree_modified": self.worktree_modified,
            "timed_out": self.timed_out,
            "summary": self.why if not self.ok else (self.verdict or "PASS"),
            "rc": self.rc,
        }


def worktree_fingerprint(root: Path) -> str:
    proc = subprocess.run(
        ["git", "status", "--porcelain", "-uall"],
        cwd=str(root),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=60,
    )
    blob = (proc.stdout or "") + "\n" + (proc.stderr or "")
    return hashlib.sha256(blob.encode("utf-8", errors="replace")).hexdigest()


def append_grok_call(
    *,
    wave_dir: Path,
    ticket_id: str,
    role: str,
    rc: int,
    verdict: str | None,
) -> None:
    path = wave_dir / "autonomy" / "grok_calls.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    day = datetime.now(ET).date().isoformat()
    row = {
        "ts": datetime.now(ET).isoformat(),
        "day": day,
        "ticket": ticket_id,
        "role": role,
        "rc": rc,
        "verdict": verdict,
    }
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def parse_challenge_verdict(text: str) -> tuple[str | None, bool]:
    """Return (verdict, unresolved_blocker)."""
    import re

    m = re.search(r"CHALLENGE VERDICT:\s*(PASS|FINDINGS|NEEDS HUMAN)", text or "", re.I)
    if not m:
        # Architecture-style fallback
        m = re.search(r"ARCHITECTURE VERDICT:\s*(PASS|FINDINGS|NEEDS HUMAN)", text or "", re.I)
    if not m:
        return None, True
    verdict = m.group(1).upper()
    if verdict == "PASS":
        return "PASS", False
    if verdict == "NEEDS HUMAN":
        return "NEEDS_HUMAN", True
    # FINDINGS: blocker if any BLOCKER line present; else notes-only (no hold)
    has_blocker = bool(re.search(r"(?i)\bBLOCKER\b", text or ""))
    return "FINDINGS", has_blocker


def write_review_diff(worktree: Path, base: str = "origin/HEAD") -> Path:
    """Write .wave-review.diff (tracked + untracked) the way review.sh does, and keep
    it out of the fingerprint via the common-dir exclude. Grok must not create it:
    an untracked file it writes changes the fingerprint and fails the review."""

    def git(*args: str) -> str:
        return subprocess.run(
            ["git", *args], cwd=str(worktree), capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=120,
        ).stdout or ""

    common = Path(git("rev-parse", "--git-common-dir").strip())
    if not common.is_absolute():
        common = worktree / common
    exclude = common / "info" / "exclude"
    exclude.parent.mkdir(parents=True, exist_ok=True)
    existing = exclude.read_text(encoding="utf-8", errors="replace") if exclude.exists() else ""
    if ".wave-review.*" not in existing.splitlines():
        with exclude.open("a", encoding="utf-8") as f:
            f.write(".wave-review.*\n")
    parts = [git("diff", "--merge-base", base)]
    devnull = "NUL" if os.name == "nt" else "/dev/null"
    for rel in git("ls-files", "--others", "--exclude-standard").splitlines():
        if rel.strip():
            parts.append(git("diff", "--no-index", "--", devnull, rel))
    out = worktree / ".wave-review.diff"
    out.write_text("".join(parts), encoding="utf-8")
    return out


def _resolve_grok_bin() -> str | None:
    for name in ("grok.exe", "grok.cmd", "grok"):
        found = shutil.which(name)
        if found:
            return found
    return None


def run_grok_challenge(
    *,
    worktree: Path,
    wave_dir: Path,
    ticket_id: str,
    prompt: str | None = None,
    timeout_s: int = 900,
    dry_run_result: GrokResult | None = None,
    base: str = "origin/HEAD",
) -> GrokResult:
    """Run Grok challenge in worktree. dry_run_result short-circuits the CLI."""
    if dry_run_result is not None:
        append_grok_call(
            wave_dir=wave_dir,
            ticket_id=ticket_id,
            role="challenge",
            rc=dry_run_result.rc,
            verdict=dry_run_result.verdict,
        )
        return dry_run_result

    bin_path = _resolve_grok_bin()
    if not bin_path:
        return GrokResult(
            ok=False,
            rc=127,
            out="",
            why="grok binary not found on PATH",
            worktree_modified=False,
            verdict=None,
            unresolved_blocker=True,
            timed_out=False,
        )

    write_review_diff(worktree, base)
    before = worktree_fingerprint(worktree)
    err_path = wave_dir / "runs" / ticket_id.lower() / "challenge-grok.err"
    err_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [bin_path, "--permission-mode", "bypassPermissions", "-p", prompt or CHALLENGE_PROMPT]
    # Windows SystemRoot fix (agent-infra grok_env)
    env = os.environ.copy()
    if os.name == "nt":
        root = env.get("SystemRoot") or env.get("SYSTEMROOT") or r"C:\Windows"
        env["SystemRoot"] = root
        env["SystemDrive"] = env.get("SystemDrive") or env.get("SYSTEMDRIVE") or (root.split(":")[0] + ":")

    limit = timeout_s
    out = ""
    rc = 1
    timed_out = False
    for attempt in (1, 2):
        try:
            proc = subprocess.run(
                cmd,
                cwd=str(worktree),
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=limit,
                env=env,
            )
            out = proc.stdout or ""
            rc = proc.returncode
            err_path.write_text(proc.stderr or "", encoding="utf-8")
            timed_out = False
            break
        except subprocess.TimeoutExpired as e:
            timed_out = True
            out = (e.stdout or "") if isinstance(e.stdout, str) else ""
            err_path.write_text(f"timeout after {limit}s\n", encoding="utf-8")
            rc = 124
            if attempt == 1:
                limit = int(limit * 1.5)
                continue
            break

    modified = worktree_fingerprint(worktree) != before
    if modified:
        append_grok_call(wave_dir=wave_dir, ticket_id=ticket_id, role="challenge", rc=3, verdict=None)
        return GrokResult(
            ok=False,
            rc=3,
            out=out,
            why="grok modified the worktree",
            worktree_modified=True,
            verdict=None,
            unresolved_blocker=True,
            timed_out=timed_out,
        )

    if timed_out:
        # merge_policy holds on timed_out, so say so here too: a challenge that never
        # finished is an incomplete gate, not a pass. INNOV-391's soft timeout applies
        # to review.sh, where a human merges and the REVIEWER line names the gap.
        append_grok_call(wave_dir=wave_dir, ticket_id=ticket_id, role="challenge", rc=124, verdict="TIMEOUT")
        return GrokResult(
            ok=False,
            rc=124,
            out=out,
            why="grok timeout twice (incomplete; auto-merge holds)",
            worktree_modified=False,
            verdict="TIMEOUT",
            unresolved_blocker=True,
            timed_out=True,
        )

    verdict, blocker = parse_challenge_verdict(out)
    if verdict is None:
        append_grok_call(wave_dir=wave_dir, ticket_id=ticket_id, role="challenge", rc=rc, verdict=None)
        return GrokResult(
            ok=False,
            rc=rc,
            out=out,
            why="incomplete CHALLENGE VERDICT",
            worktree_modified=False,
            verdict=None,
            unresolved_blocker=True,
            timed_out=False,
        )

    append_grok_call(wave_dir=wave_dir, ticket_id=ticket_id, role="challenge", rc=rc, verdict=verdict)
    return GrokResult(
        ok=True,
        rc=rc,
        out=out,
        why=verdict,
        worktree_modified=False,
        verdict=verdict,
        unresolved_blocker=blocker,
        timed_out=False,
    )
