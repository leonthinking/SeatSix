"""Regressions for publishing the public source without its private work history."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("public_source", ROOT / "scripts/export-public-source.py")
public_source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(public_source)


class PublicSourceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.repo = Path(temp.name) / "development"
        self.repo.mkdir()
        self.destination = Path(temp.name) / "public"
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.filemode", "true")
        (self.repo / "scripts").mkdir()
        self.manifest = self.repo / public_source.MANIFEST
        self.manifest.write_text("app.swift\nscripts/build.sh\n")
        (self.repo / "app.swift").write_text("public code\n")
        (self.repo / "scripts/build.sh").write_text("#!/bin/sh\n")
        (self.repo / "scripts/build.sh").chmod(0o755)
        (self.repo / "record.txt").write_text("synthetic private history\n")
        self.commit()

    def git(self, *arguments):
        subprocess.run(["git", "-C", str(self.repo), *arguments], capture_output=True, check=True)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture")

    def test_export_only_contains_reviewed_blobs_from_selected_commit(self):
        (self.repo / "app.swift").write_text("updated code\n")
        (self.repo / "record.txt").unlink()
        self.commit()
        (self.repo / "app.swift").write_text("uncommitted edits\n")
        self.manifest.write_text("record.txt\n")
        (self.repo / "secret.txt").write_text("untracked fixture\n")
        self.assertEqual(public_source.export(self.repo, self.destination, "HEAD~1"), 2)
        self.assertEqual({p.relative_to(self.destination).as_posix() for p in self.destination.rglob("*")},
                         {"app.swift", "scripts", "scripts/build.sh"})
        self.assertEqual((self.destination / "app.swift").read_text(), "public code\n")
        self.assertEqual((self.destination / "scripts/build.sh").stat().st_mode & 0o777, 0o755)

    def test_export_rejects_existing_destination_without_writing(self):
        self.destination.mkdir()
        marker = self.destination / "keep"
        marker.write_text("preserve")
        with self.assertRaises(FileExistsError):
            public_source.export(self.repo, self.destination)
        self.assertEqual(list(self.destination.iterdir()), [marker])
        self.assertEqual(marker.read_text(), "preserve")

    def test_missing_paths_directories_and_links_fail_closed(self):
        (self.repo / "alias").symlink_to("record.txt")
        for name in ("missing", "alias", "scripts", "../outside", ".git/config"):
            with self.subTest(name=name):
                self.manifest.write_text("app.swift\n" + name + "\n")
                self.commit()
                with self.assertRaises(ValueError):
                    public_source.export(self.repo, self.destination)
                self.assertFalse(self.destination.exists())

    def test_public_manifest_contains_required_inputs_and_no_private_materials(self):
        paths = (ROOT / public_source.MANIFEST).read_text().splitlines()
        for name in paths:
            with self.subTest(name=name):
                self.assertTrue((ROOT / name).is_file(), name)
                self.assertNotIn(name.split("/")[0], {".git", ".runtime", "build", "work", "outputs", "prototype"})
                self.assertFalse(name.startswith(("docs/native-verification/", "docs/prototype-previews/")))
        for required in ("README.md", "LICENSE", "Package.swift", "scripts/build-app.sh",
                         "scripts/test.sh", ".github/workflows/release.yml", "scripts/package-release.sh",
                         "scripts/verify-installed-app.swift", "scripts/test-release-decoder.py",
                         "tests/fixtures/hevc-ac3.mkv", "docs/decoder-sources.md",
                         "scripts/decoder-sources.py", "scripts/decoder-sources.lock.json", "scripts/prepare-decoder.py"):
            self.assertIn(required, paths)
        # Adding compiled sources requires an explicit public-source review.
        compiled = {p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources").rglob("*")
                    if p.suffix in (".swift", ".c", ".h")}
        self.assertFalse(compiled.difference(paths), compiled.difference(paths))


if __name__ == "__main__":
    unittest.main()
