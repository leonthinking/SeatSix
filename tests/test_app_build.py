"""Build orchestration tests with fake Swift and signing, never a real build."""

import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import struct
import time
import unittest
from unittest import mock


BUILD_SCRIPT = Path(__file__).resolve().parents[1] / "scripts/build-app.sh"


class AppBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "docs").mkdir()
        (self.root / "tools").mkdir()
        shutil.copyfile(BUILD_SCRIPT, self.root / "scripts/build-app.sh")
        shutil.copyfile(BUILD_SCRIPT.with_name("Info.plist"), self.root / "scripts/Info.plist")
        shutil.copyfile(BUILD_SCRIPT.with_name("publish-app.py"), self.root / "scripts/publish-app.py")
        (self.root / "scripts/build-icon.sh").write_text('cp "$1" "$3"\n')
        (self.root / "icon").mkdir()
        (self.root / "icon/SeatSix.png").write_bytes(b"icon-stub")
        (self.root / "docs/third-party-media.md").write_text("test notice")
        (self.root / "LICENSE").write_text("test license")
        (self.root / "scripts/bundle-media-libraries.py").write_text("# Deliberate offline stub.\n")
        self.app = self.root / "build/SeatSix.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        shutil.copyfile(self.root / "scripts/Info.plist", self.app / "Contents/Info.plist")
        (self.app / "Contents/MacOS/SeatSix").write_text("old")
        self.legacy = self.root / "build/Theater.app"
        (self.app / "original-marker").write_text("preserve on failure")
        self.log = self.root / "events.log"
        self.gate = self.root / "allow-first-sign"
        self.processes = []
        self.addCleanup(self.stop_processes)
        self.make_tools()

    def stop_processes(self):
        # Release test stubs before terminating the top-level build processes.
        self.gate.touch()
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=5)

    def make_tools(self):
        common = '''import os, sys, time
from pathlib import Path
root = Path(os.environ["SEATSIX_TEST_ROOT"])
build_id = os.environ["SEATSIX_TEST_BUILD_ID"]
def event(message):
    fd = os.open(root / "events.log", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, (build_id + ":" + message + "\\n").encode())
    finally:
        os.close(fd)
'''
        swift = self.root / "tools/swift"
        swift.write_text(f"#!{sys.executable}\n" + common + '''
binary_dir = root / "fake-bin"
if "--arch" in sys.argv:
    cpu = sys.argv[sys.argv.index("--arch") + 1]
    edition = "system" if os.environ.get("SEATSIX_SYSTEM_PLAYER") == "1" else "full"
    if edition == "full":
        assert Path(os.environ["SEATSIX_DECODER_PREFIX"]).samefile(root / "decoder-sdk")
    binary_dir = root / ("fake-bin-" + cpu)
    if "--show-bin-path" not in sys.argv:
        event(edition + "-" + cpu)
binary_dir.mkdir(exist_ok=True)
if "--show-bin-path" in sys.argv:
    print(binary_dir)
else:
    event("build")
    event("configuration=" + sys.argv[sys.argv.index("-c") + 1])
    assert sys.argv[sys.argv.index("--product") + 1] == "SeatSix"
    (binary_dir / "SeatSix").write_text(build_id)
    (binary_dir / "SeatSix_SeatSixApp.bundle").mkdir(exist_ok=True)
    (binary_dir / "Theater_TheaterApp.bundle").mkdir(exist_ok=True)
''')
        swift.chmod(0o755)
        lipo = self.root / "tools/lipo"
        lipo.write_text(f"#!{sys.executable}\n" + common + '''
assert [Path(path).name for path in sys.argv[2:4]] == ["SeatSix-arm64", "SeatSix-x86_64"]
Path(sys.argv[sys.argv.index("-output") + 1]).write_text("universal")
''')
        lipo.chmod(0o755)
        python = self.root / "tools/python3"
        python.write_text(f"#!{sys.executable}\n" + common + '''
if len(sys.argv) > 1 and sys.argv[1] == "-":
    event("lock-request")
os.execv(sys.executable, [sys.executable] + sys.argv[1:])
''')
        python.chmod(0o755)
        (self.root / "scripts/sign-app.py").write_text(common + '''
import hashlib, json, plistlib
app = Path(sys.argv[1])
previous = Path(sys.argv[sys.argv.index("--previous-app") + 1]) if "--previous-app" in sys.argv else None
event("sign-start")
event("mode=" + ("public" if "--public" in sys.argv else "local" if "--local" in sys.argv else "certificate"))
if previous and previous.exists():
    info = plistlib.loads((previous / "Contents/Info.plist").read_bytes())
    event("previous=" + (previous / "Contents/MacOS" / info["CFBundleExecutable"]).read_text())
if os.environ.get("SEATSIX_TEST_BLOCK_SIGN") == "1":
    deadline = time.monotonic() + 15
    while not (root / "allow-first-sign").exists():
        if time.monotonic() > deadline:
            sys.exit(20)
        time.sleep(0.01)
if os.environ.get("SEATSIX_TEST_FAIL_SIGN") == "1":
    sys.exit(8)
event("verify")
if os.environ.get("SEATSIX_TEST_FAIL_VERIFY") == "1":
    sys.exit(9)
manifest = {str(path.relative_to(app)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in app.rglob("*") if path.is_file()}
(app / "test-signature.json").write_text(json.dumps(manifest, sort_keys=True))
event("signed")
''')

    def start_build(self, build_id, *, block_sign=False, fail_sign=False, fail_verify=False, arguments=(), explicit_identity=None):
        environment = os.environ.copy()
        environment.pop("SEATSIX_SIGNING_IDENTITY", None)
        environment.pop("THEATER_SIGNING_IDENTITY", None)
        environment.update({
            "PATH": str(self.root / "tools") + os.pathsep + environment.get("PATH", ""),
            "SEATSIX_TEST_ROOT": str(self.root),
            "SEATSIX_TEST_BUILD_ID": build_id,
            "SEATSIX_TEST_BLOCK_SIGN": "1" if block_sign else "0",
            "SEATSIX_TEST_FAIL_SIGN": "1" if fail_sign else "0",
            "SEATSIX_TEST_FAIL_VERIFY": "1" if fail_verify else "0",
        })
        if explicit_identity is not None:
            environment["SEATSIX_SIGNING_IDENTITY"] = explicit_identity
        process = subprocess.Popen(["/bin/bash", "scripts/build-app.sh", *arguments], cwd=self.root,
                                   env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(process)
        return process

    def events(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def wait_for(self, event):
        deadline = time.monotonic() + 5
        while event not in self.events():
            if time.monotonic() > deadline:
                self.fail(f"Timed out waiting for {event}; events: {self.events()}")
            time.sleep(0.01)

    def complete(self, process):
        output, errors = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, errors)
        self.assertEqual(output.count("Built: "), 1)

    def test_concurrent_builds_serialize_from_swift_through_publication(self):
        first = self.start_build("A", block_sign=True)
        self.wait_for("A:sign-start")
        second = self.start_build("B")
        self.wait_for("B:lock-request")
        # The second process has reached the lock wrapper while the first is
        # deliberately held in signing. It must not touch shared Swift output.
        deadline = time.monotonic() + 0.3
        while time.monotonic() < deadline:
            self.assertNotIn("B:build", self.events())
            self.assertIsNone(second.poll())
            time.sleep(0.01)
        self.gate.touch()
        self.complete(first)
        self.complete(second)
        events = self.events()
        self.assertLess(events.index("A:signed"), events.index("B:build"))
        self.assertIn("A:previous=old", events)
        self.assertIn("B:previous=A", events)
        self.assertEqual((self.app / "Contents/MacOS/SeatSix").read_text(), "B")
        self.assertFalse((self.app / "SeatSix.app").exists())
        manifest = json.loads((self.app / "test-signature.json").read_text())
        actual = {str(path.relative_to(self.app)): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in self.app.rglob("*") if path.is_file() and path.name != "test-signature.json"}
        self.assertEqual(actual, manifest)
        self.assertEqual(list((self.root / "build").glob(".SeatSix.*")), [])

    def test_failed_signing_preserves_old_bundle_and_releases_build_lock(self):
        before = {str(path.relative_to(self.app)): path.read_bytes()
                  for path in self.app.rglob("*") if path.is_file()}
        failed = self.start_build("failed", fail_sign=True)
        output, errors = failed.communicate(timeout=10)
        self.assertNotEqual(failed.returncode, 0, errors)
        self.assertNotIn("Built: ", output)
        after = {str(path.relative_to(self.app)): path.read_bytes()
                 for path in self.app.rglob("*") if path.is_file()}
        self.assertEqual(after, before)
        self.assertEqual(list((self.root / "build").glob(".SeatSix.*")), [])
        successful = self.start_build("recovery")
        self.complete(successful)
        self.assertIn("recovery:previous=old", self.events())
        self.assertEqual((self.app / "Contents/MacOS/SeatSix").read_text(), "recovery")

    def test_explicit_local_release_is_forwarded_and_publishes_verified_bundle(self):
        local = self.start_build("local", arguments=("release", "--local"))
        self.complete(local)
        self.assertIn("local:configuration=release", self.events())
        self.assertIn("local:mode=local", self.events())
        self.assertIn("local:verify", self.events())
        self.assertEqual((self.app / "Contents/MacOS/SeatSix").read_text(), "local")
        self.assertTrue((self.app / "test-signature.json").exists())
        self.assertEqual(os.readlink(self.legacy), "SeatSix.app")
        plist = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        self.assertEqual([plist[key] for key in ("CFBundleExecutable", "CFBundleDisplayName", "CFBundleName")],
                         ["SeatSix"] * 3)
        self.assertEqual(plist["CFBundleIdentifier"], "com.theater.mac")
        resources = self.app / "Contents/Resources"
        self.assertEqual((resources / plist["CFBundleIconFile"]).read_bytes(), b"icon-stub")
        self.assertTrue((resources / "SeatSix_SeatSixApp.bundle").is_dir())
        self.assertFalse((resources / "Theater_TheaterApp.bundle").exists())
        self.assertEqual(list((self.root / "build").glob(".SeatSix.*")), [])

    def test_public_release_is_universal_and_keeps_local_app_separate(self):
        self.complete(self.start_build("public", arguments=("release", "--public")))
        self.assertIn("public:system-arm64", self.events())
        self.assertIn("public:system-x86_64", self.events())
        self.assertIn("public:mode=public", self.events())
        app = self.root / "build/public/SeatSix.app"
        self.assertEqual((app / "Contents/MacOS/SeatSix").read_text(), "universal")
        self.assertEqual((app / "Contents/Resources/LICENSE").read_text(), "test license")
        self.assertFalse((app / "Contents/Frameworks").exists())
        self.assertFalse((app / "Contents/Resources/Third-Party-Media.md").exists())
        self.assertFalse((app.parent / "Theater.app").is_symlink())
        self.assertEqual((self.app / "Contents/MacOS/SeatSix").read_text(), "old")

    def test_full_release_uses_universal_sdk_and_embeds_third_party_notices(self):
        sdk = self.root / "decoder-sdk"
        for path in ("include/mpv/client.h", "lib/libmpv.dylib", "ThirdPartyNotices/COPYING"):
            (sdk / path).parent.mkdir(parents=True, exist_ok=True)
            (sdk / path).write_text("fixture")
        with mock.patch.dict(os.environ, {"SEATSIX_DECODER_PREFIX": str(sdk), "SEATSIX_SYSTEM_PLAYER": "1"}):
            self.complete(self.start_build("full", arguments=("release", "--full")))
        self.assertIn("full:full-arm64", self.events())
        self.assertIn("full:full-x86_64", self.events())
        self.assertIn("full:mode=public", self.events())
        app = self.root / "build/full/SeatSix.app"
        self.assertEqual((app / "Contents/Resources/ThirdPartyNotices/COPYING").read_text(), "fixture")
        self.assertEqual((app / "Contents/MacOS/SeatSix").read_text(), "universal")
        self.assertFalse((app.parent / "Theater.app").exists())
        self.assertEqual((self.app / "Contents/MacOS/SeatSix").read_text(), "old")

    def test_local_signing_and_verification_failure_preserve_published_bundle(self):
        before = {str(path.relative_to(self.app)): path.read_bytes()
                  for path in self.app.rglob("*") if path.is_file()}
        for phase in ("sign", "verify"):
            with self.subTest(phase=phase):
                failed = self.start_build(phase, arguments=("release", "--local"),
                                          fail_sign=phase == "sign", fail_verify=phase == "verify")
                output, errors = failed.communicate(timeout=10)
                self.assertNotEqual(failed.returncode, 0, errors)
                self.assertNotIn("Built: ", output)
                after = {str(path.relative_to(self.app)): path.read_bytes()
                         for path in self.app.rglob("*") if path.is_file()}
                self.assertEqual(after, before)
                self.assertEqual(list((self.root / "build").glob(".SeatSix.*")), [])
        recovery = self.start_build("recovery", arguments=("--local",))
        self.complete(recovery)
        self.assertIn("recovery:configuration=debug", self.events())
        self.assertIn("recovery:previous=old", self.events())

    def test_invalid_arguments_or_local_identity_conflict_do_not_build_or_publish(self):
        before = {str(path.relative_to(self.app)): path.read_bytes()
                  for path in self.app.rglob("*") if path.is_file()}
        cases = [
            (("unknown",), None), (("release", "extra"), None),
            (("release", "debug"), None), (("--local", "--local"), None),
            (("release", "--loc"), None), (("release", "--unknown"), None),
            (("release", "--local"), "A" * 40), (("--local",), ""),
        ]
        for arguments, explicit in cases:
            with self.subTest(arguments=arguments, explicit=explicit):
                failed = self.start_build("invalid", arguments=arguments, explicit_identity=explicit)
                output, errors = failed.communicate(timeout=10)
                self.assertEqual(failed.returncode, 2, errors)
                self.assertNotIn("Built: ", output)
                self.assertEqual(self.events(), [])
                after = {str(path.relative_to(self.app)): path.read_bytes()
                         for path in self.app.rglob("*") if path.is_file()}
                self.assertEqual(after, before)

    def install_legacy_bundle(self):
        self.app.rename(self.legacy)
        info = self.legacy / "Contents/Info.plist"
        metadata = plistlib.loads(info.read_bytes())
        metadata["CFBundleExecutable"] = "Theater"
        info.write_bytes(plistlib.dumps(metadata))
        (self.legacy / "Contents/MacOS/SeatSix").rename(self.legacy / "Contents/MacOS/Theater")

    def test_first_upgrade_uses_previous_signature_and_preserves_legacy_entry(self):
        self.install_legacy_bundle()
        failure = self.start_build("bad", fail_verify=True)
        self.assertNotEqual(failure.wait(timeout=10), 0)
        self.assertFalse(self.app.exists())
        self.assertFalse(self.legacy.is_symlink())
        self.assertTrue((self.legacy / "original-marker").is_file())
        self.complete(self.start_build("upgrade"))
        self.assertIn("upgrade:previous=old", self.events())
        self.assertEqual(os.readlink(self.legacy), "SeatSix.app")
        self.assertEqual((self.legacy / "Contents/MacOS/SeatSix").read_text(), "upgrade")

    def test_interrupted_publication_preserves_both_original_app_entries(self):
        # Interrupt the real publisher immediately after a successful filesystem
        # rename, before it has a chance to register a rollback callback.
        publisher = self.root / "scripts/publish-app.py"
        original = publisher.read_text()
        wrapper = '''import os, signal
from pathlib import Path
rename = Path.rename
def interrupt_after_rename(source, target):
    result = rename(source, target)
    if source.name == {source!r} and target.name == {target!r}:
        os.kill(os.getpid(), signal.SIGTERM)
    return result
Path.rename = interrupt_after_rename
'''
        self.install_legacy_bundle()
        for source, target in [("SeatSix.app", "SeatSix.app"),
                               ("Theater.app", "previous-Theater.app"),
                               ("legacy-link", "Theater.app")]:
            with self.subTest(source=source, target=target):
                publisher.write_text(wrapper.format(source=source, target=target) + original)
                failed = self.start_build("interrupted")
                self.assertNotEqual(failed.wait(timeout=10), 0)
                self.assertFalse(self.app.exists())
                self.assertFalse(self.legacy.is_symlink())
                self.assertEqual((self.legacy / "Contents/MacOS/Theater").read_text(), "old")
                self.assertEqual(list(self.app.parent.glob(".SeatSix.*")), [])

        publisher.write_text(original)
        self.complete(self.start_build("first-upgrade"))
        publisher.write_text(wrapper.format(source="SeatSix.app", target="SeatSix.app") + original)
        self.assertNotEqual(self.start_build("next-upgrade").wait(timeout=10), 0)
        self.assertEqual(os.readlink(self.legacy), self.app.name)
        self.assertEqual((self.app / "Contents/MacOS/SeatSix").read_text(), "first-upgrade")

    def test_missing_icon_stops_publication_before_signing(self):
        (self.root / "icon/SeatSix.png").unlink()
        failed = self.start_build("icon")
        self.assertNotEqual(failed.wait(timeout=10), 0)
        self.assertNotIn("icon:sign-start", self.events())
        self.assertFalse(self.legacy.exists())
        self.assertTrue((self.app / "original-marker").is_file())

    def test_unrelated_directory_or_link_at_legacy_path_is_preserved(self):
        self.legacy.mkdir()
        marker = self.legacy / "keep"
        marker.write_text("keep")
        self.assertNotEqual(self.start_build("directory").wait(timeout=10), 0)
        self.assertEqual(marker.read_text(), "keep")
        self.assertTrue((self.app / "original-marker").exists())
        moved = self.root / "other"
        self.legacy.rename(moved)
        self.legacy.symlink_to(moved)
        self.assertNotEqual(self.start_build("symlink").wait(timeout=10), 0)
        self.assertEqual(os.readlink(self.legacy), str(moved))
        self.assertTrue((self.app / "original-marker").exists())

    def test_master_icon_has_full_macos_resolution(self):
        source = BUILD_SCRIPT.parents[1] / "icon/SeatSix.png"
        header = source.read_bytes()[:33]
        self.assertEqual(header[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(header[12:16], b"IHDR")
        self.assertEqual(struct.unpack(">II", header[16:24]), (1024, 1024))

    def test_real_icon_round_trips_at_all_finder_and_retina_sizes(self):
        output = self.root / "SeatSix.icns"
        source = BUILD_SCRIPT.parents[1] / "icon/SeatSix.png"
        subprocess.run(["/bin/bash", BUILD_SCRIPT.with_name("build-icon.sh"), source, self.root, output],
                       check=True)
        decoded = self.root / "Decoded.iconset"
        subprocess.run(["/usr/bin/iconutil", "-c", "iconset", output, "-o", decoded], check=True)
        for points in (16, 32, 128, 256, 512):
            for scale, suffix in ((1, ""), (2, "@2x")):
                with self.subTest(points=points, scale=scale):
                    image = (decoded / f"icon_{points}x{points}{suffix}.png").read_bytes()
                    self.assertEqual(struct.unpack(">II", image[16:24]), (points * scale,) * 2)

    def test_default_signing_failure_never_retries_local_mode(self):
        failed = self.start_build("default", fail_sign=True)
        output, errors = failed.communicate(timeout=10)
        self.assertNotEqual(failed.returncode, 0, errors)
        self.assertNotIn("Built: ", output)
        self.assertEqual(self.events().count("default:sign-start"), 1)
        self.assertIn("default:mode=certificate", self.events())
        self.assertNotIn("default:mode=local", self.events())
        self.assertEqual((self.app / "Contents/MacOS/SeatSix").read_text(), "old")


if __name__ == "__main__":
    unittest.main()
