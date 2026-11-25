"""Check release assets or install a verified set with one atomic macOS rename."""
import argparse
import ctypes
import fcntl
import hashlib
import os
from pathlib import Path
import re
import sys


def validate(directory, tag, allow_previous_format=False):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError(f"Invalid release version: {tag}")
    prefix = "SeatSix-" + tag[1:]
    names = [prefix + "-universal.dmg", prefix + "-decoder-sources.tar.gz"]
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"Expected a release directory: {directory}")
    files = {p.name: p for p in directory.iterdir()}
    if allow_previous_format and set(files) == {names[0], names[0] + ".sha256"}:
        names = names[:1]
    if (set(files) != {item for name in names for item in (name, name + ".sha256")}
            or any(p.is_symlink() or not p.is_file() for p in files.values())):
        raise ValueError(f"Unexpected or missing release assets in {directory}")
    for name in names:
        validate_checksum(directory / name)


def validate_checksum(payload):
    digest = hashlib.sha256()
    with payload.open("rb") as stream:
        if os.fstat(stream.fileno()).st_size == 0:
            raise ValueError(f"Empty release asset: {payload}")
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    expected = f"{digest.hexdigest()}  {payload.name}\n".encode("ascii")
    with payload.with_name(payload.name + ".sha256").open("rb") as checksum:
        if checksum.read(len(expected) + 1) != expected:
            raise ValueError(f"Checksum does not match {payload}")


def publish(candidate, destination):
    validate(candidate, destination.name)
    # Serialize checks of the previous directory across packagers. Swapping
    # directories keeps the previous release visible until the new set is ready.
    lock = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        replace = os.path.lexists(destination)
        if replace:
            validate(destination, destination.name, allow_previous_format=True)
        rename = ctypes.CDLL(None, use_errno=True).renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        # macOS <sys/stdio.h>: RENAME_SWAP = 2, RENAME_EXCL = 4.
        if rename(os.fsencode(candidate), os.fsencode(destination), 2 if replace else 4) != 0:
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code), str(destination))
    finally:
        os.close(lock)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify DIRECTORY for the release TAG")
    parser.add_argument("directory", type=Path)
    parser.add_argument("destination_or_tag", metavar="DESTINATION_OR_TAG")
    args = parser.parse_args()
    try:
        if args.check:
            validate(args.directory, args.destination_or_tag)
        else:
            publish(args.directory, Path(args.destination_or_tag))
    except (ValueError, OSError) as error:
        sys.exit(f"Could not publish release: {error}")
