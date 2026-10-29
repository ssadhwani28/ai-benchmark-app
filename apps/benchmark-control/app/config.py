from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


@dataclass(frozen=True)
class Settings:
    app_secret: str
    db_path: Path
    artifact_dir: Path
    auth_mode: str = "disabled"
    public_url: str = ""
    oidc_domain_url: str = ""
    oidc_issuer: str = ""
    oidc_client_id: str = ""
    oidc_client_secret: str = ""
    oidc_allowed_subjects: tuple[str, ...] = ()
    oidc_authorization_mode: str = "subject_allowlist"


def secret_setting(name: str) -> str:
    path = os.getenv(f"{name}_FILE")
    return Path(path).read_text().strip() if path else os.getenv(name, "")


def get_settings() -> Settings:
    secret = secret_setting("APP_SECRET")
    if not secret or len(secret) < 24:
        raise RuntimeError("APP_SECRET must be set to at least 24 characters")
    mode = os.getenv("APP_AUTH_MODE", "disabled")
    if mode not in {"disabled", "oci_iam"}:
        raise RuntimeError("APP_AUTH_MODE must be disabled or oci_iam")
    public_url = os.getenv("APP_PUBLIC_URL", "").rstrip("/")
    domain_url = os.getenv("APP_OIDC_DOMAIN_URL", "").rstrip("/")
    issuer = os.getenv("APP_OIDC_ISSUER", "")
    client_id = os.getenv("APP_OIDC_CLIENT_ID", "")
    client_secret = secret_setting("APP_OIDC_CLIENT_SECRET")
    subjects = tuple(x.strip() for x in os.getenv("APP_OIDC_ALLOWED_SUBJECTS", "").split(",") if x.strip())
    authorization_mode = os.getenv("APP_OIDC_AUTHORIZATION_MODE", "subject_allowlist")
    if authorization_mode not in {"subject_allowlist", "app_assignment"}:
        raise RuntimeError("APP_OIDC_AUTHORIZATION_MODE must be subject_allowlist or app_assignment")
    if mode == "oci_iam":
        for name, value in (("APP_PUBLIC_URL", public_url), ("APP_OIDC_DOMAIN_URL", domain_url), ("APP_OIDC_ISSUER", issuer)):
            url = urlsplit(value)
            if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ("", "/"):
                raise RuntimeError(f"{name} must be an HTTPS origin")
        if not client_id or not client_secret or (authorization_mode == "subject_allowlist" and not subjects):
            raise RuntimeError("OCI IAM requires client credentials and, in subject_allowlist mode, explicit allowed subjects")
    db_path = Path(os.getenv("APP_DB_PATH", "/data/app.db"))
    artifact_dir = Path(os.getenv("APP_ARTIFACT_DIR", "/data/artifacts"))
    artifact_dir.mkdir(parents=True, exist_ok=True)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    return Settings(secret, db_path, artifact_dir, mode, public_url, domain_url, issuer, client_id, client_secret, subjects, authorization_mode)
