"""OCI IAM Identity Domain OIDC login; cloud API credentials are independent."""
from __future__ import annotations

import hashlib
import hmac
import secrets
import time
from urllib.parse import urlsplit

from authlib.integrations.starlette_client import OAuth
from fastapi import HTTPException, Request
from fastapi.responses import RedirectResponse
from starlette.middleware.sessions import SessionMiddleware

from .security import create_token

SESSION_COOKIE = "__Host-benchmark_session"


def session_key(token: str) -> str:
    return "sha256:" + hashlib.sha256(token.encode()).hexdigest()


def install_iam_auth(app, settings, database):
    # This signed cookie holds only the short-lived OIDC transaction, never tokens.
    app.add_middleware(SessionMiddleware, secret_key=settings.app_secret,
                       session_cookie="__Host-benchmark_oidc", https_only=True,
                       same_site="lax", max_age=600)
    oauth = OAuth()
    if settings.auth_mode == "oci_iam":
        oauth.register("oci", client_id=settings.oidc_client_id,
                       client_secret=settings.oidc_client_secret,
                       server_metadata_url=settings.oidc_domain_url + "/.well-known/openid-configuration",
                       client_kwargs={"scope": "openid profile email", "code_challenge_method": "S256",
                                      "token_endpoint_auth_method": "client_secret_basic", "timeout": 15})

    @app.get("/auth/login")
    async def iam_login(request: Request):
        if settings.auth_mode != "oci_iam":
            raise HTTPException(503, "OCI IAM sign-in is not configured")
        request.session.clear()
        nonce = secrets.token_urlsafe(32)
        request.session["login_nonce"] = nonce
        try:
            metadata = await oauth.oci.load_server_metadata()
            if metadata.get("issuer") != settings.oidc_issuer or any(
                urlsplit(metadata.get(key, "")).scheme != "https"
                for key in ("authorization_endpoint", "token_endpoint", "jwks_uri")
            ):
                raise ValueError("Untrusted IAM discovery configuration")
            return await oauth.oci.authorize_redirect(request, settings.public_url + "/auth/callback", nonce=nonce)
        except Exception:
            request.session.clear()
            raise HTTPException(502, "Could not start OCI IAM sign-in") from None

    @app.get("/auth/callback")
    async def iam_callback(request: Request):
        if settings.auth_mode != "oci_iam":
            raise HTTPException(503, "OCI IAM sign-in is not configured")
        nonce = request.session.pop("login_nonce", "")
        try:
            token = await oauth.oci.authorize_access_token(
                request, claims_options={"iss": {"essential": True, "value": settings.oidc_issuer}}, leeway=30)
            claims = token["userinfo"]  # Authlib verifies signature, audience, expiry and state.
            if not nonce or not hmac.compare_digest(nonce, str(claims.get("nonce", ""))):
                raise ValueError("Invalid nonce")
            if claims["exp"] <= time.time():
                raise ValueError("Expired ID token")
            subject = claims["sub"]
            if not isinstance(subject, str) or not subject.strip():
                raise ValueError("Invalid subject")
            # app_assignment relies on this client enforcing IAM app grants.
            # Issuer/audience/signature/state/nonce validation above still applies.
            if settings.oidc_authorization_mode == "subject_allowlist" and subject not in settings.oidc_allowed_subjects:
                raise HTTPException(403, "This IAM user is not approved for the benchmark application")
        except HTTPException:
            raise
        except Exception:
            raise HTTPException(401, "OCI IAM sign-in failed") from None
        finally:
            request.session.clear()

        db = database()
        # Never attach an IAM login to an existing account by matching email.
        with db._lock, db.connect() as con:
            identity = con.execute("SELECT user_id FROM oidc_identities WHERE issuer=? AND subject=?",
                                   (settings.oidc_issuer, subject)).fetchone()
            if identity:
                user_id = identity["user_id"]
            else:
                internal_name = "iam:" + hashlib.sha256((settings.oidc_issuer + "\0" + subject).encode()).hexdigest()
                cur = con.execute("INSERT INTO users(email,password_hash) VALUES(?, 'sso-only')", (internal_name,))
                user_id = int(cur.lastrowid)
                con.execute("INSERT INTO oidc_identities(issuer,subject,user_id) VALUES(?,?,?)",
                            (settings.oidc_issuer, subject, user_id))
        existing = request.cookies.get(SESSION_COOKIE)
        if existing:
            db.execute("DELETE FROM sessions WHERE token=?", (session_key(existing),))
        session = create_token()
        # Limit application sessions to both one hour and the IAM token lifetime.
        lifetime = max(1, min(3600, int(claims["exp"] - time.time())))
        db.execute("INSERT INTO sessions(token,user_id,expires_at,authorization_mode) VALUES(?,?,?,?)",
                   (session_key(session), user_id, int(time.time()) + lifetime, settings.oidc_authorization_mode))
        db.audit(user_id, "login", "session", None, {})
        response = RedirectResponse("/", status_code=303)
        response.set_cookie(SESSION_COOKIE, session, secure=True, httponly=True, samesite="lax", max_age=lifetime, path="/")
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.post("/auth/logout")
    async def iam_logout(request: Request):
        # Explicit origin check also protects logout when the session has expired.
        if request.headers.get("origin") != settings.public_url:
            raise HTTPException(403, "Invalid request origin")
        session = request.cookies.get(SESSION_COOKIE)
        if session:
            database().execute("DELETE FROM sessions WHERE token=?", (session_key(session),))
        response = RedirectResponse("/login", status_code=303)
        response.delete_cookie(SESSION_COOKIE, path="/", secure=True, httponly=True, samesite="lax")
        return response

    return oauth
