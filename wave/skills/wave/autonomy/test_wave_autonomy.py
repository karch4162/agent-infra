"""Tests for wave-autonomy modules.

Run: python .claude/wave/test_wave_autonomy.py
"""
from __future__ import annotations

import json
import time
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import auto_merge
import backlog_watch
import budget_guard
import daily_cap
import grok_challenge
import merge_policy
import model_roles
import plan_step
import ticket_sufficiency
from autonomy_config import load_autonomy_config


class Sufficiency(unittest.TestCase):
    def test_thin_needs_plan(self):
        r = ticket_sufficiency.assess_ticket(title="x", body="y", tags=["agent-ready"])
        self.assertTrue(r.plan_needed)
        self.assertFalse(r.enough)

    def test_plan_needed_tag(self):
        r = ticket_sufficiency.assess_ticket(
            title="Big feature with lots of text " * 5,
            body="src/a.ts:1\nAcceptance: given x when y then z",
            tags=["agent-ready", "PLAN_NEEDED"],
        )
        self.assertTrue(r.plan_needed)

    def test_rich_enough(self):
        r = ticket_sufficiency.assess_ticket(
            title="Refund lesson",
            body=(
                "Touch src/payments/refunds.ts:42.\n"
                "Acceptance: given paid lesson when cancel then refund price+tax.\n"
                "Expected: refund_application_fee false."
            ),
            tags=["agent-ready", "rating:low"],
        )
        self.assertTrue(r.enough)
        self.assertFalse(r.plan_needed)
        self.assertTrue(r.file_hits)

    def test_cited_prose_without_acceptance_wording_is_enough(self):
        r = ticket_sufficiency.assess_ticket(
            title="Rename the export button",
            body="The label in src/components/Toolbar.tsx:88 says Export; change it to Download. " + "x" * 20,
            tags=["agent-ready", "rating:low"],
        )
        self.assertTrue(r.enough)
        self.assertEqual(r.reasons, ())


class PlanStep(unittest.TestCase):
    def test_parse_decisions(self):
        self.assertEqual(
            plan_step.parse_plan_decision("PLAN_REVIEW_RESULT:\n  decision: PASS\n"),
            "PASS",
        )
        self.assertEqual(plan_step.parse_plan_decision("PLAN VERDICT: REVISE"), "FAIL")

    def test_required_sections(self):
        ok, missing = plan_step.plan_has_required_sections("# x\n## Files\n## Approach\n")
        self.assertFalse(ok)
        self.assertIn("Tests", missing)

    def test_loop_cap(self):
        def planner(_):
            return "## Files\na\n## Approach\nb\n## Tests\nc\n"

        def reviewer(_):
            return "PLAN VERDICT: REVISE"

        out = plan_step.run_plan_loop(
            ticket_id="t",
            title="t",
            body="",
            plan_needed=True,
            max_rounds=2,
            planner=planner,
            reviewer=reviewer,
        )
        self.assertFalse(out.approved)
        self.assertEqual(len(out.rounds), 2)
        self.assertIn("cap", out.hold_reason or "")

    def test_skip_when_not_needed(self):
        out = plan_step.run_plan_loop(
            ticket_id="t", title="t", body="", plan_needed=False
        )
        self.assertTrue(out.approved)
        self.assertFalse(out.needed)


class MergePolicy(unittest.TestCase):
    BODY = "## Wave\nRATING: low\nMIGRATION: no\nREVIEWER: codex-terra\n"

    def test_merge(self):
        d = merge_policy.decide(
            {
                "body": self.BODY,
                "rating": "low",
                "primary_review": "codex",
                "primary_verdict": "YES",
                "challenge": {
                    "ran": True,
                    "verdict": "PASS",
                    "unresolved_blocker": False,
                },
                "checks": [{"name": "Unit", "bucket": "pass"}],
                "mergeable": "MERGEABLE",
            }
        )
        self.assertEqual(d, "MERGE")

    def test_risky_hold(self):
        d = merge_policy.decide(
            {
                "body": self.BODY,
                "rating": "risky",
                "primary_review": "codex",
                "primary_verdict": "YES",
                "challenge": {"ran": True, "unresolved_blocker": False},
                "checks": [{"name": "Unit", "bucket": "pass"}],
                "mergeable": "MERGEABLE",
            }
        )
        self.assertTrue(d.startswith("HOLD"))

    def test_challenge_blocker(self):
        d = merge_policy.decide(
            {
                "body": self.BODY,
                "rating": "medium",
                "primary_review": "codex",
                "primary_verdict": "YES",
                "challenge": {
                    "ran": True,
                    "verdict": "FINDINGS",
                    "unresolved_blocker": True,
                    "summary": "x",
                },
                "checks": [{"name": "Unit", "bucket": "pass"}],
                "mergeable": "MERGEABLE",
            }
        )
        self.assertTrue(d.startswith("HOLD"))

    def test_notes_only_findings_may_merge(self):
        d = merge_policy.decide(
            {
                "body": self.BODY,
                "rating": "low",
                "primary_review": "codex",
                "primary_verdict": "YES",
                "challenge": {
                    "ran": True,
                    "verdict": "FINDINGS",
                    "unresolved_blocker": False,
                },
                "checks": [{"name": "Unit", "bucket": "pass"}],
                "mergeable": "MERGEABLE",
            }
        )
        self.assertEqual(d, "MERGE")

    def test_second_rebase_hold(self):
        d = merge_policy.decide(
            {
                "body": self.BODY,
                "rating": "low",
                "primary_review": "codex",
                "primary_verdict": "YES",
                "challenge": {"ran": True, "unresolved_blocker": False},
                "checks": [{"name": "Unit", "bucket": "pass"}],
                "mergeable": "CONFLICTING",
                "rebase_attempts": 1,
            }
        )
        self.assertTrue(d.startswith("HOLD"))


class Roles(unittest.TestCase):
    def test_low_codex_impl(self):
        a = model_roles.assign_roles("low")
        self.assertEqual(a.implementer, "codex")
        self.assertEqual(a.reviewer, "claude")

    def test_medium_opus_impl(self):
        a = model_roles.assign_roles("medium")
        self.assertEqual(a.implementer, "claude")
        self.assertEqual(a.reviewer, "codex")


class DailyCap(unittest.TestCase):
    def test_cap(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            self.assertTrue(daily_cap.can_start("a", 2, p)[0])
            daily_cap.record_start("a", p)
            daily_cap.record_start("b", p)
            ok, why = daily_cap.can_start("c", 2, p)
            self.assertFalse(ok)
            self.assertIn("cap", why)


class Budget(unittest.TestCase):
    def test_claude_threshold(self):
        import os
        from unittest import mock

        with tempfile.TemporaryDirectory() as td:
            with mock.patch.dict(os.environ, {"WAVE_CLAUDE_WEEKLY_PCT": "90"}):
                snap = budget_guard.check_budget(wave_dir=Path(td), require_readable=False)
                self.assertTrue(snap.pause)
                self.assertFalse(snap.ok)


class GrokParse(unittest.TestCase):
    def test_pass(self):
        v, b = grok_challenge.parse_challenge_verdict("CHALLENGE VERDICT: PASS")
        self.assertEqual(v, "PASS")
        self.assertFalse(b)

    def test_findings_blocker(self):
        v, b = grok_challenge.parse_challenge_verdict(
            "BLOCKER: rls\nCHALLENGE VERDICT: FINDINGS"
        )
        self.assertEqual(v, "FINDINGS")
        self.assertTrue(b)


class BacklogWatch(unittest.TestCase):
    def test_off_by_default(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            (p / "config.env").write_text("WAVE_BACKLOG_WATCH=0\n", encoding="utf-8")
            rep = backlog_watch.run_watch(wave_dir=p, dry_run=True)
            self.assertFalse(rep.enabled)
            self.assertTrue(rep.ok)

    def test_selects_and_flags(self):
        class T:
            def __init__(self, id, name, tags, text):
                self.id, self.name, self.tags, self.text = id, name, tags, text

        rich = (
            "File src/a.ts:10.\nAcceptance: given a when b then c.\n"
            "Expected: test asserts behavior."
        )
        tickets = [
            T("1", "low rich", ["agent-ready", "rating:low"], rich),
            T("2", "risky", ["agent-ready", "rating:risky"], rich),
            T("3", "thin", ["agent-ready", "rating:medium"], "fix"),
        ]
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            (p / "config.env").write_text(
                "WAVE_BACKLOG_WATCH=1\nWAVE_DAILY_TICKET_CAP=3\n"
                "WAVE_MAX_IMPLEMENT_WORKERS=3\nWAVE_BUDGET_GUARD=0\n"
                "WAVE_CLICKUP_LIST=1\n",
                encoding="utf-8",
            )
            (p / "runs").mkdir()
            rep = backlog_watch.run_watch(
                wave_dir=p, dry_run=True, force_enabled=True, tickets=tickets
            )
            self.assertTrue(rep.ok)
            by = {x.ticket_id: x.action for x in rep.picks}
            self.assertEqual(by["1"], "spawn")
            self.assertEqual(by["3"], "plan_first")
            self.assertEqual(rep.flagged_risky[0]["id"], "2")


class Config(unittest.TestCase):
    def test_state_names_come_from_config_env(self):
        # The tick runs from a scheduler: an env-only read left every tracker
        # status transition as None. The loader must carry them.
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "config.env"
            p.write_text(
                "WAVE_STATE_START='in progress'\nWAVE_STATE_DONE=completed\nWAVE_QUEUE_STATUS=todo\n",
                encoding="utf-8",
            )
            cfg = load_autonomy_config(p)
            self.assertEqual(cfg.state_start, "in progress")
            self.assertEqual(cfg.state_done, "completed")
            self.assertEqual(cfg.queue_status, "todo")
            self.assertEqual(cfg.clickup_list, "")  # no repo ids baked into the plugin

    def test_defaults_off(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = load_autonomy_config(Path(td) / "missing.env")
            self.assertFalse(cfg.backlog_watch)
            self.assertEqual(cfg.daily_ticket_cap, 3)


class AutoMergeDry(unittest.TestCase):
    def test_dry_merge(self):
        body = "## Wave\nRATING: low\nMIGRATION: no\nREVIEWER: codex\n"
        mr = auto_merge.evaluate_and_maybe_merge(
            repo="karch4162/sports-management",
            pr=1,
            rating="low",
            primary_review="codex",
            primary_verdict="YES",
            challenge={"ran": True, "verdict": "PASS", "unresolved_blocker": False},
            dry_run=True,
            snapshot={
                "body": body,
                "checks": [{"name": "Unit", "bucket": "pass"}],
                "mergeable": "MERGEABLE",
                "number": 1,
            },
        )
        self.assertEqual(mr.action, "dry_run")
        self.assertEqual(mr.decision, "MERGE")




class FailClosedR1(unittest.TestCase):
    BODY = "## Wave\nRATING: low\nMIGRATION: no\nREVIEWER: codex-terra\n"

    def test_empty_primary_verdict_holds(self):
        d = merge_policy.decide(
            {
                "body": self.BODY,
                "rating": "low",
                "primary_review": "codex",
                "primary_verdict": "",
                "challenge": {"ran": True, "verdict": "PASS", "unresolved_blocker": False},
                "checks": [{"name": "Unit", "bucket": "pass"}],
                "mergeable": "MERGEABLE",
            }
        )
        self.assertTrue(d.startswith("HOLD"))

    def test_challenge_timeout_holds(self):
        d = merge_policy.decide(
            {
                "body": self.BODY,
                "rating": "low",
                "primary_review": "codex",
                "primary_verdict": "YES",
                "challenge": {
                    "ran": True,
                    "verdict": "TIMEOUT",
                    "timed_out": True,
                    "unresolved_blocker": False,
                },
                "checks": [{"name": "Unit", "bucket": "pass"}],
                "mergeable": "MERGEABLE",
                "require_challenge": True,
            }
        )
        self.assertTrue(d.startswith("HOLD"))

    def test_plan_rounds_clamped(self):
        n = {"i": 0}

        def planner(_):
            n["i"] += 1
            return "## Files\na\n## Approach\nb\n## Tests\nc\n"

        def reviewer(_):
            return "PLAN VERDICT: REVISE"

        out = plan_step.run_plan_loop(
            ticket_id="t",
            title="t",
            body="",
            plan_needed=True,
            max_rounds=99,
            planner=planner,
            reviewer=reviewer,
        )
        self.assertEqual(len(out.rounds), 2)

    def test_execute_refused_when_watch_off(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            (p / "config.env").write_text("WAVE_BACKLOG_WATCH=0\n", encoding="utf-8")
            rep = backlog_watch.run_watch(
                wave_dir=p, dry_run=False, execute=True, force_enabled=True
            )
            self.assertFalse(rep.execute)
            self.assertFalse(rep.ok)


class RunLockAtomic(unittest.TestCase):
    def test_second_acquire_fails(self):
        from daily_cap import RunLock
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            a = RunLock(d)
            ok, _ = a.acquire("a")
            self.assertTrue(ok)
            b = RunLock(d)
            ok2, reason = b.acquire("b")
            self.assertFalse(ok2)
            self.assertIn("held", reason)
            a.release("a")
            ok3, _ = b.acquire("b")
            self.assertTrue(ok3)
            b.release("b")

    def test_release_allows_reacquire(self):
        from daily_cap import RunLock
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            a = RunLock(d)
            self.assertTrue(a.acquire("a")[0])
            a.release("a")
            b = RunLock(d)
            ok, reason = b.acquire("b")
            self.assertTrue(ok, reason)
            b.release("b")

    def test_same_process_double_acquire_rejected(self):
        from daily_cap import RunLock
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            a = RunLock(d)
            self.assertTrue(a.acquire("a")[0])
            ok2, reason = a.acquire("a2")
            self.assertFalse(ok2)
            self.assertIn("already held", reason)
            a.release("a")



    def test_multiprocess_contention(self):
        """Two processes: exactly one holds the advisory lock (Windows byte-0 fix)."""
        import subprocess
        import sys
        from daily_cap import RunLock
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            a = RunLock(d)
            ok, _ = a.acquire("parent")
            self.assertTrue(ok)
            helper = Path(__file__).resolve().parent / "_mp_lock_child.py"
            proc = subprocess.run(
                [sys.executable, str(helper), str(d)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            out = (proc.stdout or "").strip().splitlines()
            self.assertGreaterEqual(len(out), 1, proc.stdout)
            self.assertEqual(out[0], "HELD", proc.stdout)
            a.release("parent")
            proc2 = subprocess.run(
                [sys.executable, str(helper), str(d)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(proc2.returncode, 0, proc2.stderr)
            out2 = (proc2.stdout or "").strip().splitlines()
            self.assertEqual(out2[0], "OK", proc2.stdout)





class Phase1Fixes(unittest.TestCase):
    """Regressions from the 2026-11-02 review of the autonomy branch."""

    RICH = "File src/a.ts:10.\nAcceptance: given a when b then c.\n"

    def _tickets(self, n):
        return [
            {"id": f"t{i}", "name": "x", "tags": ["agent-ready", "rating:low"], "text": self.RICH}
            for i in range(n)
        ]

    def _cfg(self, p, extra=""):
        (p / "config.env").write_text(
            "WAVE_BACKLOG_WATCH=1\nWAVE_DAILY_TICKET_CAP=3\nWAVE_MAX_IMPLEMENT_WORKERS=3\n"
            "WAVE_BUDGET_GUARD=0\nWAVE_CLICKUP_LIST=1\n" + extra,
            encoding="utf-8",
        )

    def test_one_pass_never_picks_past_daily_cap(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            self._cfg(p)
            daily_cap.record_start("a1", p)
            daily_cap.record_start("a2", p)
            rep = backlog_watch.run_watch(wave_dir=p, dry_run=True, force_enabled=True, tickets=self._tickets(5))
            self.assertEqual(len(rep.picks), 1, [x.ticket_id for x in rep.picks])

    def test_dead_running_worker_does_not_hold_a_slot(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            self._cfg(p, "WAVE_MAX_IMPLEMENT_WORKERS=1\n")
            run = p / "runs" / "dead"
            run.mkdir(parents=True)
            (run / "status.json").write_text(json.dumps({"state": "running", "pid": 999999}), encoding="utf-8")
            rep = backlog_watch.run_watch(wave_dir=p, dry_run=True, force_enabled=True, tickets=self._tickets(1))
            self.assertEqual(len(rep.picks), 1)
            import os

            (run / "status.json").write_text(json.dumps({"state": "running", "pid": os.getpid()}), encoding="utf-8")
            rep = backlog_watch.run_watch(wave_dir=p, dry_run=True, force_enabled=True, tickets=self._tickets(1))
            self.assertEqual(len(rep.picks), 0)

    def test_record_starts_false_leaves_cap_untouched(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            self._cfg(p)
            rep = backlog_watch.run_watch(
                wave_dir=p, dry_run=False, execute=True, tickets=self._tickets(2), record_starts=False
            )
            self.assertTrue(rep.execute)
            self.assertEqual(daily_cap.load_daily(p).started, [])
            self.assertTrue((p / "autonomy" / "pending_spawns.jsonl").exists())

    def test_pid_alive_is_not_a_substring_match(self):
        import os
        from worker_runtime import pid_alive

        self.assertTrue(pid_alive(os.getpid()))
        self.assertFalse(pid_alive(999999))
        self.assertFalse(pid_alive(0))

    def test_sufficiency_ignores_abbreviations_domains_versions(self):
        r = ticket_sufficiency.assess_ticket(
            title="Tweak copy",
            body="Change the wording, e.g. friendlier; see sportify-360.com and v2.0. "
            "It should show a nicer message. " + "x" * 20,
        )
        self.assertEqual(r.file_hits, ())
        self.assertTrue(r.plan_needed)
        r = ticket_sufficiency.assess_ticket(
            title="Fix", body="See app/api/foo/route.ts:12 and calendar-grid.tsx. Expected: 404. " + "x" * 20
        )
        self.assertEqual(r.file_hits, ("app/api/foo/route.ts", "calendar-grid.tsx"))
        self.assertTrue(r.enough)

    def test_ci_classify_counts_every_reported_check(self):
        import ci_wait

        self.assertEqual(ci_wait.classify({}), "pending")
        self.assertEqual(ci_wait.classify({"Unit Tests": "SUCCESS", "RLS Regression Tests": "FAILURE"}), "failed")
        self.assertEqual(ci_wait.classify({"Unit Tests": "SUCCESS", "Vercel": "SUCCESS"}), "green")
        self.assertEqual(ci_wait.classify({"Unit Tests": "IN_PROGRESS"}), "pending")

    def test_merge_policy_reads_review_verdict_with_space(self):
        body = "## Wave\nTIER: quick\nREVIEWER: codex-terra\nREVIEW VERDICT: YES\nMIGRATION: no\n"
        d = {"body": body, "rating": "low", "checks": [{"name": "Unit Tests", "bucket": "pass"}],
             "mergeable": "MERGEABLE", "challenge": {"ran": True, "verdict": "PASS", "unresolved_blocker": False},
             "require_challenge": True}
        self.assertEqual(merge_policy.decide(d), "MERGE")
        d2 = dict(d, body=body + "TIE-BREAKER: astra (diff)\n")
        self.assertTrue(merge_policy.decide(d2).startswith("HOLD: TIE-BREAKER"))
        d3 = dict(d, body=body.replace("REVIEWER: codex-terra", "REVIEWER: grok-fallback (codex quota exhausted)"))
        self.assertTrue(merge_policy.decide(d3).startswith("HOLD: primary reviewer was a fallback"))

    def test_budget_check_writes_nothing(self):
        import os
        from unittest import mock

        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            with mock.patch.dict(os.environ, {"WAVE_CLAUDE_WEEKLY_PCT": "90"}):
                snap = budget_guard.check_budget(wave_dir=p, require_readable=False)
            self.assertTrue(snap.pause)
            self.assertFalse((p / "autonomy" / "daily_cap.json").exists())
            self.assertFalse((p / "autonomy" / "mason_notice.md").exists())

    def test_grok_double_timeout_blocks(self):
        import subprocess
        from unittest import mock

        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            with mock.patch.object(grok_challenge, "_resolve_grok_bin", return_value="grok"), \
                 mock.patch.object(grok_challenge, "write_review_diff", return_value=p / "d"), \
                 mock.patch.object(grok_challenge, "worktree_fingerprint", return_value="same"), \
                 mock.patch.object(grok_challenge.subprocess, "run",
                                   side_effect=subprocess.TimeoutExpired(cmd="grok", timeout=1)):
                r = grok_challenge.run_grok_challenge(worktree=p, wave_dir=p, ticket_id="t", timeout_s=1)
            self.assertTrue(r.timed_out)
            self.assertFalse(r.ok)
            self.assertTrue(r.unresolved_blocker)
            self.assertTrue(merge_policy.decide({
                "body": "## Wave\nREVIEWER: codex-terra\nREVIEW VERDICT: YES\nMIGRATION: no\n",
                "rating": "low", "checks": [{"name": "u", "bucket": "pass"}], "mergeable": "MERGEABLE",
                "challenge": r.to_challenge_dict(), "require_challenge": True,
            }).startswith("HOLD: challenge review timed out"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
