from __future__ import annotations

import json
import sqlite3
import threading
from pathlib import Path
from typing import Any


SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'user',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS sessions (
  token TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS vm_profiles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_user_id INTEGER NOT NULL REFERENCES users(id),
  name TEXT NOT NULL,
  host TEXT NOT NULL,
  port INTEGER NOT NULL,
  username TEXT NOT NULL,
  encrypted_private_key TEXT NOT NULL,
  encrypted_passphrase TEXT,
  last_status TEXT NOT NULL DEFAULT 'unknown',
  last_checked_at TEXT,
  UNIQUE(owner_user_id, name)
);
CREATE TABLE IF NOT EXISTS vm_setup_status (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  vm_profile_id INTEGER NOT NULL REFERENCES vm_profiles(id),
  owner_user_id INTEGER NOT NULL REFERENCES users(id),
  root_expand_status TEXT NOT NULL DEFAULT 'unknown',
  root_device TEXT,
  root_usage_before TEXT,
  root_usage_after TEXT,
  vllm_status TEXT NOT NULL DEFAULT 'unknown',
  vllm_version TEXT,
  benchmark_status TEXT NOT NULL DEFAULT 'unknown',
  benchmark_version TEXT,
  python_path TEXT,
  pip_path TEXT,
  curl_path TEXT,
  runtime_evidence TEXT NOT NULL DEFAULT '{}',
  log TEXT NOT NULL DEFAULT '',
  last_setup_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(vm_profile_id)
);
CREATE TABLE IF NOT EXISTS oci_auth_profiles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_user_id INTEGER NOT NULL REFERENCES users(id),
  mode TEXT NOT NULL,
  profile_name TEXT NOT NULL DEFAULT 'DEFAULT',
  encrypted_profile_text TEXT,
  encrypted_private_key TEXT,
  region TEXT,
  tenancy_id TEXT,
  last_status TEXT NOT NULL DEFAULT 'unknown',
  last_validated_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(owner_user_id, mode, profile_name)
);
CREATE TABLE IF NOT EXISTS oci_compute_instances (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_user_id INTEGER NOT NULL REFERENCES users(id),
  vm_profile_id INTEGER REFERENCES vm_profiles(id),
  oci_auth_profile_id INTEGER REFERENCES oci_auth_profiles(id),
  display_name TEXT NOT NULL,
  compartment_id TEXT NOT NULL,
  availability_domain TEXT NOT NULL,
  subnet_id TEXT NOT NULL,
  instance_id TEXT,
  boot_volume_id TEXT,
  shape TEXT NOT NULL,
  ocpus REAL NOT NULL,
  memory_gb REAL NOT NULL,
  boot_volume_gb INTEGER NOT NULL,
  image_id TEXT NOT NULL,
  assign_public_ip INTEGER NOT NULL,
  smt_requested INTEGER,
  smt_enabled INTEGER,
  public_ip TEXT,
  private_ip TEXT,
  lifecycle_state TEXT NOT NULL DEFAULT 'queued',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  destroyed_at TEXT
);
CREATE TABLE IF NOT EXISTS vllm_profiles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_user_id INTEGER NOT NULL REFERENCES users(id),
  name TEXT NOT NULL,
  model_ref TEXT NOT NULL,
  dtype TEXT NOT NULL,
  max_model_len INTEGER NOT NULL,
  max_num_batched_tokens INTEGER,
  max_num_seqs INTEGER NOT NULL,
  cpu_kvcache_space_gib INTEGER NOT NULL,
  reserved_cpu INTEGER NOT NULL,
  prefix_cache_enabled INTEGER NOT NULL,
  chunked_prefill_enabled INTEGER NOT NULL,
  request_timeout_seconds INTEGER NOT NULL,
  port INTEGER NOT NULL,
  kernel_tracing_enabled INTEGER NOT NULL DEFAULT 0,
  cpu_memory_utilization REAL,
  quantization TEXT NOT NULL DEFAULT 'none',
  model_revision TEXT,
  encrypted_hf_token TEXT,
  cpu_kvcache_auto INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(owner_user_id, name)
);
CREATE TABLE IF NOT EXISTS jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_user_id INTEGER NOT NULL REFERENCES users(id),
  job_type TEXT NOT NULL,
  status TEXT NOT NULL,
  payload TEXT NOT NULL,
  result TEXT,
  error_message TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  started_at TEXT,
  finished_at TEXT
);
CREATE TABLE IF NOT EXISTS audit_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  actor_user_id INTEGER NOT NULL REFERENCES users(id),
  event_type TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id INTEGER,
  metadata TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS job_credentials (
  job_id INTEGER PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE,
  owner_user_id INTEGER NOT NULL REFERENCES users(id),
  encrypted_private_key TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS oidc_identities (
  issuer TEXT NOT NULL,
  subject TEXT NOT NULL,
  user_id INTEGER NOT NULL REFERENCES users(id),
  PRIMARY KEY(issuer, subject)
);
CREATE TABLE IF NOT EXISTS security_migrations (
  name TEXT PRIMARY KEY
);
"""


class Database:
    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.RLock()
        self._local = threading.local()

    def connect(self) -> sqlite3.Connection:
        con = getattr(self._local, "con", None)
        if con is None:
            con = sqlite3.connect(self.path, check_same_thread=False, timeout=30)
            con.row_factory = sqlite3.Row
            con.execute("PRAGMA foreign_keys=ON")
            con.execute("PRAGMA busy_timeout=30000")
            self._local.con = con
        return con

    def init(self) -> None:
        with self._lock:
            self.connect().executescript(SCHEMA)
            from .reporting import REPORT_SCHEMA
            self.connect().executescript(REPORT_SCHEMA)
            for column, definition in {
                "archive_status": "TEXT NOT NULL DEFAULT 'pending'",
                "archive_attempts": "INTEGER NOT NULL DEFAULT 0",
                "archive_token": "TEXT", "archive_lease_until": "REAL",
                "archive_metadata": "TEXT", "archive_error": "TEXT",
            }.items():
                self._ensure_column("report_jobs", column, definition)
            self._ensure_column("vm_setup_status", "benchmark_version", "TEXT")
            self._ensure_column("oci_compute_instances", "smt_requested", "INTEGER")
            self._ensure_column("oci_compute_instances", "smt_enabled", "INTEGER")
            self._ensure_column("vm_setup_status", "runtime_evidence", "TEXT NOT NULL DEFAULT '{}'")
            self._ensure_column("vllm_profiles", "kernel_tracing_enabled", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column("vllm_profiles", "cpu_memory_utilization", "REAL")
            self._ensure_column("vllm_profiles", "quantization", "TEXT NOT NULL DEFAULT 'none'")
            self._ensure_column("vllm_profiles", "model_revision", "TEXT")
            self._ensure_column("vllm_profiles", "encrypted_hf_token", "TEXT")
            self._ensure_column("sessions", "expires_at", "INTEGER")
            # Sessions cannot cross an authorization-policy mode change.
            self._ensure_column("sessions", "authorization_mode", "TEXT NOT NULL DEFAULT 'subject_allowlist'")
            self._ensure_column("vllm_profiles", "cpu_kvcache_auto", "INTEGER NOT NULL DEFAULT 0")

    def _ensure_column(self, table: str, column: str, definition: str) -> None:
        con = self.connect()
        columns = {row["name"] for row in con.execute(f"PRAGMA table_info({table})").fetchall()}
        if column not in columns:
            con.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")
            con.commit()

    def execute(self, sql: str, params: tuple[Any, ...] = ()) -> sqlite3.Cursor:
        with self._lock:
            con = self.connect()
            cur = con.execute(sql, params)
            con.commit()
            return cur

    def one(self, sql: str, params: tuple[Any, ...] = ()) -> dict[str, Any] | None:
        with self._lock:
            row = self.connect().execute(sql, params).fetchone()
            return dict(row) if row else None

    def all(self, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
        with self._lock:
            return [dict(row) for row in self.connect().execute(sql, params).fetchall()]

    def create_job(self, user_id: int, job_type: str, payload: dict[str, Any]) -> int:
        if payload.get("ssh_private_key"):
            raise ValueError("Private keys must be stored through create_provision_job")
        cur = self.execute(
            "INSERT INTO jobs(owner_user_id, job_type, status, payload) VALUES (?, ?, 'queued', ?)",
            (user_id, job_type, json.dumps(payload, separators=(",", ":"))),
        )
        return int(cur.lastrowid)

    def create_provision_job(self, user_id: int, payload: dict[str, Any], encrypt) -> int:
        safe_payload = dict(payload)
        private_key = safe_payload.pop("ssh_private_key", None)
        encrypted = encrypt(private_key)
        with self._lock, self.connect() as con:
            cur = con.execute(
                "INSERT INTO jobs(owner_user_id, job_type, status, payload) VALUES (?, 'provision_vm', 'queued', ?)",
                (user_id, json.dumps(safe_payload, separators=(",", ":"))),
            )
            job_id = int(cur.lastrowid)
            if encrypted:
                con.execute("INSERT INTO job_credentials(job_id,owner_user_id,encrypted_private_key) VALUES(?,?,?)",
                            (job_id, user_id, encrypted))
        return job_id

    def migrate_provision_credentials(self, encrypt) -> None:
        """Protect legacy queue entries before the worker can consume them.

        This is logical cleanup; old backups and SQLite free pages may still
        contain historical plaintext and require separate operator cleanup.
        """
        with self._lock, self.connect() as con:
            for row in con.execute("SELECT id,owner_user_id,status,payload FROM jobs WHERE job_type='provision_vm'").fetchall():
                payload = json.loads(row["payload"])
                if "ssh_private_key" not in payload:
                    continue
                private_key = payload.pop("ssh_private_key")
                if private_key and row["status"] == "queued":
                    con.execute("INSERT OR REPLACE INTO job_credentials(job_id,owner_user_id,encrypted_private_key) VALUES(?,?,?)",
                                (row["id"], row["owner_user_id"], encrypt(private_key)))
                con.execute("UPDATE jobs SET payload=? WHERE id=?",
                            (json.dumps(payload, separators=(",", ":")), row["id"]))
            con.execute("DELETE FROM job_credentials WHERE job_id IN (SELECT id FROM jobs WHERE status NOT IN ('queued','running'))")

    def provision_private_key(self, job_id: int, user_id: int, decrypt) -> str:
        row = self.one("SELECT encrypted_private_key FROM job_credentials WHERE job_id=? AND owner_user_id=?",
                       (job_id, user_id))
        return (decrypt(row["encrypted_private_key"]) or "") if row else ""

    def revoke_legacy_sessions(self) -> None:
        with self._lock, self.connect() as con:
            if not con.execute("SELECT 1 FROM security_migrations WHERE name='iam-only-auth'").fetchone():
                con.execute("DELETE FROM sessions")
                con.execute("INSERT INTO security_migrations(name) VALUES('iam-only-auth')")

    def audit(self, user_id: int, event_type: str, entity_type: str, entity_id: int | None, metadata: dict[str, Any] | None = None) -> None:
        self.execute(
            "INSERT INTO audit_events(actor_user_id, event_type, entity_type, entity_id, metadata) VALUES (?, ?, ?, ?, ?)",
            (user_id, event_type, entity_type, entity_id, json.dumps(metadata or {}, separators=(",", ":"))),
        )
