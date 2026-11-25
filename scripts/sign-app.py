#!/usr/bin/env python3
"""Sign SeatSix builds with a pinned certificate, or explicitly for local use.

The pin contains only a certificate fingerprint and a code requirement. Private
keys remain in the user's Keychain and are accessed exclusively by codesign.
The --local mode uses ad-hoc signing without accessing the certificate pin or
Keychain. It is intended only for running the application on this Mac.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


APP_IDENTIFIER = "com.theater.mac"
DEFAULT_PIN = Path(__file__).resolve().parents[1] / ".runtime/signing-identity.json"
SECURITY = "/usr/bin/security"
CODESIGN = "/usr/bin/codesign"
FINGERPRINT = re.compile(r"[0-9A-Fa-f]{40}\Z")
IDENTITY_LINE = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"\s*$')
AUTO_PREFIXES = ("Apple Development:", "Developer ID Application:")


class SigningError(Exception):
    """A signing failure that can be safely shown without subprocess output."""


def run_command(arguments: list[str], purpose: str, runner=None) -> str:
    if runner is None:
        runner = subprocess.run
    try:
        result = runner(arguments, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        raise SigningError(f"{purpose} failed (exit {error.returncode}).") from None
    except OSError:
        raise SigningError(f"{purpose} could not be started.") from None
    # codesign writes its display output to stderr; security uses stdout.
    return (result.stdout or "") + "\n" + (result.stderr or "")


def parse_identities(output: str) -> dict[str, str]:
    identities = {}
    for line in output.splitlines():
        match = IDENTITY_LINE.fullmatch(line)
        if match:
            identities[match[1].upper()] = match[2]
    return identities


def validate_requirement(requirement: str) -> str:
    if not isinstance(requirement, str) or not requirement.strip():
        raise SigningError("The signing requirement is empty or invalid.")
    if re.search(r"\bcdhash\b", requirement, re.IGNORECASE):
        raise SigningError("The signing requirement depends on a build hash; a certificate identity is required.")
    if not re.search(r'\bidentifier\s+"com\.theater\.mac"', requirement):
        raise SigningError("The signing requirement does not identify SeatSix.")
    if not re.search(r"\bcertificate\s+(?:leaf|root|\d+)\b", requirement):
        raise SigningError("The signing requirement is missing a certificate constraint.")
    return requirement.strip()


def extract_requirement(output: str) -> str:
    requirements = re.findall(r"^designated\s*=>\s*(.*)$", output, re.MULTILINE)
    if len(requirements) != 1:
        raise SigningError("Could not read one designated signing requirement.")
    return validate_requirement(requirements[0])


def load_pin(path: Path) -> dict | None:
    if path.is_symlink():
        raise SigningError("The signing identity pin must not be a symbolic link.")
    if not path.exists():
        return None
    try:
        pin = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise SigningError("Cannot read the signing identity pin; it will not be replaced.") from None
    if not isinstance(pin, dict) or type(pin.get("version")) is not int or pin["version"] != 1:
        raise SigningError("Unsupported signing identity pin; it will not be replaced.")
    identity = pin.get("identity")
    if not isinstance(identity, str) or not FINGERPRINT.fullmatch(identity):
        raise SigningError("The signing identity pin has an invalid certificate fingerprint.")
    if pin.get("identifier") != APP_IDENTIFIER:
        raise SigningError("The signing identity pin belongs to another application.")
    requirement = validate_requirement(pin.get("designated_requirement"))
    return {
        "version": 1,
        "identity": identity.upper(),
        "identifier": APP_IDENTIFIER,
        "designated_requirement": requirement,
    }


def select_identity(identities: dict[str, str], pin: dict | None, explicit: str | None) -> str:
    if explicit is not None:
        if not FINGERPRINT.fullmatch(explicit):
            raise SigningError("SEATSIX_SIGNING_IDENTITY must be a full 40-character certificate fingerprint.")
        explicit = explicit.upper()
    if pin is not None:
        identity = pin["identity"]
        if explicit is not None and explicit != identity:
            raise SigningError("SEATSIX_SIGNING_IDENTITY conflicts with the pinned signing identity.")
        if identity not in identities:
            raise SigningError("The pinned signing certificate is unavailable or invalid. Restore that identity in Keychain; no fallback was used.")
        return identity
    if explicit is not None:
        if explicit not in identities:
            raise SigningError("The requested signing certificate is unavailable or invalid.")
        return explicit
    candidates = [identity for identity, name in identities.items() if name.startswith(AUTO_PREFIXES)]
    if len(candidates) != 1:
        raise SigningError("A unique valid Apple Development or Developer ID Application identity is required. Set SEATSIX_SIGNING_IDENTITY to a valid certificate's full fingerprint.")
    return candidates[0]


def validate_bundle(app: Path) -> None:
    try:
        with (app / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise SigningError("Cannot read the application bundle's Info.plist.") from None
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") != APP_IDENTIFIER:
        raise SigningError(f"The application bundle identifier must be {APP_IDENTIFIER}.")


@contextmanager
def pin_lock(path: Path):
    """Serialize selection and pinning so concurrent first builds cannot switch identity."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lock")
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def write_pin(path: Path, pin: dict) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=".signing-identity-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(pin, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def previous_requirement(previous_app: Path | None, runner=None) -> str | None:
    if previous_app is None or not previous_app.exists():
        return None
    validate_bundle(previous_app)
    run_command([CODESIGN, "--verify", "--deep", "--strict", str(previous_app)], "Previous application verification", runner)
    output = run_command([CODESIGN, "-d", "--verbose=4", "-r-", str(previous_app)], "Previous signing requirement inspection", runner)
    if re.search(r"^Signature=adhoc\s*$", output, re.MULTILINE):
        return None  # One-time migration from the former local ad-hoc build.
    return extract_requirement(output)


def sign_app(app: Path, pin_path: Path = DEFAULT_PIN, explicit: str | None = None,
             previous_app: Path | None = None, runner=None) -> dict:
    # Absolute paths cannot be interpreted as codesign options, including names
    # beginning with a dash. Arguments remain literal throughout; no shell runs.
    app = app.absolute()
    pin_path = pin_path.absolute()
    previous_app = previous_app.absolute() if previous_app is not None else None
    validate_bundle(app)
    if previous_app is not None and previous_app.resolve() == app.resolve():
        raise SigningError("The candidate application must differ from the previous application.")
    try:
        with pin_lock(pin_path):
            pin = load_pin(pin_path)
            output = run_command([SECURITY, "find-identity", "-v", "-p", "codesigning"], "Signing identity lookup", runner)
            identity = select_identity(parse_identities(output), pin, explicit)
            previous = previous_requirement(previous_app, runner)
            run_command([CODESIGN, "--force", "--deep", "--sign", identity, str(app)], "Application signing", runner)
            run_command([CODESIGN, "--verify", "--deep", "--strict", str(app)], "Application signature verification", runner)
            requirement = extract_requirement(run_command([CODESIGN, "-d", "-r-", str(app)], "Signing requirement inspection", runner))
            required = list(dict.fromkeys(value for value in [pin["designated_requirement"] if pin else None, previous] if value))
            for baseline in required:
                # The app requirement must not be applied to nested libraries,
                # whose identifiers are intentionally different. Their complete
                # signatures were verified by the deep verification above.
                # codesign requires '=' to distinguish inline requirements from
                # requirement filenames. The expression remains one literal arg.
                run_command([CODESIGN, "--verify", "--strict", "-R", "=" + baseline, str(app)], "Signing compatibility verification", runner)
            result = pin or {
                "version": 1,
                "identity": identity,
                "identifier": APP_IDENTIFIER,
                "designated_requirement": requirement,
            }
            write_pin(pin_path, result)
            return result
    except OSError:
        raise SigningError("Cannot lock or save the signing identity pin.") from None


def sign_local_app(app: Path, explicit: str | None = None,
                   previous_app: Path | None = None, runner=None) -> None:
    """Explicit ad-hoc signing, independent of certificate discovery and pins."""
    if explicit is not None:
        raise SigningError("--local conflicts with SEATSIX_SIGNING_IDENTITY; unset it for a local ad-hoc build.")
    app = app.absolute()
    validate_bundle(app)
    if previous_app is not None and previous_app.resolve() == app.resolve():
        raise SigningError("The candidate application must differ from the previous application.")
    run_command([CODESIGN, "--force", "--deep", "--sign", "-", str(app)], "Local application signing", runner)
    run_command([CODESIGN, "--verify", "--deep", "--strict", str(app)], "Local application signature verification", runner)


def sign_public_app(app: Path, identity: str | None, runner=None) -> None:
    app = app.absolute()
    validate_bundle(app)
    sign_args = ["--force", "--sign", "-"]
    if identity:
        if not FINGERPRINT.fullmatch(identity):
            raise SigningError("SEATSIX_DEVELOPER_ID must be a full Developer ID Application certificate fingerprint.")
        identities = parse_identities(run_command(
            [SECURITY, "find-identity", "-v", "-p", "codesigning"], "Developer ID lookup", runner))
        if not identities.get(identity.upper(), "").startswith("Developer ID Application:"):
            raise SigningError("The requested Developer ID Application identity is unavailable.")
        sign_args = ["--force", "--options", "runtime", "--timestamp", "--sign", identity.upper()]
    frameworks = app / "Contents/Frameworks"
    if frameworks.is_symlink():
        raise SigningError("Unexpected Frameworks symlink in public application.")
    if frameworks.exists():
        for library in sorted(frameworks.iterdir()):
            if library.is_symlink() or not library.is_file() or library.suffix != ".dylib":
                raise SigningError("Expected regular dylibs in public application Frameworks.")
            run_command([CODESIGN, *sign_args, str(library)], "Embedded library signing", runner)
    run_command([CODESIGN, *sign_args, str(app)], "Public application signing", runner)
    run_command([CODESIGN, "--verify", "--deep", "--strict", str(app)], "Public signature verification", runner)
    if identity:
        requirement = 'identifier "com.theater.mac" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
        run_command([CODESIGN, "--verify", "--strict", "-R", "=" + requirement, str(app)],
                    "Developer ID signature verification", runner)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("app", type=Path, help="The complete staged SeatSix.app bundle")
    parser.add_argument("--pin-file", type=Path, default=DEFAULT_PIN)
    parser.add_argument("--previous-app", type=Path, help="Previously published bundle, if any")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--local", action="store_true", help="Explicit ad-hoc signing for this Mac; leaves certificate pins untouched")
    modes.add_argument("--public", action="store_true", help="Sign a distribution bundle using SEATSIX_DEVELOPER_ID when configured")
    args = parser.parse_args(argv)
    try:
        if args.public:
            identity = os.environ.get("SEATSIX_DEVELOPER_ID")
            sign_public_app(args.app, identity)
            print("Verified Developer ID signature." if identity else "Verified ad-hoc signature (unnotarized).")
            return 0
        explicit = os.environ.get("SEATSIX_SIGNING_IDENTITY")
        legacy = os.environ.get("THEATER_SIGNING_IDENTITY")
        if explicit is not None and legacy is not None and explicit.upper() != legacy.upper():
            raise SigningError("Conflicting SeatSix and legacy signing identity overrides.")
        if explicit is None:
            explicit = legacy
        if args.local:
            sign_local_app(args.app, explicit, args.previous_app)
        else:
            sign_app(args.app, args.pin_file, explicit, args.previous_app)
    except SigningError as error:
        print(f"SeatSix signing: {error}", file=sys.stderr)
        return 1
    if args.local:
        print("SeatSix local ad-hoc signature verified; certificate signing pin unchanged.")
    else:
        print("SeatSix signature verified; the local signing identity is pinned.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
