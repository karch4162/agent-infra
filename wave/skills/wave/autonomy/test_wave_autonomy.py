"""Tests for wave-autonomy modules.

Run: python .claude/wave/test_wave_autonomy.py
"""
from __future__ import annotations

import contextlib
import io
import json
from datetime import datetime, timezone
import os
import subprocess
import time
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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


class SpawnPreflightLoad(unittest.TestCase):
    def test_dataclass_module_loads_from_file(self):
        """preflight.py is loaded by path; @dataclass with string annotations needs the
        module in sys.modules first (Python 3.14 crashed every direct spawn without it)."""
        import importlib.util
        from unittest import mock

        import worker_runtime

        with tempfile.TemporaryDirectory() as d:
            fake = Path(d) / "preflight.py"
            fake.write_text(
                "from __future__ import annotations\n"
                "from dataclasses import dataclass\n"
                "@dataclass\n"
                "class R:\n"
                "    ok: bool\n"
                "    def to_dict(self):\n"
                "        return {'ok': self.ok, 'checks': []}\n"
                "def run_preflight(repo):\n"
                "    return R(True)\n",
                encoding="utf-8",
            )
            real = importlib.util.spec_from_file_location
            with mock.patch.object(importlib.util, "spec_from_file_location",
                                   lambda name, _path: real(name, fake)):
                self.assertTrue(worker_runtime.run_spawn_preflight(Path(d))["ok"])


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

    def test_template_plan_fails_without_review(self):
        reviews = []
        seen = []

        def planner(ctx):
            seen.append(ctx)
            return plan_step.scaffold_plan("t", "t") if len(seen) == 1 else (
                "## Files\na.ts:1\n## Approach\nb\n## Tests\nc\n")

        def reviewer(plan):
            reviews.append(plan)
            return "PLAN VERDICT: APPROVE"

        out = plan_step.run_plan_loop(ticket_id="t", title="t", body="", plan_needed=True,
                                      max_rounds=2, planner=planner, reviewer=reviewer)
        self.assertEqual(out.rounds[0].decision, "FAIL")
        self.assertEqual(len(reviews), 1)  # only the filled round-two plan was reviewed
        self.assertIn("placeholder", seen[1])
        self.assertTrue(out.approved)

    def test_round_two_planner_sees_review(self):
        seen = []

        def planner(ctx):
            seen.append(ctx)
            return "## Files\na\n## Approach\nb\n## Tests\nc\n"

        def reviewer(_):
            return "Tests section names no assertion.\nPLAN VERDICT: REVISE"

        plan_step.run_plan_loop(
            ticket_id="t", title="t", body="", plan_needed=True, max_rounds=2,
            planner=planner, reviewer=reviewer,
        )
        self.assertEqual(len(seen), 2)
        self.assertNotIn("Reviewer feedback", seen[0])
        self.assertIn("Reviewer feedback (round 1", seen[1])
        self.assertIn("names no assertion", seen[1])

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
                wave_dir=p, dry_run=True, force_enabled=True, tickets=tickets, trigger="owner"
            )
            self.assertTrue(rep.ok)
            by = {x.ticket_id: x.action for x in rep.picks}
            self.assertEqual(by["1"], "spawn")
            self.assertEqual(by["3"], "plan_first")
            self.assertEqual(rep.flagged_risky[0]["id"], "2")


class JiraPicking(unittest.TestCase):
    """INNOV-440: the picker reads a Jira repo's WAVE_QUEUE through acli."""

    RICH = "File src/a.ts:10.\nAcceptance: given a when b then c.\nExpected: test asserts behavior."

    def _item(self, key, labels, assignee=None):
        doc = {"type": "doc", "content": [{"type": "paragraph", "content": [{"type": "text", "text": line}]}
                                          for line in self.RICH.split("\n")]}
        return {"key": key, "fields": {"summary": key, "status": {"name": "To Do"}, "labels": labels,
                                       "assignee": {"displayName": assignee} if assignee else None,
                                       "description": doc}}

    def test_jira_queue_feeds_the_picker(self):
        import subprocess
        import jira_tracker
        items = [self._item("INNOV-1", ["agent-ready", "rating:low"]),
                 self._item("INNOV-2", ["agent-ready", "rating:low"], assignee="Mike"),
                 self._item("INNOV-3", ["rating:low"])]
        calls = []

        def fake(args):
            calls.append(args)
            return subprocess.CompletedProcess(args, 0, json.dumps(items), "")

        with tempfile.TemporaryDirectory() as td, mock.patch.object(jira_tracker, "_run", fake):
            p = Path(td)
            (p / "config.env").write_text(
                "WAVE_BACKLOG_WATCH=1\nWAVE_BUDGET_GUARD=0\nWAVE_TRACKER=jira\n"
                "WAVE_QUEUE='project = INNOV AND labels = agent-ready'\nWAVE_JIRA_SITE=x.atlassian.net\n",
                encoding="utf-8")
            with mock.patch.dict(os.environ, {"WAVE_TRACKER": "", "WAVE_QUEUE": ""}):
                rep = backlog_watch.run_watch(wave_dir=p, dry_run=True, force_enabled=True)
        self.assertIn("project = INNOV AND labels = agent-ready", calls[0])
        self.assertEqual([x.ticket_id for x in rep.picks], ["INNOV-1"])        # INNOV-3 lacks agent-ready
        self.assertIn({"id": "INNOV-2", "reason": "assigned to Mike"}, rep.skipped)

    def test_adf_description_becomes_text(self):
        import jira_tracker
        self.assertEqual(jira_tracker.adf_text(self._item("K", [])["fields"]["description"]).strip(), self.RICH)


class SpendCap(unittest.TestCase):
    """INNOV-441: per-day spend from worker.log (direct) and priced session logs (Orca)."""

    def test_price_table(self):
        import run_spend
        u = {"output_tokens": 1_000_000, "cache_creation_input_tokens": 1_000_000,
             "cache_creation": {"ephemeral_1h_input_tokens": 1_000_000}}
        self.assertEqual(run_spend.claude_usd("claude-opus-5-5", u), 28)   # $20 output + $8 1-hour write
        self.assertIsNone(run_spend.claude_usd("gpt-9", u))

    def _setup(self, p, home):
        import daily_cap
        direct = p / "runs" / "innov-1"
        direct.mkdir(parents=True)
        (direct / "status.json").write_text(json.dumps({"agent": "claude", "runtime": "direct"}), encoding="utf-8")
        (direct / "worker.log").write_text('{"type":"result","total_cost_usd":3.5}\n', encoding="utf-8")
        orca = p / "runs" / "innov-2"
        orca.mkdir(parents=True)
        wt = "C:/wt/innov-2"
        (orca / "status.json").write_text(json.dumps({"agent": "claude", "runtime": "orca", "path": wt}), encoding="utf-8")
        proj = home / ".claude" / "projects" / "C--wt-innov-2"
        proj.mkdir(parents=True)
        msg = {"type": "assistant", "requestId": "r1", "message": {"id": "m1", "model": "claude-opus-5-5",
                                                                   "usage": {"output_tokens": 50_000}}}
        (proj / "s.jsonl").write_text(json.dumps(msg) + "\n" + json.dumps(msg) + "\n", encoding="utf-8")  # repeated: count once
        daily_cap.record_start("INNOV-1", p)
        daily_cap.record_start("INNOV-2", p)

    def test_spend_today_and_the_gate(self):
        import run_spend
        with tempfile.TemporaryDirectory() as td:
            p, home = Path(td) / "wave", Path(td) / "home"
            self._setup(p, home)
            with mock.patch.object(Path, "home", return_value=home), mock.patch.dict(os.environ, {"USERPROFILE": str(home), "HOME": str(home)}):
                self.assertEqual(run_spend.spend_today(p), 4.5)   # 3.5 from worker.log + 1.0 (50k out at $20/M)
                self.assertEqual(json.loads((p / "runs" / "innov-2" / "usage.json").read_text())["cost_source"], "session logs")
                (p / "config.env").write_text("WAVE_BACKLOG_WATCH=1\nWAVE_BUDGET_GUARD=0\nWAVE_DAILY_TICKET_CAP=9\n"
                                              "WAVE_BUDGET_PER_DAY_USD=6\n", encoding="utf-8")
                tickets = [{"id": f"t{i}", "name": "x", "tags": ["agent-ready", "rating:low"],
                            "text": "File src/a.ts:10.\nAcceptance: given a when b then c.\nExpected: test asserts behavior."}
                           for i in range(3)]
                rep = backlog_watch.run_watch(wave_dir=p, dry_run=True, force_enabled=True, tickets=tickets)
        self.assertEqual(len(rep.picks), 0)   # $4.50 spent + ~$2.25/run would cross $6
        self.assertTrue(any(n.startswith("spend cap: $4.50 of $6.00") for n in rep.notices), rep.notices)


class WaveRun(unittest.TestCase):
    """INNOV-443: one firing = one tick per allowlisted repo under machine-wide caps."""

    def _control(self, td, extra=""):
        import daily_cap
        root = Path(td)
        repos = []
        for name, spent in (("a", 30.0), ("b", 0.0)):
            r = root / name
            (r / ".claude" / "wave" / "runs").mkdir(parents=True)
            (r / ".claude" / "wave" / "config.env").write_text("WAVE_TRACKER=jira\n", encoding="utf-8")
            if spent:   # repo a: one live direct worker, started today, that has cost $30
                run = r / ".claude" / "wave" / "runs" / "t1"
                run.mkdir()
                (run / "status.json").write_text(json.dumps({"state": "running", "pid": os.getpid(), "agent": "claude"}), encoding="utf-8")
                (run / "worker.log").write_text(json.dumps({"total_cost_usd": spent}) + "\n", encoding="utf-8")
                daily_cap.record_start("T1", r / ".claude" / "wave")
            repos.append(r)
        control = root / "control"
        control.mkdir()
        (control / "config.env").write_text(
            f"WAVE_CONTROL_REPOS={repos[0]};{repos[1]};{root / 'missing'}\nMAX_WORKERS=3\nDAILY_TICKET_CAP=3\n"
            "BUDGET_PER_DAY=100\nCLAUDE_PAUSE_PCT=70\n" + extra, encoding="utf-8")
        return control, repos

    def _ctl(self, control, tick):
        import wave_run
        return wave_run.Control(wave_run.Config(control), tick=tick)

    def test_gates(self):
        with tempfile.TemporaryDirectory() as td, contextlib.redirect_stdout(io.StringIO()):
            control, _ = self._control(td)
            ctl = self._ctl(control, lambda *a: self.fail("must not tick"))
            self.assertEqual(ctl.run("scheduled"), 3)        # SCHEDULE_WAVE empty
            self.assertEqual(ctl.run("bogus"), 2)
            (control / "STOP").write_text("", encoding="utf-8")
            self.assertEqual(ctl.precheck("owner"), 3)

    def test_each_repo_gets_what_the_machine_has_left(self):
        seen = {}

        def tick(repo, trigger, env):
            seen[repo.name] = env
            if repo.name == "a":   # repo a's tick starts a worker: this firing is a wave
                (repo / ".claude" / "wave" / "autonomy").mkdir(exist_ok=True)
                (repo / ".claude" / "wave" / "autonomy" / "tick-last.json").write_text(json.dumps(
                    {"ts": datetime.now(timezone.utc).isoformat(), "events": [{"ticket": "X", "event": "spawned"}]}), encoding="utf-8")
            return 0, [], ""

        with tempfile.TemporaryDirectory() as td, contextlib.redirect_stdout(io.StringIO()):
            control, _ = self._control(td, "SCHEDULE_WAVE=0 10 * * *\nMAX_WAVES_PER_DAY=1\n")
            ctl = self._ctl(control, tick)
            self.assertEqual(ctl.run("scheduled"), 0)
            self.assertEqual(ctl.run("scheduled"), 3)        # MAX_WAVES_PER_DAY=1 used up
            audit = [json.loads(l) for l in (control / "state" / "audit.jsonl").read_text(encoding="utf-8").splitlines()]
        # 1 live worker of 3, 1 start of 3 and $30 of $100 used machine-wide.
        self.assertEqual((seen["a"]["WAVE_MAX_IMPLEMENT_WORKERS"], seen["b"]["WAVE_MAX_IMPLEMENT_WORKERS"]), ("3", "2"))
        self.assertEqual((seen["a"]["WAVE_DAILY_TICKET_CAP"], seen["b"]["WAVE_DAILY_TICKET_CAP"]), ("3", "2"))
        self.assertEqual((float(seen["a"]["WAVE_BUDGET_PER_DAY_USD"]), float(seen["b"]["WAVE_BUDGET_PER_DAY_USD"])), (100.0, 70.0))
        self.assertEqual(seen["a"]["WAVE_CLAUDE_PAUSE_PCT"], "70")
        self.assertEqual([r["stage"] for r in audit][:5], ["start", "tick", "tick", "repo", "end"])

    def test_ticks_that_start_nothing_are_not_waves(self):
        with tempfile.TemporaryDirectory() as td, contextlib.redirect_stdout(io.StringIO()):
            control, _ = self._control(td, "MAX_WAVES_PER_DAY=1\n")
            ctl = self._ctl(control, lambda *a: (0, [], ""))
            for _ in range(3):   # CI/merge-only ticks: no worker started, no wave used
                self.assertEqual(ctl.run("owner"), 0)
            self.assertEqual(ctl.waves_today(), [])

    def test_failed_tick_escalates_and_cools_down(self):
        with tempfile.TemporaryDirectory() as td, contextlib.redirect_stdout(io.StringIO()):
            control, _ = self._control(td, "SCHEDULE_WAVE=0 10 * * *\n")
            ctl = self._ctl(control, lambda repo, t, e: (0, ["closeout failed (rc=1)"] if repo.name == "a" else [], ""))
            self.assertEqual(ctl.run("scheduled"), 1)
            self.assertIn("closeout failed", (control / "state" / "escalations.md").read_text(encoding="utf-8"))
            ticked = []
            ctl.tick = lambda repo, t, e: ticked.append(repo.name) or (0, [], "")
            ctl.run("scheduled")
        self.assertEqual(ticked, ["b"])                      # a is cooling down

    def test_every_spawn_failing_fails_the_firing(self):
        # Hub demo 2026-11-16: an hour of firings picked tickets, spawned none, and said ok.
        import wave_run
        fail = "ENT-1: spawn failed: spawn.sh DRY_RUN failed: line 27: Beard: command not found\n"
        with tempfile.TemporaryDirectory() as td, contextlib.redirect_stdout(io.StringIO()):
            control, _ = self._control(td, "")
            ctl = self._ctl(control, lambda repo, t, e: (0, [fail] if repo.name == "a" else [], ""))
            self.assertEqual(ctl.run("owner"), 1)
            esc = (control / "state" / "escalations.md").read_text(encoding="utf-8")
            self.assertIn("no worker started; ENT-1: spawn failed", esc)
            # one failure beside a started worker is a notice, not a failed firing
            with mock.patch.object(wave_run, "spawned_since", lambda repo, t0: ["ENT-2"]):
                self.assertEqual(ctl.run("owner"), 0)

    def test_statusline_weekly_pct(self):
        import budget_guard
        with tempfile.TemporaryDirectory() as td:
            f = Path(td) / "rate-limits.json"
            f.write_text(json.dumps({"ts": time.time() * 1000, "rate_limits": {"seven_day": {"used_percentage": 72}}}), encoding="utf-8")
            self.assertEqual(budget_guard._claude_weekly_from_statusline(f), "72")
            f.write_text(json.dumps({"ts": (time.time() - 7 * 3600) * 1000, "rate_limits": {"seven_day": {"used_percentage": 72}}}), encoding="utf-8")
            self.assertEqual(budget_guard._claude_weekly_from_statusline(f), "")   # stale is not headroom


class TickIgnoresWalkers(unittest.TestCase):
    def test_walk_runs_are_not_tickets(self):
        # INNOV-446: walker runs share runs/ but have no PR; the tick reported each as "exited without a PR".
        import autonomy_tick
        with tempfile.TemporaryDirectory() as td, mock.patch.dict(os.environ, {}):
            runs = Path(td) / ".claude" / "wave" / "runs"
            for name in ("innov-1", "walk-2026-11-11"):
                (runs / name).mkdir(parents=True)
                (runs / name / "status.json").write_text(json.dumps({"state": "running"}), encoding="utf-8")
            (runs.parent / "config.env").write_text("WAVE_TRACKER=jira\n", encoding="utf-8")
            tick = autonomy_tick.Tick(repo=Path(td), execute=False, log=lambda m: None)
            self.assertEqual([p.parent.name for p, _ in tick.statuses()], ["innov-1"])


    def test_held_pr_merged_by_a_human_is_closed_out_and_swept(self):
        # Hub demo 2026-11-17: three held PRs merged by hand stayed done_held forever;
        # nothing ran closeout or removed their worktrees.
        import autonomy_tick
        with tempfile.TemporaryDirectory() as td, mock.patch.dict(os.environ, {}):
            runs = Path(td) / ".claude" / "wave" / "runs"
            (runs.parent / "config.env").parent.mkdir(parents=True)
            (runs.parent / "config.env").write_text("WAVE_TRACKER=jira\n", encoding="utf-8")
            wts = {}
            for name, n in (("ent-1", 1), ("ent-2", 2)):
                (runs / name).mkdir(parents=True)
                wts[name] = Path(td) / "wt" / name
                wts[name].mkdir(parents=True)
                (runs / name / "status.json").write_text(json.dumps({
                    "ticket_id": name.upper(), "state": "done_held", "pr": f"u/{n}", "pr_number": n,
                    "runtime": "orca", "path": str(wts[name])}), encoding="utf-8")
            removed = []

            def sh(args, cwd, **kw):
                out = ""
                if args[:3] == ["gh", "pr", "view"]:
                    out = json.dumps({"state": "MERGED", "mergeCommit": {"oid": "abc" + args[3]}})
                elif args[:2] == ["git", "status"] and Path(cwd).name == "ent-2":
                    out = " M dirty.ts"
                return subprocess.CompletedProcess(args, 0, out, "")

            def orca(args):
                removed.append(args[3])
                return subprocess.CompletedProcess(args, 0, "{}", "")

            with mock.patch.object(autonomy_tick, "_sh", sh), mock.patch.object(autonomy_tick, "_orca", orca):
                tick = autonomy_tick.Tick(repo=Path(td), execute=True, log=lambda m: None)
                tick._slug = "o/r"
                tick.track = lambda *a, **k: None
                tick.reconcile()
                tick.sweep()
            self.assertEqual(tick.merged_this_tick, ["ENT-1", "ENT-2"])
            self.assertEqual(tick.merged_shas, ["abc1", "abc2"])
            self.assertEqual(removed, ["name:ent-1"])  # the dirty worktree stays
            st1 = json.loads((runs / "ent-1" / "status.json").read_text(encoding="utf-8"))
            st2 = json.loads((runs / "ent-2" / "status.json").read_text(encoding="utf-8"))
            self.assertEqual(st1["state"], "done_merged")
            self.assertTrue(st1.get("swept"))
            self.assertTrue(st2.get("sweep_blocked"))
            self.assertIn("uncommitted", tick.report["notices"][0])


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

    def _medium(self, td, env):
        body = "## Wave\nRATING: medium\nMIGRATION: no\nREVIEWER: codex\n"
        with mock.patch.dict(os.environ, {"WAVE_REPO": td, **env}):
            return auto_merge.evaluate_and_maybe_merge(
                repo="r/r", pr=1, rating="medium", primary_review="codex", primary_verdict="YES",
                challenge={"ran": True, "verdict": "PASS", "unresolved_blocker": False}, dry_run=True,
                snapshot={"body": body, "checks": [{"name": "Unit", "bucket": "pass"}], "mergeable": "MERGEABLE", "number": 1})

    def test_medium_needs_switch_and_streak(self):
        # INNOV-439: medium auto-merges only with the owner's switch AND N clean waves; a red closeout resets it.
        with tempfile.TemporaryDirectory() as td:
            wd = Path(td) / ".claude" / "wave"
            on = {"WAVE_AUTO_MERGE_MEDIUM": "1", "WAVE_CLEAN_WAVES_FOR_MEDIUM": "2"}
            self.assertEqual(self._medium(td, {}).action, "held")
            auto_merge.record_closeout(wd, True)
            self.assertEqual(self._medium(td, on).action, "held")   # streak 1 < 2
            auto_merge.record_closeout(wd, True)
            self.assertEqual(self._medium(td, on).decision, "MERGE")
            auto_merge.record_closeout(wd, False)
            self.assertEqual(auto_merge.clean_streak(wd), 0)
            self.assertEqual(self._medium(td, on).action, "held")




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

    def test_scheduled_takes_low_only_and_never_guesses_a_rating(self):
        # INNOV-439: unrated is not READY; medium waits for an owner wave.
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            self._cfg(p)
            t = self._tickets(3)
            t[1]["tags"] = ["agent-ready", "rating:medium"]
            t[2]["tags"] = ["agent-ready"]
            rep = backlog_watch.run_watch(wave_dir=p, dry_run=True, force_enabled=True, tickets=t)
            self.assertEqual([x.ticket_id for x in rep.picks], ["t0"])
            reasons = {x["id"]: x["reason"] for x in rep.skipped}
            self.assertEqual(reasons["t1"], "medium: owner waves only")
            self.assertTrue(reasons["t2"].startswith("unrated"))
            rep = backlog_watch.run_watch(wave_dir=p, dry_run=True, force_enabled=True, tickets=t, trigger="owner")
            self.assertEqual(sorted(x.ticket_id for x in rep.picks), ["t0", "t1"])

    def test_tickets_assigned_to_the_wave_owner_stay_pickable(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            self._cfg(p, "WAVE_SELF=Mason Beard\nWAVE_CODEX_IMPLEMENTS_LOW=0\n")
            tickets = self._tickets(2)
            tickets[0]["assignees"] = ["mason beard"]
            tickets[1]["assignees"] = ["Pomesh"]
            rep = backlog_watch.run_watch(wave_dir=p, dry_run=True, force_enabled=True, tickets=tickets)
            self.assertEqual([x.ticket_id for x in rep.picks], ["t0"])
            self.assertEqual(rep.picks[0].roles["implementer"], "claude")   # Claude implements low too
            self.assertIn({"id": "t1", "reason": "assigned to Pomesh"}, rep.skipped)

    def test_assigned_ticket_is_never_picked(self):
        # INNOV-438: agent-ready does not override a human owner.
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            self._cfg(p)
            tickets = self._tickets(2)
            tickets[0]["assignees"] = ["mike"]
            rep = backlog_watch.run_watch(wave_dir=p, dry_run=True, force_enabled=True, tickets=tickets)
            self.assertEqual([x.ticket_id for x in rep.picks], ["t1"])
            self.assertIn({"id": "t0", "reason": "assigned to mike"}, rep.skipped)

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
