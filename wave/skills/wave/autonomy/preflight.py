"""Preflight before any DirectWorkerRuntime spawn (Mason t24u).

Checks: Docker running (start if possible), no DENY ACEs on .git (self-healing
the one known Codex-sandbox case, INNOV-458), expected Claude/Codex launch flags, Codex quota probe, ClickUp token reachability.
Never fakes a pass — returns structured results; exit 1 if any hard check fails.
"""
from __future__ import annotations

import base64
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


# The one ACE shape the elevated Codex sandbox stamps (seen 2026-11-18): a raw (unresolvable)
# machine/domain SID, (OI)(CI) DENY of W,D,Rc,DC. Children carry it with (I).
_CODEX_DENY = re.compile(r"(S-1-5-21(?:-\d+)+):(\(I\))?((?:\(OI\)\(CI\))?)\(DENY\)\(W,D,Rc,DC\)\s*$")
# W,D,Rc,DC as FileSystemRights (Write|Delete|ReadPermissions|DeleteSubdirectoriesAndFiles|Synchronize).
_CODEX_DENY_RIGHTS = 0x130156


def _scan_deny(targets: list[Path], run: Callable[..., tuple[int, str, str]]) -> tuple[list[str], dict[Path, str], set[str]]:
    """icacls /T every target: (scan failures, raw output per target, DENY lines)."""
    failures: list[str] = []
    outputs: dict[Path, str] = {}
    deny_hits: set[str] = set()
    for t in targets:
        try:
            # 24s for 5k files here, so the 60s default is too tight on a larger .git.
            code, out, err = run(["icacls", str(t), "/T"], timeout=300)
        except (OSError, subprocess.SubprocessError) as e:
            failures.append(f"icacls {t} did not run: {e}")
            continue
        text = out + err
        outputs[t] = text
        deny_hits.update(line.strip() for line in text.splitlines() if "(DENY)" in line.upper())
        failure = _icacls_failure(t, code, text)
        if failure:
            failures.append(failure)
    return failures, outputs, deny_hits


def _own_acl_block(git_dir: Path, text: str) -> list[str]:
    """The ACE lines icacls printed for git_dir itself (its first entry sits on the path line)."""
    prefix = str(git_dir) + " "
    lines = text.splitlines()
    for k, line in enumerate(lines):
        if line.startswith(prefix):
            block = [line[len(prefix):].strip()]
            for cont in lines[k + 1:]:
                if not cont.strip() or not cont[:1].isspace():
                    break
                block.append(cont.strip())
            return block
    return []


def codex_sandbox_deny_sids(git_dir: Path, text: str, deny_hits: set[str]) -> list[str]:
    """SIDs to heal when the DENY ACEs are the known Codex-sandbox case, else [].

    The case (INNOV-458): an elevated Codex sandbox stamped an explicit
    (OI)(CI)(DENY)(W,D,Rc,DC) on .git for its own SID, which no longer resolves, so
    icacls prints it raw; children only inherit it; and .git carries a
    CodexSandboxUsers ACE. Any other DENY anywhere (a named principal, other rights or
    flags) means a rule this heal did not see stamped, so nothing is healed.
    """
    sids: set[str] = set()
    for hit in deny_hits:
        m = _CODEX_DENY.search(hit)
        if not m:
            return []
        sids.add(m[1])
    block = _own_acl_block(git_dir, text)
    if not any(ace.split(":", 1)[0].endswith("\\CodexSandboxUsers") for ace in block):
        return []
    explicit = set()
    for ace in block:
        m = _CODEX_DENY.search(ace)
        if m and not m[2] and m[3]:
            explicit.add(m[1])
    return sorted(sids) if sids and sids <= explicit else []


def codex_cap_sids() -> set[str]:
    """Every sandbox SID Codex has minted, from its ledger (CODEX_HOME/cap_sid, a JSON map
    of workspace/readonly/workspace_by_cwd -> SID). Empty when unreadable."""
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    try:
        data = json.loads((home / "cap_sid").read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return set()
    found: set[str] = set()
    stack: list[Any] = [data]
    while stack:
        v = stack.pop()
        if isinstance(v, dict):
            stack.extend(v.values())
        elif isinstance(v, list):
            stack.extend(v)
        elif isinstance(v, str) and v.startswith("S-1-"):
            found.add(v)
    return found


def _heal_script(git_dir: Path, sids: list[str]) -> str:
    def q(v: str) -> str:
        return "'" + v.replace("'", "''") + "'"

    return "\n".join([
        "$ErrorActionPreference = 'Stop'",
        f"$p = {q(str(git_dir))}",
        f"$sids = @({', '.join(q(s) for s in sids)})",
        "$acl = Get-Acl -LiteralPath $p",
        "if (-not ($acl.Access | Where-Object { $_.IdentityReference.Value -like '*\\CodexSandboxUsers' })) { exit 3 }",
        "$rules = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' -and -not $_.IsInherited -and"
        " $_.IdentityReference -is [System.Security.Principal.SecurityIdentifier] -and $sids -contains $_.IdentityReference.Value -and"
        f" [int]$_.FileSystemRights -eq {_CODEX_DENY_RIGHTS} -and $_.InheritanceFlags -eq 'ContainerInherit, ObjectInherit' -and"
        " $_.PropagationFlags -eq 'None' })",
        "if ($rules.Count -eq 0) { exit 4 }",
        "foreach ($r in $rules) { $acl.RemoveAccessRuleSpecific($r) }",
        "Set-Acl -LiteralPath $p -AclObject $acl",
        "Write-Output \"REMOVED $($rules.Count)\"",
    ])


def heal_cmd(git_dir: Path, sids: list[str]) -> list[str]:
    """PowerShell that removes only explicit DENY rules for these unresolvable SIDs on
    .git itself. icacls /remove:d can't: it fails with 1332 on an unresolvable SID."""
    encoded = base64.b64encode(_heal_script(git_dir, sids).encode("utf-16-le")).decode("ascii")
    return ["powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]


def _deny_detail(failures: list[str], deny_hits: set[str]) -> str:
    parts = []
    if failures:
        parts.append(f"scan failed ({len(failures)}): " + "; ".join(failures[:5]))
    if deny_hits:
        hits = sorted(deny_hits)
        parts.append(f"DENY ACEs present ({len(hits)}): " + "; ".join(hits[:5]))
    return " | ".join(parts)


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
    failures, outputs, deny_hits = _scan_deny(targets, run)
    if not failures and not deny_hits:
        return Check("git_deny_aces", True, True, f"no DENY ACEs in {len(targets)} icacls /T scans under .git")
    # Never heal on a scan we can't trust.
    sids = [] if failures else codex_sandbox_deny_sids(git_dir, outputs.get(git_dir, ""), deny_hits)
    if not sids:
        return Check("git_deny_aces", False, True, _deny_detail(failures, deny_hits))
    # The shape alone could be a deleted domain account's deliberate DENY: only heal
    # SIDs Codex itself recorded minting.
    unknown = sorted(set(sids) - codex_cap_sids())
    if unknown:
        return Check("git_deny_aces", False, True, _deny_detail(failures, deny_hits)
                     + f" | not healed: {', '.join(unknown)} not in the Codex cap_sid ledger")
    try:
        # Set-Acl re-propagates inheritance to every child, as slow as the /T scan.
        code, out, err = run(heal_cmd(git_dir, sids), timeout=300)
    except (OSError, subprocess.SubprocessError) as e:
        code, out, err = -1, "", f"did not run: {e}"
    m = re.search(r"REMOVED (\d+)", out)
    healed = f"self-heal exit={code}: {(m[0] if m else (out + err).strip()[-200:])}"
    if code != 0 or not m:
        return Check("git_deny_aces", False, True, _deny_detail(failures, deny_hits) + f" | {healed}")
    # The rescan is the only judge: inheritance must have cleared every child too.
    failures2, _, deny_hits2 = _scan_deny(targets, run)
    if failures2 or deny_hits2:
        return Check("git_deny_aces", False, True, _deny_detail(failures2, deny_hits2) + f" | after {healed}")
    notice = (f"self-healed: removed {m[1]} explicit DENY rule(s) on {git_dir} for unresolvable "
              f"Codex sandbox SID(s) {', '.join(sids)}; rescan clean. A sandboxed Codex session "
              "ran in this checkout; launch Codex with --dangerously-bypass-approvals-and-sandbox here")
    print(f"NOTICE: git_deny_aces {notice}", file=sys.stderr)
    return Check("git_deny_aces", True, True, notice)


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