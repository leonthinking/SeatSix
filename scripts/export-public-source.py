#!/usr/bin/env python3
"""Create an independent public SeatSix source tree from reviewed files in a commit."""
import argparse
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys

MANIFEST = "scripts/export-public-source.files"


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), "--literal-pathspecs", *args],
        stdout=subprocess.PIPE, check=True,
    ).stdout


def export(repo, destination, revision="HEAD"):
    commit = git(repo, "rev-parse", "--verify", "--end-of-options", revision + "^{commit}").decode().strip()
    paths = git(repo, "cat-file", "blob", f"{commit}:{MANIFEST}").decode().splitlines()
    if not paths or len({p.casefold() for p in paths}) != len(paths):
        raise ValueError("The public source manifest must contain a nonempty set of unique paths")
    for name in paths:
        path = PurePosixPath(name)
        if (not re.fullmatch(r"[A-Za-z0-9_./-]+", name) or path.is_absolute()
                or str(path) != name or ".." in path.parts
                or any(part.startswith(".") and part not in (".github", ".gitignore") for part in path.parts)):
            raise ValueError(f"Invalid public source path: {name!r}")

    # Tree entries also record whether each reviewed path was an executable, a
    # regular file, a symbolic link or a submodule. Only the first two are safe.
    entries = {}
    for row in git(repo, "ls-tree", "-rz", commit, "--", *paths).split(b"\0"):
        if row:
            info, raw_name = row.split(b"\t", 1)
            mode, kind, oid = info.decode().split()
            name = raw_name.decode()
            if mode not in ("100644", "100755") or kind != "blob":
                raise ValueError(f"Public source requires regular files: {name}")
            entries[name] = (mode, oid)
    if set(entries) != set(paths):
        raise ValueError("Manifest entry is missing or names a directory: " + ", ".join(sorted(set(paths) - entries.keys())))

    destination.mkdir()  # Require an unused directory, including on retry.
    try:
        for name, (mode, oid) in entries.items():
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(git(repo, "cat-file", "blob", oid))
            target.chmod(int(mode, 8) & 0o777)
    except BaseException:
        shutil.rmtree(destination)
        raise
    return len(entries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="new directory inside an existing parent")
    parser.add_argument("--revision", default="HEAD", help="committed Git revision (default HEAD)")
    args = parser.parse_args()
    try:
        count = export(Path(__file__).resolve().parents[1], args.destination, args.revision)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"Could not export public source: {error}")
    print(f"Exported {count} files to {args.destination}")


if __name__ == "__main__":
    main()
