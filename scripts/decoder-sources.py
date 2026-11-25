#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Package the exact library sources used by the universal IINA decoder build."""

import argparse
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
from concurrent.futures import ThreadPoolExecutor

HERE = Path(__file__).resolve().parent
LOCK = HERE / "decoder-sources.lock.json"
README = HERE.parent / "docs" / "decoder-sources.md"
CACHE = HERE.parent / ".runtime" / "decoder-sources-cache"
NOTICES = "ThirdPartyNotices"
ASSET = "decoder-sources.tar.gz"
NOTICE_NAME = re.compile(
    r"(?:licen[cs]es?|copying|copyright|notice[s]?|authors?|patents?|credits|"
    r"acknowledg[e]?ments)(?:[._-].*)?|.*[.]licen[cs]e|readme[.]ijg|ftl[.]txt|gplv2[.]txt",
    re.IGNORECASE,
)
# These upstream license summaries refer readers to terms in individual files.
EXTRA_NOTICES = {
    "freetype": {
        "src/bdf/README", "src/pcf/README", "src/gzip/zlib.h",
        "src/base/fthash.c", "include/freetype/internal/fthash.h",
        "src/autofit/ft-hb-ft.c", "src/autofit/ft-hb-decls.h",
        "src/autofit/ft-hb-types.h", "src/autofit/hb-script-list.h",
    },
    "libarchive": {
        "libarchive/archive_read_support_filter_compress.c",
        "libarchive/archive_write_add_filter_compress.c", "libarchive/mtree.5",
        "libarchive/archive_blake2.h", "libarchive/archive_blake2_impl.h",
        "libarchive/archive_blake2s_ref.c", "libarchive/archive_blake2sp_ref.c",
    },
}


def safe_path(name):
    path = PurePosixPath(name)
    if not path.parts or path.is_absolute() or ".." in path.parts or "\\" in name:
        raise ValueError(f"Unsafe relative path {name!r}")
    return path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as data:
        for block in iter(lambda: data.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def acquire(item, cache):
    expected = item["sha256"]
    if not re.fullmatch(r"[a-f0-9]{64}", expected):
        raise ValueError(f"Invalid SHA-256 for {item['file']}")
    target = cache / expected
    if target.is_file() and sha256(target) == expected:
        return target
    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as temp:
        staging = Path(temp.name)
    try:
        subprocess.run(
            ["curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
             "--proto-redir", "=https", "--retry", "3", "--connect-timeout", "15",
             "--max-time", "300", "--output", str(staging), item["url"]], check=True,
        )
        if sha256(staging) != expected:
            raise ValueError(f"SHA-256 mismatch for {item['file']}")
        staging.replace(target)
    finally:
        staging.unlink(missing_ok=True)
    return target


def collect_notices(item, source, notices):
    directory = notices / safe_path(item.get("path", item["project"]))
    extra = EXTRA_NOTICES.get(item["project"], set()) if "path" not in item else set()
    found = set()
    has_terms = False
    with tarfile.open(source, "r|*") as archive:
        for member in archive:
            path = safe_path(member.name)
            if not member.isfile() or len(path.parts) < 2:
                continue
            relative = PurePosixPath(*path.parts[1:])
            is_notice = (NOTICE_NAME.fullmatch(relative.name)
                         or "LICENSES" in relative.parts[:-1]
                         or relative.as_posix() in extra)
            if is_notice:
                destination = directory / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                with destination.open("xb") as out:
                    shutil.copyfileobj(archive.extractfile(member), out)
                found.add(relative.as_posix())
                if relative.name.lower().startswith(("licen", "copying", "copyright")) or "LICENSES" in relative.parts:
                    has_terms = True
    if not has_terms or extra - found:
        raise ValueError(f"Missing license material in {item['file']}: {sorted(extra - found)}")


def check_notice_paths(notices):
    names = set()
    for path in notices.rglob("*"):
        name = unicodedata.normalize("NFD", path.relative_to(notices).as_posix()).casefold()
        if name in names:
            raise ValueError(f"Conflicting notice path on a macOS volume: {path}")
        names.add(name)


def archive_name(item):
    name = safe_path(item["file"])
    return name if name.parts[0] == "patches" else Path("sources") / name


def add_file(archive, source, name):
    entry = tarfile.TarInfo(str(Path("decoder-sources") / name))
    entry.size = source.stat().st_size
    entry.mode = 0o644
    with source.open("rb") as data:
        archive.addfile(entry, data)


def create(staging, cache, manifest, lock, guide):
    archives = manifest["archives"] + manifest["git"]
    items = archives + manifest["patches"]
    cache.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=6) as pool:
        files = list(pool.map(lambda item: acquire(item, cache), items))

    notices = staging / NOTICES
    notices.mkdir()
    shutil.copyfile(guide, notices / "README.md")
    shutil.copyfile(lock, notices / LOCK.name)
    for item, source in zip(archives, files):
        collect_notices(item, source, notices)
    check_notice_paths(notices)

    with (staging / ASSET).open("xb") as output:
        with gzip.GzipFile(filename="", fileobj=output, mode="wb", compresslevel=1, mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode="w|") as archive:
                add_file(archive, lock, LOCK.name)
                add_file(archive, guide, "README.md")
                add_file(archive, Path(__file__), "decoder-sources.py")
                add_file(archive, HERE.parent / "LICENSE", "LICENSE")
                for item, source in zip(items, files):
                    add_file(archive, source, archive_name(item))


def contents_match(candidate, existing):
    if existing.is_symlink():
        return False
    if candidate.is_file():
        return (existing.is_file() and existing.stat().st_size == candidate.stat().st_size
                and sha256(candidate) == sha256(existing))
    if not existing.is_dir():
        return False
    names = {p.name for p in candidate.iterdir()}
    return (names == {p.name for p in existing.iterdir()}
            and all(contents_match(candidate / name, existing / name) for name in names))


def package(output, cache):
    manifest = json.loads(LOCK.read_text())
    if cache.resolve().is_relative_to(output.resolve()):
        raise ValueError("Place the download cache outside the output directory.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        candidate = Path(temp) / "release"
        candidate.mkdir()
        create(candidate, cache, manifest, LOCK, README)
        # A concurrent first publish can complete while this candidate is being built.
        descriptor = os.open(output.parent, os.O_RDONLY)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            if os.path.lexists(output):
                if not contents_match(candidate, output):
                    raise ValueError(f"Output differs from the candidate. Choose a new directory: {output}")
            else:
                candidate.rename(output)
        finally:
            os.close(descriptor)


def restore(bundle, target):
    """Recreate IINA's expected sources/ layout from an unpacked release asset."""
    if target.exists():
        raise ValueError(f"Choose a new sources directory: {target}")
    manifest = json.loads((bundle / LOCK.name).read_text())
    if not hasattr(tarfile, "data_filter"):
        raise ValueError("Restoring source trees requires Python with tarfile.data_filter (3.12+).")
    with tempfile.TemporaryDirectory(dir=target.parent) as work:
        stage = Path(work) / "sources"
        stage.mkdir()
        for group in ("archives", "git", "patches"):
            for item in manifest[group]:
                src = bundle / archive_name(item)
                if sha256(src) != item["sha256"]:
                    raise ValueError(f"SHA-256 mismatch for {src.name}")
                if group == "archives":
                    shutil.copyfile(src, stage / safe_path(item["file"]))
                elif group == "git":
                    destination = stage / safe_path(item["path"])
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    if destination.is_dir() and not destination.is_symlink():
                        destination.rmdir()  # a parent Git archive can include an empty gitlink
                    with tempfile.TemporaryDirectory(dir=work) as extracted:
                        with tarfile.open(src) as archive:
                            archive.extractall(extracted, filter="data")
                        roots = list(Path(extracted).iterdir())
                        if len(roots) != 1 or not roots[0].is_dir() or roots[0].is_symlink():
                            raise ValueError(f"Expected one source root in {src.name}")
                        roots[0].rename(destination)
                else:
                    # The checkout already contains the patches consumed by build.sh.
                    if sha256(target.parent / safe_path(item["file"])) != item["sha256"]:
                        raise ValueError(f"Upstream checkout has different patch {item['file']}")
        stage.rename(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, nargs="?", help="directory for the source asset and notices")
    parser.add_argument("--cache", type=Path, default=Path(os.environ.get("SEATSIX_DECODER_SOURCE_CACHE", CACHE)))
    parser.add_argument("--restore-to", type=Path, metavar="RECIPES/sources", help="restore verified build inputs from this extracted asset")
    args = parser.parse_args()
    if bool(args.output) == bool(args.restore_to):
        parser.error("provide an output directory or --restore-to DIRECTORY")
    try:
        if args.restore_to:
            restore(HERE, args.restore_to)
        else:
            package(args.output, args.cache)
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
