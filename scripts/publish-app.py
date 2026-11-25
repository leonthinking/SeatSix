#!/usr/bin/env python3
"""Publish SeatSix.app and its relative Theater.app compatibility link under the build lock."""
from contextlib import ExitStack
import os
from pathlib import Path
import plistlib
import sys


def check_previous(path, executable):
    if not os.path.lexists(path):
        return
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"Refusing to replace unexpected build output: {path}")
    with (path / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if (info.get("CFBundleIdentifier") != "com.theater.mac"
            or info.get("CFBundleExecutable") != executable
            or not (path / "Contents/MacOS" / executable).is_file()):
        raise ValueError(f"Refusing to replace an unrelated bundle: {path}")


def publish(candidate, directory, *, legacy_link=True):
    current = directory / "SeatSix.app"
    legacy = directory / "Theater.app"
    check_previous(current, "SeatSix")
    if legacy_link and legacy.is_symlink():
        if os.readlink(legacy) != current.name:
            raise ValueError(f"Unexpected legacy app link: {legacy}")
    elif legacy_link:
        check_previous(legacy, "Theater")
    staging = candidate.parent
    alias = staging / "legacy-link"
    if legacy_link:
        alias.symlink_to(current.name)
    # The shell owns the staging directory and can recover even if this child
    # is terminated before Python gets to unwind the ExitStack.
    transaction = staging / "publishing"
    transaction.touch()
    with ExitStack() as rollback:
        if current.exists():
            previous = staging / "previous-SeatSix.app"
            current.rename(previous)
            rollback.callback(previous.rename, current)
        candidate.rename(current)
        rollback.callback(current.rename, candidate)
        if legacy_link and not legacy.is_symlink():
            if legacy.exists():
                previous = staging / "previous-Theater.app"
                legacy.rename(previous)
                rollback.callback(previous.rename, legacy)
            alias.rename(legacy)
            rollback.callback(legacy.rename, alias)
        transaction.unlink()
        rollback.pop_all()


if __name__ == "__main__":
    try:
        publish(Path(sys.argv[1]), Path(sys.argv[2]), legacy_link="--public" not in sys.argv[3:])
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        sys.exit(f"Could not publish SeatSix: {error}")
