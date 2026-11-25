"""Offline coverage for release source integrity, license delivery and reconstruction."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("decoder_sources", ROOT / "scripts/decoder-sources.py")
sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sources)


class DecoderSourcesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.lock = self.root / sources.LOCK.name
        self.output = self.root / "release"

    def component(self, name, members, git_dir=None):
        blob = io.BytesIO()
        with tarfile.open(fileobj=blob, mode="w:gz") as archive:
            for path, data in members.items():
                entry = tarfile.TarInfo(path)
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        data = blob.getvalue()
        sha = hashlib.sha256(data).hexdigest()
        (self.cache / sha).write_bytes(data)
        record = {"project": name, "version": "1", "file": name + ".tar.gz",
                  "sha256": sha, "url": "https://fixture.invalid/" + name}
        if git_dir:
            record["path"] = git_dir
        return record

    def package(self, archives, git=(), patches=()):
        self.lock.write_text(json.dumps({"archives": list(archives), "git": list(git), "patches": list(patches)}))
        with patch.object(sources, "LOCK", self.lock), patch.object(sources.subprocess, "run") as network:
            sources.package(self.output, self.cache)
            network.assert_not_called()

    def test_packages_verified_sources_nested_licenses_submodules_and_exact_patch(self):
        lib = self.component("library", {"lib/COPYING": b"original", "lib/ext/NOTICE.txt": b"authors"})
        tree = self.component("tree", {"git/LICENSE": b"terms", "git/src.c": b"root"}, "tree-1")
        child = self.component("submodule", {"git/COPYING": b"child", "git/src.c": b"nested"}, "tree-1/deps/child")
        raw_patch = b"upstream patch text"
        digest = hashlib.sha256(raw_patch).hexdigest()
        (self.cache / digest).write_bytes(raw_patch)
        patch_item = {"file": "patches/tree/fix.patch", "sha256": digest, "url": "https://fixture.invalid/fix"}
        self.package([lib], [tree, child], [patch_item])
        notices = self.output / sources.NOTICES
        self.assertEqual((notices / "library/ext/NOTICE.txt").read_bytes(), b"authors")
        self.assertEqual((notices / "tree-1/deps/child/COPYING").read_bytes(), b"child")
        asset = self.output / sources.ASSET
        expected = sources.sha256(asset)
        self.package([lib], [tree, child], [patch_item])
        self.assertEqual(sources.sha256(asset), expected)
        # Read the known synthetic archive back just as a recipient would.
        with tarfile.open(asset) as archive:
            for member in archive.getmembers():
                destination = self.root / sources.safe_path(member.name)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(archive.extractfile(member).read())
        restored = self.root / "recipes/sources"
        patch_path = restored.parent / patch_item["file"]
        patch_path.parent.mkdir(parents=True)
        patch_path.write_bytes(raw_patch)
        bundle = self.root / "decoder-sources"
        self.assertEqual((bundle / patch_item["file"]).read_bytes(), raw_patch)
        if hasattr(tarfile, "data_filter"):
            sources.restore(bundle, restored)
            self.assertEqual((restored / "tree-1/deps/child/src.c").read_bytes(), b"nested")
            self.assertEqual(sources.sha256(restored / lib["file"]), lib["sha256"])

    def test_interrupt_at_directory_rename_publishes_both_outputs_or_neither(self):
        record = self.component("library", {"tree/LICENSE": b"original"})
        rename = Path.rename
        for after in (False, True):
            with self.subTest(after=after):
                def interrupted(candidate, destination):
                    self.assertEqual(destination, self.output)
                    self.assertEqual({p.name for p in candidate.iterdir()}, {sources.ASSET, sources.NOTICES})
                    if after:
                        rename(candidate, destination)
                    raise KeyboardInterrupt

                with patch.object(Path, "rename", interrupted), self.assertRaises(KeyboardInterrupt):
                    self.package([record])
                self.assertEqual(self.output.exists(), after)
        self.assertEqual((self.output / sources.NOTICES / "library/LICENSE").read_bytes(), b"original")
        with tarfile.open(self.output / sources.ASSET) as archive:
            self.assertIn("decoder-sources/sources/library.tar.gz", archive.getnames())

    def test_repeated_publish_preserves_changed_licenses_extra_files_and_symlinks(self):
        record = self.component("library", {"tree/LICENSE": b"original"})
        self.package([record])
        asset = self.output / sources.ASSET
        inode = asset.stat().st_ino
        self.package([record])
        self.assertEqual(inode, asset.stat().st_ino)

        license_file = self.output / sources.NOTICES / "library/LICENSE"
        license_file.write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "Choose a new directory"):
            self.package([record])
        self.assertEqual(license_file.read_bytes(), b"modified")
        license_file.write_bytes(b"original")
        user_file = self.output / "local-notes.txt"
        user_file.write_text("keep")
        with self.assertRaisesRegex(ValueError, "Choose a new directory"):
            self.package([record])
        self.assertEqual(user_file.read_text(), "keep")
        user_file.unlink()

        external = self.root / "external-license"
        license_file.rename(external)
        license_file.symlink_to(external)
        with self.assertRaisesRegex(ValueError, "Choose a new directory"):
            self.package([record])
        self.assertTrue(license_file.is_symlink())
        self.assertEqual(external.read_bytes(), b"original")
        self.assertEqual(inode, asset.stat().st_ino)

    def test_concurrent_different_candidates_publish_one_complete_directory(self):
        ready = threading.Barrier(2)

        def prepare(candidate, cache, manifest, lock, guide):
            (candidate / sources.NOTICES).mkdir()
            (candidate / sources.NOTICES / "LICENSE").write_text(cache.name)
            (candidate / sources.ASSET).write_text(cache.name)
            ready.wait(timeout=5)

        def publish(label):
            try:
                sources.package(self.output, self.root / label)
                return label
            except ValueError as error:
                self.assertIn("Choose a new directory", str(error))
                return None

        with patch.object(sources, "create", side_effect=prepare), ThreadPoolExecutor(2) as pool:
            results = list(pool.map(publish, ["first", "second"]))
        winners = [result for result in results if result is not None]
        self.assertEqual(len(winners), 1)
        self.assertEqual((self.output / sources.ASSET).read_text(), winners[0])
        self.assertEqual((self.output / sources.NOTICES / "LICENSE").read_text(), winners[0])

    def test_detects_changed_artifact_without_polluting_cache(self):
        artifact = self.component("library", {"tree/LICENSE": b"terms"})
        stored = self.cache / artifact["sha256"]
        stored.unlink()

        def wrong_body(command, check):
            self.assertTrue(check)
            Path(command[command.index("--output") + 1]).write_bytes(b"different archive")

        with patch.object(sources.subprocess, "run", side_effect=wrong_body):
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                sources.acquire(artifact, self.cache)
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_missing_license_or_escaping_member_preserves_previous_release(self):
        self.package([self.component("good", {"tree/LICENSE": b"original"})])
        expected = sources.sha256(self.output / sources.ASSET)
        for members in ({"tree/AUTHORS": b"authors alone"}, {"tree/../../escape/LICENSE": b"bad"}):
            with self.subTest(paths=list(members)), self.assertRaises(ValueError):
                self.package([self.component("broken", members)])
            self.assertEqual(sources.sha256(self.output / sources.ASSET), expected)
            self.assertEqual((self.output / sources.NOTICES / "good/LICENSE").read_bytes(), b"original")
            self.assertFalse((self.root / "escape").exists())

    def test_rejects_colliding_notice_names_on_case_insensitive_volumes(self):
        record = self.component("bad", {"tree/A/LICENSE": b"first", "tree/a/License": b"second"})
        with self.assertRaises((ValueError, FileExistsError)):
            self.package([record])
        self.assertFalse((self.output / sources.ASSET).exists())

    def test_pins_include_full_recipe_archive_git_submodule_and_patch_inventory(self):
        manifest = json.loads(sources.LOCK.read_text())
        self.assertEqual(manifest["iina_commit"], "f86d54276547df6d14104583ea604af67433f1e1")
        self.assertEqual(manifest["binary_sha256"], "d6b3bb920f14780ec9c9df22e323e2bf72a5ca2b198473c67bf37581f0a60b6e")
        self.assertEqual(len(manifest["archives"]), 28)
        self.assertEqual(len(manifest["git"]), 18)
        self.assertEqual(len(manifest["patches"]), 5)
        git_paths = {item["path"] for item in manifest["git"]}
        for directory in ("libjxl-0.11.2/third_party/brotli", "libjxl-0.11.2/third_party/highway",
                          "libjxl-0.11.2/third_party/lcms", "libplacebo-7.360.1/3rdparty/glad"):
            self.assertIn(directory, git_paths)
        items = manifest["archives"] + manifest["git"] + manifest["patches"]
        self.assertEqual(len({item["file"] for item in items}), len(items))
        for item in items:
            self.assertRegex(item["sha256"], r"^[a-f0-9]{64}$")
            self.assertTrue(item["url"].startswith("https://"))
            if "path" in item:
                self.assertRegex(item["version"], r"^[a-f0-9]{40}$")
                self.assertIn(item["version"], item["url"])


if __name__ == "__main__":
    unittest.main()
