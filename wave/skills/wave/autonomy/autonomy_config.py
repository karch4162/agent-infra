"""Parse wave autonomy flags from config.env / process env.

Defaults keep backlog-watch OFF until Mason enables WAVE_BACKLOG_WATCH=1.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


DEFAULTS = {
    "WAVE_BACKLOG_WATCH": "0",
    "WAVE_DAILY_TICKET_CAP": "3",
    "WAVE_MAX_IMPLEMENT_WORKERS": "3",
    "WAVE_PLAN_ROUNDS_CAP": "2",
    "WAVE_REVIEW_ROUNDS_CAP": "3",
    "WAVE_AUTO_MERGE_LOW_MEDIUM": "1",
    "WAVE_BUDGET_GUARD": "1",
    "WAVE_GROK_CHALLENGE": "1",
    # Repo identity lives in <repo>/.claude/wave/config.env, never here.
    "WAVE_CLICKUP_LIST": "",
    "WAVE_CLICKUP_SPACE": "",
    "WAVE_CLICKUP_TEAM": "",
    "WAVE_BASE": "",
    "WAVE_RUNTIME": "orca",
    "WAVE_BRANCH_PREFIX": "wave/",
    "WAVE_MERGE_METHOD": "merge",
    "WAVE_PREFLIGHT_DOCKER": "0",
    "WAVE_PREFLIGHT_CODEX": "0",
    "WAVE_CLOSEOUT_CMD": "",
    "WAVE_REPO": "",
    "WAVE_STATE_START": "",
    "WAVE_STATE_DONE": "",
    "WAVE_QUEUE_STATUS": "backlog",
}


def repo_root(start: Path | None = None) -> Path:
    """Main checkout of the repo we run in (the common dir's parent, so a worktree
    resolves to the main checkout the way lib.sh's MAIN_CHECKOUT does)."""
    import subprocess

    env_repo = os.environ.get("WAVE_REPO", "").strip()
    if env_repo:
        return Path(env_repo).resolve()
    proc = subprocess.run(
        ["git", "rev-parse", "--git-common-dir"],
        cwd=str(start or Path.cwd()), capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise SystemExit("wave: not inside a git repo (set WAVE_REPO)")
    common = Path(proc.stdout.strip())
    if not common.is_absolute():
        common = (start or Path.cwd()) / common
    return common.resolve().parent


def wave_dir(repo: Path | None = None) -> Path:
    """<repo>/.claude/wave: config.env, notes.md, runs/, autonomy/ state."""
    return (repo or repo_root()) / ".claude" / "wave"


def load_config_env(path: Path | None = None) -> dict[str, str]:
    """Load KEY=VALUE lines from <repo>/.claude/wave/config.env (no shell expansion)."""
    out: dict[str, str] = {}
    if path is None:
        path = wave_dir() / "config.env"
    if not path.exists():
        return out
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip()
        if (val.startswith("'") and val.endswith("'")) or (
            val.startswith('"') and val.endswith('"')
        ):
            val = val[1:-1]
        out[key] = val
    return out


def _get(key: str, file_vals: dict[str, str]) -> str:
    if key in os.environ and os.environ[key] != "":
        return os.environ[key]
    if key in file_vals:
        return file_vals[key]
    return DEFAULTS.get(key, "")


@dataclass(frozen=True)
class AutonomyConfig:
    backlog_watch: bool
    daily_ticket_cap: int
    max_implement_workers: int
    plan_rounds_cap: int
    review_rounds_cap: int
    auto_merge_low_medium: bool
    budget_guard: bool
    grok_challenge: bool
    clickup_list: str
    clickup_space: str
    clickup_team: str
    wave_base: str
    tracker: str
    runtime: str
    branch_prefix: str
    merge_method: str
    preflight_docker: bool
    preflight_codex: bool
    closeout_cmd: str
    state_start: str
    state_done: str
    queue_status: str

    @property
    def enabled(self) -> bool:
        return self.backlog_watch


def load_autonomy_config(config_path: Path | None = None) -> AutonomyConfig:
    file_vals = load_config_env(config_path)
    return AutonomyConfig(
        backlog_watch=_get("WAVE_BACKLOG_WATCH", file_vals) == "1",
        daily_ticket_cap=int(_get("WAVE_DAILY_TICKET_CAP", file_vals) or "3"),
        max_implement_workers=int(_get("WAVE_MAX_IMPLEMENT_WORKERS", file_vals) or "3"),
        plan_rounds_cap=int(_get("WAVE_PLAN_ROUNDS_CAP", file_vals) or "2"),
        review_rounds_cap=int(_get("WAVE_REVIEW_ROUNDS_CAP", file_vals) or "3"),
        auto_merge_low_medium=_get("WAVE_AUTO_MERGE_LOW_MEDIUM", file_vals) != "0",
        budget_guard=_get("WAVE_BUDGET_GUARD", file_vals) != "0",
        grok_challenge=_get("WAVE_GROK_CHALLENGE", file_vals) != "0",
        clickup_list=_get("WAVE_CLICKUP_LIST", file_vals),
        clickup_space=_get("WAVE_CLICKUP_SPACE", file_vals),
        clickup_team=_get("WAVE_CLICKUP_TEAM", file_vals),
        wave_base=_get("WAVE_BASE", file_vals) or "origin/HEAD",
        tracker=_get("WAVE_TRACKER", file_vals) or "",
        runtime=_get("WAVE_RUNTIME", file_vals) or "orca",
        branch_prefix=_get("WAVE_BRANCH_PREFIX", file_vals) or "wave/",
        merge_method=_get("WAVE_MERGE_METHOD", file_vals) or "merge",
        preflight_docker=_get("WAVE_PREFLIGHT_DOCKER", file_vals) == "1",
        preflight_codex=_get("WAVE_PREFLIGHT_CODEX", file_vals) == "1",
        closeout_cmd=_get("WAVE_CLOSEOUT_CMD", file_vals),
        # Tracker state names: the tick runs from a scheduler, not through lib.sh, so
        # these must come from config.env, not only from an exported environment.
        state_start=_get("WAVE_STATE_START", file_vals),
        state_done=_get("WAVE_STATE_DONE", file_vals),
        queue_status=_get("WAVE_QUEUE_STATUS", file_vals) or "backlog",
    )
