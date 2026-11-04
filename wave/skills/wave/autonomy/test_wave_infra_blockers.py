"""PR #477 blockers: fail-closed DENY scan, brain:save gate, aggregate summaries.

Run: python .claude/wave/test_wave_infra_blockers.py
"""
from __future__ import annotations

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import aggregate_wave_report  # noqa: E402
import brain_save_consume_report  # noqa: E402
import preflight  # noqa: E402

CLEAN = "x NT AUTHORITY\\SYSTEM:(I)(F)\n\nSuccessfully processed 3 files; Failed processing 0 files\n"


class Runner:
    """Stands in for preflight._run; records every icacls call."""

    def __init__(self, *result):
        self.result = result or (0, CLEAN, "")
        self.calls: list[list[str]] = []

    def __call__(self, cmd, *, timeout):
        self.calls.append(cmd)
        if isinstance(self.result[0], Exception):
            raise self.result[0]
        return self.result


class SyncBaseBeforeCloseout(unittest.TestCase):
    """Closeout ran in a checkout behind origin, so it tested code older than the merge."""

    def setUp(self):
        import autonomy_tick

        self.sync = autonomy_tick.sync_base
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.git = lambda cwd, *a: subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()
        self.git(root, "init", "-q", "--bare", "-b", "development", "origin.git")
        for name in ("worker", "main"):
            self.git(root, "clone", "-q", str(root / "origin.git"), name)
            self.git(root / name, "config", "user.email", "t@example.invalid")
            self.git(root / name, "config", "user.name", "t")
        self.worker, self.main = root / "worker", root / "main"
        self.git(self.worker, "commit", "-q", "--allow-empty", "-m", "base")
        self.git(self.worker, "push", "-q", "origin", "HEAD:development")
        self.git(self.main, "pull", "-q", "origin", "development")
        self.git(self.worker, "commit", "-q", "--allow-empty", "-m", "merged PR")  # main is now stale
        self.git(self.worker, "push", "-q", "origin", "HEAD:development")
        self.merged = self.git(self.worker, "rev-parse", "HEAD")

    def tearDown(self):
        self.tmp.cleanup()

    def test_stale_checkout_is_brought_to_the_merge(self):
        self.assertIsNone(self.sync(self.main, "origin/development", [self.merged]))
        self.assertEqual(self.git(self.main, "rev-parse", "HEAD"), self.merged)

    def test_missing_merge_fails(self):
        why = self.sync(self.main, "origin/development", ["0" * 40])
        self.assertIn("does not contain merged commit", why or "")

    def test_other_branch_is_not_switched(self):
        self.git(self.main, "checkout", "-q", "-b", "mine")
        why = self.sync(self.main, "origin/development", [self.merged])
        self.assertIn("needs development checked out", why or "")
        self.assertEqual(self.git(self.main, "branch", "--show-current"), "mine")


class ClickUpCli(unittest.TestCase):
    def test_cli_starts(self):
        """0.6.4 shipped a main() that died before argparse ran (UnboundLocalError on sys)."""
        p = subprocess.run([sys.executable, str(Path(__file__).resolve().parent / "clickup_tracker.py")],
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
        self.assertNotIn("Traceback", p.stderr)
        self.assertEqual(p.returncode, 2)  # argparse: subcommand required
        self.assertIn("usage", p.stderr)


class DenyScan(unittest.TestCase):
    def setUp(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.repo = Path(td.name)
        self.slug = self.repo / ".git" / "worktrees" / "slug-a"
        self.slug.mkdir(parents=True)
        # Only preflight's own `os` reference, so pathlib stays usable off Windows.
        patcher = mock.patch.object(preflight, "os", types.SimpleNamespace(name="nt"))
        patcher.start()
        self.addCleanup(patcher.stop)

    def scan(self, *result):
        return preflight.check_git_deny_aces(str(self.repo), run=Runner(*result))

    def test_nonzero_exit_fails_with_code_and_output(self):
        check = self.scan(5, "x: Access is denied.\n", "")
        self.assertFalse(check.ok)
        self.assertIn("exit=5", check.detail)
        self.assertIn("Access is denied", check.detail)

    def test_success_without_deny_passes(self):
        self.assertTrue(self.scan().ok)

    def test_deny_line_fails(self):
        check = self.scan(0, "x U:(DENY)(W)\n" + CLEAN, "")
        self.assertFalse(check.ok)
        self.assertIn("DENY ACEs present", check.detail)

    def test_every_target_scanned_recursively_including_slug(self):
        run = Runner()
        self.assertTrue(preflight.check_git_deny_aces(str(self.repo), run=run).ok)
        git_dir = self.repo / ".git"
        self.assertEqual(
            run.calls,
            [["icacls", str(p), "/T"] for p in (git_dir, git_dir / "worktrees", self.slug)],
        )

    def test_one_failed_target_fails_the_check(self):
        results = iter([(0, CLEAN, ""), (0, CLEAN, ""), (5, "denied", "")])
        check = preflight.check_git_deny_aces(str(self.repo), run=lambda cmd, *, timeout: next(results))
        self.assertFalse(check.ok)
        self.assertIn("slug-a", check.detail)

    def test_exit_zero_that_processed_nothing_fails(self):
        # Real icacls behaviour for `/T` on a path that vanished.
        self.assertFalse(self.scan(0, "Successfully processed 0 files; Failed processing 0 files\n", "").ok)

    def test_exit_zero_with_failed_files_fails(self):
        self.assertFalse(self.scan(0, "Successfully processed 3 files; Failed processing 1 files\n", "").ok)

    def test_exit_zero_without_summary_fails(self):
        self.assertFalse(self.scan(0, "", "").ok)

    def test_timeout_and_missing_binary_fail(self):
        for exc in (subprocess.TimeoutExpired("icacls", 300), FileNotFoundError("icacls")):
            self.assertFalse(self.scan(exc).ok)

    def test_unlistable_worktrees_fails(self):
        with mock.patch.object(preflight, "deny_scan_targets", side_effect=PermissionError("denied")):
            self.assertFalse(self.scan().ok)

    def test_non_windows_skips(self):
        with mock.patch.object(preflight, "os", types.SimpleNamespace(name="posix")):
            check = preflight.check_git_deny_aces(str(self.repo), run=Runner(5, "", ""))
        self.assertTrue(check.ok)
        self.assertIn("skipped", check.detail)


class BrainSaveConsume(unittest.TestCase):
    def setUp(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.dir = Path(td.name)
        self.md = self.dir / "wave-report.md"
        self.sidecar = self.dir / "wave-report.json"

    def consume(self, *extra):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return brain_save_consume_report.main([str(self.md), *extra])

    def write(self, body="# report\n\nworker text\n", sidecar=None):
        self.md.write_text(body, encoding="utf-8")
        data = {"ok": True, "missing": []} if sidecar is None else sidecar
        self.sidecar.write_text(json.dumps(data), encoding="utf-8")

    def test_missing_md(self):
        self.assertEqual(self.consume(), 1)

    def test_empty_md(self):
        for body in ("", " \n\t\n"):
            self.write(body=body)
            self.assertEqual(self.consume(), 1)

    def test_missing_sibling_sidecar(self):
        self.md.write_text("# report\n", encoding="utf-8")
        self.assertEqual(self.consume(), 1)

    def test_missing_explicit_sidecar(self):
        self.write()  # a valid sibling must not rescue a bad --json
        self.assertEqual(self.consume("--json", str(self.dir / "nope.json")), 1)

    def test_invalid_sidecar_json(self):
        self.write()
        self.sidecar.write_text("{not json", encoding="utf-8")
        self.assertEqual(self.consume(), 1)

    def test_sidecar_not_ok(self):
        for sidecar in ({"ok": False}, {}, {"ok": "false"}, [{"ok": True}]):
            self.write(sidecar=sidecar)
            self.assertEqual(self.consume(), 1, sidecar)

    def test_missing_summaries_refused_even_if_sidecar_ok(self):
        self.write(sidecar={"ok": True, "missing": ["t1"]})
        self.assertEqual(self.consume(), 1)
        for marker in ("**MISSING summary.md**", "**EMPTY summary.md**"):
            self.write(body=f"# report\n- {marker}\n")
            self.assertEqual(self.consume(), 1)

    def test_happy_path_copies(self):
        self.write()
        copy = self.dir / "hot.md"
        self.assertEqual(self.consume("--copy-to", str(copy)), 0)
        self.assertIn("worker text", copy.read_text(encoding="utf-8"))

    def test_failure_does_not_copy(self):
        self.write(sidecar={"ok": False})
        copy = self.dir / "hot.md"
        self.assertEqual(self.consume("--copy-to", str(copy)), 1)
        self.assertFalse(copy.exists())


class Aggregate(unittest.TestCase):
    def setUp(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.root = Path(td.name)
        self.runs = self.root / "runs"
        self.runs.mkdir()

    def worker(self, name, summary):
        run_dir = self.runs / name
        run_dir.mkdir()
        (run_dir / "summary.md").write_text(summary, encoding="utf-8")

    def test_empty_summary_is_missing(self):
        for i, body in enumerate(("", "  \n\n")):
            self.worker(f"blank{i}", body)
        report = aggregate_wave_report.build_report(self.runs, "w")
        self.assertFalse(report.ok)
        self.assertEqual(report.missing, ["blank0", "blank1"])
        self.assertFalse(any(w.present for w in report.workers))
        self.assertIn("**EMPTY summary.md**", report.markdown)

    def test_absent_summary_marked_missing(self):
        (self.runs / "t1").mkdir()
        (self.runs / "t1" / "worker.log").write_text("log", encoding="utf-8")
        report = aggregate_wave_report.build_report(self.runs, "w")
        self.assertFalse(report.ok)
        self.assertIn("**MISSING summary.md**", report.markdown)

    def test_non_empty_summary_ok(self):
        self.worker("t1", "# done\n")
        report = aggregate_wave_report.build_report(self.runs, "w")
        self.assertTrue(report.ok)
        self.assertTrue(report.workers[0].present)
        self.assertEqual(report.missing, [])

    def test_one_empty_among_good_fails(self):
        self.worker("t1", "# done\n")
        self.worker("t2", "")
        report = aggregate_wave_report.build_report(self.runs, "w")
        self.assertFalse(report.ok)
        self.assertEqual(report.missing, ["t2"])

    def test_no_workers_not_ok(self):
        self.assertFalse(aggregate_wave_report.build_report(self.runs, "w").ok)

    def test_cli_exit_follows_ok(self):
        self.worker("t1", "")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(aggregate_wave_report.main([str(self.runs), "w", str(self.root / "out")]), 1)


if __name__ == "__main__":
    unittest.main()
