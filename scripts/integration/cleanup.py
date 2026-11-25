#!/usr/bin/env python3
"""Stop/remove only the two explicitly labelled integration containers."""
import argparse
import shutil

from common import CREDENTIALS, RUNTIME, RUNTIME_MARKER, SERVERS, docker, inspect_owned, inspect_owned_volume, volume_name, validate_runtime


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--purge-test-data", action="store_true", help="Also delete this project's .runtime/servers, .runtime/media and test-credentials.json; no other data")
    args = parser.parse_args()
    # Validate every existing container before changing anything.
    existing = {kind: inspect_owned(kind) for kind in SERVERS}
    volumes = {}
    if args.purge_test_data:
        volumes = {volume_name(kind, role): inspect_owned_volume(volume_name(kind, role)) for kind in SERVERS for role in (["config", "media", "cache"] if kind == "jellyfin" else ["config", "media"])}
        validate_runtime()
    for kind, info in existing.items():
        if info:
            docker("rm", "--force", SERVERS[kind]["name"])
            print(f"Removed {SERVERS[kind]['name']}")
    if args.purge_test_data:
        for name, info in volumes.items():
            if info:
                docker("volume", "rm", name)
        for name in ("servers", "media"):
            target = RUNTIME / name
            if target.is_symlink():
                raise RuntimeError(f"Refusing to remove symlink {target.name}")
            if target.exists():
                shutil.rmtree(target)
        CREDENTIALS.unlink(missing_ok=True)
        RUNTIME_MARKER.unlink()
        print("Removed only generated integration media, configs and test credentials")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as exc:
        raise SystemExit(str(exc)) from None
