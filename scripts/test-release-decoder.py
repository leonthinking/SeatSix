#!/usr/bin/env python3
"""Decode a synthetic 10-bit HEVC/AC-3 MKV using the installed app on this CPU."""
import argparse
import ctypes as c
from pathlib import Path
import struct
import tempfile
import time

FIXTURE = Path(__file__).resolve().parents[1] / "tests/fixtures/hevc-ac3.mkv"


def function(library, name, result, *parameters):
    fn = getattr(library, name)
    fn.restype = result
    fn.argtypes = parameters
    return fn


def check_result(value, operation):
    if value < 0:
        raise RuntimeError(f"{operation} failed (mpv error {value})")


def wait_for(description, check):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.05)
    raise RuntimeError(f"Timed out waiting for {description}")


def seek_and_resume(prop, command, wait=wait_for):
    command("set", "pause", "yes")
    wait("paused playback", lambda: prop("pause") == "yes")
    start = float(prop("time-pos") or -1)
    if not 0 <= start < 4:
        raise RuntimeError(f"Could not establish a pre-seek position, got {start}")
    command("seek", "6", "absolute+exact")
    wait("seek to 6s while paused", lambda: prop("pause") == "yes" and
         abs(float(prop("time-pos") or -1) - 6) < 0.2)
    command("set", "pause", "no")
    wait("resumed audio and video", lambda: float(prop("audio-pts") or 0) > 6.2 and
         float(prop("time-pos") or 0) > 6.2)


def verify(app):
    frameworks = (app / "Contents/Frameworks").resolve(strict=True)
    library = c.CDLL(str(frameworks / "libmpv.2.dylib"))
    handle, string = c.c_void_p, c.c_char_p
    player = function(library, "mpv_create", handle)()
    if not player:
        raise RuntimeError("mpv_create failed")
    destroy = function(library, "mpv_terminate_destroy", None, handle)
    option = function(library, "mpv_set_option_string", c.c_int, handle, string, string)
    init = function(library, "mpv_initialize", c.c_int, handle)
    execute = function(library, "mpv_command", c.c_int, handle, c.POINTER(string))
    get = function(library, "mpv_get_property_string", handle, handle, string)
    free = function(library, "mpv_free", None, handle)

    def prop(name):
        ptr = get(player, name.encode())
        if not ptr:
            return ""
        try:
            return c.string_at(ptr).decode()
        finally:
            free(ptr)

    def command(*args):
        argv = (string * (len(args) + 1))(*(a.encode() for a in args), None)
        check_result(execute(player, argv), args[0])

    try:
        for name, value in {"config": "no", "load-scripts": "no", "vo": "null", "ao": "null",
                            "hwdec": "no", "keep-open": "yes", "terminal": "no"}.items():
            check_result(option(player, name.encode(), value.encode()), name)
        check_result(init(player), "mpv_initialize")
        command("loadfile", str(FIXTURE.resolve(strict=True)))
        wait_for("A/V decoding", lambda: float(prop("audio-pts") or 0) > 0.3 and
                 float(prop("time-pos") or 0) > 0.3)
        if prop("video-format") != "hevc" or prop("audio-codec-name") != "ac3":
            raise RuntimeError(f"Unexpected codecs: {prop('video-format')} / {prop('audio-codec-name')}")
        seek_and_resume(prop, command)
        with tempfile.TemporaryDirectory() as temp:
            frame = Path(temp) / "frame.png"
            command("screenshot-to-file", str(frame), "video")
            data = frame.read_bytes()
            if (not data.startswith(b"\x89PNG\r\n\x1a\n") or
                    struct.unpack(">II", data[16:24]) != (160, 90) or len(data) < 1500):
                raise RuntimeError("The decoder did not produce the expected test-pattern frame")
        # Every loaded third-party dylib from the shipped SDK must resolve inside this app.
        dyld = c.CDLL(None)
        count = function(dyld, "_dyld_image_count", c.c_uint32)()
        image_name = function(dyld, "_dyld_get_image_name", string, c.c_uint32)
        shipped = {p.name for p in frameworks.glob("*.dylib")}
        seen = set()
        for index in range(count):
            path = Path(image_name(index).decode())
            if path.name in shipped:
                if path.resolve() != (frameworks / path.name).resolve():
                    raise RuntimeError(f"Loaded dependency outside app: {path}")
                seen.add(path.name)
        if not {"libmpv.2.dylib", "libavcodec.63.dylib", "libavformat.63.dylib"} <= seen:
            raise RuntimeError("Could not verify the active mpv/FFmpeg libraries")
        print(f"Decoded a 160×90 HEVC frame and AC-3 audio after seeking to 6s ({len(seen)} bundled libraries).")
    finally:
        destroy(player)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    verify(parser.parse_args().app)
