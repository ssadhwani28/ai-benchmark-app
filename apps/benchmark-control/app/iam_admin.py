"""Offline administrator mapping of existing local data to an approved IAM identity."""
import argparse
from pathlib import Path

from .db import Database


def link_user(db, user_id, issuer, subject):
    with db._lock, db.connect() as con:
        if not con.execute("SELECT id FROM users WHERE id=?", (user_id,)).fetchone():
            raise ValueError("Existing user ID was not found")
        if con.execute("SELECT 1 FROM oidc_identities WHERE user_id=? OR (issuer=? AND subject=?)",
                       (user_id, issuer, subject)).fetchone():
            raise ValueError("User or IAM identity is already mapped; review the existing mapping first")
        con.execute("INSERT INTO oidc_identities(issuer,subject,user_id) VALUES(?,?,?)", (issuer, subject, user_id))
        con.execute("DELETE FROM sessions WHERE user_id=?", (user_id,))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=Path("/data/app.db"))
    parser.add_argument("--user-id", type=int, required=True)
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--subject", required=True)
    args = parser.parse_args()
    if not args.db.is_file():
        parser.error("Database does not exist; refusing to create an empty database")
    db = Database(args.db)
    try:
        db.init()
        link_user(db, args.user_id, args.issuer, args.subject)
    finally:
        db.connect().close()
    print("IAM identity linked; existing sessions for this user were revoked.")


if __name__ == "__main__":
    main()
