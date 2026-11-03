"""Auto-merge low/medium PRs with one rebase retry; never force-push.

Uses the `gh` login on the worker machine. Pure decision via
merge_policy.decide; this module executes MERGE / CONFLICT rebase / HOLD.
"""
from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

import merge_policy
from autonomy_config import load_autonomy_config


@dataclass
class MergeResult:
    action: str  # merged | held | pending | conflict_held | dry_run
    decision: str
    pr: int | None
    detail: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "action": self.action,
            "decision": self.decision,
            "pr": self.pr,
            "detail": self.detail,
        }


GhFn = Callable[[list[str]], subprocess.CompletedProcess]


def _default_gh(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["gh", *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=180,
    )


def fetch_pr_snapshot(repo: str, pr: int, *, gh: GhFn | None = None) -> dict[str, Any]:
    gh = gh or _default_gh
    view = gh(
        [
            "pr",
            "view",
            str(pr),
            "--repo",
            repo,
            "--json",
            "body,mergeable,statusCheckRollup,url,number,title",
        ]
    )
    if view.returncode != 0:
        raise RuntimeError(f"gh pr view failed: {view.stderr[-500:]}")
    data = json.loads(view.stdout)
    checks = []
    for c in data.get("statusCheckRollup") or []:
        conclusion = (c.get("conclusion") or c.get("state") or "").upper()
        name = c.get("name") or c.get("context") or "check"
        if conclusion in {"SUCCESS", "NEUTRAL", "SKIPPED"}:
            bucket = "pass"
        elif conclusion in {"FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"}:
            bucket = "fail" if conclusion != "CANCELLED" else "cancel"
        elif conclusion in {"", "PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED"}:
            bucket = "pending"
        else:
            bucket = "pending"
        # Skip non-required noise? Policy treats all reported checks.
        if conclusion == "SKIPPED":
            continue
        checks.append({"name": name, "bucket": bucket, "raw": conclusion})
    mergeable = data.get("mergeable") or "UNKNOWN"
    return {
        "body": data.get("body") or "",
        "mergeable": mergeable,
        "checks": checks,
        "url": data.get("url"),
        "title": data.get("title"),
        "number": data.get("number") or pr,
    }


def rebase_once(repo: str, pr: int, *, gh: GhFn | None = None) -> dict[str, Any]:
    """Attempt one `gh pr update-branch` (rebase onto base). Never force-push."""
    gh = gh or _default_gh
    proc = gh(["pr", "update-branch", str(pr), "--repo", repo, "--rebase"])
    return {
        "ok": proc.returncode == 0,
        "stdout": (proc.stdout or "")[-1000:],
        "stderr": (proc.stderr or "")[-1000:],
        "code": proc.returncode,
    }


def merge_pr(repo: str, pr: int, *, gh: GhFn | None = None, method: str = "merge") -> dict[str, Any]:
    """gh pr merge with the repo's WAVE_MERGE_METHOD. No --delete-branch: from the
    main checkout it fails while a worktree still holds the branch; the sweep deletes."""
    gh = gh or _default_gh
    flag = {"merge": "--merge", "squash": "--squash", "rebase": "--rebase"}.get(method, "--merge")
    proc = gh(["pr", "merge", str(pr), "--repo", repo, flag])
    return {
        "ok": proc.returncode == 0,
        "stdout": (proc.stdout or "")[-1000:],
        "stderr": (proc.stderr or "")[-1000:],
        "code": proc.returncode,
    }


def evaluate_and_maybe_merge(
    *,
    repo: str,
    pr: int,
    rating: str,
    primary_review: str,
    primary_verdict: str,
    challenge: dict[str, Any] | None,
    rebase_attempts: int = 0,
    require_challenge: bool = True,
    dry_run: bool = True,
    gh: GhFn | None = None,
    snapshot: dict[str, Any] | None = None,
) -> MergeResult:
    cfg = load_autonomy_config()
    if not cfg.auto_merge_low_medium:
        return MergeResult(
            "held",
            "HOLD: WAVE_AUTO_MERGE_LOW_MEDIUM=0",
            pr,
            {},
        )

    snap = snapshot or fetch_pr_snapshot(repo, pr, gh=gh)
    payload = {
        "body": snap.get("body") or "",
        "checks": snap.get("checks") or [],
        "mergeable": snap.get("mergeable"),
        "rating": rating,
        "primary_review": primary_review,
        "primary_verdict": primary_verdict,
        "challenge": challenge or {"ran": False},
        "require_challenge": require_challenge,
        "rebase_attempts": rebase_attempts,
    }
    decision = merge_policy.decide(payload)

    if decision.startswith("PENDING"):
        return MergeResult("pending", decision, pr, {"snapshot": _safe(snap)})
    if decision.startswith("HOLD"):
        return MergeResult("held", decision, pr, {"snapshot": _safe(snap)})

    if decision == "CONFLICT":
        if dry_run:
            return MergeResult(
                "dry_run",
                decision,
                pr,
                {"would": "rebase_once", "snapshot": _safe(snap)},
            )
        rb = rebase_once(repo, pr, gh=gh)
        if not rb["ok"]:
            return MergeResult(
                "conflict_held",
                "HOLD: rebase failed",
                pr,
                {"rebase": rb, "snapshot": _safe(snap)},
            )
        # Re-evaluate once after rebase; second conflict holds.
        return evaluate_and_maybe_merge(
            repo=repo,
            pr=pr,
            rating=rating,
            primary_review=primary_review,
            primary_verdict=primary_verdict,
            challenge=challenge,
            rebase_attempts=rebase_attempts + 1,
            require_challenge=require_challenge,
            dry_run=False,
            gh=gh,
            snapshot=None,
        )

    if decision != "MERGE":
        return MergeResult("held", decision, pr, {"snapshot": _safe(snap)})

    if dry_run:
        return MergeResult(
            "dry_run",
            decision,
            pr,
            {"would": "merge_squash", "snapshot": _safe(snap)},
        )

    merged = merge_pr(repo, pr, gh=gh, method=cfg.merge_method)
    if not merged["ok"]:
        return MergeResult(
            "held",
            "HOLD: gh pr merge failed",
            pr,
            {"merge": merged, "snapshot": _safe(snap)},
        )
    return MergeResult("merged", decision, pr, {"merge": merged, "url": snap.get("url")})


def _safe(snap: dict[str, Any]) -> dict[str, Any]:
    return {
        "mergeable": snap.get("mergeable"),
        "checks": snap.get("checks"),
        "url": snap.get("url"),
        "title": snap.get("title"),
        "number": snap.get("number"),
        "body_has_wave": "## Wave" in (snap.get("body") or ""),
    }
