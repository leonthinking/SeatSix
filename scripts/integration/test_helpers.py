"""Safety regressions for the disposable integration environment, no network."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import common
import cleanup
import setup


class IntegrationSafetyTests(unittest.TestCase):
    def test_persisted_fixture_names_and_new_names_work_without_a_second_library(self):
        legacy = {"Name": "Theater Test Movies"}
        current = {"Name": "SeatSix Test Movies"}
        self.assertIs(common.fixture_named([legacy], "Test Movies"), legacy)
        self.assertIs(common.fixture_named([legacy, current], "Test Movies"), current)
        self.assertIsNone(common.fixture_named([{"Name": "Private Movies"}], "Test Movies"))

    def test_existing_unowned_container_is_rejected(self):
        result = subprocess.CompletedProcess([], 0, json.dumps([{"Config": {"Labels": {}}}]), "")
        with patch.object(common, "docker", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "Refusing"):
                common.inspect_owned("jellyfin")

    def test_matching_workspace_container_is_accepted(self):
        item = {"Config": {"Labels": {common.LABEL: str(common.ROOT)}}}
        result = subprocess.CompletedProcess([], 0, json.dumps([item]), "")
        with patch.object(common, "docker", return_value=result):
            self.assertEqual(common.inspect_owned("emby"), item)

    def test_missing_container_is_case_insensitive(self):
        for text in ["error: no such object: theater-dev-jellyfin", "Error: No such container: theater-dev-jellyfin"]:
            with patch.object(common, "docker", return_value=subprocess.CompletedProcess([], 1, "[]", text)):
                self.assertIsNone(common.inspect_owned("jellyfin"))

    def test_media_requests_never_escape_owned_origin(self):
        api = common.API("jellyfin", token="synthetic-test-only")
        for url in ["https://example.com/video", "http://localhost:18096/video", "http://127.0.0.1:28096/video", "https://127.0.0.1:18096/video"]:
            with self.assertRaisesRegex(RuntimeError, "outside"):
                api.fetch("GET", url)

    def test_redirect_is_rejected_before_forwarding_credentials(self):
        with self.assertRaisesRegex(RuntimeError, "redirect"):
            common.NoRedirect().redirect_request(None, None, 302, "", {}, "https://outside.invalid/")

    def test_credentials_have_owner_only_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "credentials.json"
            common.write_private(path, {"password": "synthetic-only"})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text())["password"], "synthetic-only")

    def test_existing_unowned_volume_is_rejected(self):
        result = subprocess.CompletedProcess([], 0, json.dumps([{"Labels": {}}]), "")
        with patch.object(common, "docker", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "Refusing"):
                common.inspect_owned_volume("theater-dev-jellyfin-config")

    def test_runtime_without_marker_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            with patch.object(common, "RUNTIME", path), patch.object(common, "RUNTIME_MARKER", path / "missing"):
                with self.assertRaisesRegex(RuntimeError, "ownership marker"):
                    common.validate_runtime()

    def test_marked_runtime_still_rejects_media_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            marker = path / "marker.json"
            marker.write_text(json.dumps({"workspace": str(common.ROOT)}))
            (path / "media").symlink_to(path / "outside")
            with patch.object(common, "RUNTIME", path), patch.object(common, "RUNTIME_MARKER", marker):
                with self.assertRaisesRegex(RuntimeError, "symlink"):
                    common.validate_runtime()

    def test_cleanup_validates_all_volumes_before_any_removal(self):
        with patch("sys.argv", ["cleanup.py", "--purge-test-data"]), patch.object(cleanup, "inspect_owned", return_value={"Config": {}}), patch.object(cleanup, "inspect_owned_volume", side_effect=RuntimeError("Refusing unowned")), patch.object(cleanup, "docker") as docker:
            with self.assertRaisesRegex(RuntimeError, "Refusing"):
                cleanup.main()
            docker.assert_not_called()

    def test_cleanup_validates_all_containers_before_removal(self):
        with patch("sys.argv", ["cleanup.py"]), patch.object(cleanup, "inspect_owned", side_effect=[{"Config": {}}, RuntimeError("Refusing unowned")]), patch.object(cleanup, "docker") as docker:
            with self.assertRaisesRegex(RuntimeError, "Refusing"):
                cleanup.main()
            docker.assert_not_called()

    def test_setup_refuses_owned_container_with_unexpected_volume(self):
        item = {"Mounts": [{"Type": "volume", "Name": "somebody-elses-media", "Destination": "/media"}]}
        with patch.object(setup, "inspect_owned", return_value=item), patch.object(setup, "docker") as docker:
            with self.assertRaisesRegex(RuntimeError, "unexpected volumes"):
                setup.start_container("jellyfin", False)
            docker.assert_not_called()

    def test_emby_repeated_setup_reuses_login_when_public_omits_wizard_flag(self):
        api = Mock()
        api.login.return_value = {"Id": "existing-test-user"}
        user = setup.login_or_initialize("emby", api, {"Version": "4.9.3.0"}, {"username": "test", "password": "test-only"})
        self.assertEqual(user["Id"], "existing-test-user")
        api.request.assert_not_called()

    def test_existing_credentials_auth_failure_never_resets_startup(self):
        for info in [{}, {"StartupWizardCompleted": False}, {"StartupWizardCompleted": True}]:
            api = Mock()
            api.login.side_effect = RuntimeError("HTTP 401")
            with self.assertRaisesRegex(RuntimeError, "stored test credentials"):
                setup.login_or_initialize("emby", api, info, {"username": "test", "password": "wrong", "server_id": "existing"})
            api.request.assert_not_called()

    def test_auth_failure_on_completed_server_never_calls_startup(self):
        api = Mock()
        api.login.side_effect = RuntimeError("HTTP 401")
        with self.assertRaisesRegex(RuntimeError, "without evidence"):
            setup.login_or_initialize("jellyfin", api, {"StartupWizardCompleted": True}, {"username": "test", "password": "wrong"})
        api.request.assert_not_called()

    def test_emby_missing_flag_plus_inaccessible_wizard_is_not_new_server(self):
        api = Mock()
        api.login.side_effect = RuntimeError("HTTP 401")
        api.request.side_effect = RuntimeError("HTTP 401")
        with self.assertRaisesRegex(RuntimeError, "startup configuration is unavailable"):
            setup.login_or_initialize("emby", api, {}, {"username": "test", "password": "wrong"})
        api.request.assert_called_once_with("GET", "/Startup/Configuration")

    def test_malformed_startup_configuration_never_triggers_writes(self):
        for configuration in [{}, [], "unexpected"]:
            api = Mock()
            api.login.side_effect = RuntimeError("HTTP 401")
            api.request.return_value = configuration
            with self.assertRaisesRegex(RuntimeError, "did not establish"):
                setup.login_or_initialize("emby", api, {}, {"username": "test", "password": "new"})
            api.request.assert_called_once_with("GET", "/Startup/Configuration")

    def test_first_setup_requires_explicit_or_readable_wizard_evidence(self):
        for kind, info in [("jellyfin", {"StartupWizardCompleted": False}), ("emby", {})]:
            api = Mock()
            api.login.side_effect = [RuntimeError("HTTP 401"), {"Id": "new-test-user"}]
            api.request.return_value = {"UICulture": "en-US"}
            user = setup.login_or_initialize(kind, api, info, {"username": "test", "password": "new"})
            self.assertEqual(user["Id"], "new-test-user")
            self.assertEqual(api.request.call_args_list[0].args, ("GET", "/Startup/Configuration"))
            self.assertIn(("POST", "/Startup/Complete"), [call.args for call in api.request.call_args_list])


if __name__ == "__main__":
    unittest.main()
