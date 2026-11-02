"""Preflight before any DirectWorkerRuntime spawn (Mason t24u).

Checks: Docker running (start if possible), no DENY ACEs on .git,
expected Claude/Codex launch flags, Codex quota probe, ClickUp token reachability.
Never fakes a pass — returns structured results; exit 1 if any hard check fails.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable


@dataclass
class Check:
    name: str
    ok: bool
    hard: bool
    detail: str


@dataclass
class PreflightReport:
    ts: str
    repo: str
    checks: list[Check] = field(default_factory=list)
    ok: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "ts": self.ts,
            "repo": self.repo,
            "ok": self.ok,
            "checks": [asdict(c) for c in self.checks],
        }


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _run(cmd: list[str], *, timeout: int = 60) -> tuple[int, str, str]:
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, p.stdout or "", p.stderr or ""


def check_docker(start_if_stopped: bool = True) -> Check:
    code, out, err = _run(["docker", "info"], timeout=45)
    if code == 0:
        return Check("docker", True, True, "docker info OK")
    detail = (err or out)[-400:]
    if start_if_stopped and os.name == "nt":
        # Best-effort start Docker Desktop
        candidates = [
            r"C:\Program Files\Docker\Docker\Docker Desktop.exe",
            os.path.expandvars(r"%ProgramFiles%\Docker\Docker\Docker Desktop.exe"),
        ]
        started = False
        for c in candidates:
            if Path(c).exists():
                subprocess.Popen([c], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                started = True
                break
        if started:
            for _ in range(30):
                import time

                time.sleep(2)
                code2, _, _ = _run(["docker", "info"], timeout=30)
                if code2 == 0:
                    return Check("docker", True, True, "Docker Desktop started; docker info OK")
            return Check("docker", False, True, f"started Desktop but still not ready: {detail}")
    return Check("docker", False, True, f"docker info failed: {detail}")


def deny_scan_targets(git_dir: Path) -> list[Path]:
    """.git, .git/worktrees and every .git/worktrees/<slug> that exists."""
    worktrees = git_dir / "worktrees"
    targets = [git_dir]
    if worktrees.exists():
        targets.append(worktrees)
        targets.extend(sorted(p for p in worktrees.iterdir() if p.is_dir()))
    return targets


def _icacls_failure(target: Path, code: int, text: str) -> str | None:
    """Why this scan can't be trusted, or None when it really covered the path."""
    # Exit code alone is not enough: `/T` on a vanished path exits 0 having processed
    # nothing. Don't add /C either: it turns an access-denied exit 5 into exit 0.
    summary = re.search(r"Successfully processed (\d+) files; Failed processing (\d+) files", text)
    if code == 0 and summary and int(summary[1]) > 0 and int(summary[2]) == 0:
        return None
    return f"icacls {target} exit={code}: {text.strip()[-300:]}"


def check_git_deny_aces(repo: str, run: Callable[..., tuple[int, str, str]] = _run) -> Check:
    git_dir = Path(repo) / ".git"
    if not git_dir.exists():
        return Check("git_deny_aces", False, True, f"missing {git_dir}")
    if os.name != "nt":
        return Check("git_deny_aces", True, True, "non-Windows: skipped ACL DENY scan")
    try:
        targets = deny_scan_targets(git_dir)
    except OSError as e:
        return Check("git_deny_aces", False, True, f"could not list scan targets: {e}")
    failures: list[str] = []
    deny_hits: set[str] = set()
    for t in targets:
        try:
            # 24s for 5k files here, so the 60s default is too tight on a larger .git.
            code, out, err = run(["icacls", str(t), "/T"], timeout=300)
        except (OSError, subprocess.SubprocessError) as e:
            failures.append(f"icacls {t} did not run: {e}")
            continue
        text = out + err
        deny_hits.update(line.strip() for line in text.splitlines() if "(DENY)" in line.upper())
        failure = _icacls_failure(t, code, text)
        if failure:
            failures.append(failure)
    if failures or deny_hits:
        parts = []
        if failures:
            parts.append(f"scan failed ({len(failures)}): " + "; ".join(failures[:5]))
        if deny_hits:
            hits = sorted(deny_hits)
            parts.append(f"DENY ACEs present ({len(hits)}): " + "; ".join(hits[:5]))
        return Check("git_deny_aces", False, True, " | ".join(parts))
    return Check("git_deny_aces", True, True, f"no DENY ACEs in {len(targets)} icacls /T scans under .git")


def check_launch_flags() -> Check:
    """Verify expected Claude/Codex flag builders match Mason t16u policy."""
    try:
        from worker_runtime import build_claude_reviewer_cmd, build_codex_reviewer_cmd
    except ImportError:
        # same package dir
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from worker_runtime import build_claude_reviewer_cmd, build_codex_reviewer_cmd

    claude = build_claude_reviewer_cmd("claude")
    codex = build_codex_reviewer_cmd("codex")
    need_c = ["--model", "opus", "--dangerously-skip-permissions", "--effort", "medium"]
    need_x = ["--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check"]
    missing_c = [x for x in need_c if x not in claude]
    missing_x = [x for x in need_x if x not in codex]
    if missing_c or missing_x:
        return Check(
            "launch_flags",
            False,
            True,
            f"missing claude={missing_c} codex={missing_x}; claude={claude} codex={codex}",
        )
    return Check("launch_flags", True, True, f"claude={claude}; codex={codex}")


def check_codex_quota() -> Check:
    """Soft/hard probe: run `codex --version` and look for recent usage-limit markers.

    A real remaining-quota API is not exposed; we fail hard only when a marker file
    says blocked-until is still in the future, else warn via soft check on binary present.
    """
    bin_names = ["codex.cmd", "codex.exe", "codex"] if os.name == "nt" else ["codex"]
    found = None
    import shutil

    for n in bin_names:
        found = shutil.which(n)
        if found:
            break
    if not found:
        return Check("codex_quota", False, True, "codex binary not on PATH")
    code, out, err = _run([found, "--version"], timeout=30)
    marker = Path(os.environ.get("WAVE_CODEX_LIMIT_MARKER", str(Path.home() / ".codex" / "wave-limit-until.txt")))
    if marker.exists():
        until = marker.read_text(encoding="utf-8", errors="replace").strip()
        return Check("codex_quota", False, True, f"limit marker present until={until!r} at {marker}")
    if code != 0:
        return Check("codex_quota", False, True, f"codex --version failed: {(err or out)[-300:]}")
    return Check("codex_quota", True, False, f"codex present ({found}); no local limit marker; version={(out or err).strip()[:120]}")


def check_clickup_token() -> Check:
    # Env only. config.env is committed; a fallback that reads the token from it
    # invites the token into git.
    token = os.environ.get("CLICKUP_API_TOKEN", "").strip()
    if not token:
        return Check("clickup_token", False, True, "CLICKUP_API_TOKEN not set in the environment")
    req = urllib.request.Request(
        "https://api.clickup.com/api/v2/user",
        headers={"Authorization": token, "Content-Type": "application/json"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            data = json.loads(raw) if raw else {}
            user = (data.get("user") or {}).get("username") or (data.get("user") or {}).get("id")
            return Check("clickup_token", True, True, f"GET /user OK user={user}")
    except urllib.error.HTTPError as e:
        return Check("clickup_token", False, True, f"HTTP {e.code}")
    except Exception as e:  # noqa: BLE001
        return Check("clickup_token", False, True, str(e)[:300])


def run_preflight(repo: str, *, start_docker: bool = True) -> PreflightReport:
    """Checks are gated by the repo's config.env: Docker only when
    WAVE_PREFLIGHT_DOCKER=1 (a shared local stack is a repo fact, not a wave fact),
    the Codex probe hard only when WAVE_PREFLIGHT_CODEX=1, the ClickUp token only
    when WAVE_TRACKER=clickup. The .git DENY-ACE scan and launch flags always run."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from autonomy_config import load_autonomy_config

    cfg = load_autonomy_config(Path(repo) / ".claude" / "wave" / "config.env")
    report = PreflightReport(ts=_now(), repo=repo)
    if cfg.preflight_docker:
        report.checks.append(check_docker(start_if_stopped=start_docker))
    report.checks.append(check_git_deny_aces(repo))
    report.checks.append(check_launch_flags())
    codex = check_codex_quota()
    if not cfg.preflight_codex:
        codex.hard = False
    report.checks.append(codex)
    if cfg.tracker == "clickup":
        report.checks.append(check_clickup_token())
    hard_fail = [c for c in report.checks if c.hard and not c.ok]
    report.ok = len(hard_fail) == 0
    return report


def main(argv: list[str] | None = None) -> int:
    argv = list(argv or sys.argv[1:])
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from autonomy_config import repo_root, wave_dir

    repo = argv[0] if argv else str(repo_root())
    out = Path(argv[1]) if len(argv) > 1 else wave_dir(Path(repo)) / "autonomy" / "preflight-last.json"
    report = run_preflight(repo)
    out.write_text(json.dumps(report.to_dict(), indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report.to_dict(), indent=2))
    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())