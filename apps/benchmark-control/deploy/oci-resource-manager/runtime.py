"""Run HTTPS with private mounted configuration or optional Vault/KMS delivery.

Secret values stay out of environment variables and command arguments. Mounted
configuration is OCI access-controlled; its base64 representation is not encryption.
"""
from __future__ import annotations

import base64
import json
import gzip
import hashlib
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading

import oci

REQUIRED = {
    "app_secret", "oidc_client_secret", "oidc_client_id", "public_url",
    "oidc_domain_url", "oidc_issuer", "tls_key", "tls_cert",
}


def archive_environment(config):
    archive = config.get("report_archive", {"enabled": False})
    if not isinstance(archive, dict) or not isinstance(archive.get("enabled"), bool):
        raise ValueError("Invalid archive configuration")
    hours = archive.get("link_hours", 168)
    if not isinstance(hours, int) or isinstance(hours, bool) or not 1 <= hours <= 8760:
        raise ValueError("Invalid archive link lifetime")
    active = archive["enabled"]
    if active and not all(isinstance(archive.get(k), str) and archive[k].strip() for k in ("bucket", "namespace", "region")):
        raise ValueError("Incomplete archive configuration")
    return {
        "APP_REPORT_ARCHIVE_BUCKET": archive["bucket"] if active else "",
        "APP_REPORT_ARCHIVE_NAMESPACE": archive["namespace"] if active else "",
        "APP_REPORT_ARCHIVE_REGION": archive.get("region") or os.getenv("OCI_REGION", "us-ashburn-1"),
        "APP_REPORT_ARCHIVE_AUTH": "principal",
        "APP_REPORT_ARCHIVE_LINK_HOURS": str(hours),
    }


def validate_config(config):
    if not isinstance(config, dict) or not REQUIRED.issubset(config) or any(not config[k] for k in REQUIRED):
        raise ValueError("Incomplete runtime configuration")
    mode = config.get("authorization_mode", "subject_allowlist")
    if mode not in {"app_assignment", "subject_allowlist"}:
        raise ValueError("Invalid authorization mode")
    subjects = config.get("allowed_subjects", [])
    if not isinstance(subjects, list) or (mode == "subject_allowlist" and not subjects) or not all(
        isinstance(v, str) and v.strip() == v and v and "," not in v for v in subjects
    ):
        raise ValueError("Invalid subject allowlist")
    archive_environment(config)
    return config


def fetch(client, name, vault_id):
    bundle = client.get_secret_bundle_by_name(name, vault_id, stage="CURRENT",
                                            retry_strategy=oci.retry.NoneRetryStrategy()).data
    config = json.loads(base64.b64decode(bundle.secret_bundle_content.content, validate=True))
    return bundle.version_number, validate_config(config)


def fetch_encrypted(storage, crypto, namespace, bucket, object_name, key_id, deployment):
    response = storage.get_object(namespace, bucket, object_name, retry_strategy=oci.retry.NoneRetryStrategy())
    try:
        ciphertext = response.data.raw.read(65537)
    finally:
        response.data.close()
    if len(ciphertext) > 65536:
        raise ValueError("Runtime object too large")
    result = crypto.decrypt(oci.key_management.models.DecryptDataDetails(
        key_id=key_id, ciphertext=ciphertext.decode("ascii"),
        associated_data={"purpose": "runtime-config", "deployment": deployment}),
        retry_strategy=oci.retry.NoneRetryStrategy()).data
    compressed = base64.b64decode(result.plaintext, validate=True)
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
        plaintext = stream.read(65537)
    if len(plaintext) > 65536:
        raise ValueError("Runtime configuration too large")
    config = validate_config(json.loads(plaintext))
    return hashlib.sha256(plaintext).hexdigest(), config


def fetch_file(filename):
    # Bound the read and validate before starting any application process.
    with open(filename, "rb") as stream:
        plaintext = stream.read(65537)
    if len(plaintext) > 65536:
        raise ValueError("Runtime configuration too large")
    config = validate_config(json.loads(plaintext))
    return hashlib.sha256(plaintext).hexdigest(), config


def prepare(config, directory):
    env = os.environ.copy()
    env.update(archive_environment(config))
    for key, filename in (("app_secret", "app-secret"), ("oidc_client_secret", "client-secret"),
                          ("tls_key", "tls.key"), ("tls_cert", "tls.crt")):
        path = directory / filename
        # directory is private and file names are fixed, never secret-derived.
        path.write_text(config[key])
        path.chmod(0o600)
    env.update({
        "APP_AUTH_MODE": "oci_iam",
        "APP_SECRET_FILE": str(directory / "app-secret"),
        "APP_OIDC_CLIENT_SECRET_FILE": str(directory / "client-secret"),
        "APP_OIDC_CLIENT_ID": config["oidc_client_id"],
        "APP_PUBLIC_URL": config["public_url"],
        "APP_OIDC_DOMAIN_URL": config["oidc_domain_url"],
        "APP_OIDC_ISSUER": config["oidc_issuer"],
        "APP_OIDC_ALLOWED_SUBJECTS": ",".join(config.get("allowed_subjects", [])),
        "APP_OIDC_AUTHORIZATION_MODE": config.get("authorization_mode", "subject_allowlist"),
        "APP_REPORT_WORKER_MODE": "embedded",
        "APP_DB_PATH": "/data/app.db",
        "APP_ARTIFACT_DIR": "/data/artifacts",
    })
    command = [sys.executable, "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "443", "--no-access-log",
               "--ssl-keyfile", str(directory / "tls.key"), "--ssl-certfile", str(directory / "tls.crt")]
    return command, env


def stop(child):
    if child is not None and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=20)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def run(client, name, vault_id, stopped, poll_seconds=30, configuration_loader=None):
    loader = configuration_loader or (lambda: fetch(client, name, vault_id))
    child = None
    version = None
    current_dir = None
    os.umask(0o077)
    try:
        while not stopped.is_set():
            try:
                new_version, config = loader()
            except Exception:
                # IAM propagation, a not-yet-created secret, or temporary API outage.
                # SDK errors may contain response bodies; never print them here.
                print("Runtime configuration unavailable; retrying.", flush=True)
            else:
                if new_version != version:
                    candidate = tempfile.TemporaryDirectory(prefix="benchmark-runtime-")
                    try:
                        command, env = prepare(config, Path(candidate.name))
                        stop(child)
                        child = subprocess.Popen(command, env=env)
                    except Exception:
                        candidate.cleanup()
                        raise
                    if current_dir:
                        current_dir.cleanup()
                    current_dir = candidate
                    version = new_version
                    print("Applied runtime configuration.", flush=True)
            if child is not None and child.poll() is not None:
                # Let the service restart policy retry; do not leave a dead app marked running.
                raise RuntimeError("Application process exited")
            stopped.wait(poll_seconds)
    finally:
        stop(child)
        if current_dir:
            current_dir.cleanup()


def main():
    stopped = threading.Event()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: stopped.set())
    source = os.getenv("BENCHMARK_CONFIG_SOURCE", "vault")
    if source == "config_volume":
        filename = os.environ["BENCHMARK_CONFIG_FILE"]
        # Fail closed on an invalid immutable volume; OCI can report/restart it.
        fetch_file(filename)
        run(None, "", "", stopped, configuration_loader=lambda: fetch_file(filename))
        return
    if source not in {"vault", "kms_object_storage"}:
        raise ValueError("Unknown runtime configuration source")
    signer = oci.auth.signers.get_resource_principals_signer()
    if os.getenv("BENCHMARK_CONFIG_SOURCE", "vault") == "kms_object_storage":
        storage = oci.object_storage.ObjectStorageClient({"region": os.environ["BENCHMARK_CONFIG_REGION"]}, signer=signer)
        crypto = oci.key_management.KmsCryptoClient({"region": os.environ["OCI_REGION"]}, signer=signer,
                                                  service_endpoint=os.environ["BENCHMARK_KMS_CRYPTO_ENDPOINT"])
        loader = lambda: fetch_encrypted(storage, crypto, os.environ["BENCHMARK_CONFIG_NAMESPACE"],
            os.environ["BENCHMARK_CONFIG_BUCKET"], os.environ["BENCHMARK_CONFIG_OBJECT"],
            os.environ["BENCHMARK_KMS_KEY_ID"], os.environ["BENCHMARK_CONFIG_DEPLOYMENT"])
        run(None, "", "", stopped, configuration_loader=loader)
    else:
        client = oci.secrets.SecretsClient({"region": os.environ["OCI_REGION"]}, signer=signer)
        run(client, os.environ["BENCHMARK_SECRET_NAME"], os.environ["BENCHMARK_VAULT_ID"], stopped)


if __name__ == "__main__":
    main()
