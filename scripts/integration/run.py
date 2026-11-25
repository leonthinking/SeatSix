#!/usr/bin/env python3
"""Run local container integration tests with an owned, bounded service lifetime."""
from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager

from common import LABEL, ROOT, SERVERS

HERE = Path(__file__).resolve().parent


def command(args, *, check=True, timeout=30, env=None):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
    if check and result.returncode:
        # Docker errors can include connection/configuration details; keep diagnostics bounded.
        raise RuntimeError(f"{Path(args[0]).name} {args[1] if len(args) > 1 else ''} failed (exit {result.returncode})")
    return result


@contextmanager
def session_lock():
    """One managed run per user across workspaces; never unlink a live lock inode."""
    path = Path(tempfile.gettempdir()) / f"theater-orbstack-{os.getuid()}.lock"
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise RuntimeError("Refusing unsafe integration session lock")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another managed integration run is active; wait for it to finish") from None
        yield
    finally:
        os.close(fd)


class Services:
    def __init__(self):
        self.orb = shutil.which("orbctl") or str(Path.home() / ".orbstack/bin/orbctl")
        self.docker = shutil.which("docker")
        if not self.docker or not Path(self.orb).is_file():
            raise RuntimeError("OrbStack and its Docker CLI are required for local integration tests")
        self.env = dict(os.environ, DOCKER_CONTEXT="orbstack", SEATSIX_INTEGRATION_MANAGED="1")
        for name in ("DOCKER_HOST", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"):
            self.env.pop(name, None)
        self.started_orb = False
        self.had_gui = True  # Preserve the GUI if its original state cannot be determined.
        self.before = None

    def docker_command(self, *args, check=True):
        return command([self.docker, "--context", "orbstack", *args], check=check, env=self.env)

    def owned(self):
        result = {}
        for kind, spec in SERVERS.items():
            info = self.docker_command("inspect", spec["name"], check=False)
            if info.returncode:
                if "no such object" in info.stderr.lower() or "no such container" in info.stderr.lower():
                    result[kind] = None
                    continue
                raise RuntimeError("Cannot inspect local test containers")
            item = json.loads(info.stdout)[0]
            if item.get("Config", {}).get("Labels", {}).get(LABEL) != str(ROOT):
                raise RuntimeError(f"Refusing test container without this workspace's label: {spec['name']}")
            result[kind] = item
        return result

    def start(self):
        status = command([self.orb, "status"], check=False)
        expected = {0: "Running", 1: "Stopped", 2: "Starting"}
        if status.stdout.strip() != expected.get(status.returncode):
            raise RuntimeError("Cannot reliably determine OrbStack status; refusing to change it")
        if status.returncode == 1:
            self.had_gui = command(["pgrep", "-x", "OrbStack"], check=False).returncode != 1
            # Mark before starting so a partially failed start still reaches teardown.
            self.started_orb = True
            print("Starting OrbStack for this integration run...", flush=True)
            command([self.orb, "start"], timeout=120)
        deadline = time.monotonic() + 90
        while self.docker_command("info", "--format", "{{.ServerVersion}}", check=False).returncode:
            if time.monotonic() >= deadline:
                raise RuntimeError("OrbStack Docker did not become ready within 90 seconds")
            time.sleep(1)
        self.before = self.owned()

    def finish(self):
        errors = []
        if self.before is not None:
            try:
                # Validate every name before stopping anything. Address IDs, never reused names.
                after = self.owned()
                for kind, item in after.items():
                    previous = self.before[kind]
                    if item and item.get("State", {}).get("Running") and not (previous and previous.get("State", {}).get("Running")):
                        try:
                            self.docker_command("stop", "--time", "10", item["Id"])
                        except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
                            errors.append(str(exc))
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
                errors.append(str(exc))
        if self.started_orb:
            try:
                running = self.docker_command("ps", "--quiet").stdout.strip()
                machines = command([self.orb, "list", "--running", "--quiet"]).stdout.strip()
                if running or machines or errors:
                    print("Keeping OrbStack running: another workload is active or cleanup could not be verified.", file=sys.stderr)
                else:
                    command([self.orb, "stop"], timeout=90)
                    if command([self.orb, "status"], check=False).stdout.strip() != "Stopped":
                        raise RuntimeError("OrbStack did not confirm that it stopped")
                    if not self.had_gui:
                        command(["osascript", "-e", 'if application id "dev.kdrag0n.MacVirt" is running then tell application id "dev.kdrag0n.MacVirt" to quit'])
                    print("Stopped OrbStack started by this integration run.", flush=True)
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
                errors.append(str(exc))
        if errors:
            raise RuntimeError("Integration teardown incomplete: " + "; ".join(errors))


def run_child(args, env):
    """Keep teardown behind all test processes, including on Ctrl-C / SIGTERM."""
    child = subprocess.Popen(args, cwd=ROOT, env=env, start_new_session=True)
    try:
        return child.wait()
    finally:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        finally:
            # A test may leave grandchildren after its direct process exits.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-pull", action="store_true", help="Reuse downloaded test images")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="Optional foreground test command after --; default: smoke.py")
    args = parser.parse_args(argv)
    test_command = args.command
    if test_command[:1] == ["--"]:
        test_command = test_command[1:]
    if not test_command:
        test_command = [sys.executable, "-B", str(HERE / "smoke.py")]
    services = Services()
    interrupted = [0]

    def on_signal(number, _frame):
        interrupted[0] = number
        # Protect child-process teardown too, before control reaches main's finally.
        for pending in (signal.SIGINT, signal.SIGTERM):
            signal.signal(pending, signal.SIG_IGN)
        raise InterruptedError("Integration run interrupted")

    with session_lock():
        handlers = {s: signal.signal(s, on_signal) for s in (signal.SIGINT, signal.SIGTERM)}
        result = 1
        try:
            services.start()
            setup_command = [sys.executable, "-B", str(HERE / "setup.py"), "--managed"]
            if args.no_pull:
                setup_command.append("--no-pull")
            result = run_child(setup_command, services.env)
            if result == 0:
                result = run_child(test_command, services.env)
        except InterruptedError:
            result = 128 + interrupted[0]
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
            result = 1
            print(f"Integration run failed: {exc}", file=sys.stderr)
        finally:
            # A second interrupt must not skip teardown. All cleanup commands have timeouts.
            for s in handlers:
                signal.signal(s, signal.SIG_IGN)
            try:
                services.finish()
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
                print(str(exc), file=sys.stderr)
                if result == 0:
                    result = 1
            finally:
                for s, handler in handlers.items():
                    signal.signal(s, handler)
        return result if result >= 0 else 128 - result


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError) as exc:
        raise SystemExit(str(exc)) from None
