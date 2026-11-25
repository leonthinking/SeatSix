#!/usr/bin/env python3
"""Create only this workspace's two local test servers and artificial media."""
from __future__ import annotations

import argparse
import json
import os
import platform
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from common import API, CREDENTIALS, FIXTURE_BRANDS, LABEL, ROOT, RUNTIME, RUNTIME_MARKER, SERVERS, docker, fixture_named, inspect_owned, inspect_owned_volume, volume_name, write_private, validate_runtime


# One sample for each playback path. Both names identify the same fixture role.
FIXTURES = {
    "Direct Test": ("mp4", "libx264", ["-preset", "ultrafast", "-crf", "30", "-movflags", "+faststart"]),
    "Compatibility Test": ("mkv", "mpeg4", ["-q:v", "8"]),
}


def fixture_paths(media, role, suffix):
    for brand in FIXTURE_BRANDS:
        title = f"{brand} {role}"
        yield media / f"{title} (2026)" / f"{title}.{suffix}", media / f"{title} (2026).{suffix}"


def generate_media():
    media = RUNTIME / "media"
    media.mkdir(parents=True, exist_ok=True)
    selected = {}
    for role, (suffix, codec, args) in FIXTURES.items():
        candidates = list(fixture_paths(media, role, suffix))
        output = candidates[0][0]
        for nested, flat in candidates:
            if any(path.is_symlink() for path in (nested.parent, nested, flat, nested.with_name("movie.nfo"))):
                raise RuntimeError("Refusing synthetic media symlink")
            if nested.is_file() and nested.stat().st_size:
                output = nested
                break
            if flat.is_file() and flat.stat().st_size:
                nested.parent.mkdir(exist_ok=True)
                flat.replace(nested)  # Older setup versions kept samples at the media root.
                output = nested
                break
        else:
            ffmpeg = shutil.which("ffmpeg")
            if not ffmpeg:
                raise RuntimeError("ffmpeg is required to generate missing synthetic test media")
            output.parent.mkdir(exist_ok=True)
            with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
                encoded = Path(temporary) / output.name
                subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=600:size=640x360:rate=15", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=600", "-c:v", codec, *args, "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "64k", "-shortest", str(encoded)], check=True)
                encoded.replace(output)
        metadata = output.with_name("movie.nfo")
        if not metadata.exists():
            metadata.write_text(f"<movie><title>{output.stem}</title><year>2026</year><plot>Artificial local integration fixture. Color bars, visible running counter, and 440 Hz audio. No private media.</plot></movie>\n")
        selected[role] = output
    return selected


def populate_media(container, selected):
    # Inspect the mounted volume even after recreating its container: the volume can
    # already contain a different brand generation than the host fixture directory.
    for role, source in selected.items():
        paths = fixture_paths(Path("/media"), role, source.suffix[1:])
        candidates = [str(path) for pair in paths for path in pair]
        present = docker("exec", container, "sh", "-ec", """
            for file do
                test ! -L "$file" && test ! -L "${file%/*}" || exit 2
                if test -f "$file" && test -s "$file"; then echo present; exit 0; fi
            done
            echo missing
        """, "check-fixture", *candidates).stdout.strip()
        if present == "present":
            continue
        if present != "missing":
            raise RuntimeError("Cannot determine whether the owned media volume contains the fixture")
        folder = "/media/" + source.parent.name
        # Transfer metadata and video individually. A retry can safely replace our staged
        # file, and extra host files never enter the container or its library.
        docker("exec", container, "sh", "-ec", """
            mkdir -p "$1"
            for file in "$1/movie.nfo" "$1/.seatsix-transfer" "$1/$2"; do
                test ! -L "$file" || exit 2
                test ! -e "$file" || test -f "$file" || exit 2
            done
        """, "prepare-fixture", folder, source.name)
        docker("cp", str(source.with_name("movie.nfo")), f"{container}:{folder}/movie.nfo")
        docker("cp", str(source), f"{container}:{folder}/.seatsix-transfer")
        docker("exec", container, "mv", f"{folder}/.seatsix-transfer", f"{folder}/{source.name}")


def start_container(kind, pull):
    spec = SERVERS[kind]
    owned = inspect_owned(kind)
    roles = ["config", "media"] + (["cache"] if kind == "jellyfin" else [])
    if owned:
        if all(mount["Type"] == "volume" for mount in owned.get("Mounts", [])):
            expected_mounts = {(volume_name(kind, role), "/" + role) for role in roles}
            actual_mounts = {(mount.get("Name"), mount.get("Destination")) for mount in owned.get("Mounts", [])}
            if actual_mounts != expected_mounts:
                raise RuntimeError(f"Refusing {kind} container with unexpected volumes")
            for role in roles:
                if not inspect_owned_volume(volume_name(kind, role)):
                    raise RuntimeError(f"Missing {kind} owned volume")
            bindings = owned.get("HostConfig", {}).get("PortBindings", {})
            if bindings != {"8096/tcp": [{"HostIp": "127.0.0.1", "HostPort": str(spec["port"])}]}:
                raise RuntimeError(f"Refusing {kind} container with unexpected port bindings")
            docker("start", spec["name"])
            return
        if owned.get("State", {}).get("Running"):
            raise RuntimeError(f"Refusing to replace running {kind} test container; stop it before migrating fixtures")
        # Upgrade only our own disposable bind-mount test container. No host data removed.
        docker("rm", "--force", spec["name"])
    if pull:
        print(f"Pulling official {kind} image...", flush=True)
        docker("pull", spec["image"])
    for role in roles:
        name = volume_name(kind, role)
        if not inspect_owned_volume(name):
            docker("volume", "create", "--label", f"{LABEL}={ROOT}", name)
    command = ["create", "--name", spec["name"], "--label", f"{LABEL}={ROOT}", "--publish", f"127.0.0.1:{spec['port']}:8096", "--mount", f"type=volume,source={volume_name(kind, 'config')},target=/config", "--mount", f"type=volume,source={volume_name(kind, 'media')},target=/media", "--restart", "no"]
    if kind == "jellyfin":
        command += ["--mount", f"type=volume,source={volume_name(kind, 'cache')},target=/cache"]
    else:
        command += ["--env", "UID=0", "--env", "GID=0"]
    docker(*command, spec["image"])
    docker("start", spec["name"])


def login_or_initialize(kind, api, info, credential):
    """Reuse credentials first; an authentication error is not startup evidence."""
    try:
        return api.login(credential)
    except RuntimeError:
        # Provisioned credentials identify an existing instance. Never reset its
        # password because of an auth failure, even if startup state is missing.
        if credential.get("user_id") or credential.get("server_id"):
            raise RuntimeError(f"{kind}: stored test credentials could not log in; refusing startup changes") from None

    state = info.get("StartupWizardCompleted")
    if state is not False and not (kind == "emby" and "StartupWizardCompleted" not in info):
        raise RuntimeError(f"{kind}: login failed without evidence of an unfinished startup wizard; refusing initialization")
    # Emby omits StartupWizardCompleted from Public, including after setup.
    # Its anonymous startup configuration is accessible only during the wizard.
    # Require this read-only confirmation for both servers before any POST.
    try:
        configuration = api.request("GET", "/Startup/Configuration")
    except RuntimeError:
        raise RuntimeError(f"{kind}: login failed and anonymous startup configuration is unavailable; refusing initialization") from None
    if not isinstance(configuration, dict) or not any(key in configuration for key in ("UICulture", "PreferredMetadataLanguage", "MetadataCountryCode")):
        raise RuntimeError(f"{kind}: startup configuration response did not establish an unfinished wizard; refusing initialization")

    api.request("POST", "/Startup/Configuration", {"ServerName": f"SeatSix Test {kind.title()}", "UICulture": "en-US", "MetadataCountryCode": "US", "PreferredMetadataLanguage": "en"})
    api.request("GET", "/Startup/User")
    api.request("POST", "/Startup/User", {"Name": credential["username"], "Password": credential["password"]})
    api.request("POST", "/Startup/RemoteAccess", {"EnableRemoteAccess": False, "EnableAutomaticPortMapping": False})
    api.request("POST", "/Startup/Complete")
    return api.login(credential)


def initialize(kind, credential):
    api = API(kind)
    deadline = time.monotonic() + 150
    while True:
        try:
            info = api.request("GET", "/System/Info/Public")
            break
        except RuntimeError:
            if time.monotonic() >= deadline:
                raise RuntimeError(f"{kind} did not become ready within 150 seconds")
            time.sleep(2)
    user = login_or_initialize(kind, api, info, credential)
    libraries = api.request("GET", "/Library/VirtualFolders")
    if fixture_named(libraries, "Test Movies") is None:
        api.request("POST", "/Library/VirtualFolders", {"LibraryOptions": {"EnableRealtimeMonitor": False, "EnableAutomaticSeriesGrouping": False, "PathInfos": [{"Path": "/media"}], "MetadataSavers": [], "TypeOptions": [{"Type": "Movie", "MetadataFetchers": [], "ImageFetchers": []}]}}, query={"name": "SeatSix Test Movies", "collectionType": "movies", "refreshLibrary": "true"})
    api.request("POST", "/Library/Refresh")
    deadline = time.monotonic() + 150
    while True:
        views = api.request("GET", f"/Users/{user['Id']}/Views")
        library = fixture_named(views.get("Items", []), "Test Movies")
        if library:
            result = api.request("GET", f"/Users/{user['Id']}/Items", query={"ParentId": library["Id"], "Recursive": "true", "IncludeItemTypes": "Movie"})
            if all(fixture_named(result.get("Items", []), role) for role in FIXTURES):
                break
        if time.monotonic() >= deadline:
            raise RuntimeError(f"{kind}: synthetic library scan did not finish in 150 seconds")
        time.sleep(2)
    credential.update({"url": f"http://127.0.0.1:{SERVERS[kind]['port']}", "user_id": user["Id"], "version": info.get("Version"), "server_id": info.get("Id")})
    print(f"{kind}: ready, server {info.get('Version')}, both synthetic playback roles indexed", flush=True)


def main():
    # Legacy setup invocations use the same bounded session as the documented entrypoint.
    if "--managed" not in sys.argv[1:]:
        from run import main as run_session
        return run_session()
    if os.environ.get("SEATSIX_INTEGRATION_MANAGED") != "1":
        raise RuntimeError("Use scripts/integration/run.py to manage startup and teardown")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--managed", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--no-pull", action="store_true", help="Use already-downloaded official images")
    args = parser.parse_args()
    if platform.machine() != "arm64":
        SERVERS["emby"]["image"] = "emby/embyserver@sha256:7082c63b10a2fcb3805a7eaebba407d5723bc57c085c9f0b29b7d0a702765cc1"
    docker("info", "--format", "{{.ServerVersion}}")
    if RUNTIME.is_symlink():
        raise RuntimeError("Refusing integration runtime symlink")
    RUNTIME.mkdir(exist_ok=True)
    if not RUNTIME_MARKER.exists():
        if any((RUNTIME / name).exists() for name in ("media", "servers", "test-credentials.json")):
            raise RuntimeError("Integration data exists without ownership marker; refusing to overwrite it")
        RUNTIME_MARKER.write_text(json.dumps({"workspace": str(ROOT), "purpose": "theater-synthetic-integration-v1"}) + "\n")
    validate_runtime()
    selected = generate_media()
    if CREDENTIALS.exists():
        credentials = json.loads(CREDENTIALS.read_text())
    else:
        credentials = {kind: {"username": "seatsix-test", "password": secrets.token_urlsafe(24)} for kind in SERVERS}
        write_private(CREDENTIALS, credentials)
    for kind in SERVERS:
        start_container(kind, not args.no_pull)
        populate_media(SERVERS[kind]["name"], selected)
        initialize(kind, credentials[kind])
        write_private(CREDENTIALS, credentials)
    print("Ready. Test-only credentials are in .runtime/test-credentials.json (0600); they are not printed.")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        raise SystemExit(str(exc)) from None
