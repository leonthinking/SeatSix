"""Lifecycle regressions: no Docker daemon or private server required."""
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

import common
import run


def item(kind, running=True, owned=True):
    return {"Id": kind + "-id", "State": {"Running": running},
            "Config": {"Labels": {common.LABEL: str(common.ROOT) if owned else "another-workspace"}}}


def result(code=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class FakeServices(run.Services):
    def __init__(self, running=False):
        self.orb, self.docker, self.env = "fake-orb", "fake-docker", {}
        self.started_orb, self.had_gui, self.before = False, True, None
        self.running = running
        self.containers = {k: None for k in common.SERVERS}
        self.other = self.machines = False
        self.calls = []
        self.fail_stop = set()
        self.fail_start = False
        self.fail_info = False
        self.gui = False

    def docker_command(self, *args, check=True):
        self.calls.append(args)
        if args[0] == "inspect":
            kind = next(k for k, spec in common.SERVERS.items() if spec["name"] == args[1])
            value = self.containers[kind]
            return result(stdout=json.dumps([value])) if value else result(1, stderr="No such container")
        if args[0] == "info":
            return result(1 if self.fail_info else 0)
        if args[0] == "ps":
            active = [v["Id"] for v in self.containers.values() if v and v["State"]["Running"]]
            return result(stdout="\n".join(active + (["unrelated-id"] if self.other else [])))
        if args[0] == "stop":
            if args[-1] in self.fail_stop:
                raise RuntimeError("stop failed")
            for value in self.containers.values():
                if value and value["Id"] == args[-1]:
                    value["State"]["Running"] = False
            return result()
        raise AssertionError(args)

    def control(self, args, **kwargs):
        self.calls.append(tuple(args))
        if args[0] == "pgrep":
            return result(0 if self.gui else 1)
        if args[0] == "osascript":
            self.gui = False
            return result()
        if args[1] == "status":
            return result(0 if self.running else 1, "Running" if self.running else "Stopped")
        if args[1] == "start":
            self.running = self.gui = True
            if self.fail_start:
                raise RuntimeError("partial startup failure")
            return result()
        if args[1] == "stop":
            self.running = False
            return result()
        if args[1] == "list":
            return result(stdout="user-machine" if self.machines else "")
        raise AssertionError(args)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        # Offline regressions must not contend with a real integration session.
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        lock_directory = patch.object(run.tempfile, "gettempdir", return_value=directory.name)
        lock_directory.start()
        self.addCleanup(lock_directory.stop)

    def perform(self, services, body):
        with patch.object(run, "command", side_effect=services.control), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            services.start()
            body()
            services.finish()

    def test_cold_run_stops_only_its_containers_and_exits_app(self):
        s = FakeServices()
        self.perform(s, lambda: s.containers.update({k: item(k) for k in common.SERVERS}))
        self.assertFalse(s.running)
        self.assertFalse(s.gui)
        self.assertEqual([c[-1] for c in s.calls if c[0] == "stop"], ["jellyfin-id", "emby-id"])
        self.assertTrue(any(c[0] == "osascript" for c in s.calls))

    def test_preexisting_runtime_and_running_container_are_preserved(self):
        s = FakeServices(running=True)
        s.containers["jellyfin"] = item("jellyfin")
        self.perform(s, lambda: s.containers.update(emby=item("emby")))
        self.assertTrue(s.running)
        self.assertTrue(s.containers["jellyfin"]["State"]["Running"])
        self.assertFalse(s.containers["emby"]["State"]["Running"])
        self.assertNotIn((s.orb, "stop"), s.calls)

    def test_existing_stopped_containers_are_stopped_after_the_test(self):
        s = FakeServices()
        s.containers = {k: item(k, running=False) for k in common.SERVERS}
        self.perform(s, lambda: s.containers.update({k: item(k) for k in common.SERVERS}))
        self.assertFalse(s.running)

    def test_snapshot_is_immutable_when_state_changes(self):
        # Docker inspect parses a fresh JSON snapshot rather than retaining mutable state.
        s = FakeServices(running=True)
        s.containers["emby"] = item("emby", running=False)
        self.perform(s, lambda: s.containers["emby"]["State"].update(Running=True))
        self.assertFalse(s.containers["emby"]["State"]["Running"])

    def test_new_unrelated_container_or_linux_machine_preserves_orbstack(self):
        for attribute in ("other", "machines"):
            s = FakeServices()
            self.perform(s, lambda: setattr(s, attribute, True))
            self.assertTrue(s.running)
            self.assertNotIn((s.orb, "stop"), s.calls)

    def test_gui_open_before_service_start_is_preserved(self):
        s = FakeServices()
        s.gui = True
        self.perform(s, lambda: None)
        self.assertFalse(s.running)
        self.assertTrue(s.gui)
        self.assertFalse(any(c[0] == "osascript" for c in s.calls))

    def test_replaced_unowned_container_blocks_all_teardown_changes(self):
        s = FakeServices()
        with patch.object(run, "command", side_effect=s.control), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            s.start()
            s.containers = {k: item(k, owned=(k == "jellyfin")) for k in common.SERVERS}
            with self.assertRaisesRegex(RuntimeError, "teardown incomplete"):
                s.finish()
        self.assertFalse(any(c[0] == "stop" for c in s.calls))
        self.assertTrue(s.running)

    def test_container_stop_failure_still_attempts_the_other_container(self):
        s = FakeServices()
        with patch.object(run, "command", side_effect=s.control), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            s.start()
            s.containers = {k: item(k) for k in common.SERVERS}
            s.fail_stop = {"jellyfin-id"}
            with self.assertRaisesRegex(RuntimeError, "stop failed"):
                s.finish()
        self.assertFalse(s.containers["emby"]["State"]["Running"])
        self.assertTrue(s.running)

    def test_failed_partial_start_still_shuts_down_if_no_other_workloads(self):
        s = FakeServices()
        s.fail_start = True
        with patch.object(run, "command", side_effect=s.control), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "partial startup"):
                s.start()
            s.finish()
        self.assertFalse(s.running)

    def test_unknown_status_is_not_treated_as_stopped(self):
        s = FakeServices()
        with patch.object(run, "command", return_value=result(1, "", "permission denied")):
            with self.assertRaisesRegex(RuntimeError, "reliably"):
                s.start()
        self.assertFalse(s.started_orb)

    def test_environment_is_pinned_without_changing_parent_context(self):
        with patch.dict(os.environ, {"DOCKER_CONTEXT": "remote", "DOCKER_HOST": "tcp://remote:2375"}), patch.object(run.shutil, "which", return_value=sys.executable):
            s = run.Services()
            self.assertEqual(s.env["DOCKER_CONTEXT"], "orbstack")
            self.assertNotIn("DOCKER_HOST", s.env)
            self.assertEqual(os.environ["DOCKER_CONTEXT"], "remote")

    def test_concurrent_managed_run_fails_before_starting_services(self):
        with run.session_lock():
            with self.assertRaisesRegex(RuntimeError, "Another managed"):
                with run.session_lock():
                    self.fail("lock was acquired twice")

    def test_failed_tests_and_setup_preserve_exit_code_and_always_clean_up(self):
        for exits in ([9], [0, 7], [0, 0]):
            s = Mock()
            with patch.object(run, "Services", return_value=s), patch.object(run, "run_child", side_effect=exits):
                self.assertEqual(run.main([]), exits[-1])
            s.finish.assert_called_once()

    def test_missing_custom_command_cannot_report_success(self):
        s = Mock()
        with patch.object(run, "Services", return_value=s), patch.object(run, "run_child", side_effect=[0, FileNotFoundError("missing command")]), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(run.main(["--", "missing-command"]), 1)
        s.finish.assert_called_once()

    def test_cleanup_failure_changes_success_to_failure_but_keeps_test_failure(self):
        for exits, expected in (([0, 0], 1), ([0, 7], 7)):
            s = Mock()
            s.finish.side_effect = RuntimeError("cleanup failed")
            with patch.object(run, "Services", return_value=s), patch.object(run, "run_child", side_effect=exits), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(run.main([]), expected)

    def test_first_interrupt_ignores_repeated_signals_during_child_cleanup(self):
        s = Mock()
        def interrupt(*_args):
            handler = signal.getsignal(signal.SIGTERM)
            try:
                handler(signal.SIGTERM, None)
            except InterruptedError:
                self.assertEqual(signal.getsignal(signal.SIGINT), signal.SIG_IGN)
                self.assertEqual(signal.getsignal(signal.SIGTERM), signal.SIG_IGN)
                raise
        with patch.object(run, "Services", return_value=s), patch.object(run, "run_child", side_effect=interrupt):
            self.assertEqual(run.main([]), 143)
        s.finish.assert_called_once()

    def test_legacy_setup_forwards_exit_code_and_rejects_unmanaged_internal_flag(self):
        import setup
        with patch.object(sys, "argv", ["setup.py", "--no-pull"]), patch.object(run, "main", return_value=7) as runner:
            self.assertEqual(setup.main(), 7)
            runner.assert_called_once_with()
        with patch.object(sys, "argv", ["setup.py", "--managed"]), patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "run.py"):
                setup.main()

    def test_sigint_and_sigterm_stop_child_before_teardown(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "setup.py").write_text("import os,time,pathlib\npathlib.Path(__file__).with_name('ready').write_text(str(os.getpid()))\ntime.sleep(60)\n")
                harness = """import os,sys,pathlib,contextlib
import run
root=pathlib.Path(sys.argv[1])
class Fake:
 env=dict(os.environ)
 def start(self): pass
 def finish(self): root.joinpath('cleaned').write_text('done')
run.Services=Fake
run.HERE=root
run.session_lock=contextlib.nullcontext
raise SystemExit(run.main([]))
"""
                env = dict(os.environ, PYTHONPATH=str(Path(run.__file__).parent))
                process = subprocess.Popen([sys.executable, "-c", harness, directory], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 5
                    while not (root / "ready").exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue((root / "ready").exists())
                    child = int((root / "ready").read_text())
                    process.send_signal(sig)
                    process.communicate(timeout=15)
                    self.assertEqual(process.returncode, 128 + sig)
                    self.assertTrue((root / "cleaned").exists())
                    with self.assertRaises(ProcessLookupError):
                        os.kill(child, 0)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()

    def test_running_legacy_container_is_not_replaced_during_setup(self):
        import setup
        legacy = {"State": {"Running": True}, "Mounts": [{"Type": "bind"}]}
        with patch.object(setup, "inspect_owned", return_value=legacy), patch.object(setup, "docker") as docker:
            with self.assertRaisesRegex(RuntimeError, "Refusing to replace running"):
                setup.start_container("emby", False)
            docker.assert_not_called()


if __name__ == "__main__":
    unittest.main()
