"""Offline signing regression tests: no real certificates or Keychain access."""

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/sign-app.py"
SPEC = importlib.util.spec_from_file_location("seatsix_sign_app", SCRIPT)
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)

FIRST = "A" * 40
SECOND = "B" * 40
THIRD = "C" * 40
REQUIREMENT = 'identifier "com.theater.mac" and anchor apple generic and certificate leaf[subject.OU] = "TEAM123"'
OTHER_REQUIREMENT = REQUIREMENT + ' and certificate leaf[field.1.2.3] exists'


def identity_output(*identities):
    return "\n".join(f'  {number}) {fingerprint} "{name}"' for number, (fingerprint, name) in enumerate(identities, 1)) + f"\n     {len(identities)} valid identities found\n"


class FakeCommands:
    def __init__(self, identities=None, requirement=REQUIREMENT, previous=None, fail=None):
        self.identities = identities if identities is not None else [(FIRST, "Apple Development: Example (TEAM123)")]
        self.requirement = requirement
        self.previous = previous or f"Signature size=1234\ndesignated => {REQUIREMENT}"
        self.fail = fail
        self.calls = []

    def __call__(self, arguments, **kwargs):
        self.calls.append((arguments, kwargs))
        if self.fail is not None and self.fail(arguments):
            raise subprocess.CalledProcessError(9, arguments, output="private output must not escape", stderr="private error must not escape")
        if arguments[0] == signing.SECURITY:
            return subprocess.CompletedProcess(arguments, 0, identity_output(*self.identities), "")
        if "--verbose=4" in arguments:
            return subprocess.CompletedProcess(arguments, 0, "", self.previous)
        if "-d" in arguments:
            return subprocess.CompletedProcess(arguments, 0, "", f"Executable=sample\ndesignated => {self.requirement}\n")
        return subprocess.CompletedProcess(arguments, 0, "", "")

    def signing_calls(self):
        return [args for args, _ in self.calls if "--sign" in args]


class IdentityTests(unittest.TestCase):
    def test_valid_identity_lines_only_and_normalized(self):
        output = identity_output((FIRST.lower(), "Apple Development: Example"))
        output += f'2) {SECOND} "Expired" (CSSMERR_TP_CERT_EXPIRED)\n'
        output += f'{THIRD} "Not a numbered identity"\n'
        self.assertEqual(signing.parse_identities(output), {FIRST: "Apple Development: Example"})

    def test_auto_selection_ignores_unrelated_identity_types(self):
        identities = {FIRST: "Apple Development: Example", SECOND: "Apple Distribution: Example"}
        self.assertEqual(signing.select_identity(identities, None, None), FIRST)
        self.assertEqual(signing.select_identity({SECOND: "Developer ID Application: Example"}, None, None), SECOND)

    def test_auto_selection_requires_exactly_one_candidate(self):
        for identities in ({}, {FIRST: "Unrelated"}, {FIRST: "Apple Development: A", SECOND: "Developer ID Application: B"}):
            with self.subTest(identities=identities), self.assertRaises(signing.SigningError):
                signing.select_identity(identities, None, None)

    def test_explicit_selection_accepts_full_hash_only(self):
        self.assertEqual(signing.select_identity({FIRST: "Apple Development: A", SECOND: "Apple Development: B"}, None, SECOND.lower()), SECOND)
        for explicit in ("-", "Apple Development", "A" * 39, FIRST + "\n", " $(touch /tmp/unsafe) "):
            with self.subTest(explicit=explicit), self.assertRaises(signing.SigningError):
                signing.select_identity({FIRST: "Apple Development: A"}, None, explicit)

    def test_explicit_missing_identity_is_rejected(self):
        with self.assertRaises(signing.SigningError):
            signing.select_identity({FIRST: "Apple Development: A"}, None, SECOND)

    def test_pin_wins_over_new_certificates_but_conflict_is_rejected(self):
        pin = {"identity": FIRST}
        self.assertEqual(signing.select_identity({SECOND: "Apple Development: B", FIRST: "Apple Development: A"}, pin, None), FIRST)
        with self.assertRaisesRegex(signing.SigningError, "conflicts"):
            signing.select_identity({FIRST: "Apple Development: A", SECOND: "Apple Development: B"}, pin, SECOND)
        with self.assertRaisesRegex(signing.SigningError, "pinned.*unavailable"):
            signing.select_identity({SECOND: "Apple Development: B"}, pin, None)


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.make_app("SeatSix.app")
        self.pin = self.root / ".runtime/signing-identity.json"

    def make_app(self, name):
        app = self.root / name
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": signing.APP_IDENTIFIER}))
        return app

    def test_public_adhoc_never_selects_a_certificate(self):
        commands = FakeCommands()
        signing.sign_public_app(self.app, None, runner=commands)
        self.assertTrue(all(args[0] == signing.CODESIGN for args, _ in commands.calls))
        self.assertIn("-", commands.signing_calls()[0])

    def test_public_developer_id_requires_exact_identity_timestamp_and_runtime(self):
        commands = FakeCommands(identities=[(FIRST, "Developer ID Application: Example")])
        signing.sign_public_app(self.app, FIRST.lower(), runner=commands)
        signed, = commands.signing_calls()
        self.assertEqual(signed[signed.index("--sign") + 1], FIRST)
        self.assertIn("--timestamp", signed)
        self.assertEqual(signed[signed.index("--options") + 1], "runtime")
        with self.assertRaisesRegex(signing.SigningError, "unavailable"):
            signing.sign_public_app(self.app, FIRST, runner=FakeCommands())
        with self.assertRaisesRegex(signing.SigningError, "fingerprint"):
            signing.sign_public_app(self.app, "invalid", runner=FakeCommands())

    def test_public_full_signs_every_library_with_app_identity_before_outer_seal(self):
        frameworks = self.app / "Contents/Frameworks"
        frameworks.mkdir()
        libs = [frameworks / name for name in ("liba.dylib", "libmpv.2.dylib")]
        for lib in libs:
            lib.touch()
        for identity in (None, FIRST):
            with self.subTest(identity=identity):
                commands = FakeCommands(identities=[(FIRST, "Developer ID Application: Example")])
                signing.sign_public_app(self.app, identity, runner=commands)
                signatures = commands.signing_calls()
                self.assertEqual([args[-1] for args in signatures], [str(path) for path in [*libs, self.app]])
                for args in signatures:
                    self.assertEqual(args[args.index("--sign") + 1], identity or "-")
                    self.assertEqual("--timestamp" in args and "runtime" in args, bool(identity))
                self.assertIn([signing.CODESIGN, "--verify", "--deep", "--strict", str(self.app)],
                              [args for args, _ in commands.calls])

    def save_pin(self, **changes):
        data = {"version": 1, "identity": FIRST, "identifier": signing.APP_IDENTIFIER, "designated_requirement": REQUIREMENT}
        data.update(changes)
        self.pin.parent.mkdir(parents=True, exist_ok=True)
        self.pin.write_text(json.dumps(data))
        return self.pin.read_bytes()

    def test_success_pins_identity_requirement_and_private_file_mode(self):
        commands = FakeCommands()
        result = signing.sign_app(self.app, self.pin, runner=commands)
        self.assertEqual(result, json.loads(self.pin.read_text()))
        self.assertEqual(result["identity"], FIRST)
        self.assertEqual(result["designated_requirement"], REQUIREMENT)
        self.assertEqual(stat.S_IMODE(self.pin.stat().st_mode), 0o600)
        self.assertNotIn("Example", self.pin.read_text())
        self.assertEqual(commands.signing_calls(), [[signing.CODESIGN, "--force", "--deep", "--sign", FIRST, str(self.app)]])
        self.assertIn(([signing.CODESIGN, "--verify", "--deep", "--strict", str(self.app)], {"check": True, "capture_output": True, "text": True}), commands.calls)

    def test_update_reuses_identity_and_original_requirement(self):
        self.save_pin()
        commands = FakeCommands(identities=[(SECOND, "Apple Development: Other"), (FIRST, "Apple Development: Example")], requirement=OTHER_REQUIREMENT)
        result = signing.sign_app(self.app, self.pin, runner=commands)
        self.assertEqual(result["identity"], FIRST)
        self.assertEqual(result["designated_requirement"], REQUIREMENT)
        self.assertIn([signing.CODESIGN, "--verify", "--strict", "-R", "=" + REQUIREMENT, str(self.app)], [args for args, _ in commands.calls])

    def test_missing_pin_identity_never_falls_back(self):
        original = self.save_pin()
        commands = FakeCommands(identities=[(SECOND, "Apple Development: Other")])
        with self.assertRaises(signing.SigningError):
            signing.sign_app(self.app, self.pin, runner=commands)
        self.assertFalse(commands.signing_calls())
        self.assertEqual(self.pin.read_bytes(), original)

    def test_environment_conflict_preserves_pin_before_signing(self):
        original = self.save_pin()
        commands = FakeCommands(identities=[(FIRST, "Apple Development: A"), (SECOND, "Apple Development: B")])
        with self.assertRaises(signing.SigningError):
            signing.sign_app(self.app, self.pin, explicit=SECOND, runner=commands)
        self.assertFalse(commands.signing_calls())
        self.assertEqual(self.pin.read_bytes(), original)

    def test_failure_does_not_create_or_overwrite_pin_and_hides_command_output(self):
        phases = [lambda args: "find-identity" in args, lambda args: "--sign" in args, lambda args: "--verify" in args, lambda args: "-d" in args]
        for existing in (False, True):
            for phase in phases:
                with self.subTest(existing=existing, phase=phase):
                    original = self.save_pin() if existing else None
                    if not existing and self.pin.exists():
                        self.pin.unlink()
                    with self.assertRaises(signing.SigningError) as failure:
                        signing.sign_app(self.app, self.pin, runner=FakeCommands(fail=phase))
                    self.assertNotIn("private", str(failure.exception))
                    if existing:
                        self.assertEqual(self.pin.read_bytes(), original)
                    else:
                        self.assertFalse(self.pin.exists())

    def test_requirement_failure_does_not_pin(self):
        for requirement in ("", "cdhash H\"1234\"", 'identifier "com.theater.mac"', 'identifier "other" and certificate leaf[subject.OU] = "TEAM"'):
            with self.subTest(requirement=requirement), self.assertRaises(signing.SigningError):
                signing.sign_app(self.app, self.pin, runner=FakeCommands(requirement=requirement))
            self.assertFalse(self.pin.exists())

    def test_requirement_failure_preserves_existing_pin(self):
        original = self.save_pin()
        with self.assertRaises(signing.SigningError):
            signing.sign_app(self.app, self.pin, runner=FakeCommands(requirement='identifier "com.theater.mac"'))
        self.assertEqual(self.pin.read_bytes(), original)

    def test_incompatible_update_preserves_pin(self):
        original = self.save_pin()
        with self.assertRaises(signing.SigningError):
            signing.sign_app(self.app, self.pin, runner=FakeCommands(fail=lambda args: "-R" in args))
        self.assertEqual(self.pin.read_bytes(), original)

    def test_missing_pin_still_checks_previous_signed_application(self):
        previous = self.make_app("Previous.app")
        commands = FakeCommands()
        signing.sign_app(self.app, self.pin, previous_app=previous, runner=commands)
        self.assertIn([signing.CODESIGN, "--verify", "--strict", "-R", "=" + REQUIREMENT, str(self.app)], [args for args, _ in commands.calls])

    def test_incompatible_previous_application_does_not_pin(self):
        previous = self.make_app("Previous.app")
        with self.assertRaises(signing.SigningError):
            signing.sign_app(self.app, self.pin, previous_app=previous, runner=FakeCommands(fail=lambda args: "-R" in args))
        self.assertFalse(self.pin.exists())

    def test_previous_adhoc_build_can_migrate(self):
        previous = self.make_app("Previous.app")
        commands = FakeCommands(previous='Signature=adhoc\ndesignated => cdhash H"1234"')
        signing.sign_app(self.app, self.pin, previous_app=previous, runner=commands)
        self.assertTrue(self.pin.exists())
        self.assertFalse(any("-R" in args for args, _ in commands.calls))

    def test_previous_unsigned_or_invalid_requirement_is_rejected(self):
        previous = self.make_app("Previous.app")
        commands = FakeCommands(previous='designated => cdhash H"1234"')
        with self.assertRaises(signing.SigningError):
            signing.sign_app(self.app, self.pin, previous_app=previous, runner=commands)
        self.assertFalse(commands.signing_calls())
        self.assertFalse(self.pin.exists())

    def test_previous_and_pinned_requirements_are_both_checked(self):
        self.save_pin()
        previous = self.make_app("Previous.app")
        commands = FakeCommands(previous=f"Signature size=100\ndesignated => {OTHER_REQUIREMENT}")
        signing.sign_app(self.app, self.pin, previous_app=previous, runner=commands)
        requirements = [args[args.index("-R") + 1] for args, _ in commands.calls if "-R" in args]
        self.assertEqual(requirements, ["=" + REQUIREMENT, "=" + OTHER_REQUIREMENT])

    def test_invalid_bundle_identifier_is_rejected_without_commands(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "other"}))
        commands = FakeCommands()
        with self.assertRaises(signing.SigningError):
            signing.sign_app(self.app, self.pin, runner=commands)
        self.assertFalse(commands.calls)

    def test_corrupt_pin_is_never_overwritten(self):
        self.pin.parent.mkdir(parents=True)
        for contents in ("not json", "[]", '{"version":true}', json.dumps({"version": 1, "identity": "-"})):
            with self.subTest(contents=contents):
                self.pin.write_text(contents)
                commands = FakeCommands()
                with self.assertRaises(signing.SigningError):
                    signing.sign_app(self.app, self.pin, runner=commands)
                self.assertEqual(self.pin.read_text(), contents)
                self.assertFalse(commands.calls)

    def test_pin_symlink_is_rejected(self):
        target = self.root / "target.json"
        target.write_text("do not change")
        self.pin.parent.mkdir(parents=True)
        self.pin.symlink_to(target)
        with self.assertRaises(signing.SigningError):
            signing.sign_app(self.app, self.pin, runner=FakeCommands())
        self.assertEqual(target.read_text(), "do not change")

    def test_failed_atomic_replace_keeps_existing_pin_and_cleans_temporary(self):
        original = self.save_pin()
        with mock.patch.object(signing.os, "replace", side_effect=OSError("cannot replace")):
            with self.assertRaises(signing.SigningError):
                signing.sign_app(self.app, self.pin, runner=FakeCommands())
        self.assertEqual(self.pin.read_bytes(), original)
        self.assertEqual(list(self.pin.parent.glob(".signing-identity-*")), [])

    def test_arguments_are_literal_and_never_sent_to_shell(self):
        app = self.make_app("-SeatSix $(touch not-a-command); 'quoted'.app")
        commands = FakeCommands()
        signing.sign_app(app, self.pin, explicit=FIRST, runner=commands)
        self.assertEqual(commands.signing_calls()[0][-1], str(app))
        for args, options in commands.calls:
            self.assertIsInstance(args, list)
            self.assertNotIn("shell", options)
        self.assertFalse((self.root / "not-a-command").exists())

    def test_legacy_signing_override_remains_valid_and_conflicting_overrides_fail(self):
        with mock.patch.dict(os.environ, {"THEATER_SIGNING_IDENTITY": FIRST}, clear=True), \
                mock.patch.object(signing, "sign_app") as sign, mock.patch("builtins.print"):
            self.assertEqual(signing.main([str(self.app)]), 0)
            sign.assert_called_once_with(self.app, signing.DEFAULT_PIN, FIRST, None)
            with mock.patch.dict(os.environ, {"SEATSIX_SIGNING_IDENTITY": SECOND}):
                self.assertEqual(signing.main([str(self.app)]), 1)
                self.assertEqual(sign.call_count, 1)

    def test_main_reads_environment_override_and_passes_cli_paths(self):
        with mock.patch.dict(os.environ, {"SEATSIX_SIGNING_IDENTITY": FIRST}), mock.patch.object(signing, "sign_app") as sign, mock.patch("builtins.print"):
            self.assertEqual(signing.main([str(self.app), "--pin-file", str(self.pin), "--previous-app", str(self.root / "Previous.app")]), 0)
        sign.assert_called_once_with(self.app, self.pin, FIRST, self.root / "Previous.app")

    def test_local_signs_and_strictly_verifies_without_certificate_or_pin_access(self):
        self.save_pin()
        commands = FakeCommands(identities=[])
        previous = self.make_app("Previous.app")
        # Even malformed pin contents must neither be read nor repaired in this
        # explicit mode. No certificate lookup or old certificate checks run.
        self.pin.write_text("expired or malformed certificate pin")
        original = self.pin.read_bytes()
        with mock.patch.object(signing, "pin_lock", side_effect=AssertionError("pin lock accessed")), \
                mock.patch.object(signing, "load_pin", side_effect=AssertionError("pin read")), \
                mock.patch.object(signing, "write_pin", side_effect=AssertionError("pin written")), \
                mock.patch.object(signing, "previous_requirement", side_effect=AssertionError("old certificate inspected")):
            signing.sign_local_app(self.app, previous_app=previous, runner=commands)
        self.assertEqual([args for args, _ in commands.calls], [
            [signing.CODESIGN, "--force", "--deep", "--sign", "-", str(self.app)],
            [signing.CODESIGN, "--verify", "--deep", "--strict", str(self.app)],
        ])
        self.assertEqual(self.pin.read_bytes(), original)
        self.assertFalse(self.pin.with_name(self.pin.name + ".lock").exists())

    def test_local_does_not_create_pin_or_change_symlink_target(self):
        commands = FakeCommands()
        signing.sign_local_app(self.app, runner=commands)
        self.assertFalse(self.pin.parent.exists())
        target = self.root / "target.json"
        target.write_text("existing certificate pin")
        self.pin.parent.mkdir()
        self.pin.symlink_to(target)
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(signing.subprocess, "run", commands), mock.patch("builtins.print"):
            self.assertEqual(signing.main([str(self.app), "--pin-file", str(self.pin), "--local"]), 0)
        self.assertTrue(self.pin.is_symlink())
        self.assertEqual(target.read_text(), "existing certificate pin")
        self.assertEqual(list(self.pin.parent.iterdir()), [self.pin])

    def test_local_environment_conflict_is_rejected_before_signing(self):
        original = self.save_pin()
        for explicit in (FIRST, "-", ""):
            commands = FakeCommands()
            with self.subTest(explicit=explicit), self.assertRaisesRegex(signing.SigningError, "conflicts"):
                signing.sign_local_app(self.app, explicit=explicit, runner=commands)
            self.assertFalse(commands.calls)
            self.assertEqual(self.pin.read_bytes(), original)

    def test_local_signing_or_verification_failure_keeps_pin_and_hides_output(self):
        original = self.save_pin()
        for phase in ("--sign", "--verify"):
            commands = FakeCommands(fail=lambda args: phase in args)
            with self.subTest(phase=phase), self.assertRaises(signing.SigningError) as failure:
                signing.sign_local_app(self.app, runner=commands)
            self.assertNotIn("private", str(failure.exception))
            self.assertEqual(self.pin.read_bytes(), original)
            self.assertEqual(len(commands.calls), 1 if phase == "--sign" else 2)

    def test_local_invalid_bundle_or_same_previous_is_rejected_without_commands(self):
        commands = FakeCommands()
        with self.assertRaisesRegex(signing.SigningError, "must differ"):
            signing.sign_local_app(self.app, previous_app=self.app, runner=commands)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "other"}))
        with self.assertRaisesRegex(signing.SigningError, "bundle identifier"):
            signing.sign_local_app(self.app, runner=commands)
        self.assertFalse(commands.calls)

    def test_main_requires_full_local_flag_and_rejects_extra_arguments(self):
        for extra in (["--loc"], ["--unknown"], ["extra.app"], ["--local", "extra.app"]):
            with self.subTest(extra=extra), mock.patch.object(signing, "sign_app") as sign, \
                    mock.patch.object(signing, "sign_local_app") as local_sign, mock.patch("sys.stderr"):
                with self.assertRaises(SystemExit) as failure:
                    signing.main([str(self.app)] + extra)
                self.assertEqual(failure.exception.code, 2)
                sign.assert_not_called()
                local_sign.assert_not_called()

    def test_main_local_routes_environment_and_previous_path_to_local_signer(self):
        previous = self.root / "Previous.app"
        with mock.patch.dict(os.environ, {"SEATSIX_SIGNING_IDENTITY": FIRST}), \
                mock.patch.object(signing, "sign_app") as sign, \
                mock.patch.object(signing, "sign_local_app", side_effect=signing.SigningError("conflicts")) as local_sign, \
                mock.patch("builtins.print"):
            self.assertEqual(signing.main([str(self.app), "--previous-app", str(previous), "--local"]), 1)
        sign.assert_not_called()
        local_sign.assert_called_once_with(self.app, FIRST, previous)

    def test_main_default_certificate_failure_never_calls_local_signer(self):
        with mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch.object(signing, "sign_app", side_effect=signing.SigningError("expired")) as sign, \
                mock.patch.object(signing, "sign_local_app") as local_sign, mock.patch("builtins.print"):
            self.assertEqual(signing.main([str(self.app)]), 1)
        sign.assert_called_once()
        local_sign.assert_not_called()


if __name__ == "__main__":
    unittest.main()
