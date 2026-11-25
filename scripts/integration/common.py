"""Helpers for disposable, loopback-only integration servers (stdlib only)."""
from __future__ import annotations

import json
import http.client
from pathlib import Path
import subprocess
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / ".runtime"
CREDENTIALS = RUNTIME / "test-credentials.json"
# Persistent ownership markers, device IDs and volume names span both app names.
RUNTIME_MARKER = RUNTIME / ".theater-integration.json"
LABEL = "red.theater.integration.workspace"
DEVICE_ID = "theater-local-integration-v1"
SERVERS = {
    "jellyfin": {"name": "theater-dev-jellyfin", "port": 18096, "image": "jellyfin/jellyfin@sha256:357724bf0ae27a672c7cbaa899db2d9abeb13dbd8657ccce750258a4c059d037", "prefix": ""},
    "emby": {"name": "theater-dev-emby", "port": 28096, "image": "emby/embyserver_arm64v8@sha256:22aeef01c017467c3e41d5f735bf93bff5745b54b7366b2df951d99efdf5f9da", "prefix": "/emby"},
}


FIXTURE_BRANDS = ("SeatSix", "Theater")


def fixture_named(items, suffix):
    # Existing dedicated volumes retain their original library and movie titles.
    for prefix in FIXTURE_BRANDS:
        for item in items:
            if item.get("Name") == f"{prefix} {suffix}":
                return item
    return None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("Integration requests may not redirect")


def docker(*args, check=True):
    result = subprocess.run(["docker", *args], capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(f"Docker {' '.join(args[:2])} failed: {result.stderr.strip()}")
    return result


def inspect_owned(kind):
    info = docker("inspect", SERVERS[kind]["name"], check=False)
    if info.returncode:
        if "no such object" in info.stderr.lower() or "no such container" in info.stderr.lower():
            return None
        raise RuntimeError("Docker is unavailable; start OrbStack before setup.")
    item = json.loads(info.stdout)[0]
    if item.get("Config", {}).get("Labels", {}).get(LABEL) != str(ROOT):
        raise RuntimeError(f"Refusing to alter pre-existing container {SERVERS[kind]['name']} without this workspace's ownership label")
    return item


def volume_name(kind, role):
    return f"theater-dev-{kind}-{role}"


def inspect_owned_volume(name):
    result = docker("volume", "inspect", name, check=False)
    if result.returncode:
        if "no such volume" in result.stderr.lower():
            return None
        raise RuntimeError("Docker volume inspection failed")
    item = json.loads(result.stdout)[0]
    if item.get("Labels", {}).get(LABEL) != str(ROOT):
        raise RuntimeError(f"Refusing to alter pre-existing volume {name} without this workspace's ownership label")
    return item


def validate_runtime():
    if RUNTIME.is_symlink() or not RUNTIME_MARKER.exists() or RUNTIME_MARKER.is_symlink():
        raise RuntimeError("Refusing to alter integration files without the workspace ownership marker")
    marker = json.loads(RUNTIME_MARKER.read_text())
    if marker.get("workspace") != str(ROOT):
        raise RuntimeError("Integration runtime belongs to another workspace")
    for name in ("media", "servers", "test-credentials.json"):
        if (RUNTIME / name).is_symlink():
            raise RuntimeError(f"Refusing integration runtime symlink {name}")


class API:
    def __init__(self, kind, token=None):
        self.kind = kind
        self.base = f"http://127.0.0.1:{SERVERS[kind]['port']}" + SERVERS[kind]["prefix"]
        self.token = token

    def request(self, method, path, body=None, query=None, raw=False, limit=None):
        url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        return self.fetch(method, url, body, raw, limit)

    def fetch(self, method, url, body=None, raw=False, limit=None):
        # Never follow a server-provided media URL outside our two loopback ports.
        parsed = urllib.parse.urlsplit(url)
        if parsed.hostname != "127.0.0.1" or parsed.port != SERVERS[self.kind]["port"] or parsed.scheme != "http" or parsed.username is not None or parsed.password is not None:
            raise RuntimeError("Refusing a test media URL outside the owned loopback server")
        auth = f'MediaBrowser Client="SeatSix Integration", Device="Synthetic Fixtures", DeviceId="{DEVICE_ID}", Version="0.1.0"'
        if self.token:
            auth += f', Token="{self.token}"'
        headers = {"Accept": "application/json", "Authorization": auth, "X-Emby-Authorization": auth}
        if self.token:
            headers["X-Emby-Token"] = self.token
        if body is not None:
            headers["Content-Type"] = "application/json"
        if limit:
            headers["Range"] = f"bytes=0-{limit-1}"
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
                data = response.read(limit) if limit else response.read()
                if raw:
                    return data
                return json.loads(data) if data else None
        except urllib.error.HTTPError as exc:
            # URL queries, request/response bodies may contain credentials.
            raise RuntimeError(f"{self.kind}: {method} {parsed.path} returned HTTP {exc.code}") from None
        except (urllib.error.URLError, TimeoutError, http.client.HTTPException, ConnectionError):
            raise RuntimeError(f"{self.kind}: {method} {parsed.path} could not connect") from None

    def login(self, credential):
        result = self.request("POST", "/Users/AuthenticateByName", {"Username": credential["username"], "Pw": credential["password"]})
        self.token = result["AccessToken"]
        return result["User"]


def write_private(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch(mode=0o600, exist_ok=True)
    path.chmod(0o600)
    path.write_text(json.dumps(value, indent=2) + "\n")
