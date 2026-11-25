"""Exercise the public release protocol against disposable tags and a local GitHub fixture."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PUBLISH = ROOT / "scripts/publish-github-release.sh"
NAME = "SeatSix-0.1.0-universal.dmg"
SOURCE = "SeatSix-0.1.0-decoder-sources.tar.gz"
TAG = "v0.1.0"

# Model draft creation, upload, download, publication, and an interruption.
GH = r'''
import os, shutil, sys, subprocess
from pathlib import Path
args = sys.argv[1:]
store = Path(os.environ["RELEASE_FIXTURE"])
state = store / "state"
if args[0] == "api":
    if state.exists():
        print(state.read_text())
elif args[:2] == ["release", "create"]:
    assert "--draft" in args and not state.exists()
    state.write_text("resume")
elif args[:2] == ["release", "upload"]:
    assert state.read_text() == "resume"
    for asset in args[3:args.index("--clobber")]:
        shutil.copyfile(asset, store / Path(asset).name)
        if os.environ.get("INTERRUPT_UPLOAD"):
            sys.exit(1)
elif args[:2] == ["release", "download"]:
    output = Path(args[args.index("--dir") + 1])
    for file in store.iterdir():
        if file != state:
            shutil.copyfile(file, output / file.name)
    if os.environ.get("CORRUPT_DOWNLOAD"):
        (output / os.environ["CORRUPT_DOWNLOAD"]).write_bytes(b"corrupt")
    if os.environ.get("MOVE_TAG"):
        subprocess.run(["git", "-C", os.environ["REMOTE_FIXTURE"], "tag", "-f", "v0.1.0", "HEAD~1"], check=True)
elif args[:2] == ["release", "edit"]:
    assert "--draft=false" in args and state.read_text() == "resume"
    state.write_text("existing")
else:
    sys.exit(2)
'''


class GitHubReleaseTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        self.remote = root / "origin"
        self.checkout = root / "checkout"
        self.assets = root / "assets"
        self.store = root / "draft"
        for path in (self.remote, self.assets, self.store):
            path.mkdir()
        self.git(self.remote, "init", "-q")
        for key, value in (("user.name", "Fixture"), ("user.email", "fixture@example.invalid"),
                           ("commit.gpgsign", "false"), ("tag.gpgsign", "false")):
            self.git(self.remote, "config", key, value)
        for title in ("previous", "tested"):
            self.git(self.remote, "commit", "--allow-empty", "-qm", title)
        self.git(self.remote, "tag", "-a", TAG, "-m", "release")
        self.commit = self.git(self.remote, "rev-parse", "HEAD")
        self.git(root, "clone", "-q", str(self.remote), str(self.checkout))
        fake = root / "gh"
        fake.write_text(f"#!{sys.executable}\n" + GH)
        fake.chmod(0o755)
        self.env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                    "RELEASE_FIXTURE": str(self.store), "REMOTE_FIXTURE": str(self.remote)}
        for name, payload in ((NAME, b"synthetic disk image"), (SOURCE, b"corresponding source")):
            (self.assets / name).write_bytes(payload)
            (self.assets / (name + ".sha256")).write_text(f"{hashlib.sha256(payload).hexdigest()}  {name}\n")

    @staticmethod
    def git(path, *arguments):
        return subprocess.run(["git", "-C", path, *arguments], capture_output=True,
                              text=True, check=True).stdout.strip()

    def publish(self, **settings):
        return subprocess.run([PUBLISH, TAG, self.commit, self.assets], cwd=self.checkout,
                              capture_output=True, text=True, env={**self.env, **settings})

    def test_interrupted_upload_can_resume_matching_draft(self):
        self.assertNotEqual(self.publish(INTERRUPT_UPLOAD="1").returncode, 0)
        self.assertEqual((self.store / "state").read_text(), "resume")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.store / "state").read_text(), "existing")
        self.assertEqual({p.name for p in self.store.iterdir()} - {"state"},
                         {NAME, NAME + ".sha256", SOURCE, SOURCE + ".sha256"})
        self.assertNotEqual(self.publish().returncode, 0)  # never overwrite a published version

    def test_source_is_required_before_draft_creation(self):
        (self.assets / SOURCE).unlink()
        self.assertNotEqual(self.publish().returncode, 0)
        self.assertFalse((self.store / "state").exists())

    def test_draft_with_corrupt_download_or_unexpected_asset_stays_private(self):
        result = self.publish(CORRUPT_DOWNLOAD=SOURCE)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checksum does not match", result.stderr)
        (self.store / "unexpected.txt").write_text("unexpected")
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unexpected or missing", result.stderr)
        self.assertEqual((self.store / "state").read_text(), "resume")

    def test_retargeted_tag_cannot_publish_already_uploaded_assets(self):
        result = self.publish(MOVE_TAG="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no longer identifies", result.stderr)
        self.assertEqual((self.store / "state").read_text(), "resume")
