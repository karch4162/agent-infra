"""Dry-run autonomy flow (no ClickUp mutate, no spawn, no merge).

Mirrors dry_run_wave_flow.py style: exercise sufficiency, plan loop with fakes,
merge policy, daily cap, budget guard, backlog_watch --force-enabled.
"""
from __future__ import annotations

import json
import sys
import tempfile
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from auto_merge import evaluate_and_maybe_merge
from backlog_watch import run_watch
from budget_guard import check_budget
from daily_cap import ET, RunLock, can_start, load_daily, record_start, save_daily, DailyCapState
from grok_challenge import GrokResult, parse_challenge_verdict, run_grok_challenge
from merge_policy import decide
from plan_step import run_plan_loop, write_plan_artifacts
from ticket_sufficiency import assess_ticket




def main() -> int:
    wave_dir = Path(__file__).resolve().parent
    out_path = wave_dir / "dry-run-autonomy-last.json"
    results: dict = {"ts": datetime.now(ET).isoformat(), "steps": [], "ok": True}

    def add(name: str, ok: bool, detail):
        results["steps"].append({"name": name, "ok": ok, "detail": detail})
        if not ok:
            results["ok"] = False

    # 1) sufficiency: thin vs rich
    thin = assess_ticket(title="Fix thing", body="broken", tags=["agent-ready"])
    rich = assess_ticket(
        title="Refund lesson tax",
        body=(
            "In src/payments/refunds.ts:42 reverse_transfer must stay true.\n"
            "Acceptance: given a paid lesson, when cancelled, then price+tax refunded "
            "and application fee kept.\n"
            "Expected: unit test asserts refund_application_fee=false."
        ),
        tags=["agent-ready", "rating:low"],
    )
    add(
        "ticket_sufficiency",
        thin.plan_needed and rich.enough,
        {"thin": thin.to_dict(), "rich": rich.to_dict()},
    )

    # 2) plan loop with fakes (2nd round PASS)
    plans = {"n": 0}

    def planner(prev: str) -> str:
        plans["n"] += 1
        return (
            "# plan\n\n## Files\n- src/x.ts:1\n\n## Approach\n- do the thing\n\n"
            "## Tests\n- asserts behavior\n"
        )

    def reviewer(plan: str) -> str:
        if plans["n"] < 2:
            return "missing tests detail\nPLAN VERDICT: REVISE"
        return (
            "PLAN_REVIEW_RESULT:\n  schema_version: 1\n  decision: PASS\n"
            "  issues: []\n  summary: ok\n"
        )

    outcome = run_plan_loop(
        ticket_id="dry-thin",
        title="Fix thing",
        body="broken",
        plan_needed=True,
        max_rounds=2,
        planner=planner,
        reviewer=reviewer,
    )
    with tempfile.TemporaryDirectory() as td:
        arts = write_plan_artifacts(Path(td), outcome)
    add(
        "plan_loop",
        outcome.approved and len(outcome.rounds) == 2,
        outcome.to_dict() | {"artifacts": arts},
    )

    # skip plan when enough
    skip = run_plan_loop(
        ticket_id="dry-rich",
        title="x",
        body="y",
        plan_needed=False,
    )
    add("plan_skip_when_enough", skip.approved and not skip.needed, skip.to_dict())

    # 3) merge policy matrix
    good_body = "## Wave\nRATING: low\nMIGRATION: no\nREVIEWER: codex-terra\nREVIEW_VERDICT: YES\n"
    merge_cases = [
        (
            "merge_low",
            {
                "body": good_body,
                "rating": "low",
                "primary_review": "codex",
                "primary_verdict": "YES",
                "challenge": {
                    "ran": True,
                    "verdict": "PASS",
                    "unresolved_blocker": False,
                    "worktree_modified": False,
                },
                "checks": [{"name": "Unit Tests", "bucket": "pass"}],
                "mergeable": "MERGEABLE",
                "rebase_attempts": 0,
            },
            "MERGE",
        ),
        (
            "hold_risky",
            {
                "body": good_body.replace("low", "risky"),
                "rating": "risky",
                "primary_review": "codex",
                "primary_verdict": "YES",
                "challenge": {"ran": True, "verdict": "PASS", "unresolved_blocker": False},
                "checks": [{"name": "Unit Tests", "bucket": "pass"}],
                "mergeable": "MERGEABLE",
            },
            "HOLD:",
        ),
        (
            "hold_challenge_blocker",
            {
                "body": good_body,
                "rating": "medium",
                "primary_review": "codex",
                "primary_verdict": "YES",
                "challenge": {
                    "ran": True,
                    "verdict": "FINDINGS",
                    "unresolved_blocker": True,
                    "summary": "RLS hole",
                },
                "checks": [{"name": "Unit Tests", "bucket": "pass"}],
                "mergeable": "MERGEABLE",
            },
            "HOLD:",
        ),
    ]
    for name, payload, expect_prefix in merge_cases:
        got = decide(payload)
        add(name, got.startswith(expect_prefix) or got == expect_prefix, {"got": got})

    # 4) auto_merge dry_run
    mr = evaluate_and_maybe_merge(
        repo="karch4162/sports-management",
        pr=477,
        rating="low",
        primary_review="opus",
        primary_verdict="YES",
        challenge={
            "ran": True,
            "verdict": "PASS",
            "unresolved_blocker": False,
            "worktree_modified": False,
        },
        dry_run=True,
        snapshot={
            "body": good_body,
            "checks": [{"name": "Unit Tests", "bucket": "pass"}, {"name": "Vercel", "bucket": "pass"}],
            "mergeable": "MERGEABLE",
            "url": "https://example.invalid/pr/477",
            "title": "dry",
            "number": 477,
        },
    )
    add("auto_merge_dry", mr.action == "dry_run" and mr.decision == "MERGE", mr.to_dict())

    # 5) daily cap + lock
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        (td_path / "autonomy").mkdir()
        ok1, _ = can_start("t1", 3, td_path)
        record_start("t1", td_path)
        record_start("t2", td_path)
        record_start("t3", td_path)
        ok4, why4 = can_start("t4", 3, td_path)
        lock = RunLock(td_path)
        got, _ = lock.acquire("dry")
        got2, why2 = lock.acquire("other")
        lock.release("dry")
        add(
            "daily_cap_and_lock",
            ok1 and (not ok4) and got and (not got2),
            {"why4": why4, "lock2": why2, "daily": load_daily(td_path).to_dict()},
        )

    # 6) budget guard unknown continues
    bud = check_budget(wave_dir=wave_dir, preflight_path=None, require_readable=False)
    add("budget_guard_unknown_ok", bud.ok and not bud.pause, bud.to_dict())

    # 7) grok verdict parse + dry challenge log
    v, blocker = parse_challenge_verdict("CHALLENGE VERDICT: PASS\n")
    fake = GrokResult(
        ok=True,
        rc=0,
        out="CHALLENGE VERDICT: PASS",
        why="PASS",
        worktree_modified=False,
        verdict="PASS",
        unresolved_blocker=False,
        timed_out=False,
    )
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        gr = run_grok_challenge(
            worktree=td_path,
            wave_dir=td_path,
            ticket_id="dry",
            dry_run_result=fake,
        )
        log = td_path / "autonomy" / "grok_calls.jsonl"
        add(
            "grok_challenge_dry",
            v == "PASS" and not blocker and gr.ok and log.exists(),
            {"verdict": v, "logged": log.exists()},
        )

    # 8) backlog_watch force-enabled with fake tickets
    class T:
        def __init__(self, id, name, tags, text):
            self.id = id
            self.name = name
            self.tags = tags
            self.text = text

    fake_tickets = [
        T(
            "86bcwdry1",
            "Rich low ticket",
            ["agent-ready", "rating:low"],
            (
                "In src/payments/refunds.ts:42 reverse_transfer must stay true.\n"
                "Acceptance: given a paid lesson, when cancelled, then price+tax refunded.\n"
                "Expected: unit test asserts refund_application_fee=false."
            ),
        ),
        T("86bcwdry2", "Risky cron", ["agent-ready", "rating:risky"], "cron GET vs POST"),
        T("86bcwdry3", "Thin", ["agent-ready", "rating:medium"], "fix it"),
    ]
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        # minimal config.env
        (td_path / "config.env").write_text(
            "WAVE_BACKLOG_WATCH=0\nWAVE_DAILY_TICKET_CAP=3\nWAVE_MAX_IMPLEMENT_WORKERS=3\n"
            "WAVE_CLICKUP_LIST=901422761393\nWAVE_BUDGET_GUARD=0\n",
            encoding="utf-8",
        )
        (td_path / "runs").mkdir()
        rep = run_watch(
            wave_dir=td_path,
            dry_run=True,
            execute=False,
            force_enabled=True,
            tickets=fake_tickets,
        )
        actions = {p.ticket_id: p.action for p in rep.picks}
        add(
            "backlog_watch_select",
            rep.ok
            and actions.get("86bcwdry1") == "spawn"
            and actions.get("86bcwdry3") == "plan_first"
            and any(r["id"] == "86bcwdry2" for r in rep.flagged_risky),
            rep.to_dict(),
        )

    out_path.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(results, indent=2))
    return 0 if results["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
