"""Explicit IAM identities and expiring hashed sessions for existing API tests."""
from app.config import Settings
from app.iam_auth import session_key


def iam_settings(root):
    return Settings("test-only-encryption-secret-long-enough", root / "app.db", root / "artifacts",
                    "oci_iam", "https://testserver", "https://iam.test", "https://iam.test",
                    "fixture-client", "fixture-secret", ("fixture-1", "fixture-2"))


def add_session(db, uid, token):
    db.execute("INSERT INTO oidc_identities(issuer,subject,user_id) VALUES('https://iam.test',?,?)", (f"fixture-{uid}", uid))
    db.execute("INSERT INTO sessions(token,user_id,expires_at) VALUES(?,?,unixepoch()+3600)", (session_key(token), uid))
