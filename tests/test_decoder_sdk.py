import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("decoder_sdk", Path(__file__).resolve().parents[1] / "scripts/prepare-decoder.py")
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)


class DecoderSDKTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.library = self.cache / sdk.RUNTIME_NAME
        self.source = self.cache / sdk.SOURCE_NAME
        self.destination = self.root / "sdk"
        with zipfile.ZipFile(self.library, "w") as archive:
            archive.writestr("libmpv.2.dylib", b"universal")
        with tarfile.open(self.source, "w:gz") as archive:
            for name in sdk.HEADERS:
                info = tarfile.TarInfo("mpv-0.41.0/include/mpv/" + name)
                info.size = 3
                archive.addfile(info, io.BytesIO(b"api"))

    def prepare(self):
        runtime_sha = hashlib.sha256(self.library.read_bytes()).hexdigest()
        source_sha = hashlib.sha256(self.source.read_bytes()).hexdigest()
        with patch.multiple(sdk, RUNTIME_SHA=runtime_sha, SOURCE_SHA=source_sha):
            sdk.prepare(self.destination, self.cache)

    def test_verified_inputs_create_and_check_exact_sdk(self):
        self.prepare()
        self.prepare()
        self.assertEqual((self.destination / "lib/libmpv.dylib").read_bytes(), b"universal")
        self.assertEqual((self.destination / "include/mpv/render_gl.h").read_bytes(), b"api")
        (self.destination / "extra").touch()
        with self.assertRaisesRegex(ValueError, "layout"):
            self.prepare()
        (self.destination / "extra").unlink()
        (self.destination / "lib/libmpv.2.dylib").write_bytes(b"other")
        with self.assertRaisesRegex(ValueError, "differs"):
            self.prepare()

    def test_inputs_must_match_hard_coded_digests(self):
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            sdk.prepare(self.destination, self.cache)
        self.assertFalse(self.destination.exists())

    def test_rejects_unexpected_archive_paths_before_publication(self):
        with zipfile.ZipFile(self.library, "a") as archive:
            archive.writestr("../other.dylib", b"bad")
        with self.assertRaisesRegex(ValueError, "runtime entry"):
            self.prepare()
        self.assertFalse(self.destination.exists())
        self.assertFalse((self.root / "other.dylib").exists())

    def test_sdk_directories_and_abi_alias_are_validated(self):
        self.prepare()
        path = self.destination / "lib/libmpv.dylib"
        path.unlink()
        path.symlink_to((self.destination / "lib/libmpv.2.dylib").resolve())
        with self.assertRaisesRegex(ValueError, "layout"):
            self.prepare()
        lib = self.destination / "lib"
        lib.rename(self.root / "libs")
        lib.symlink_to(self.root / "libs", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "regular SDK directory"):
            self.prepare()
