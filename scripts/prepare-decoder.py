#!/usr/bin/env python3
"""Prepare the pinned Universal libmpv SDK used to compile SeatSix release builds."""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_NAME = "iina-deps-fat.zip"
RUNTIME_URL = "https://github.com/iina/deps-buildscripts/releases/download/iina-1.5.0-release/" + RUNTIME_NAME
RUNTIME_SHA = "d6b3bb920f14780ec9c9df22e323e2bf72a5ca2b198473c67bf37581f0a60b6e"
SOURCE_NAME = "mpv-0.41.0.tar.gz"
SOURCE_URL = "https://codeload.github.com/mpv-player/mpv/tar.gz/refs/tags/v0.41.0"
SOURCE_SHA = "ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209"
HEADERS = ("client.h", "render.h", "render_gl.h")


def digest(stream):
    sha = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        sha.update(chunk)
    return sha.digest()


def check_artifact(path, checksum):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected a regular file: {path}")
    with path.open("rb") as stream:
        if digest(stream).hex() != checksum:
            raise ValueError(f"SHA-256 mismatch: {path}")


def download(cache, name, url, checksum):
    target = cache / name
    if not target.exists():
        with tempfile.TemporaryDirectory(dir=cache) as temporary:
            candidate = Path(temporary) / name
            subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                            "--proto", "=https", "--proto-redir", "=https", "--retry", "3",
                            "--connect-timeout", "20", "--max-time", "300", "--output",
                            str(candidate), url], check=True)
            check_artifact(candidate, checksum)
            os.replace(candidate, target)
    check_artifact(target, checksum)
    return target


def sdk_entries(binaries, source):
    names = set()
    for entry in binaries.infolist():
        if (not re.fullmatch(r"lib[A-Za-z0-9_.-]+\.dylib", entry.filename)
                or entry.filename.casefold() in names
                or stat.S_IFMT(entry.external_attr >> 16) not in (0, stat.S_IFREG)):
            raise ValueError(f"Unexpected runtime entry: {entry.filename}")
        names.add(entry.filename.casefold())
        with binaries.open(entry) as stream:
            yield Path("lib", entry.filename), stream
    if "libmpv.2.dylib" not in names or "libmpv.dylib" in names:
        raise ValueError("Expected exactly the versioned libmpv ABI 2 library")
    for name in HEADERS:
        entry = source.getmember("mpv-0.41.0/include/mpv/" + name)
        if not entry.isfile():
            raise ValueError(f"Missing regular mpv header: {name}")
        with source.extractfile(entry) as stream:
            yield Path("include", "mpv", name), stream


def materialize(directory, binaries, source, *, verify):
    if verify:
        for name in ("lib", "include", "include/mpv"):
            sub = directory / name
            if sub.is_symlink() or not sub.is_dir():
                raise ValueError(f"Expected a regular SDK directory at {sub}")
    expected = {Path("lib/libmpv.dylib")}
    for path, stream in sdk_entries(binaries, source):
        expected.add(path)
        target = directory / path
        if verify:
            if target.is_symlink() or not target.is_file():
                raise ValueError(f"Incomplete decoder SDK at {target}")
            with target.open("rb") as installed:
                if digest(installed) != digest(stream):
                    raise ValueError(f"Decoder SDK differs from pinned input: {target}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("xb") as installed:
                shutil.copyfileobj(stream, installed)
    link = directory / "lib/libmpv.dylib"
    if verify:
        expected.update([Path("lib"), Path("include"), Path("include/mpv")])
        actual = {entry.relative_to(directory) for entry in directory.rglob("*")}
        if actual != expected or not link.is_symlink() or os.readlink(link) != "libmpv.2.dylib":
            raise ValueError(f"Unexpected decoder SDK layout at {directory}")
    else:
        link.symlink_to("libmpv.2.dylib")


def prepare(destination, cache):
    cache.mkdir(parents=True, exist_ok=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Serialize publication and never repair a modified SDK in place.
    with (destination.parent / ("." + destination.name + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        binaries = download(cache, RUNTIME_NAME, RUNTIME_URL, RUNTIME_SHA)
        headers = download(cache, SOURCE_NAME, SOURCE_URL, SOURCE_SHA)
        with zipfile.ZipFile(binaries) as library_zip, tarfile.open(headers) as sources:
            if os.path.lexists(destination):
                if destination.is_symlink() or not destination.is_dir():
                    raise ValueError(f"Unexpected SDK destination: {destination}")
                materialize(destination, library_zip, sources, verify=True)
            else:
                with tempfile.TemporaryDirectory(dir=destination.parent) as staging:
                    candidate = Path(staging) / "sdk"
                    materialize(candidate, library_zip, sources, verify=False)
                    candidate.rename(destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--cache", type=Path, default=ROOT / ".runtime/decoder-download")
    args = parser.parse_args()
    try:
        prepare(args.destination, args.cache)
    except (OSError, KeyError, ValueError, zipfile.BadZipFile, tarfile.TarError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
    print(f"Verified Universal libmpv SDK: {args.destination}")
