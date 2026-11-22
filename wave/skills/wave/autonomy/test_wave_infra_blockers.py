"""PR #477 blockers: fail-closed DENY scan, brain:save gate, aggregate summaries.

Run: python .claude/wave/test_wave_infra_blockers.py
"""
from __future__ import annotations

import base64
import contextlib
import io
import json
import subprocess
import sys
import tempfile
import time
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


class FakeOrca:
    """Stands in for the orca CLI; maps the first two args to a JSON result and records every call."""

    def __init__(self, results, rc=0):
        self.results, self.rc, self.calls = results, rc, []

    def __call__(self, args):
        self.calls.append(args)
        res = self.results.get(" ".join(args[:2]))
        out = json.dumps({"result": res}) if res is not None else ""
        return subprocess.CompletedProcess(args, self.rc if res is not None else 1, out, "" if res is not None else "no such command")


class OrcaRuntime(unittest.TestCase):
    def setUp(self):
        import worker_runtime

        self.wr = worker_runtime
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        self.orca = FakeOrca({
            "repo list": {"repos": [{"id": "r1", "path": str(self.repo)}]},
            "worktree create": {"worktree": {"id": "r1::wt", "path": "C:/wt/86bcabc", "branch": "refs/heads/wave/86bcabc"}},
        })
        self.rt = worker_runtime.OrcaWorkerRuntime(repo_path=str(self.repo), base_branch="origin/development", orca=self.orca)
        self.run_dir = self.repo / ".claude" / "wave" / "runs" / "86bcabc"

    def tearDown(self):
        self.tmp.cleanup()

    def test_spawn_writes_the_run_folder_contract(self):
        self.run_dir.mkdir(parents=True)
        (self.run_dir / "summary.md").write_text("old attempt", encoding="utf-8")
        with mock.patch.dict("os.environ", {"WAVE_SKIP_PREFLIGHT": "1"}):
            rec = self.rt.spawn(ticket_id="86bcabc", prompt="WAVE WORKER ...", agent="codex", model="gpt-5.6-terra")
        st = json.loads((self.run_dir / "status.json").read_text(encoding="utf-8"))
        self.assertEqual((st["runtime"], st["state"], st["agent"], st["path"], st["branch"]),
                         ("orca", "running", "codex", "C:/wt/86bcabc", "wave/86bcabc"))
        self.assertEqual(rec.mode, "orca")
        create = self.orca.calls[-1]
        for flag, value in (("--agent", "codex"), ("--surface", "terminal"), ("--model", "gpt-5.6-terra"),
                            ("--base-branch", "origin/development"), ("--repo", "id:r1")):
            self.assertEqual(create[create.index(flag) + 1], value)
        self.assertFalse((self.run_dir / "summary.md").exists())  # a stale summary would read as done
        self.assertTrue((self.run_dir / "summary.prev.md").exists())

    def test_live_run_is_not_spawned_twice(self):
        self.run_dir.mkdir(parents=True)
        (self.run_dir / "status.json").write_text('{"state": "running"}', encoding="utf-8")
        with self.assertRaisesRegex(self.wr.WorkerError, "claim_guard"):
            self.rt.spawn(ticket_id="86bcabc", prompt="p", agent="claude")

    def test_unregistered_repo_fails(self):
        self.orca.results["repo list"] = {"repos": [{"id": "x", "path": str(Path(self.tmp.name) / "other")}]}
        with self.assertRaisesRegex(self.wr.WorkerError, "not registered with Orca"):
            self.rt.repo_id()

    def test_liveness(self):
        wt = Path(self.tmp.name) / "wt-86bcabc"
        wt.mkdir()
        st = {"path": str(wt)}
        self.run_dir.mkdir(parents=True)
        now_ms = time.time() * 1000
        alive, idle = self.wr.orca_worker_state(st, self.run_dir, FakeOrca({"terminal list": {"terminals": [{"lastOutputAt": now_ms - 90_000}]}}))
        self.assertTrue(alive)
        self.assertAlmostEqual(idle, 90, delta=5)
        self.assertEqual(self.wr.orca_worker_state(st, self.run_dir, FakeOrca({"terminal list": {"terminals": []}})), (False, None))
        # Orca not answering is not "exited": a failed query must not end a live worker.
        self.assertEqual(self.wr.orca_worker_state(st, self.run_dir, FakeOrca({})), (True, None))
        (self.run_dir / "summary.md").write_text("TIER: quick", encoding="utf-8")
        self.assertEqual(self.wr.orca_worker_state(st, self.run_dir, FakeOrca({})), (False, None))

    def test_swept_worktree_is_not_a_live_worker(self):
        # A merged run's worktree was swept; Orca can't be asked about a deleted path, and
        # "can't ask" used to read as alive, holding a slot forever (sportify 86bcuuhwk).
        self.run_dir.mkdir(parents=True)
        st = {"path": str(Path(self.tmp.name) / "swept")}
        self.assertEqual(self.wr.orca_worker_state(st, self.run_dir, FakeOrca({})), (False, None))

    def test_orca_workers_count_toward_the_cap(self):
        # INNOV-437: Orca workers have no PID; a PID check counted them as zero and over-spawned.
        import backlog_watch
        self.run_dir.mkdir(parents=True)
        wt = Path(self.tmp.name) / "wt-cap"
        wt.mkdir()
        (self.run_dir / "status.json").write_text("﻿" + json.dumps(   # BOM: PowerShell-written status
            {"state": "running", "runtime": "orca", "path": str(wt)}), encoding="utf-8")
        live = FakeOrca({"terminal list": {"terminals": [{"lastOutputAt": time.time() * 1000}]}})
        self.assertEqual(backlog_watch._active_worker_count(self.run_dir.parent, live), 1)
        (self.run_dir / "summary.md").write_text("TIER: quick", encoding="utf-8")
        self.assertEqual(backlog_watch._active_worker_count(self.run_dir.parent, live), 0)

    def test_codex_env_policy(self):
        cfg = Path(self.tmp.name) / "config.toml"
        self.assertTrue(self.wr.codex_inherits_all(cfg))  # no config: Codex inherits everything
        cfg.write_text('[shell_environment_policy]\ninherit = "core"\n', encoding="utf-8")
        self.assertFalse(self.wr.codex_inherits_all(cfg))
        cfg.write_text('[shell_environment_policy]\ninherit = "all"\n', encoding="utf-8")
        self.assertTrue(self.wr.codex_inherits_all(cfg))


class HeartbeatWithoutEnv(unittest.TestCase):
    """An Orca-launched worker's shell has no WAVE_RUN_DIR; the heartbeat finds the run from the worktree."""

    def test_heartbeat_finds_run_and_never_wipes_an_unreadable_status(self):
        import worker_step_commit

        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            git = lambda cwd, *a: subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True, text=True)
            main, wt = root / "main", root / "wt"
            main.mkdir()
            git(main, "init", "-q")
            git(main, "-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base")
            git(main, "worktree", "add", "-q", "-b", "wave/86bcabc", str(wt))
            run = main / ".claude" / "wave" / "runs" / "86bcabc"
            run.mkdir(parents=True)
            status = run / "status.json"
            status.write_text("\ufeff" + json.dumps({"ticket_id": "86bcabc", "state": "running"}), encoding="utf-8")
            with mock.patch.dict("os.environ", {"WAVE_RUN_DIR": ""}):
                worker_step_commit.heartbeat("implement", "abc123", worktree=str(wt), ticket_id="86BCABC")
                st = json.loads(status.read_text(encoding="utf-8-sig"))
                self.assertEqual((st["state"], st["step"], st["step_sha"]), ("running", "implement", "abc123"))
                status.write_text("{not json", encoding="utf-8")
                worker_step_commit.heartbeat("test", None, worktree=str(wt), ticket_id="86bcabc")
                self.assertEqual(status.read_text(encoding="utf-8"), "{not json")


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


SID = "S-1-5-21-3334757451-3060406414-2442283242-4068458768"
SANDBOX = "Masons-Razer\\CodexSandboxUsers:(I)(OI)(CI)(M)"


class DenySelfHeal(unittest.TestCase):
    """INNOV-458: the known Codex-sandbox DENY on .git heals; anything else hard-fails."""

    def setUp(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.repo = Path(td.name)
        self.git = self.repo / ".git"
        self.slug = self.git / "worktrees" / "slug-a"
        self.slug.mkdir(parents=True)
        patcher = mock.patch.object(preflight, "os", types.SimpleNamespace(name="nt"))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.calls: list[list[str]] = []

    @staticmethod
    def block(path, *aces, n=1):
        """Real icacls /T shape: first ACE on the path line, the rest indented."""
        pad = " " * (len(str(path)) + 1)
        lines = [f"{path} {aces[0]}"] + [pad + a for a in aces[1:]]
        return "\n".join(lines) + f"\n\nSuccessfully processed {n} files; Failed processing 0 files\n"

    def dirty(self, git_aces=None, child_ace=f"{SID}:(I)(DENY)(W,D,Rc,DC)", crlf=False):
        git_aces = git_aces or (f"{SID}:(OI)(CI)(DENY)(W,D,Rc,DC)", SANDBOX, "NT AUTHORITY\\SYSTEM:(I)(OI)(CI)(F)")
        out = {
            self.git: self.block(self.git, *git_aces) + self.block(self.git / "HEAD", child_ace, SANDBOX),
            self.git / "worktrees": self.block(self.git / "worktrees", child_ace, SANDBOX),
            self.slug: self.block(self.slug, child_ace, SANDBOX),
        }
        if crlf:
            out = {k: v.replace("\n", "\r\n") for k, v in out.items()}
        return out

    def clean(self):
        return {t: self.block(t, SANDBOX) for t in (self.git, self.git / "worktrees", self.slug)}

    def check(self, first, *, heal=(0, "REMOVED 1\n", ""), after=None):
        scans = [first, after if after is not None else self.clean()]

        def run(cmd, *, timeout):
            self.calls.append(cmd)
            if cmd[0] == "powershell":
                if isinstance(heal, Exception):
                    raise heal
                return heal
            target = Path(cmd[1])
            scan = scans[0] if self.calls.count(cmd) == 1 else scans[1]
            return 0, scan[target], ""

        return preflight.check_git_deny_aces(str(self.repo), run=run)

    def heals(self):
        return [c for c in self.calls if c[0] == "powershell"]

    def test_known_case_heals_with_notice_after_clean_rescan(self):
        with contextlib.redirect_stderr(io.StringIO()) as err:
            check = self.check(self.dirty())
        self.assertTrue(check.ok, check.detail)
        self.assertIn("self-healed: removed 1", check.detail)
        self.assertIn(SID, check.detail)
        self.assertIn("NOTICE: git_deny_aces", err.getvalue())
        self.assertEqual(len(self.heals()), 1)
        self.assertEqual(len([c for c in self.calls if c[0] == "icacls"]), 6)  # scan + rescan

    def test_crlf_output_heals(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertTrue(self.check(self.dirty(crlf=True)).ok)

    def test_heal_script_targets_git_only_and_explicit_sid_rules(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.check(self.dirty())
        cmd = self.heals()[0]
        self.assertEqual(cmd[:4], ["powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand"])
        script = base64.b64decode(cmd[4]).decode("utf-16-le")
        self.assertIn(f"$p = '{self.git}'", script)
        self.assertIn(f"$sids = @('{SID}')", script)
        self.assertIn("-not $_.IsInherited", script)
        self.assertIn("CodexSandboxUsers", script)
        self.assertNotIn("-Recurse", script)

    def test_named_principal_deny_is_not_healed(self):
        out = self.dirty()
        out[self.slug] = self.block(self.slug, "BUILTIN\\Users:(DENY)(W)", SANDBOX)
        check = self.check(out)
        self.assertFalse(check.ok)
        self.assertIn("DENY ACEs present", check.detail)
        self.assertEqual(self.heals(), [])

    def test_no_codex_sandbox_ace_is_not_healed(self):
        out = self.dirty(git_aces=(f"{SID}:(OI)(CI)(DENY)(W,D,Rc,DC)", "NT AUTHORITY\\SYSTEM:(I)(OI)(CI)(F)"))
        self.assertFalse(self.check(out).ok)
        self.assertEqual(self.heals(), [])

    def test_sandbox_ace_only_on_a_child_is_not_healed(self):
        out = self.dirty(git_aces=(f"{SID}:(OI)(CI)(DENY)(W,D,Rc,DC)", "NT AUTHORITY\\SYSTEM:(I)(OI)(CI)(F)"))
        out[self.git] += self.block(self.git / "config", SANDBOX)
        self.assertFalse(self.check(out).ok)
        self.assertEqual(self.heals(), [])

    def test_inherited_only_deny_on_git_is_not_healed(self):
        # The rule comes from above .git: removing nothing on .git could not fix it.
        out = self.dirty(git_aces=(f"{SID}:(I)(OI)(CI)(DENY)(W,D,Rc,DC)", SANDBOX))
        self.assertFalse(self.check(out).ok)
        self.assertEqual(self.heals(), [])

    def test_child_deny_for_another_sid_is_not_healed(self):
        out = self.dirty()
        out[self.slug] = self.block(self.slug, "S-1-5-21-9-9-9-9:(DENY)(W)", SANDBOX)
        self.assertFalse(self.check(out).ok)
        self.assertEqual(self.heals(), [])

    def test_other_rights_or_flags_are_not_healed(self):
        # Codex review: only the exact stamped shape heals, not any raw-SID DENY.
        for ace in (f"{SID}:(OI)(CI)(DENY)(W,D,Rc,RD,DC)", f"{SID}:(DENY)(W,D,Rc,DC)",
                    f"{SID}:(OI)(CI)(IO)(DENY)(W,D,Rc,DC)"):
            self.calls = []
            out = self.dirty(git_aces=(ace, SANDBOX))
            self.assertFalse(self.check(out).ok, ace)
            self.assertEqual(self.heals(), [], ace)

    def test_non_account_raw_sid_is_not_healed(self):
        cap = "S-1-15-3-1024-1-2-3"
        out = self.dirty(git_aces=(f"{cap}:(OI)(CI)(DENY)(W,D,Rc,DC)", SANDBOX), child_ace=f"{cap}:(I)(DENY)(W,D,Rc,DC)")
        self.assertFalse(self.check(out).ok)
        self.assertEqual(self.heals(), [])

    def test_heal_script_matches_the_exact_rights_and_inheritance(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.check(self.dirty())
        script = base64.b64decode(self.heals()[0][4]).decode("utf-16-le")
        self.assertIn("[int]$_.FileSystemRights -eq 1245526", script)  # measured: icacls W,D,Rc,DC
        self.assertIn("$_.InheritanceFlags -eq 'ContainerInherit, ObjectInherit'", script)
        self.assertIn("$_.PropagationFlags -eq 'None'", script)

    def test_scan_failure_with_deny_is_not_healed(self):
        out = self.dirty()
        out[self.slug] = out[self.slug].replace("Failed processing 0", "Failed processing 1")
        check = self.check(out)
        self.assertFalse(check.ok)
        self.assertIn("scan failed", check.detail)
        self.assertEqual(self.heals(), [])

    def test_heal_ok_but_rescan_still_dirty_fails(self):
        check = self.check(self.dirty(), after=self.dirty())
        self.assertFalse(check.ok)
        self.assertIn("DENY ACEs present", check.detail)
        self.assertIn("after self-heal exit=0", check.detail)

    def test_heal_refusal_or_crash_fails(self):
        for heal in ((3, "", ""), (0, "", ""), (1, "", "Set-Acl: denied"), OSError("no powershell")):
            self.calls = []
            check = self.check(self.dirty(), heal=heal)
            self.assertFalse(check.ok, heal)
            self.assertIn("DENY ACEs present", check.detail)
            self.assertIn("self-heal exit=", check.detail)
            self.assertEqual(len([c for c in self.calls if c[0] == "icacls"]), 3)  # no rescan


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
