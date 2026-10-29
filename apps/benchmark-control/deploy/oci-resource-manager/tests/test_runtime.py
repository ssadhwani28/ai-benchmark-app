import base64
import importlib.util
import json
import gzip
import io
import os
from pathlib import Path
import stat
import subprocess
import tempfile
from types import SimpleNamespace as NS
import unittest
from unittest.mock import ANY, Mock, patch

STACK = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("benchmark_runtime", STACK / "runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def configuration(**changes):
    return dict(app_secret="a" * 64, oidc_client_secret="secret-token", oidc_client_id="client",
                public_url="https://192.0.2.10", oidc_domain_url="https://iam.example.test",
                oidc_issuer="https://identity.oraclecloud.com/", allowed_subjects=["approved-user"],
                tls_key="private-key", tls_cert="certificate", **changes)


def bundle(version=1, config=None):
    content = base64.b64encode(json.dumps(configuration() if config is None else config).encode()).decode()
    return NS(data=NS(version_number=version, secret_bundle_content=NS(content=content)))


class StopAfter:
    def __init__(self, iterations):
        self.remaining = iterations

    def is_set(self):
        return self.remaining <= 0

    def wait(self, seconds):
        self.remaining -= 1


class RuntimeTests(unittest.TestCase):
    def test_assignment_configuration_without_subjects_and_legacy_default(self):
        config = configuration(authorization_mode="app_assignment")
        config["allowed_subjects"] = []
        runtime.validate_config(config)
        with tempfile.TemporaryDirectory() as directory:
            _, env = runtime.prepare(config, Path(directory))
        self.assertEqual(env["APP_OIDC_AUTHORIZATION_MODE"], "app_assignment")
        self.assertEqual(env["APP_OIDC_ALLOWED_SUBJECTS"], "")
        config.pop("authorization_mode")
        with self.assertRaises(ValueError):
            runtime.validate_config(config)
        config["authorization_mode"] = "unknown"
        with self.assertRaises(ValueError):
            runtime.validate_config(config)

    def test_private_volume_content_validation_and_stable_version(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "configuration.json"
            path.write_text(json.dumps(configuration()))
            version, config = runtime.fetch_file(path)
            self.assertEqual(config, configuration())
            self.assertEqual(version, runtime.fetch_file(path)[0])
            for content in ("{}", "[]", "invalid-json", "x" * 65537):
                path.write_text(content)
                with self.assertRaises(ValueError):
                    runtime.fetch_file(path)
            with self.assertRaises(FileNotFoundError):
                runtime.fetch_file(Path(directory) / "missing")

    def test_private_volume_boot_does_not_request_resource_principal_or_vault(self):
        with patch.dict(os.environ, BENCHMARK_CONFIG_SOURCE="config_volume", BENCHMARK_CONFIG_FILE="/private/config.json"), \
             patch.object(runtime, "fetch_file", return_value=("version", configuration())) as fetch, \
             patch.object(runtime, "run") as run, \
             patch.object(runtime.signal, "signal"), \
             patch.object(runtime.oci.auth.signers, "get_resource_principals_signer") as signer:
            runtime.main()
            signer.assert_not_called()
            fetch.assert_called_once_with("/private/config.json")
            self.assertEqual(run.call_args.kwargs["configuration_loader"](), ("version", configuration()))

    def test_invalid_mounted_configuration_fails_before_application_start(self):
        with patch.dict(os.environ, BENCHMARK_CONFIG_SOURCE="config_volume", BENCHMARK_CONFIG_FILE="/private/config.json"), \
             patch.object(runtime, "fetch_file", side_effect=ValueError("Invalid runtime configuration")), \
             patch.object(runtime, "run") as run, patch.object(runtime.signal, "signal"):
            with self.assertRaises(ValueError):
                runtime.main()
            run.assert_not_called()

    def test_fetch_current_by_name_without_secret_metadata_permission(self):
        client = Mock()
        client.get_secret_bundle_by_name.return_value = bundle()
        version, config = runtime.fetch(client, "deployment-runtime", "vault-id")
        client.get_secret_bundle_by_name.assert_called_once_with("deployment-runtime", "vault-id", stage="CURRENT", retry_strategy=ANY)
        self.assertEqual(version, 1)
        self.assertEqual(config["oidc_client_id"], "client")

    def test_invalid_bundle_is_rejected(self):
        client = Mock()
        for config in ({}, {**configuration(), "allowed_subjects": ["user,other"]}):
            client.get_secret_bundle_by_name.return_value = bundle(config=config)
            with self.assertRaises(ValueError):
                runtime.fetch(client, "name", "vault")

    def test_tls_and_secret_files_not_plaintext_environment_or_access_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            command, env = runtime.prepare(configuration(), Path(directory))
            self.assertEqual(command[command.index("--port") + 1], "443")
            self.assertIn("--ssl-keyfile", command)
            self.assertIn("--no-access-log", command)  # do not log OAuth callback query strings
            self.assertEqual(env["APP_AUTH_MODE"], "oci_iam")
            self.assertNotIn("secret-token", env.values())
            for filename in ("app-secret", "client-secret", "tls.key", "tls.crt"):
                self.assertEqual(stat.S_IMODE((Path(directory) / filename).stat().st_mode), 0o600)

    def test_archive_configuration_reaches_api_and_embedded_worker(self):
        config = configuration(report_archive=dict(enabled=True, bucket="reports", namespace="ns", region="eu-frankfurt-1", link_hours=24))
        with tempfile.TemporaryDirectory() as directory:
            _, env = runtime.prepare(config, Path(directory))
        self.assertEqual(env["APP_REPORT_ARCHIVE_BUCKET"], "reports")
        self.assertEqual(env["APP_REPORT_ARCHIVE_NAMESPACE"], "ns")
        self.assertEqual(env["APP_REPORT_ARCHIVE_REGION"], "eu-frankfurt-1")
        self.assertEqual(env["APP_REPORT_ARCHIVE_LINK_HOURS"], "24")
        self.assertEqual(env["APP_REPORT_ARCHIVE_AUTH"], "principal")
        self.assertEqual(env["APP_REPORT_WORKER_MODE"], "embedded")

    def test_disabled_archive_clears_inherited_bucket_and_credentials_mode(self):
        with patch.dict(os.environ, APP_REPORT_ARCHIVE_BUCKET="stale", APP_REPORT_ARCHIVE_NAMESPACE="stale", APP_REPORT_ARCHIVE_AUTH="config"):
            with tempfile.TemporaryDirectory() as directory:
                _, env = runtime.prepare(configuration(), Path(directory))
        self.assertEqual(env["APP_REPORT_ARCHIVE_BUCKET"], "")
        self.assertEqual(env["APP_REPORT_ARCHIVE_NAMESPACE"], "")
        self.assertEqual(env["APP_REPORT_ARCHIVE_AUTH"], "principal")

    def test_invalid_archive_bundle_rejected_before_process_restart(self):
        client = Mock()
        for archive in ({"enabled": "yes"}, {"enabled": True}, {"enabled": False, "link_hours": 0}):
            client.get_secret_bundle_by_name.return_value = bundle(config=configuration(report_archive=archive))
            with self.assertRaises(ValueError):
                runtime.fetch(client, "name", "vault")

    def test_first_boot_retry_rotation_outage_and_shutdown(self):
        client = Mock()
        client.get_secret_bundle_by_name.side_effect = [
            RuntimeError("DO_NOT_LOG_INITIAL_SECRET"), bundle(1),
            RuntimeError("DO_NOT_LOG_RESPONSE_BODY"), bundle(1), bundle(2),
        ]
        first, second = Mock(), Mock()
        first.poll.return_value = second.poll.return_value = None
        with patch.object(runtime.subprocess, "Popen", side_effect=[first, second]) as start, patch("builtins.print") as log:
            runtime.run(client, "name", "vault", StopAfter(5), poll_seconds=0)
        self.assertEqual(start.call_count, 2)  # same version and outage leave first process alone
        first.terminate.assert_called_once()
        second.terminate.assert_called_once()
        for call in start.call_args_list:
            self.assertFalse(Path(call.args[0][-1]).exists())  # credentials cleaned after shutdown
        self.assertNotIn("DO_NOT_LOG", str(log.call_args_list))

    def test_child_exit_fails_supervisor_for_service_restart(self):
        client, child = Mock(), Mock()
        client.get_secret_bundle_by_name.return_value = bundle()
        child.poll.return_value = 1
        with patch.object(runtime.subprocess, "Popen", return_value=child):
            with self.assertRaisesRegex(RuntimeError, "Application process exited"):
                runtime.run(client, "name", "vault", StopAfter(1), poll_seconds=0)

    def test_encrypted_object_uses_existing_key_and_bound_context(self):
        storage, crypto = Mock(), Mock()
        storage.get_object.return_value = NS(data=NS(raw=io.BytesIO(b"authenticated-ciphertext"), close=Mock()))
        crypto.decrypt.return_value.data.plaintext = base64.b64encode(gzip.compress(json.dumps(configuration()).encode())).decode()
        version, config = runtime.fetch_encrypted(storage, crypto, "ns", "private-bucket", "runtime/app.enc", "existing-key", "app-identity")
        self.assertEqual(config["oidc_client_id"], "client")
        self.assertTrue(version)
        details = crypto.decrypt.call_args.args[0]
        self.assertEqual(details.key_id, "existing-key")
        self.assertEqual(details.associated_data, {"purpose":"runtime-config", "deployment":"app-identity"})
        storage.get_object.return_value.data.close.assert_called_once()

    def test_encrypted_object_rejects_oversized_data_before_decryption(self):
        storage, crypto = Mock(), Mock()
        storage.get_object.return_value = NS(data=NS(raw=io.BytesIO(b"x"*65537), close=Mock()))
        with self.assertRaises(ValueError):
            runtime.fetch_encrypted(storage, crypto, "ns", "bucket", "runtime/app.enc", "key", "app")
        crypto.decrypt.assert_not_called()

    def test_bad_ciphertext_update_keeps_running_child(self):
        loader = Mock(side_effect=[("version-1",configuration()), ValueError("DO_NOT_LOG_CRYPTO_ERROR")])
        child = Mock(); child.poll.return_value = None
        with patch.object(runtime.subprocess, "Popen", return_value=child) as start, patch("builtins.print") as log:
            runtime.run(None, "", "", StopAfter(2), poll_seconds=0, configuration_loader=loader)
        self.assertEqual(start.call_count, 1)
        self.assertNotIn("DO_NOT_LOG", str(log.call_args_list))

    def test_unresponsive_child_is_killed_on_shutdown(self):
        child = Mock()
        child.poll.return_value = None
        child.wait.side_effect = [subprocess.TimeoutExpired("uvicorn", 20), None]
        runtime.stop(child)
        child.kill.assert_called_once()


if __name__ == "__main__":
    unittest.main()
