"""Real OIDC signature/state checks against a simulated IAM server; no cloud writes."""
import base64
from dataclasses import replace
import hashlib
import importlib
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient
from fastapi.staticfiles import StaticFiles
import httpx
from joserfc import jwt
from joserfc.jwk import RSAKey

from app.config import Settings, get_settings
from app.db import Database
from app.iam_auth import SESSION_COOKIE, install_iam_auth, session_key
from app.iam_admin import link_user
from app.security import SecretBox
from app.worker import Worker


class DayOneSecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bootstrap = tempfile.TemporaryDirectory()
        with patch.dict(os.environ, APP_SECRET="security-fixture-secret-with-enough-entropy",
                        APP_DB_PATH=str(Path(cls.bootstrap.name) / "bootstrap.db"),
                        APP_ARTIFACT_DIR=str(Path(cls.bootstrap.name) / "artifacts")):
            cls.api = importlib.import_module("app.main")
        cls.signing_key = RSAKey.generate_key(2048, parameters={"kid": "fixture"})

    @classmethod
    def tearDownClass(cls):
        cls.bootstrap.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.db = Database(self.root / "app.db")
        self.db.init()
        self.addCleanup(self.db.connect().close)
        self.box = SecretBox("security-fixture-secret-with-enough-entropy")
        self.settings = Settings(self.box.app_secret, self.root / "app.db", self.root / "artifacts",
                                 "oci_iam", "https://benchmark.test", "https://iam.test", "https://iam.test",
                                 "fixture-client", "fixture-client-secret", ("operator",))
        self.claim_overrides = {}
        self.token_requests = []
        self.app = FastAPI()
        self.oauth = install_iam_auth(self.app, self.settings, lambda: self.db)
        self.oauth.oci.client_kwargs["transport"] = httpx.MockTransport(self.iam_server)
        self.app.middleware("http")(self.api.protect_browser_requests)
        self.app.get("/")(self.api.index)
        self.app.get("/login")(self.api.login_page)
        self.app.mount("/static", StaticFiles(directory=Path(self.api.__file__).parent / "static"), name="static")
        self.app.get("/api/me")(self.api.me)
        self.app.post("/api/protected")(lambda user=Depends(self.api.current_user): {"id": user["id"]})
        self.patcher = patch.multiple(self.api, db=self.db, secret_box=self.box, settings=self.settings)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        self.client = TestClient(self.app, base_url=self.settings.public_url)
        self.addCleanup(self.client.close)

    def iam_server(self, request):
        if request.url.path == "/.well-known/openid-configuration":
            return httpx.Response(200, json={
                "issuer": "https://iam.test", "authorization_endpoint": "https://iam.test/authorize",
                "token_endpoint": "https://iam.test/token", "jwks_uri": "https://iam.test/jwks",
                "id_token_signing_alg_values_supported": ["RS256"],
            })
        if request.url.path == "/jwks":
            return httpx.Response(200, json={"keys": [self.signing_key.as_dict(private=False)]})
        if request.url.path == "/token":
            self.token_requests.append(parse_qs(request.content.decode()))
            claims = dict(iss="https://iam.test", sub="operator", aud="fixture-client",
                          exp=int(time.time()) + 300, iat=int(time.time()), nonce=self.nonce)
            claims.update(self.claim_overrides)
            encoded = jwt.encode({"alg": "RS256", "kid": "fixture"}, claims, self.signing_key)
            return httpx.Response(200, json={"access_token": "fixture-access", "token_type": "Bearer", "id_token": encoded})
        raise AssertionError("Unexpected IAM endpoint")

    def login(self, **overrides):
        self.claim_overrides = overrides
        response = self.client.get("/auth/login", follow_redirects=False)
        self.assertEqual(response.status_code, 302, response.text)
        query = parse_qs(urlsplit(response.headers["location"]).query)
        self.nonce = query["nonce"][0]
        self.assertEqual(query["code_challenge_method"], ["S256"])
        self.assertEqual(query["redirect_uri"], ["https://benchmark.test/auth/callback"])
        self.challenge = query["code_challenge"][0]
        return self.client.get("/auth/callback", params={"state": query["state"][0], "code": "fixture-code"}, follow_redirects=False)

    def use_assignment_authorization(self):
        self.settings = replace(self.settings, oidc_authorization_mode="app_assignment", oidc_allowed_subjects=())
        app = FastAPI()
        self.oauth = install_iam_auth(app, self.settings, lambda: self.db)
        self.oauth.oci.client_kwargs["transport"] = httpx.MockTransport(self.iam_server)
        app.get("/api/me")(self.api.me)
        patcher = patch.object(self.api, "settings", self.settings)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.client = TestClient(app, base_url=self.settings.public_url)
        self.addCleanup(self.client.close)

    def test_assignment_mode_admits_verified_new_subjects_without_local_allowlist(self):
        self.use_assignment_authorization()
        for subject in ("newly-assigned-user", "another-assigned-user"):
            self.assertEqual(self.login(sub=subject).status_code, 303)
            self.assertEqual(self.client.get("/api/me").status_code, 200)
        self.assertEqual(len(self.db.all("SELECT * FROM oidc_identities")), 2)
        self.assertTrue(all(r["authorization_mode"] == "app_assignment" for r in self.db.all("SELECT * FROM sessions")))

    def test_assignment_mode_keeps_signature_issuer_audience_nonce_expiry_checks(self):
        self.use_assignment_authorization()
        for claims in ({"iss":"https://evil.test"}, {"aud":"other-app"}, {"nonce":"wrong"},
                       {"exp":int(time.time())-120}, {"sub":""}):
            self.assertEqual(self.login(**claims).status_code, 401)
        self.assertIsNone(self.db.one("SELECT * FROM sessions"))

    def test_assignment_mode_rejects_iam_authorization_denial_without_session(self):
        self.use_assignment_authorization()
        response = self.client.get("/auth/login", follow_redirects=False)
        state = parse_qs(urlsplit(response.headers["location"]).query)["state"][0]
        response = self.client.get("/auth/callback", params={"state":state,"error":"access_denied"})
        self.assertEqual(response.status_code, 401)
        self.assertIsNone(self.db.one("SELECT * FROM sessions"))

    def test_sessions_cannot_cross_authorization_mode_changes(self):
        self.assertEqual(self.login().status_code, 303)
        token = self.client.cookies.get(SESSION_COOKIE)
        self.use_assignment_authorization()
        self.client.cookies.set(SESSION_COOKIE, token, domain="benchmark.test", path="/")
        self.assertEqual(self.client.get("/api/me").status_code, 401)
        self.assertEqual(self.login(sub="new-user").status_code, 303)
        with patch.object(self.api, "settings", replace(self.settings, oidc_authorization_mode="subject_allowlist", oidc_allowed_subjects=("new-user",))):
            self.assertEqual(self.client.get("/api/me").status_code, 401)

    def test_assignment_settings_accept_empty_allowlist_only_with_explicit_mode(self):
        env = dict(APP_SECRET=self.box.app_secret, APP_AUTH_MODE="oci_iam", APP_PUBLIC_URL="https://benchmark.test",
                   APP_OIDC_DOMAIN_URL="https://iam.test", APP_OIDC_ISSUER="https://iam.test", APP_OIDC_CLIENT_ID="client",
                   APP_OIDC_CLIENT_SECRET="secret", APP_DB_PATH=str(self.root/"config.db"), APP_ARTIFACT_DIR=str(self.root/"config-artifacts"))
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaises(RuntimeError):
                get_settings()
            with patch.dict(os.environ, APP_OIDC_AUTHORIZATION_MODE="app_assignment"):
                self.assertEqual(get_settings().oidc_authorization_mode, "app_assignment")
            with patch.dict(os.environ, APP_OIDC_AUTHORIZATION_MODE="unknown"):
                with self.assertRaises(RuntimeError):
                    get_settings()

    def test_login_page_gates_workspace_and_direct_static_access(self):
        response = self.client.get("/", follow_redirects=False)
        self.assertEqual(response.status_code, 303)
        self.assertEqual(response.headers["location"], "/login")
        self.assertIn("no-store", response.headers["cache-control"])
        page = self.client.get("/login")
        self.assertIn('href="/auth/login"', page.text)
        self.assertNotIn('id="workspace-content"', page.text)
        self.assertNotIn("{{LOGIN_", page.text)
        self.assertNotIn('type="password"', page.text)
        self.assertIn("no-store", page.headers["cache-control"])
        self.assertEqual(self.client.get("/static/index.html").status_code, 404)
        self.assertEqual(self.client.get("/static/login.css").status_code, 200)
        self.login()
        self.assertIn('id="workspace-content"', self.client.get("/").text)
        page = self.client.get("/login", follow_redirects=False)
        self.assertEqual(page.status_code, 303)
        self.assertEqual(page.headers["location"], "/")
        logout = self.client.post("/auth/logout", headers={"Origin": self.settings.public_url}, follow_redirects=False)
        self.assertEqual(logout.headers["location"], "/login")
        self.assertEqual(self.client.get("/", follow_redirects=False).headers["location"], "/login")

    def test_expired_revoked_and_forged_sessions_cannot_open_workspace(self):
        self.login()
        self.db.execute("UPDATE sessions SET expires_at=unixepoch()-1")
        self.assertEqual(self.client.get("/", follow_redirects=False).headers["location"], "/login")
        self.assertIn("Your session has ended", self.client.get("/login?expired=1").text)
        self.login()
        with patch.object(self.api, "settings", replace(self.settings, oidc_allowed_subjects=("another-user",))):
            self.assertEqual(self.client.get("/", follow_redirects=False).headers["location"], "/login")
        self.client.cookies.clear()
        self.client.cookies.set(SESSION_COOKIE, "forged-session")
        self.assertEqual(self.client.get("/", follow_redirects=False).headers["location"], "/login")
        self.assertEqual(self.client.get("/api/me").status_code, 401)

    def test_login_page_fails_closed_without_iam_configuration(self):
        with patch.object(self.api, "settings", replace(self.settings, auth_mode="disabled")):
            page = self.client.get("/login")
            self.assertIn("Sign-in is not configured", page.text)
            self.assertNotIn('href="/auth/login"', page.text)
            self.assertEqual(self.client.get("/", follow_redirects=False).headers["location"], "/login")

    def test_workspace_form_logout_policy_and_csrf_rejections(self):
        callback = self.login()
        self.assertEqual(callback.headers["referrer-policy"], "no-referrer")
        workspace = self.client.get("/")
        self.assertEqual(workspace.headers["referrer-policy"], "same-origin")
        for headers in ({}, {"Origin": "null"}, {"Origin": "https://evil.test"}):
            rejected = self.client.post("/auth/logout", headers=headers, follow_redirects=False)
            self.assertEqual(rejected.status_code, 403)
            self.assertEqual(self.client.get("/api/me").status_code, 200)
        logout = self.client.post("/auth/logout", headers={"Origin": self.settings.public_url}, follow_redirects=False)
        self.assertEqual(logout.status_code, 303)
        self.assertEqual(logout.headers["location"], "/login")
        self.assertEqual(self.client.get("/api/me").status_code, 401)
        self.assertEqual(self.client.get("/login").headers["referrer-policy"], "no-referrer")

    def test_oidc_login_pkce_cookie_expiry_csrf_and_logout(self):
        response = self.login()
        self.assertEqual(response.status_code, 303, response.text)
        cookie = response.headers["set-cookie"]
        for attribute in ("Secure", "HttpOnly", "SameSite=lax"):
            self.assertIn(attribute, cookie)
        verifier = self.token_requests[0]["code_verifier"][0]
        self.assertEqual(base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("="), self.challenge)
        raw_session = self.client.cookies.get(SESSION_COOKIE)
        row = self.db.one("SELECT * FROM sessions")
        self.assertEqual(row["token"], session_key(raw_session))
        self.assertNotIn(raw_session, row["token"])
        self.assertLessEqual(row["expires_at"], int(time.time()) + 300)
        self.assertEqual(self.client.get("/api/me").status_code, 200)
        self.assertEqual(self.client.post("/api/protected").status_code, 403)
        self.assertEqual(self.client.post("/api/protected", headers={"Origin": "https://evil.test"}).status_code, 403)
        self.assertEqual(self.client.post("/api/protected", headers={"Origin": self.settings.public_url}).status_code, 200)
        self.assertEqual(self.client.post("/auth/logout", headers={"Origin": self.settings.public_url}, follow_redirects=False).status_code, 303)
        self.assertEqual(self.client.get("/api/me").status_code, 401)
        self.assertIsNone(self.db.one("SELECT * FROM sessions"))

    def test_rejects_wrong_issuer_audience_nonce_expiry_and_unapproved_subject(self):
        cases = [{"iss": "https://evil.test"}, {"aud": "another-client"}, {"nonce": "wrong"},
                 {"exp": int(time.time()) - 120}, {"sub": "unapproved"}]
        for overrides in cases:
            with self.subTest(overrides=overrides):
                response = self.login(**overrides)
                self.assertIn(response.status_code, (401, 403), response.text)
                self.assertIsNone(self.db.one("SELECT * FROM sessions"))

    def test_rejects_bad_signature_and_missing_state(self):
        self.signing_key = RSAKey.generate_key(2048, parameters={"kid": "different"})
        self.oauth.oci.server_metadata["jwks"] = {"keys": [self.__class__.signing_key.as_dict(private=False)]}
        # Return a different public key than the signing key at the JWKS endpoint.
        with patch.object(self.signing_key, "as_dict", return_value=self.__class__.signing_key.as_dict(private=False)):
            self.assertEqual(self.login().status_code, 401)
        self.assertEqual(self.client.get("/auth/callback?code=fixture-code").status_code, 401)

    def test_does_not_link_by_email_and_rejects_revoked_or_expired_session(self):
        self.db.execute("INSERT INTO users(email,password_hash) VALUES('operator@example.test','old')")
        self.assertEqual(self.login(email="operator@example.test").status_code, 303)
        identity = self.db.one("SELECT * FROM oidc_identities")
        self.assertNotEqual(identity["user_id"], 1)
        with patch.object(self.api, "settings", replace(self.settings, oidc_allowed_subjects=("someone-else",))):
            self.assertEqual(self.client.get("/api/me").status_code, 403)
        self.db.execute("UPDATE sessions SET expires_at=0")
        self.assertEqual(self.client.get("/api/me").status_code, 401)

    def test_removed_login_bypasses_and_url_tokens(self):
        client = TestClient(self.api.app, base_url="https://benchmark.test")
        self.addCleanup(client.close)
        for route in ("/api/local-session", "/api/register", "/api/login"):
            self.assertEqual(client.post(route, json={"email": "attacker", "password": "password"}).status_code, 404)
        self.assertEqual(self.login().status_code, 303)
        token = self.client.cookies.get(SESSION_COOKIE)
        self.assertEqual(client.get("/api/me", params={"token": token}).status_code, 401)

    def test_legacy_session_revocation_is_once_only(self):
        self.db.execute("INSERT INTO users(id,email,password_hash) VALUES(1,'legacy','old')")
        self.db.execute("INSERT INTO sessions(token,user_id) VALUES('legacy',1)")
        self.db.revoke_legacy_sessions()
        self.assertIsNone(self.db.one("SELECT * FROM sessions"))
        self.db.execute("INSERT INTO sessions(token,user_id) VALUES('new',1)")
        self.db.revoke_legacy_sessions()
        self.assertIsNotNone(self.db.one("SELECT * FROM sessions"))

    def test_private_key_queue_encryption_migration_and_ownership(self):
        self.db.execute("INSERT INTO users(id,email,password_hash) VALUES(1,'operator','old')")
        self.db.execute("INSERT INTO users(id,email,password_hash) VALUES(2,'other','old')")
        payload = {"display_name": "fixture", "ssh_private_key": "fixture-private-key"}
        job_id = self.db.create_provision_job(1, payload, self.box.encrypt)
        self.assertNotIn("ssh_private_key", self.db.one("SELECT payload FROM jobs WHERE id=?", (job_id,))["payload"])
        self.assertNotIn("fixture-private-key", self.db.one("SELECT * FROM job_credentials")["encrypted_private_key"])
        self.assertEqual(self.db.provision_private_key(job_id, 1, self.box.decrypt), "fixture-private-key")
        self.assertEqual(self.db.provision_private_key(job_id, 2, self.box.decrypt), "")
        with self.assertRaises(ValueError):
            self.db.create_job(1, "provision_vm", payload)
        for status in ("queued", "succeeded", "failed"):
            self.db.execute("INSERT INTO jobs(owner_user_id,job_type,status,payload) VALUES(1,'provision_vm',?,?)", (status, json.dumps(payload)))
        self.db.migrate_provision_credentials(self.box.encrypt)
        self.db.migrate_provision_credentials(self.box.encrypt)
        self.assertTrue(all("ssh_private_key" not in row["payload"] for row in self.db.all("SELECT payload FROM jobs")))
        self.assertEqual(len(self.db.all("SELECT * FROM job_credentials")), 2)
        self.db.execute("DELETE FROM jobs WHERE id=?", (job_id,))
        self.assertEqual(self.db.provision_private_key(job_id, 1, self.box.decrypt), "")

    def test_failed_worker_removes_queued_credential(self):
        self.db.execute("INSERT INTO users(id,email,password_hash) VALUES(1,'operator','old')")
        self.db.create_provision_job(1, {"ssh_private_key": "fixture-key"}, self.box.encrypt)
        worker = Worker(self.db, self.box)
        with patch.object(worker._stop, "is_set", side_effect=[False, True]), patch.object(worker, "_run_job", side_effect=RuntimeError("fixture failure")):
            worker._loop()
        self.assertIsNone(self.db.one("SELECT * FROM job_credentials"))
        self.assertEqual(self.db.one("SELECT status FROM jobs")["status"], "failed")

    def test_offline_identity_mapping_preserves_account_and_revokes_sessions(self):
        self.db.execute("INSERT INTO users(id,email,password_hash) VALUES(1,'existing@example.test','old')")
        self.db.execute("INSERT INTO sessions(token,user_id) VALUES('old',1)")
        link_user(self.db, 1, "https://iam.test", "operator")
        self.assertIsNone(self.db.one("SELECT * FROM sessions"))
        with self.assertRaises(ValueError):
            link_user(self.db, 1, "https://iam.test", "someone-else")
        self.assertEqual(self.login().status_code, 303)
        self.assertEqual(self.client.get("/api/me").json()["id"], 1)

    def test_provision_api_never_persists_plaintext_key(self):
        self.app.post("/api/oci/instances")(self.api.create_oci_instance)
        self.assertEqual(self.login().status_code, 303)
        response = self.client.post("/api/oci/instances", headers={"Origin": self.settings.public_url}, json={
            "display_name": "fixture", "compartment_id": "fixture", "availability_domain": "fixture",
            "shape": "VM.Standard.E6.Ax.Flex", "image_id": "fixture", "subnet_id": "fixture",
            "ssh_public_key": "ssh-ed25519 fixture", "ssh_private_key": "fixture-private-key",
        })
        self.assertEqual(response.status_code, 200, response.text)
        job = self.db.one("SELECT * FROM jobs WHERE id=?", (response.json()["job_id"],))
        self.assertNotIn("ssh_private_key", job["payload"])
        self.assertEqual(self.db.provision_private_key(job["id"], job["owner_user_id"], self.box.decrypt), "fixture-private-key")

    def test_iam_settings_fail_closed_without_full_configuration(self):
        with patch.dict(os.environ, {"APP_SECRET": self.box.app_secret, "APP_AUTH_MODE": "oci_iam"}, clear=True):
            with self.assertRaises(RuntimeError):
                get_settings()

    def test_disabled_authentication_rejects_existing_sessions(self):
        self.assertEqual(self.login().status_code, 303)
        with patch.object(self.api, "settings", replace(self.settings, auth_mode="disabled")):
            self.assertEqual(self.client.get("/api/me").status_code, 401)


if __name__ == "__main__":
    unittest.main()
