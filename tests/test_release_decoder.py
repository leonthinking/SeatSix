import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("release_decoder", Path(__file__).resolve().parents[1] / "scripts/test-release-decoder.py")
decoder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decoder)


class ReleaseDecoderTests(unittest.TestCase):
    def test_natural_progress_cannot_masquerade_as_a_seek(self):
        state = {"time-pos": "0.5", "audio-pts": "0.5", "pause": "no"}

        def command(*args):
            if args[0] == "set":
                state[args[1]] = args[2]
            # Simulate a decoder which accepts the command but ignores the seek.

        def wait(description, predicate):
            for _ in range(15):
                if predicate():
                    return
                if state["pause"] == "no":
                    state["time-pos"] = state["audio-pts"] = str(float(state["time-pos"]) + 1)
            raise TimeoutError(description)

        with self.assertRaisesRegex(TimeoutError, "seek to 6s while paused"):
            decoder.seek_and_resume(state.get, command, wait)
        self.assertEqual(state["time-pos"], "0.5")
