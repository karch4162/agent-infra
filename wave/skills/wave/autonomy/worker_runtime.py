"""Direct WorkerRuntime for orchestrated waves (no Orca).

Uses git worktree + claude/codex CLIs on the local machine. Tracks each worker
with PID and status files under .claude/wave/runs/<ticket_id>/.

Orca remains installed for Mason's manual use; orchestrated waves MUST use
DirectWorkerRuntime (this module), not orca_runtime / OrcaWorkerRuntime.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Literal

AgentName = Literal["claude", "codex"]


class WorkerError(RuntimeError):
    pass


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def _read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8-sig"))  # a hand edit in PowerShell adds a BOM


def pid_alive(pid: int) -> bool:
    """True when the process exists. Substring-matching tasklist output said 123
    was alive while 1234 ran; ask the kernel instead (same as wave coordinator.sh)."""
    if not pid or pid <= 0:
        return False
    if os.name != "nt":
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False
    import ctypes

    k = ctypes.windll.kernel32  # type: ignore[attr-defined]
    h = k.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return False
    code = ctypes.c_ulong()
    k.GetExitCodeProcess(h, ctypes.byref(code))
    k.CloseHandle(h)
    return code.value == 259  # STILL_ACTIVE


def _resolve_agent_bin(agent: str) -> str:
    """Resolve claude/codex to an executable path Windows Popen can launch.

    npm installs `codex` as a .cmd shim; bare `codex` fails CreateProcess (WinError 2).
    Prefer .cmd/.exe on Windows via PATHEXT-aware shutil.which.
    """
    names: list[str]
    if os.name == "nt":
        if agent == "codex":
            names = ["codex.cmd", "codex.exe", "codex"]
        else:
            names = ["claude.exe", "claude.cmd", "claude"]
    else:
        names = [agent]
    for name in names:
        found = shutil.which(name)
        if found:
            return found
    raise WorkerError(
        f"agent binary not found for {agent!r}; tried {names}. "
        "Install CLI or put it on PATH."
    )



def build_claude_reviewer_cmd(agent_bin: str, *, model: str = "opus", output_format: str = "text") -> list[str]:
    """The one Claude launch shape (reviewers and workers; preflight checks it).

    --model opus --effort medium --dangerously-skip-permissions; tie-break only:
    model="fable" (no --effort). Workers pass output_format="stream-json" so the
    log keeps tool calls and cost (-p needs --verbose for it); reviewers keep text.
    """
    cmd = [
        agent_bin,
        "-p",
        "--output-format",
        output_format,
        "--model",
        model,
        "--dangerously-skip-permissions",
    ]
    if output_format == "stream-json":
        cmd.append("--verbose")
    if model != "fable":
        cmd.extend(["--effort", "medium"])
    return cmd


def build_codex_reviewer_cmd(agent_bin: str, *, read_only: bool = False) -> list[str]:
    """Flags for Codex reviewer / worker launches (Mason t16u).

    Prefer --dangerously-bypass-approvals-and-sandbox (Orca equivalent / full-auto).
    Read-only reviews may pass -s read-only instead of bypass when intentionally
    sandboxed; implementer workers must use bypass so Windows does not DENY-ACL
    .git/worktrees.
    """
    if read_only:
        return [agent_bin, "exec", "-s", "read-only"]
    return [
        agent_bin,
        "exec",
        "--dangerously-bypass-approvals-and-sandbox",
        "--skip-git-repo-check",
    ]


@dataclass
class RunRecord:
    run_id: str
    ticket_id: str
    agent: str
    worktree_name: str
    worktree_id: str | None = None
    path: str | None = None
    branch: str | None = None
    task_id: str | None = None
    dispatch_id: str | None = None
    mode: str = "direct"
    pid: int | None = None
    status_path: str | None = None
    pid_path: str | None = None
    log_path: str | None = None



def run_spawn_preflight(repo_root: Path, out_path: Path | None = None) -> dict:
    """Hard gate before spawn (Mason t24u). Raises WorkerError on failure."""
    import importlib.util

    pre_path = Path(__file__).resolve().parent / "preflight.py"
    spec = importlib.util.spec_from_file_location("wave_preflight", pre_path)
    if spec is None or spec.loader is None:
        raise WorkerError(f"preflight.py not loadable at {pre_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod  # @dataclass resolves its module through sys.modules
    spec.loader.exec_module(mod)
    report_obj = mod.run_preflight(str(repo_root))
    report = report_obj.to_dict() if hasattr(report_obj, "to_dict") else dict(report_obj)
    if out_path is not None:
        out_path = Path(out_path)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if not report.get("ok"):
        failed = [c for c in report.get("checks", []) if c.get("hard") and not c.get("ok")]
        raise WorkerError(f"preflight failed: {failed}")
    return report


class DirectWorkerRuntime:
    """git worktree + CLI agents; PID/status files for tracking."""

    def __init__(
        self,
        *,
        repo_path: str,
        base_branch: str = "origin/development",
        worktrees_root: str | None = None,
        runs_dir: str | None = None,
    ):
        self.repo_path = str(Path(repo_path).resolve())
        self.base_branch = base_branch
        self.worktrees_root = Path(
            worktrees_root
            or os.environ.get(
                "WAVE_WORKTREES_ROOT",
                str(Path(self.repo_path).parent / "sports-management-worktrees"),
            )
        )
        self.runs_dir = Path(
            runs_dir
            or os.environ.get(
                "WAVE_RUNS_DIR",
                str(Path(self.repo_path) / ".claude" / "wave" / "runs"),
            )
        )
        self.runs_dir.mkdir(parents=True, exist_ok=True)
        self.worktrees_root.mkdir(parents=True, exist_ok=True)
        self._claims: dict[str, str] = {}

    def _run_dir(self, ticket_id: str) -> Path:
        d = self.runs_dir / ticket_id.lower()
        d.mkdir(parents=True, exist_ok=True)
        return d

    def _git(self, *args: str, cwd: str | None = None, timeout: int = 120) -> str:
        proc = subprocess.run(
            ["git", *args],
            cwd=cwd or self.repo_path,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
        if proc.returncode != 0:
            raise WorkerError(
                f"git {' '.join(args)} failed ({proc.returncode}): {(proc.stderr or proc.stdout)[-2000:]}"
            )
        return (proc.stdout or "").strip()

    def claim_guard(self, ticket_id: str) -> None:
        slug = ticket_id.lower()
        if ticket_id in self._claims:
            raise WorkerError(f"claim_guard: {ticket_id} already claimed in this process")
        # Existing run dir with live PID
        st = _read_json(self._run_dir(ticket_id) / "status.json")
        pid = st.get("pid")
        if pid and self._pid_alive(int(pid)) and st.get("state") in {"running", "starting"}:
            raise WorkerError(f"claim_guard: {ticket_id} already running pid={pid}")
        # Existing git worktree path
        wt_path = self.worktrees_root / slug
        if wt_path.exists():
            raise WorkerError(f"claim_guard: worktree path already exists: {wt_path}")
        listed = self._git("worktree", "list", "--porcelain")
        for line in listed.splitlines():
            if line.startswith("worktree ") and line.endswith(slug):
                raise WorkerError(f"claim_guard: git worktree already listed for {slug}")

    @staticmethod
    def _pid_alive(pid: int) -> bool:
        return pid_alive(pid)

    def _ensure_base(self) -> str:
        # Resolve base to a commit; fetch if needed
        try:
            return self._git("rev-parse", "--verify", self.base_branch)
        except WorkerError:
            remote, _, branch = self.base_branch.partition("/")
            if remote == "origin" and branch:
                self._git("fetch", "origin", branch)
                return self._git("rev-parse", "--verify", self.base_branch)
            raise

    def spawn(
        self,
        *,
        ticket_id: str,
        prompt: str,
        agent: str,
        model: str | None = None,
        run_id: str | None = None,
        activate: bool = False,  # unused; kept for API parity
    ) -> RunRecord:
        if agent not in ("claude", "codex"):
            raise WorkerError(f"unsupported agent for DirectWorkerRuntime: {agent}")
        # Preflight before any spawn (Docker, .git DENY ACEs, flags, Codex quota, ClickUp).
        skip_pf = os.environ.get("WAVE_SKIP_PREFLIGHT") == "1"
        if not skip_pf:
            pf_out = self.runs_dir / ticket_id.lower() / "preflight.json"
            run_spawn_preflight(Path(self.repo_path), pf_out)
        self.claim_guard(ticket_id)
        slug = ticket_id.lower()
        branch = f"{os.environ.get('WAVE_BRANCH_PREFIX', 'wave/')}{ticket_id}"
        wt_path = self.worktrees_root / slug
        run_dir = self._run_dir(ticket_id)
        prompt_path = run_dir / "prompt.txt"
        status_path = run_dir / "status.json"
        pid_path = run_dir / "worker.pid"
        log_path = run_dir / "worker.log"

        sha = self._ensure_base()
        prompt_path.write_text(prompt, encoding="utf-8")
        _write_json(
            status_path,
            {
                "ticket_id": ticket_id,
                "agent": agent,
                "model": model,
                "state": "starting",
                "branch": branch,
                "path": str(wt_path),
                "updated_at": _now(),
                "runtime": "direct",
            },
        )

        # Create detached worktree on a new branch from base
        # If branch exists locally, fail rather than reuse (claim_guard should catch path).
        self._git(
            "worktree",
            "add",
            "-b",
            branch,
            str(wt_path),
            sha,
            timeout=180,
        )

        env = os.environ.copy()
        env["WAVE_TICKET_ID"] = ticket_id
        env["WAVE_RUNTIME"] = "direct"
        env["WAVE_IMPLEMENTER"] = agent  # review.sh reviews with the other model family
        # worker_step_commit.py heartbeats into this dir; wave_status.py reads it.
        env["WAVE_RUN_DIR"] = str(run_dir)
        env.setdefault("WAVE_HOME", str(Path(__file__).resolve().parent.parent))
        # Do not set ORCA_TERMINAL_HANDLE for orchestrated direct workers.

        agent_bin = _resolve_agent_bin(agent)
        # Default worker models (Mason t16u): Claude Opus medium; Codex full-auto bypass.
        # Fable (--model fable) is tie-break / advisor only — pass model="fable" to override.
        if agent == "claude":
            # Non-interactive print mode; permission bypass for local sandboxed worktree.
            # stream-json (default) keeps every tool call and the final cost in
            # worker.log, which is what a status view needs to show what a worker is
            # doing; WAVE_CLAUDE_OUTPUT_FORMAT=text restores the plain transcript.
            cmd = build_claude_reviewer_cmd(
                agent_bin, model=model or "opus",
                output_format=os.environ.get("WAVE_CLAUDE_OUTPUT_FORMAT", "stream-json"))
            # Feed prompt via stdin
            creationflags = 0
            if os.name == "nt":
                creationflags = subprocess.CREATE_NEW_PROCESS_GROUP  # type: ignore[attr-defined]
            log_f = open(log_path, "w", encoding="utf-8")
            prompt_body = prompt_path.read_text(encoding="utf-8")
            proc = subprocess.Popen(
                cmd,
                cwd=str(wt_path),
                stdin=subprocess.PIPE,
                stdout=log_f,
                stderr=subprocess.STDOUT,
                env=env,
                text=True,
                encoding="utf-8",
                errors="replace",
                creationflags=creationflags,
            )
            assert proc.stdin is not None
            proc.stdin.write(prompt_body)
            proc.stdin.close()
        else:
            # codex exec; prompt on stdin.
            # Orca recognizes --dangerously-bypass-approvals-and-sandbox
            # (codex-command-classification). Without it, Windows Codex sandbox
            # stamps DENY ACLs on .git/worktrees (wave2a 76mh crash).
            cmd = [
                agent_bin,
                "exec",
                "--dangerously-bypass-approvals-and-sandbox",
                "--skip-git-repo-check",
                # Codex's default shell policy hides WAVE_* and CLICKUP_* from the worker's commands.
                "-c",
                "shell_environment_policy.inherit=all",
                "-",
            ]
            if model:
                cmd.extend(["-c", f"model=\"{model}\""])
            creationflags = 0
            if os.name == "nt":
                creationflags = subprocess.CREATE_NEW_PROCESS_GROUP  # type: ignore[attr-defined]
            log_f = open(log_path, "w", encoding="utf-8")
            prompt_body = prompt_path.read_text(encoding="utf-8")
            proc = subprocess.Popen(
                cmd,
                cwd=str(wt_path),
                stdin=subprocess.PIPE,
                stdout=log_f,
                stderr=subprocess.STDOUT,
                env=env,
                text=True,
                encoding="utf-8",
                errors="replace",
                creationflags=creationflags,
            )
            assert proc.stdin is not None
            proc.stdin.write(prompt_body)
            proc.stdin.close()

        pid_path.write_text(str(proc.pid), encoding="utf-8")
        rec = RunRecord(
            run_id=run_id or f"direct-{ticket_id}",
            ticket_id=ticket_id,
            agent=agent,
            worktree_name=slug,
            worktree_id=f"direct::{wt_path}",
            path=str(wt_path),
            branch=branch,
            mode="direct",
            pid=proc.pid,
            status_path=str(status_path),
            pid_path=str(pid_path),
            log_path=str(log_path),
        )
        _write_json(
            status_path,
            {
                "ticket_id": ticket_id,
                "agent": agent,
                "model": model,
                "state": "running",
                "pid": proc.pid,
                "branch": branch,
                "path": str(wt_path),
                "log_path": str(log_path),
                "updated_at": _now(),
                "runtime": "direct",
                "run_id": rec.run_id,
            },
        )
        _write_json(run_dir / "record.json", asdict(rec))
        self._claims[ticket_id] = slug
        # Detach log handle ownership to the child; close our copy.
        try:
            log_f.close()
        except Exception:
            pass
        return rec

    def status(self, rec: RunRecord) -> dict[str, Any]:
        status_path = Path(rec.status_path) if rec.status_path else self._run_dir(rec.ticket_id) / "status.json"
        st = _read_json(status_path)
        pid = st.get("pid") or rec.pid
        alive = self._pid_alive(int(pid)) if pid else False
        if st.get("state") == "running" and not alive:
            st["state"] = "exited"
            st["updated_at"] = _now()
            _write_json(status_path, st)
        st["alive"] = alive
        # Attach per-worker usage when usage.json exists (Mason t24u).
        usage_path = self._run_dir(rec.ticket_id) / "usage.json"
        if usage_path.exists():
            st["usage"] = _read_json(usage_path)
        return st

    def logs(self, rec: RunRecord, *, n: int = 80) -> str:
        log_path = Path(rec.log_path) if rec.log_path else self._run_dir(rec.ticket_id) / "worker.log"
        if not log_path.exists():
            return ""
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
        return "\n".join(lines[-n:])

    def stop(self, rec: RunRecord) -> None:
        st = self.status(rec)
        pid = st.get("pid") or rec.pid
        if pid and self._pid_alive(int(pid)):
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True, timeout=60)
            else:
                os.kill(int(pid), signal.SIGTERM)
        status_path = Path(rec.status_path) if rec.status_path else self._run_dir(rec.ticket_id) / "status.json"
        st = _read_json(status_path)
        st["state"] = "stopped"
        st["updated_at"] = _now()
        _write_json(status_path, st)

    def workspace(self, rec: RunRecord) -> dict[str, Any]:
        return {"status": self.status(rec), "path": rec.path, "branch": rec.branch, "name": rec.worktree_name}

    def list_repo_worktrees(self) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for child in sorted(self.runs_dir.glob("*/status.json")):
            st = _read_json(child)
            st["_status_path"] = str(child)
            out.append(st)
        return out

    def remove_worktree(self, ticket_id: str, *, force: bool = False) -> None:
        slug = ticket_id.lower()
        wt_path = self.worktrees_root / slug
        args = ["worktree", "remove", str(wt_path)]
        if force:
            args.insert(2, "--force")
        try:
            self._git(*args, timeout=180)
        except WorkerError:
            if force and wt_path.exists():
                # Last resort: git worktree prune after manual delete is Mason's call;
                # do not shutil.rmtree here.
                raise
            raise
        st_path = self._run_dir(ticket_id) / "status.json"
        st = _read_json(st_path)
        st["state"] = "removed"
        st["updated_at"] = _now()
        _write_json(st_path, st)


def codex_inherits_all(config: Path | None = None) -> bool:
    """Whether Codex hands its shell the whole environment. Workers need CLICKUP_*/WAVE_* in
    their commands; the direct runtime forces this per launch, Orca's launch cannot."""
    import tomllib

    path = config or Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex") / "config.toml"
    try:
        cfg = tomllib.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return True  # no config: Codex's default policy inherits everything
    except (OSError, ValueError):
        return False
    return (cfg.get("shell_environment_policy") or {}).get("inherit", "all") == "all"


OrcaFn = Callable[[list[str]], subprocess.CompletedProcess]


def _orca(args: list[str]) -> subprocess.CompletedProcess:
    # The .exe, never orca.cmd: cmd.exe caps a command line at 8,191 chars and mangles the
    # newlines and quotes of a worker prompt that runs to 12 KB.
    exe = shutil.which("orca.exe") or shutil.which("orca") or "orca"
    return subprocess.run([exe, *args], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300)


class OrcaWorkerRuntime:
    """Workers as interactive agents in Orca terminals, so a person can watch and steer them.

    Same run-folder contract as DirectWorkerRuntime: status.json, record.json, prompt.txt and,
    from the worker, summary.md. Orca's per-agent launch settings decide the permission flags
    (on Mason's machine: --dangerously-skip-permissions for Claude, the sandbox bypass for Codex).
    An interactive agent does not exit when done, so liveness is summary.md or the terminal
    closing (orca_worker_state), not a PID. No worker.log: tokens come from the agents' own logs.
    """

    def __init__(self, *, repo_path: str, base_branch: str = "origin/development",
                 runs_dir: str | None = None, orca: OrcaFn | None = None):
        self.repo_path = str(Path(repo_path).resolve())
        self.base_branch = base_branch
        self.runs_dir = Path(runs_dir or Path(self.repo_path) / ".claude" / "wave" / "runs")
        self.orca = orca or _orca

    def _json(self, *args: str) -> dict[str, Any]:
        p = self.orca([*args, "--json"])
        if p.returncode != 0:
            raise WorkerError(f"orca {' '.join(args[:2])} failed ({p.returncode}): {(p.stderr or p.stdout or '')[-400:]}")
        try:
            return json.loads(p.stdout)["result"]
        except (ValueError, KeyError, TypeError) as e:
            raise WorkerError(f"orca {' '.join(args[:2])}: unreadable output ({e})")

    def repo_id(self) -> str:
        want = os.path.normcase(os.path.realpath(self.repo_path))
        for r in self._json("repo", "list").get("repos", []):
            if os.path.normcase(os.path.realpath(r.get("path", ""))) == want:
                return r["id"]
        raise WorkerError(f"{self.repo_path} is not registered with Orca")

    def spawn(self, *, ticket_id: str, prompt: str, agent: str, model: str | None = None,
              run_id: str | None = None, activate: bool = False) -> RunRecord:
        if agent not in ("claude", "codex"):
            raise WorkerError(f"unsupported agent for OrcaWorkerRuntime: {agent}")
        run_dir = self.runs_dir / ticket_id.lower()
        status_path = run_dir / "status.json"
        if _read_json(status_path).get("state") in ("starting", "running"):
            raise WorkerError(f"claim_guard: {ticket_id} already has a live run")
        if os.environ.get("WAVE_SKIP_PREFLIGHT") != "1":
            run_spawn_preflight(Path(self.repo_path), run_dir / "preflight.json")
        repo_id = self.repo_id()
        run_dir.mkdir(parents=True, exist_ok=True)
        if (run_dir / "summary.md").exists():  # a previous attempt's summary would read as "done"
            (run_dir / "summary.md").replace(run_dir / "summary.prev.md")
        (run_dir / "prompt.txt").write_text(prompt, encoding="utf-8")
        branch = f"{os.environ.get('WAVE_BRANCH_PREFIX', 'wave/')}{ticket_id}"
        args = ["worktree", "create", "--repo", f"id:{repo_id}", "--name", ticket_id.lower(), "--no-parent",
                "--base-branch", self.base_branch, "--branch", branch, "--agent", agent,
                "--surface", "terminal", "--prompt", prompt]
        if model:
            args += ["--model", model]
        wt = self._json(*args).get("worktree") or {}
        if not wt.get("path"):
            raise WorkerError(f"orca worktree create returned no worktree path for {ticket_id}")
        branch = (wt.get("branch") or branch).removeprefix("refs/heads/")
        _write_json(status_path, {
            "ticket_id": ticket_id, "agent": agent, "model": model, "state": "running",
            "branch": branch, "path": wt["path"], "worktree_id": wt.get("id"),
            "updated_at": _now(), "runtime": "orca",
        })
        rec = RunRecord(run_id=run_id or f"orca-{ticket_id}", ticket_id=ticket_id, agent=agent,
                        worktree_name=ticket_id.lower(), worktree_id=wt.get("id"), path=wt["path"],
                        branch=branch, mode="orca", status_path=str(status_path))
        _write_json(run_dir / "record.json", asdict(rec))
        return rec


def orca_worker_state(st: dict[str, Any], run_dir: Path, orca: OrcaFn | None = None) -> tuple[bool, float | None]:
    """(alive, seconds since the agent's terminal last printed) for an Orca-runtime worker.

    Done when the worker wrote summary.md (the contract's last step, after the PR) or no
    terminal is left in its worktree. If Orca cannot be asked, the worker counts as alive:
    a failed query must never mark a running worker exited."""
    if (run_dir / "summary.md").exists():
        return False, None
    p = (orca or _orca)(["terminal", "list", "--worktree", f"path:{st.get('path', '')}", "--json"])
    try:
        terms = json.loads(p.stdout)["result"]["terminals"] if p.returncode == 0 else None
    except (ValueError, KeyError, TypeError):
        terms = None
    if terms is None:
        return True, None
    if not terms:
        return False, None
    last = max((t.get("lastOutputAt") or 0) for t in terms)
    return True, (time.time() * 1000 - last) / 1000 if last else None


# Back-compat alias used by spawn scripts after the Orca cut-over.
WorkerRuntime = DirectWorkerRuntime
