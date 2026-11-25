"""Upgrade local synthetic samples without duplicating either playback role."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import setup


def sample(media, brand, role):
    suffix = setup.FIXTURES[role][0]
    title = f"{brand} {role}"
    path = media / f"{title} (2026)" / f"{title}.{suffix}"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(title.encode())
    return path


class FixtureUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.runtime = Path(self.temporary.name)
        self.media = self.runtime / "media"
        self.volume = self.runtime / "volume"
        self.volume.mkdir()
        self.copied = []
        runtime_patch = patch.object(setup, "RUNTIME", self.runtime)
        runtime_patch.start()
        self.addCleanup(runtime_patch.stop)

    def docker(self, command, *args):
        # Exercise the actual shell probes and move against a synthetic local mount.
        def mounted(path):
            return path.replace("/media/", str(self.volume) + "/", 1) if path.startswith("/media/") else path

        if command == "exec":
            container, *argv = args
            self.assertEqual(container, "fixture-test")
            return subprocess.run([mounted(arg) for arg in argv], check=True, capture_output=True, text=True)
        self.assertEqual(command, "cp")
        source, target = args
        self.copied.append(Path(source))
        shutil.copyfile(source, mounted(target.removeprefix("fixture-test:")))

    def test_legacy_host_reuses_each_sample_and_needs_no_encoder(self):
        paths = {role: sample(self.media, "Theater", role) for role in setup.FIXTURES}
        with patch.object(setup.shutil, "which", side_effect=AssertionError("unexpected encoding")):
            self.assertEqual(setup.generate_media(), paths)
            self.assertEqual(setup.generate_media(), paths)
        self.assertFalse(list(self.media.glob("SeatSix*")))

    def test_missing_role_is_generated_once_alongside_legacy_role(self):
        direct = sample(self.media, "Theater", "Direct Test")

        def encode(command, check):
            self.assertTrue(check)
            Path(command[-1]).write_bytes(b"synthetic")

        with patch.object(setup.shutil, "which", return_value="/test/ffmpeg"), \
                patch.object(setup.subprocess, "run", side_effect=encode) as run:
            selected = setup.generate_media()
            self.assertEqual(setup.generate_media(), selected)
            run.assert_called_once()
        self.assertEqual(selected["Direct Test"], direct)
        self.assertEqual(selected["Compatibility Test"].name, "SeatSix Compatibility Test.mkv")

    def test_recreation_uses_retained_volume_and_only_transfers_missing_role(self):
        sample(self.media, "Theater", "Direct Test")
        selected_direct = sample(self.media, "SeatSix", "Direct Test")
        compatibility = sample(self.media, "Theater", "Compatibility Test")
        (compatibility.parent / "extra.mp4").write_text("leave on host")
        retained = sample(self.volume, "Theater", "Direct Test")
        other = self.volume / "unrelated.txt"
        other.write_text("keep")
        selected = setup.generate_media()
        self.assertEqual(selected["Direct Test"], selected_direct)
        with patch.object(setup, "docker", side_effect=self.docker):
            setup.populate_media("fixture-test", selected)
            setup.populate_media("fixture-test", selected)
        self.assertEqual(self.copied, [compatibility.with_name("movie.nfo"), compatibility])
        self.assertEqual(list(self.volume.rglob("*.mp4")), [retained])
        self.assertEqual(len(list(self.volume.rglob("*.mkv"))), 1)
        self.assertEqual(other.read_text(), "keep")
        self.assertTrue((compatibility.parent / "extra.mp4").is_file())

    def test_scan_waits_for_both_roles_in_the_selected_library(self):
        api = Mock()
        credentials = {}
        duplicate = [{"Name": "Theater Direct Test"}, {"Name": "SeatSix Direct Test"}]
        complete = [*duplicate, {"Name": "Theater Compatibility Test"}]
        library = {"Name": "Theater Test Movies", "Id": "library"}
        views = {"Items": [library]}
        api.request.side_effect = [{"Id": "server"}, [library], None,
                                   views, {"Items": duplicate}, views, {"Items": complete}]
        with patch.object(setup, "API", return_value=api), \
                patch.object(setup, "login_or_initialize", return_value={"Id": "user"}), \
                patch.object(setup.time, "sleep") as wait, patch("builtins.print"):
            setup.initialize("jellyfin", credentials)
        wait.assert_called_once_with(2)
        queries = [call.kwargs["query"] for call in api.request.call_args_list
                   if call.args == ("GET", "/Users/user/Items")]
        self.assertEqual([query["ParentId"] for query in queries], ["library", "library"])
        self.assertEqual(credentials["user_id"], "user")


if __name__ == "__main__":
    unittest.main()
