"""coordinator_loop's tracker updates (INNOV-463): hold and merge reach Jira and ClickUp
through the tick's adapter (jira_tracker.tracker_for), never on an unset tracker, and a
failing tracker never crashes the loop (a crash leaves every worker unsupervised).

Run: python test_coordinator_loop.py
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clickup_tracker  # noqa: E402
import coordinator_loop as cl  # noqa: E402
import jira_tracker  # noqa: E402
import linear_tracker  # noqa: E402

CONFIGS = {
    "jira": "WAVE_TRACKER=jira\nWAVE_JIRA_SITE=example.atlassian.net\nWAVE_QUEUE='project = ABC'\n",
    "clickup": "WAVE_TRACKER=clickup\nWAVE_CLICKUP_LIST=901\n",
    "linear": "WAVE_TRACKER=linear\nWAVE_QUEUE='team = ABC'\n",
    "unset":"WAVE_QUEUE='project = ABC'\n",
}
# env beats the file in load_autonomy_config; a developer's shell must not pick the tracker
CLEAR = ("WAVE_TRACKER", "WAVE_QUEUE", "WAVE_JIRA_SITE", "WAVE_CLICKUP_LIST", "WAVE_CLICKUP_SPACE",
         "WAVE_CLICKUP_TEAM", "WAVE_STATE_HELD", "WAVE_STATE_START", "WAVE_STATE_DONE")


class Stub:
    made: list["Stub"] = []
    fail = False

    def __init__(self, **kw):
        self.kw, self.calls = kw, []
        Stub.made.append(self)

    def set_status(self, key, state):
        if Stub.fail:
            raise RuntimeError("transition refused")
        self.calls.append(("status", key, state))

    def comment(self, key, body):
        self.calls.append(("comment", key, body))


def issue(status="done", pr=12):
    return {"tier": "normal", "task": "t1", "dispatch": "d1", "slug": "abc-7", "status": status,
            "pr": pr, "reason": "", "rebased": False}


class CoordinatorTracker(unittest.TestCase):
    def setUp(self):
        Stub.made, Stub.fail = [], False
        self.tmp = Path(tempfile.mkdtemp())
        env = {k: v for k, v in os.environ.items() if k not in CLEAR}
        env["WAVE_STATE_START"] = "In Progress"
        p = mock.patch.dict(os.environ, env, clear=True)
        p.start(); self.addCleanup(p.stop)
        for target in (mock.patch.object(jira_tracker, "JiraTrackerAdapter", Stub),
                       mock.patch.object(clickup_tracker, "ClickUpTrackerAdapter", Stub),
                       mock.patch.object(linear_tracker, "LinearTrackerAdapter", Stub),
                       mock.patch.object(cl, "oj", lambda *a: {}),
                       mock.patch.object(cl, "log", lambda *a: None),
                       mock.patch.object(cl, "gh", self.fake_gh),
                       mock.patch.object(cl.subprocess, "run", lambda *a, **k: types.SimpleNamespace(returncode=0))):
            target.start(); self.addCleanup(target.stop)
        cl._TRACKER.clear()
        self.addCleanup(cl._TRACKER.clear)

    merged = False  # what `gh pr view --json state` reports before the loop merges

    def fake_gh(self, *args):
        if args[:2] == ("pr", "view") and "state" in args:
            return json.dumps({"state": "MERGED" if self.merged else "OPEN"})
        if args[:2] == ("pr", "view") and "mergeCommit" in args:
            return json.dumps({"mergeCommit": {"oid": "abc123def456"}})
        return ""

    def use(self, tracker):
        cfg = self.tmp / f"{tracker}.env"
        cfg.write_text(CONFIGS[tracker], encoding="utf-8")
        cl.CONFIG = str(cfg)

    def settle(self, verdict, v=None):
        d = {"issues": {"ABC-7": v or issue()}}
        with mock.patch.object(cl, "gate", lambda pr: verdict):
            cl.settle(d)
        return d["issues"]["ABC-7"]

    def calls(self):
        return [c for s in Stub.made for c in s.calls]

    def test_hold_moves_status_and_comments_reason_and_pr(self):
        for tracker in ("jira", "clickup", "linear"):
            with self.subTest(tracker=tracker):
                Stub.made = []; cl._TRACKER.clear(); self.use(tracker)
                v = self.settle("HOLD: TIER risk")
                self.assertEqual(v["status"], "held")
                calls = self.calls()
                self.assertIn(("status", "ABC-7", "In Progress"), calls)
                comments = [c[2] for c in calls if c[0] == "comment"]
                self.assertEqual(len(comments), 1, calls)
                self.assertIn("HOLD: TIER risk", comments[0])
                self.assertIn("#12", comments[0])

    def test_hold_state_prefers_wave_state_held(self):
        os.environ["WAVE_STATE_HELD"] = "On Hold"
        self.use("jira")
        self.settle("HOLD: MIGRATION: yes")
        self.assertIn(("status", "ABC-7", "On Hold"), self.calls())

    def test_merge_comments_pr_and_sha_without_status_move(self):
        for tracker in ("jira", "clickup"):
            with self.subTest(tracker=tracker):
                Stub.made = []; cl._TRACKER.clear(); self.use(tracker)
                v = self.settle("MERGE")
                self.assertEqual(v["status"], "merged")
                calls = self.calls()
                self.assertEqual([c[0] for c in calls], ["comment"], calls)
                self.assertIn("#12", calls[0][2])
                self.assertIn("abc123def456", calls[0][2])

    def test_pr_merged_outside_the_loop_is_held_without_rewinding_the_ticket(self):
        # a self-merged PR never passed gate.py: it must not count as a clean merge
        # (walked, swept), and its ticket keeps the worker's done state
        self.use("jira")
        self.merged = True
        for verdict in ("MERGE", "HOLD: TIER risk", "PENDING: mergeable UNKNOWN"):
            with self.subTest(verdict=verdict):
                v = self.settle(verdict, issue())
                self.assertEqual(v["status"], "held")
                self.assertIn("never gated", v["reason"])
        calls = self.calls()
        self.assertNotIn("status", [c[0] for c in calls])
        self.assertEqual(len(calls), 3)

    def test_resume_puts_a_hand_merged_held_ticket_back_to_done_once(self):
        os.environ["WAVE_STATE_DONE"] = "Validate"
        self.use("jira")
        self.merged = True
        d = {"issues": {"ABC-7": issue(status="held")}}
        cl.reconcile(d); cl.reconcile(d)   # a second --resume must not repeat it
        self.assertEqual(d["issues"]["ABC-7"]["status"], "held")
        calls = self.calls()
        self.assertEqual([c[0] for c in calls], ["status", "comment"])
        self.assertEqual(calls[0], ("status", "ABC-7", "Validate"))

    def test_resume_leaves_an_open_held_pr_alone(self):
        self.use("jira")
        d = {"issues": {"ABC-7": issue(status="held")}}
        cl.reconcile(d)
        self.assertEqual(self.calls(), [])

    def test_failed_merge_call_on_a_landed_merge_is_merged(self):
        self.use("jira")
        ran = []

        def run(*a, **k):
            ran.append(a); self.merged = True   # the merge landed, gh still exited non-zero
            return types.SimpleNamespace(returncode=1)
        with mock.patch.object(cl.subprocess, "run", run):
            v = self.settle("MERGE")
        self.assertTrue(ran)
        self.assertEqual(v["status"], "merged")
        self.assertEqual([c[0] for c in self.calls()], ["comment"])

    def test_unset_tracker_makes_no_tracker_call(self):
        self.use("unset")
        self.assertEqual(self.settle("HOLD: TIER risk")["status"], "held")
        self.assertEqual(self.settle("MERGE")["status"], "merged")
        self.assertEqual(Stub.made, [])

    def test_raising_tracker_still_settles_and_still_comments(self):
        Stub.fail = True
        self.use("jira")
        v = self.settle("HOLD: TIER risk")
        self.assertEqual(v["status"], "held")
        self.assertEqual([c[0] for c in self.calls()], ["comment"])

    def test_unbuildable_tracker_still_settles(self):
        self.use("jira")
        with mock.patch.object(jira_tracker, "JiraTrackerAdapter", side_effect=jira_tracker.JiraError("no JQL")):
            self.assertEqual(self.settle("MERGE")["status"], "merged")

    def test_hold_without_pr_number_still_reaches_tracker(self):
        self.use("jira")
        with mock.patch.object(cl, "pr_number", lambda v: None):
            v = self.settle("MERGE", issue(pr=None))
        self.assertEqual(v["status"], "held")
        self.assertIn(("status", "ABC-7", "In Progress"), self.calls())

    def test_worker_question_hold_reaches_tracker(self):
        self.use("jira")
        d = {"issues": {"ABC-7": issue(status="running")}}
        msg = {"type": "question", "body": "which table?", "payload": {"dispatchId": "d1", "taskId": "t1"}}
        with mock.patch.object(cl, "oj", lambda *a: {"messages": [msg]}):
            cl.consume(d)
        self.assertEqual(d["issues"]["ABC-7"]["status"], "held")
        calls = self.calls()
        self.assertIn(("status", "ABC-7", "In Progress"), calls)
        self.assertTrue(any("which table?" in c[2] for c in calls if c[0] == "comment"), calls)


TURN_END = ("Worker structworker_1b4769ae ended its turn without sending worker_done for task "
            "task_9ba74bc414cb")   # Orca's wording, from run_634d93c19dcc's state file


class TurnEndEscalation(unittest.TestCase):
    """INNOV-464: Orca escalates every time a Claude worker's turn ends (a background review, an
    advisor call). A live worker is waited on, up to WAVE_TURN_END_GRACE_MIN; a real question or
    any other escalation still holds."""

    def setUp(self):
        self.now = 1_000_000.0
        self.liveness = "live"
        self.inbox = []        # messages the next consume() receives
        self.shown = []        # worker-show calls
        env = {k: v for k, v in os.environ.items() if k not in CLEAR + ("WAVE_TURN_END_GRACE_MIN",)}
        p = mock.patch.dict(os.environ, env, clear=True)
        p.start(); self.addCleanup(p.stop)
        for target in (mock.patch.object(cl, "oj", self.fake_oj),
                       mock.patch.object(cl, "log", lambda *a: None),
                       mock.patch.object(cl, "track", lambda *a, **k: None),
                       mock.patch.object(cl.time, "time", lambda: self.now)):
            target.start(); self.addCleanup(target.stop)
        self.d = {"issues": {"ABC-7": issue(status="running", pr=None)}}

    def fake_oj(self, *args):
        if args[:2] == ("orchestration", "worker-show"):
            self.shown.append(args)
            return {"dispatchId": "d1", "state": "running", "liveness": self.liveness}
        if args[:2] == ("orchestration", "check") and "--wait" in args:
            msgs, self.inbox = self.inbox, []
            return {"messages": msgs}
        return {}

    def send(self, type_, body, **payload):
        self.inbox.append({"type": type_, "body": body,
                           "payload": dict({"dispatchId": "d1", "taskId": "t1"}, **payload)})
        cl.consume(self.d)
        return self.d["issues"]["ABC-7"]

    def test_live_worker_is_not_held_and_its_pr_is_gated_on_worker_done(self):
        v = self.send("escalation", TURN_END)
        self.assertEqual(v["status"], "running")
        self.assertTrue(self.shown)
        self.now += 20 * 60
        v = self.send("worker_done", "DONE - ABC-7 - PR #303", outcome="succeeded")
        self.assertEqual((v["status"], v["pr"]), ("done", 303))
        seen = []
        with mock.patch.object(cl, "gate", lambda pr: seen.append(pr) or "MERGE"), \
                mock.patch.object(cl, "gh", lambda *a: json.dumps({"state": "OPEN"})), \
                mock.patch.object(cl.subprocess, "run", lambda *a, **k: types.SimpleNamespace(returncode=0)):
            cl.settle(self.d)
        self.assertEqual(seen, [303])
        self.assertEqual(v["status"], "merged")

    def test_worker_no_longer_live_is_held(self):
        self.liveness = "exited"
        v = self.send("escalation", TURN_END)
        self.assertEqual(v["status"], "held")
        self.assertIn("not live", v["reason"])

    def test_unverifiable_or_unreadable_worker_waits_but_only_up_to_the_cap(self):
        # 'unverifiable' is Orca's "no status heartbeat lately" (a long review.sh), not dead; an
        # unreadable worker-show is unknown. Neither holds at once, and neither waits past the cap.
        boom = lambda *a: (_ for _ in ()).throw(ValueError("bad json")) \
            if a[:2] == ("orchestration", "worker-show") else self.fake_oj(*a)  # noqa: E731
        for case in ("unverifiable", "raises", "empty"):
            with self.subTest(case=case):
                self.d = {"issues": {"ABC-7": issue(status="running", pr=None)}}
                self.liveness = None if case == "empty" else case
                with mock.patch.object(cl, "oj", boom if case == "raises" else self.fake_oj):
                    self.assertEqual(self.send("escalation", TURN_END)["status"], "running")
                    self.now += 61 * 60
                    cl.consume(self.d)
                v = self.d["issues"]["ABC-7"]
                self.assertEqual(v["status"], "held")
                self.assertIn("60 min", v["reason"])

    def test_live_worker_past_the_grace_cap_is_held_without_another_message(self):
        self.send("escalation", TURN_END)
        self.now += 59 * 60
        cl.consume(self.d)   # no message: the parked worker is re-checked on the poll
        self.assertEqual(self.d["issues"]["ABC-7"]["status"], "running")
        self.now += 2 * 60
        cl.consume(self.d)
        v = self.d["issues"]["ABC-7"]
        self.assertEqual(v["status"], "held")
        self.assertIn("60 min", v["reason"])

    def test_later_turn_ends_do_not_reset_the_clock(self):
        self.send("escalation", TURN_END)
        self.now += 40 * 60
        self.assertEqual(self.send("escalation", TURN_END)["status"], "running")
        self.now += 21 * 60
        self.assertEqual(self.send("escalation", TURN_END)["status"], "held")

    def test_parked_worker_that_exits_is_held_on_the_poll(self):
        self.send("escalation", TURN_END)
        self.liveness = "exited"
        cl.consume(self.d)
        self.assertEqual(self.d["issues"]["ABC-7"]["status"], "held")

    def test_grace_comes_from_the_env_and_a_bad_value_falls_back(self):
        os.environ["WAVE_TURN_END_GRACE_MIN"] = "5"
        self.send("escalation", TURN_END)
        self.now += 6 * 60
        cl.consume(self.d)
        self.assertEqual(self.d["issues"]["ABC-7"]["status"], "held")
        for bad in ("soon", "nan", "inf", "0", "-5"):
            with self.subTest(bad=bad):
                # falls back to 60: still waiting at 30 min, held past 60 (nan/inf never would be)
                os.environ["WAVE_TURN_END_GRACE_MIN"] = bad
                self.d = {"issues": {"ABC-7": issue(status="running", pr=None)}}
                self.send("escalation", TURN_END)
                self.now += 30 * 60
                cl.consume(self.d)
                self.assertEqual(self.d["issues"]["ABC-7"]["status"], "running")
                self.now += 31 * 60
                cl.consume(self.d)
                self.assertEqual(self.d["issues"]["ABC-7"]["status"], "held")

    def test_questions_and_other_escalations_still_hold_while_live(self):
        for type_, body in (("question", "which table?"), ("escalation", "worker reports a blocker")):
            with self.subTest(type=type_):
                self.d = {"issues": {"ABC-7": issue(status="running", pr=None)}}
                v = self.send(type_, body)
                self.assertEqual(v["status"], "held")
                self.assertIn("needs human", v["reason"])


class LinearAdapterCommands(unittest.TestCase):
    def test_writes_go_through_orca_linear(self):
        seen = []

        def ok(args):
            seen.append(args)
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")
        a = linear_tracker.LinearTrackerAdapter(run=ok)
        a.set_status("SPO-1", "In Progress"); a.comment("SPO-1", "wave: held")
        self.assertEqual(seen, [["linear", "status", "set", "SPO-1", "--to", "In Progress", "--json"],
                                ["linear", "comment", "add", "SPO-1", "--body", "wave: held", "--json"]])

    def test_a_failed_write_raises(self):
        bad = lambda args: types.SimpleNamespace(returncode=1, stdout="", stderr="no auth")  # noqa: E731
        with self.assertRaises(linear_tracker.LinearError):
            linear_tracker.LinearTrackerAdapter(run=bad).comment("SPO-1", "x")


if __name__ == "__main__":
    unittest.main()
