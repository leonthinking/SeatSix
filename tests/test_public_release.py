"""Check release inputs before any signing, network or disk-image operation."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "scripts/package-release.sh"


class PublicReleaseTests(unittest.TestCase):
    def setUp(self):
        self.env = {k: v for k, v in os.environ.items()
                    if k not in {"SEATSIX_DEVELOPER_ID", "SEATSIX_NOTARY_PROFILE"}}

    def test_rejects_tag_other_than_bundle_version(self):
        for tag in ("v999.999.999", "../wrong", ""):
            with self.subTest(tag=tag):
                result = subprocess.run([PACKAGE, tag], env=self.env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn("Expected release tag", result.stderr)

    def test_partial_notarization_settings_cannot_fall_back_to_adhoc(self):
        with (ROOT / "scripts/Info.plist").open("rb") as source:
            version = plistlib.load(source)["CFBundleShortVersionString"]
        for variable in ("SEATSIX_DEVELOPER_ID", "SEATSIX_NOTARY_PROFILE"):
            with self.subTest(variable=variable):
                result = subprocess.run([PACKAGE, "v" + version], env={**self.env, variable: "example"},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn("set both", result.stderr)


class AtomicReleaseTests(unittest.TestCase):
    name = "SeatSix-0.1.0-universal.dmg"
    source = "SeatSix-0.1.0-decoder-sources.tar.gz"

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.target = self.root / "v0.1.0"
        self.publisher = ROOT / "scripts/publish-release.py"

    def assets(self, directory, data, legacy=False):
        directory.mkdir()
        payloads = {self.name: data}
        if not legacy:
            payloads[self.source] = b"source for " + data
        for name, content in payloads.items():
            (directory / name).write_bytes(content)
            (directory / (name + ".sha256")).write_text(f"{hashlib.sha256(content).hexdigest()}  {name}\n")
        return directory

    def publish(self, candidate):
        return subprocess.run([sys.executable, self.publisher, candidate, self.target], capture_output=True)

    def test_atomic_initial_publish_and_replacement_exchange_complete_directories(self):
        first = self.assets(self.root / "first", b"first")
        second = self.assets(self.root / "second", b"second")
        second_inode = second.stat().st_ino
        self.publish(first).check_returncode()
        first_inode = self.target.stat().st_ino
        self.assertFalse(first.exists())
        self.publish(second).check_returncode()
        self.assertEqual(self.target.stat().st_ino, second_inode)
        self.assertEqual(second.stat().st_ino, first_inode)
        self.assertEqual((second / self.name).read_bytes(), b"first")
        self.assertEqual((self.target / self.name).read_bytes(), b"second")
        self.assertEqual((self.target / self.source).read_bytes(), b"source for second")

    def test_full_assets_upgrade_previous_local_format_and_require_source(self):
        self.assets(self.target, b"system", legacy=True)
        missing = self.assets(self.root / "two", b"system", legacy=True)
        self.assertNotEqual(self.publish(missing).returncode, 0)
        self.assertEqual((self.target / self.name).read_bytes(), b"system")
        candidate = self.assets(self.root / "full", b"full")
        self.publish(candidate).check_returncode()
        self.assertEqual((self.target / self.source).read_bytes(), b"source for full")
        self.assertEqual({p.name for p in candidate.iterdir()}, {self.name, self.name + ".sha256"})

    def test_incomplete_candidate_mismatched_hash_and_user_files_keep_previous_release(self):
        self.assets(self.target, b"previous")
        incomplete = self.assets(self.root / "partial", b"incomplete")
        (incomplete / (self.name + ".sha256")).unlink()
        self.assertNotEqual(self.publish(incomplete).returncode, 0)
        mismatch = self.assets(self.root / "mismatch", b"bad")
        (mismatch / self.name).write_bytes(b"changed")
        self.assertNotEqual(self.publish(mismatch).returncode, 0)
        self.assertNotEqual(self.publish(self.assets(self.root / "empty", b"")).returncode, 0)
        corrupt_source = self.assets(self.root / "wrong-source", b"changed")
        (corrupt_source / self.source).write_bytes(b"other sources")
        self.assertNotEqual(self.publish(corrupt_source).returncode, 0)
        extra = self.target / "notes.txt"
        extra.write_text("keep")
        self.assertNotEqual(self.publish(self.assets(self.root / "good", b"new")).returncode, 0)
        self.assertEqual(extra.read_text(), "keep")
        self.assertEqual((self.target / self.name).read_bytes(), b"previous")

    def test_concurrent_packagers_use_their_own_signed_app_and_publish_matching_pair(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        for filename in ("Info.plist", "package-release.sh", "publish-release.py"):
            shutil.copy2(ROOT / "scripts" / filename, scripts)
        (scripts / "prepare-decoder.py").write_text("""
from pathlib import Path
import sys
Path(sys.argv[1]).mkdir(parents=True, exist_ok=True)
""")
        (scripts / "decoder-sources.py").write_text("""
import os, sys
from pathlib import Path
out = Path(sys.argv[1])
notices = out / "ThirdPartyNotices"
notices.mkdir(parents=True)
(notices / "LICENSE").write_text(os.environ["BUILD_LABEL"])
(out / "decoder-sources.tar.gz").write_text(os.environ["BUILD_LABEL"])
""")
        (scripts / "bundle-media-libraries.py").write_text("""
from pathlib import Path
import sys
assert sys.argv[1] == "--verify-full-app" and Path(sys.argv[2]).is_dir()
""")
        builder = scripts / "build-app.sh"
        builder.write_text("""#!/bin/bash
set -eu
[[ "$1" == "release" && "$2" == "--full" && -d "$SEATSIX_DECODER_PREFIX" ]]
[[ "$(cat "$SEATSIX_DECODER_NOTICES/LICENSE")" == "$BUILD_LABEL" ]]
app="$SEATSIX_PUBLIC_OUTPUT_DIR/SeatSix.app/Contents"
mkdir -p "$app"
cp scripts/Info.plist "$app/Info.plist"
echo "$BUILD_LABEL" > "$app/signature"
touch "$SYNC_DIR/$BUILD_LABEL"
""")
        builder.chmod(0o755)
        tools = self.root / "tools"
        tools.mkdir()
        for name in ("codesign", "spctl", "xcrun", "ditto"):
            tool = tools / name
            tool.write_text("#!/bin/sh\nexit 0\n")
            tool.chmod(0o755)
        # Pause both packagers between signing and imaging so sharing an app
        # path would let either invocation capture the other's signature.
        imaging = tools / "hdiutil"
        imaging.write_text(f"#!{sys.executable}\n" + """
import os, sys, time
from pathlib import Path
if sys.argv[1] == "create":
    deadline = time.monotonic() + 10
    while len(list(Path(os.environ["SYNC_DIR"]).iterdir())) != 2:
        if time.monotonic() > deadline:
            sys.exit(1)
        time.sleep(0.02)
    volume = Path(sys.argv[sys.argv.index("-srcfolder") + 1])
    label = (volume / "SeatSix.app/Contents/signature").read_text()
    assert label.strip() == os.environ["BUILD_LABEL"]
    Path(sys.argv[-1]).write_text(label)
elif os.environ.get("IMAGE_VERIFY_FAILURE") == "1":
    sys.exit(1)
""")
        imaging.chmod(0o755)
        sync_dir = self.root / "ready"
        sync_dir.mkdir()
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], SYNC_DIR=str(sync_dir),
                   SEATSIX_DECODER_PREFIX=str(self.root / "SDK"))
        env.pop("SEATSIX_DEVELOPER_ID", None)
        env.pop("SEATSIX_NOTARY_PROFILE", None)
        signed = dict(env, BUILD_LABEL="signed", SEATSIX_DEVELOPER_ID="A" * 40, SEATSIX_NOTARY_PROFILE="test")
        runs = [subprocess.Popen([scripts / "package-release.sh"], cwd=self.root, env=environment,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                for environment in (signed, dict(env, BUILD_LABEL="adhoc"))]
        for process in runs:
            output, errors = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, (output, errors))
        version = plistlib.loads((scripts / "Info.plist").read_bytes())["CFBundleShortVersionString"]
        published = self.root / "build/releases" / ("v" + version)
        image = published / f"SeatSix-{version}-universal.dmg"
        data = image.read_bytes()
        self.assertIn(data, (b"signed\n", b"adhoc\n"))
        self.assertEqual((published / (image.name + ".sha256")).read_text(),
                         f"{hashlib.sha256(data).hexdigest()}  {image.name}\n")
        source = published / f"SeatSix-{version}-decoder-sources.tar.gz"
        self.assertEqual(source.read_bytes(), data.strip())
        self.assertEqual((published / (source.name + ".sha256")).read_text(),
                         f"{hashlib.sha256(source.read_bytes()).hexdigest()}  {source.name}\n")
        failed = subprocess.run([scripts / "package-release.sh"], cwd=self.root,
                                env=dict(env, BUILD_LABEL="adhoc", IMAGE_VERIFY_FAILURE="1"),
                                capture_output=True, timeout=20)
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(image.read_bytes(), data)
        self.assertEqual(source.read_bytes(), data.strip())
        self.assertEqual(list(published.parent.iterdir()), [published])
