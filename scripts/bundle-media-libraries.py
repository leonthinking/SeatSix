#!/usr/bin/env python3
"""Relocate a Mach-O application's non-system library closure into its bundle.

Only copies are modified. Missing libraries, ambiguous names, unresolved references,
or an unsuccessful real libmpv initialization make the build fail closed.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass

SYSTEM_ROOTS = ("/usr/lib/", "/System/Library/", "/Library/Apple/System/Library/")
MPV_LIBRARY = "libmpv.2.dylib"
FRAMEWORK_PREFIX = "@executable_path/../Frameworks/"
UNIVERSAL_ARCHS = {"arm64", "x86_64"}


class BundleError(RuntimeError):
    pass


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True,
                          text=True).stdout


def is_system(path):
    return any(os.path.normpath(str(path)).startswith(root) for root in SYSTEM_ROOTS)


def parse_dependencies(output):
    result = []
    for line in output.splitlines():
        match = re.match(r"^\s+(.+?) \(compatibility version [^)]+\)$", line)
        if match and match.group(1) not in result:
            result.append(match.group(1))
    return result


def parse_rpaths(output):
    result = []
    awaiting = False
    for line in output.splitlines():
        if line.strip().startswith("cmd "):
            awaiting = line.strip() == "cmd LC_RPATH"
        elif awaiting:
            match = re.match(r"\s*path (.+) \(offset \d+\)$", line)
            if match:
                if match.group(1) not in result:
                    result.append(match.group(1))
                awaiting = False
    return result


@dataclass(frozen=True)
class Metadata:
    dependencies: tuple
    rpaths: tuple
    install_id: str | None = None
    minimum_macos: str | None = None


def version_key(value):
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def apply_minimum_macos(plist_path, minimum):
    with plist_path.open("rb") as file:
        info = plistlib.load(file)
    declared = info.get("LSMinimumSystemVersion", "0.0")
    info["LSMinimumSystemVersion"] = max((declared, minimum), key=version_key)
    with plist_path.open("wb") as file:
        plistlib.dump(info, file)
    return info["LSMinimumSystemVersion"]


def parse_minimum_macos(output):
    versions = []
    command = None
    for line in output.splitlines():
        if line.strip().startswith("cmd "):
            command = line.strip().split()[-1]
        elif command in ("LC_BUILD_VERSION", "LC_VERSION_MIN_MACOSX"):
            field = "minos" if command == "LC_BUILD_VERSION" else "version"
            match = re.match(r"\s*" + field + r" (\d+(?:\.\d+){0,2})$", line)
            if match:
                versions.append(match.group(1))
    return max(versions, key=version_key) if versions else None


def metadata(path, architecture=None):
    command = ["/usr/bin/otool"]
    if architecture:
        command.extend(["-arch", architecture])
    ids = run(*command, "-D", path).splitlines()[1:]
    install_id = next((line.strip() for line in ids if line.strip()), None)
    dependencies = parse_dependencies(run(*command, "-L", path))
    commands = run(*command, "-l", path)
    return Metadata(tuple(dep for dep in dependencies if dep != install_id),
                    tuple(parse_rpaths(commands)), install_id, parse_minimum_macos(commands))


def expand_path(value, loader, executable):
    for prefix, base in (("@loader_path", loader.parent),
                         ("@executable_path", executable.parent)):
        if value == prefix or value.startswith(prefix + "/"):
            return str(base / value[len(prefix):].lstrip("/"))
    return value


def resolve_dependency(value, loader, executable, rpaths):
    expanded = expand_path(value, loader, executable)
    if expanded.startswith("@rpath/"):
        candidates = [str(Path(path) / expanded[len("@rpath/"):]) for path in rpaths]
    else:
        candidates = [expanded]
    for candidate in candidates:
        if not os.path.isabs(candidate):
            continue
        normalized = Path(os.path.normpath(candidate))
        # Apple shared-cache libraries need not exist as files.
        if is_system(normalized):
            return normalized
        if normalized.is_file():
            return normalized.resolve()
    raise BundleError(f"Unresolved dependency {value!r} from {loader}")


@dataclass
class Closure:
    executable: Path
    libraries: dict
    metadata: dict
    edges: dict


def collect_closure(executable, read_metadata=metadata):
    executable = Path(executable).resolve(strict=True)
    libraries, records, edges = {}, {}, {}
    contexts = {}

    def visit(path, inherited_rpaths=()):
        if path not in records:
            records[path] = read_metadata(path)
        info = records[path]
        own_rpaths = tuple(expand_path(value, path, executable) for value in info.rpaths)
        search = tuple(dict.fromkeys(own_rpaths + inherited_rpaths))
        resolved = {dep: resolve_dependency(dep, path, executable, search)
                    for dep in info.dependencies}
        if path in contexts:
            # A dylib reached through two loader chains must resolve identically.
            if edges[path] != resolved:
                raise BundleError(f"Ambiguous inherited @rpath resolution for {path}")
            return
        contexts[path] = search
        edges[path] = resolved
        for dependency in resolved.values():
            if is_system(dependency):
                continue
            if dependency == executable:
                raise BundleError("Library dependency points back to the executable")
            # Default macOS volumes are case insensitive; reject case-only collisions too.
            key = dependency.name.casefold()
            if key in libraries and libraries[key] != dependency:
                raise BundleError(f"Library basename collision: {libraries[key]} and {dependency}")
            libraries[key] = dependency
            visit(dependency, search)

    visit(executable)
    return Closure(executable, libraries, records, edges)


def installed_formula(path):
    parts = path.parts
    if "Cellar" not in parts:
        raise BundleError(f"No Homebrew provenance for {path}")
    index = parts.index("Cellar")
    if len(parts) <= index + 2:
        raise BundleError(f"Malformed Homebrew path: {path}")
    return parts[index + 1], parts[index + 2]


def provenance(closure):
    names = sorted({installed_formula(path)[0] for path in closure.libraries.values()})
    brew = shutil.which("brew") or "/opt/homebrew/bin/brew"
    data = json.loads(run(brew, "info", "--json=v2", "--formula", *names))
    formulae = {entry["name"]: entry for entry in data["formulae"]}
    result = []
    for source in sorted(closure.libraries.values(), key=lambda path: path.name):
        name, version = installed_formula(source)
        info = formulae.get(name)
        if not info or not info.get("license"):
            raise BundleError(f"Missing license metadata for {name}")
        result.append({
            "file": source.name, "formula": name, "installedVersion": version,
            "sourcePath": str(source), "originalSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "license": info["license"], "homepage": info["homepage"],
            "minimumMacOS": closure.metadata[source].minimum_macos,
            "formulaURL": f"https://formulae.brew.sh/formula/{name}",
            "upstreamSource": info.get("urls", {}).get("stable", {}),
            "metadataStableVersion": info.get("versions", {}).get("stable"),
            "note": "Formula source metadata can differ from the installed bottle; use matching source before distribution."
        })
    return result


def verify_relocated(executable, frameworks, expected_names, read_metadata=metadata):
    for path in [executable] + [frameworks / name for name in expected_names]:
        info = read_metadata(path)
        for dep in info.dependencies:
            if is_system(dep):
                continue
            prefix = "@executable_path/../Frameworks/" if path == executable else "@loader_path/"
            if not dep.startswith(prefix) or Path(dep).name not in expected_names:
                raise BundleError(f"External dependency remains in {path.name}: {dep}")
            target = Path(expand_path(dep, path, executable)).resolve()
            if target.parent != frameworks.resolve() or not target.is_file():
                raise BundleError(f"Dependency escapes bundle: {dep}")
        if path != executable and info.install_id != "@rpath/" + path.name:
            raise BundleError(f"Unexpected install ID in {path.name}")
        if any(not is_system(rpath) for rpath in info.rpaths):
            raise BundleError(f"Non-system rpath remains in {path.name}")


def self_test(library):
    # Executed in a fresh process with no DYLD overrides. This catches missing ABI
    # symbols that otool-only dependency traversal cannot detect.
    lib = ctypes.CDLL(str(Path(library).resolve()), mode=os.RTLD_NOW | os.RTLD_LOCAL)
    lib.mpv_create.restype = ctypes.c_void_p
    lib.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.mpv_set_option_string.restype = ctypes.c_int
    lib.mpv_initialize.argtypes = [ctypes.c_void_p]
    lib.mpv_initialize.restype = ctypes.c_int
    lib.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
    lib.mpv_client_api_version.restype = ctypes.c_ulong
    handle = lib.mpv_create()
    if not handle:
        raise BundleError("mpv_create returned null")
    try:
        for name, value in ((b"config", b"no"), (b"load-scripts", b"no"),
                            (b"vo", b"null"), (b"ao", b"null"),
                            (b"terminal", b"no"), (b"ytdl", b"no")):
            code = lib.mpv_set_option_string(handle, name, value)
            if code < 0:
                raise BundleError(f"mpv option {name!r} failed: {code}")
        code = lib.mpv_initialize(handle)
        if code < 0:
            raise BundleError(f"mpv_initialize failed: {code}")
        return {"passed": True, "clientAPIVersion": lib.mpv_client_api_version(),
                "videoOutput": "null", "audioOutput": "null"}
    finally:
        lib.mpv_terminate_destroy(handle)


def prepare_distribution_slice(path, full=False):
    # SwiftPM can add the toolchain and @loader_path to LC_RPATH even for a
    # binary linked entirely against absolute macOS system install names.
    info = metadata(path)
    external = [dep for dep in info.dependencies if not is_system(dep)]
    expected = ["@rpath/" + MPV_LIBRARY] if full else []
    if not info.dependencies or external != expected:
        raise BundleError(f"Unexpected non-system dependencies in {path.name}: {external}")
    if full:
        run("/usr/bin/install_name_tool", "-change", expected[0], FRAMEWORK_PREFIX + MPV_LIBRARY, path)
    for rpath in info.rpaths:
        if full or not is_system(rpath):
            run("/usr/bin/install_name_tool", "-delete_rpath", rpath, path)
    run("/usr/bin/strip", "-S", "-x", path)


def verify_system_app(app):
    executable = app / "Contents/MacOS/SeatSix"
    with (app / "Contents/Info.plist").open("rb") as file:
        declared = plistlib.load(file)["LSMinimumSystemVersion"]
    architectures = set(run("/usr/bin/lipo", "-archs", executable).split())
    if architectures != UNIVERSAL_ARCHS:
        raise BundleError(f"Expected an arm64 and x86_64 universal executable: {architectures}")
    if (app / "Contents/Frameworks").exists():
        raise BundleError("The system player must use only macOS frameworks")
    for cpu in sorted(architectures):
        info = metadata(executable, cpu)
        if not info.dependencies or any(not is_system(dep) for dep in info.dependencies + info.rpaths):
            raise BundleError(f"External dependency or search path in {cpu} system player")
        if not info.minimum_macos or version_key(info.minimum_macos) > version_key(declared):
            raise BundleError(f"{cpu} requires macOS {info.minimum_macos}, Info.plist declares {declared}")
    verify_no_checkout_path(executable)
    print(f"Verified universal macOS system player (macOS {declared}+).")


def verify_no_checkout_path(executable):
    code = executable.read_bytes()
    if os.fsencode(Path(__file__).resolve().parents[1]) + b"/" in code or b"/Users/" in code:
        raise BundleError("The application executable contains a developer-machine path")


def install_full_sdk(app, sdk):
    """Install the pinned IINA SDK's flat universal libraries without following linker aliases."""
    source = sdk / "lib"
    libraries = sorted(path for path in source.glob("*.dylib") if not path.is_symlink())
    if source / MPV_LIBRARY not in libraries:
        raise BundleError(f"Missing {MPV_LIBRARY} in decoder SDK")
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir()
    for library in libraries:
        destination = frameworks / library.name
        shutil.copyfile(library, destination)
        destination.chmod(0o755)
    # All pinned dylibs use @rpath/<sibling>. This search path is inherited by
    # the whole libmpv dependency chain, including in a standalone dlopen.
    run("/usr/bin/install_name_tool", "-add_rpath", "@loader_path", frameworks / MPV_LIBRARY)


def test_bundled_mpv(library):
    env = {key: value for key, value in os.environ.items() if not key.startswith("DYLD_")}
    check = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--self-test", str(library)],
                           env=env, check=True, capture_output=True, text=True, timeout=30)
    return json.loads(check.stdout)


def verify_full_app(app):
    executable = app / "Contents/MacOS/SeatSix"
    frameworks = app / "Contents/Frameworks"
    resources = app / "Contents/Resources"
    notices = resources / "ThirdPartyNotices"
    with (app / "Contents/Info.plist").open("rb") as file:
        plist = plistlib.load(file)
    declared = plist.get("LSMinimumSystemVersion")
    if plist.get("CFBundleExecutable") != executable.name or plist.get("CFBundleIconFile") != "SeatSix.icns":
        raise BundleError("Unexpected executable or icon in application metadata")
    with (resources / "SeatSix.icns").open("rb") as file:
        if file.read(4) != b"icns":
            raise BundleError("Invalid SeatSix Finder icon")
    if not (resources / "LICENSE").stat().st_size:
        raise BundleError("Missing application license")
    notice_files = list(notices.rglob("*"))
    if notices.is_symlink() or any(path.is_symlink() for path in notice_files) or not any(
            path.is_file() and path.stat().st_size for path in notice_files):
        raise BundleError("Expected self-contained ThirdPartyNotices in full application")
    if executable.is_symlink() or frameworks.is_symlink() or not frameworks.is_dir():
        raise BundleError("Missing or indirect full application code")
    libraries = {path.name: path for path in frameworks.iterdir()}
    if MPV_LIBRARY not in libraries or any(path.is_symlink() or not path.is_file() or
            path.suffix != ".dylib" for path in libraries.values()):
        raise BundleError("Expected flat embedded dylibs including libmpv")
    if not isinstance(declared, str) or version_key(declared) != version_key("14.0"):
        raise BundleError("The full application must support macOS 14.0")
    for path in [executable, *libraries.values()]:
        if set(run("/usr/bin/lipo", "-archs", path).split()) != UNIVERSAL_ARCHS:
            raise BundleError(f"Expected two universal slices in {path.name}")
    verify_no_checkout_path(executable)
    for cpu in sorted(UNIVERSAL_ARCHS):
        remaining = [executable]
        visited = set()
        while remaining:
            path = remaining.pop()
            if path in visited:
                continue
            visited.add(path)
            info = metadata(path, cpu)
            if not info.minimum_macos or version_key(info.minimum_macos) > version_key(declared):
                raise BundleError(f"{path.name} ({cpu}) requires macOS {info.minimum_macos}")
            expected_rpaths = ("@loader_path",) if path.name == MPV_LIBRARY else ()
            if info.rpaths != expected_rpaths:
                raise BundleError(f"Unexpected search path in {path.name} ({cpu}): {info.rpaths}")
            deps = [dep for dep in info.dependencies if not is_system(dep)]
            if path == executable:
                if deps != [FRAMEWORK_PREFIX + MPV_LIBRARY]:
                    raise BundleError(f"The {cpu} executable must link the embedded libmpv: {deps}")
                remaining.append(libraries[MPV_LIBRARY])
            else:
                if info.install_id != "@rpath/" + path.name:
                    raise BundleError(f"Unexpected install ID in {path.name} ({cpu})")
                for dep in deps:
                    name = Path(dep).name
                    if dep != "@rpath/" + name or name not in libraries:
                        raise BundleError(f"External dependency in {path.name} ({cpu}): {dep}")
                    remaining.append(libraries[name])
        if visited != {executable, *libraries.values()}:
            raise BundleError(f"Unreferenced library in the {cpu} full application")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    test_bundled_mpv(libraries[MPV_LIBRARY])
    print(f"Verified universal macOS {declared}+ full application, {len(libraries)} embedded libraries; libmpv initialization passed.")


def bundle(app):
    app = app.resolve(strict=True)
    executable = app / "Contents/MacOS/SeatSix"
    frameworks = app / "Contents/Frameworks"
    resources = app / "Contents/Resources"
    # Stage fresh app bundles in build-app.sh. Refuse destructive reuse here.
    if frameworks.exists():
        raise BundleError("Frameworks already exists; use a fresh staging app bundle")
    closure = collect_closure(executable)
    mpv = [path for path in closure.libraries.values() if path.name.startswith("libmpv.")]
    if len(mpv) != 1:
        raise BundleError("Expected exactly one libmpv in application dependency closure")
    manifest = provenance(closure)
    frameworks.mkdir()
    resources.mkdir(exist_ok=True)
    copies = {closure.executable: executable}
    for source in closure.libraries.values():
        destination = frameworks / source.name
        shutil.copy2(source, destination)
        destination.chmod(0o755)
        copies[source] = destination
    for source, destination in copies.items():
        args = []
        if source != closure.executable:
            args += ["-id", "@rpath/" + destination.name]
        for original, dependency in closure.edges[source].items():
            if is_system(dependency):
                # Normalize resolved system @rpath references too.
                relocated = str(dependency)
            else:
                prefix = "@executable_path/../Frameworks/" if source == closure.executable else "@loader_path/"
                relocated = prefix + dependency.name
            if original != relocated:
                args += ["-change", original, relocated]
        for rpath in closure.metadata[source].rpaths:
            if not is_system(rpath):
                args += ["-delete_rpath", rpath]
        if args:
            run("/usr/bin/install_name_tool", *args, destination)
    names = {path.name for path in closure.libraries.values()}
    verify_relocated(executable, frameworks, names)
    for destination in copies.values():
        run("/usr/bin/codesign", "--force", "--sign", "-", destination)
        run("/usr/bin/codesign", "--verify", "--strict", destination)
    proof = test_bundled_mpv(frameworks / mpv[0].name)
    minimum_versions = [info.minimum_macos for info in closure.metadata.values() if info.minimum_macos]
    if not minimum_versions:
        raise BundleError("Unable to determine minimum macOS from Mach-O closure")
    minimum_macos = max(minimum_versions, key=version_key)
    minimum_macos = apply_minimum_macos(app / "Contents/Info.plist", minimum_macos)
    report = {"schemaVersion": 1, "minimumMacOS": minimum_macos, "distributionStatus": "local-development-GPL-build",
              "libraryCount": len(names), "libraries": manifest, "selfTest": proof,
              "runtimeDependencies": "Bundled libraries plus macOS system libraries",
              "releaseRequirement": "Review corresponding-source and all license obligations before redistribution."}
    (resources / "media-libraries.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Bundled {len(names)} libraries; libmpv initialization passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, nargs="?")
    parser.add_argument("--self-test", type=Path)
    parser.add_argument("--prepare-system-slice", type=Path)
    parser.add_argument("--prepare-full-slice", type=Path)
    parser.add_argument("--verify-system-app", type=Path)
    parser.add_argument("--install-full-sdk", type=Path)
    parser.add_argument("--verify-full-app", type=Path)
    args = parser.parse_args()
    try:
        if args.prepare_system_slice or args.prepare_full_slice:
            prepare_distribution_slice(args.prepare_system_slice or args.prepare_full_slice,
                                       full=args.prepare_full_slice is not None)
        elif args.verify_system_app:
            verify_system_app(args.verify_system_app)
        elif args.verify_full_app:
            verify_full_app(args.verify_full_app)
        elif args.install_full_sdk and args.app:
            install_full_sdk(args.app, args.install_full_sdk)
        elif args.self_test:
            print(json.dumps(self_test(args.self_test)))
        elif args.app:
            bundle(args.app)
        else:
            parser.error("Provide an application bundle")
    except (BundleError, OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"Media bundle failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
