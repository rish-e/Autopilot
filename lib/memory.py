#!/usr/bin/env python3
"""
memory.py — Unified SQLite memory store for Autopilot

The central intelligence layer. Every subsystem reads/writes here:
  - Traces:     step-by-step execution records for every task
  - Procedures:  abstracted reusable task patterns (learned from success)
  - Errors:      deduplicated error patterns with resolutions (learned from failure)
  - Services:    discovered service metadata cache
  - Playbooks:   browser automation playbook metadata
  - Costs:       per-task token and dollar cost tracking
  - Health:      service health check results over time
  - KV:          general key-value store for misc state

Designed to work in BOTH modes:
  - Agent mode:  called via `python3 lib/memory.py <command>` from Claude Code
  - Daemon mode: imported as `from lib.memory import AutopilotMemory`

Storage: ~/.autopilot/memory.db (user-level, cross-project)
"""

import hashlib
import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# ─── Configuration ───────────────────────────────────────────────────────────

DB_PATH = Path(os.environ.get(
    "AUTOPILOT_MEMORY_DB",
    Path.home() / ".autopilot" / "memory.db"
))
DB_PATH.parent.mkdir(parents=True, exist_ok=True)

# ─── Schema ──────────────────────────────────────────────────────────────────

SCHEMA = """
-- ════════════════════════════════════════════════════════════════════════════
-- Execution traces: every step of every agent run
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS traces (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      TEXT NOT NULL,
    task_desc   TEXT,
    step_num    INTEGER NOT NULL,
    action      TEXT NOT NULL,
    tool        TEXT,
    service     TEXT,
    input_summary TEXT,
    output_summary TEXT,
    status      TEXT NOT NULL DEFAULT 'ok',
    error_msg   TEXT,
    duration_ms INTEGER,
    tokens_in   INTEGER DEFAULT 0,
    tokens_out  INTEGER DEFAULT 0,
    model       TEXT,
    cost_usd    REAL DEFAULT 0,
    created_at  REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
CREATE INDEX IF NOT EXISTS idx_traces_run ON traces(run_id);
CREATE INDEX IF NOT EXISTS idx_traces_service ON traces(service);
CREATE INDEX IF NOT EXISTS idx_traces_status ON traces(status);
CREATE INDEX IF NOT EXISTS idx_traces_created ON traces(created_at);

-- ════════════════════════════════════════════════════════════════════════════
-- Learned procedures: successful patterns abstracted for reuse
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS procedures (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL UNIQUE,
    summary         TEXT,
    task_pattern    TEXT NOT NULL,
    services        TEXT,
    domains         TEXT,
    steps_json      TEXT NOT NULL,
    parent_id       INTEGER REFERENCES procedures(id),
    success_count   INTEGER DEFAULT 0,
    fail_count      INTEGER DEFAULT 0,
    consec_fails    INTEGER DEFAULT 0,
    last_run_at     REAL,
    last_status     TEXT,
    avg_duration_ms INTEGER,
    avg_cost_usd    REAL,
    deprecated      INTEGER DEFAULT 0,
    deprecated_reason TEXT,
    version         INTEGER DEFAULT 1,
    content_hash    TEXT,
    integrity_status TEXT DEFAULT 'unverified',
    created_at      REAL NOT NULL DEFAULT (unixepoch('subsec')),
    updated_at      REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
CREATE INDEX IF NOT EXISTS idx_procedures_services ON procedures(services);
CREATE INDEX IF NOT EXISTS idx_procedures_name ON procedures(name);
CREATE INDEX IF NOT EXISTS idx_procedures_parent ON procedures(parent_id);

-- ════════════════════════════════════════════════════════════════════════════
-- Deduplicated error patterns with learned resolutions
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS errors (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    error_hash      TEXT NOT NULL UNIQUE,
    error_type      TEXT NOT NULL,
    pattern         TEXT NOT NULL,
    service         TEXT,
    action          TEXT,
    resolution      TEXT,
    resolution_type TEXT,
    count           INTEGER DEFAULT 1,
    first_seen      REAL NOT NULL DEFAULT (unixepoch('subsec')),
    last_seen       REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
CREATE INDEX IF NOT EXISTS idx_errors_service ON errors(service);
CREATE INDEX IF NOT EXISTS idx_errors_type ON errors(error_type);

-- ════════════════════════════════════════════════════════════════════════════
-- Service metadata cache (auto-populated by service resolver)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS services (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL UNIQUE,
    display_name    TEXT,
    category        TEXT,
    website         TEXT,
    docs_url        TEXT,
    cli_tool        TEXT,
    cli_install     TEXT,
    auth_method     TEXT,
    has_mcp         INTEGER DEFAULT 0,
    mcp_package     TEXT,
    mcp_trust_score INTEGER,
    has_playbook    INTEGER DEFAULT 0,
    has_registry    INTEGER DEFAULT 0,
    dangerous_ops   TEXT,
    last_researched REAL,
    created_at      REAL NOT NULL DEFAULT (unixepoch('subsec')),
    updated_at      REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
CREATE INDEX IF NOT EXISTS idx_services_name ON services(name);
CREATE INDEX IF NOT EXISTS idx_services_category ON services(category);

-- ════════════════════════════════════════════════════════════════════════════
-- Playbook metadata (YAML stored on disk, metadata here)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS playbooks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    service         TEXT NOT NULL,
    flow            TEXT NOT NULL,
    file_path       TEXT,
    version         INTEGER DEFAULT 1,
    success_count   INTEGER DEFAULT 0,
    fail_count      INTEGER DEFAULT 0,
    last_run_at     REAL,
    last_status     TEXT,
    avg_duration_ms INTEGER,
    generated_by    TEXT DEFAULT 'auto',
    created_at      REAL NOT NULL DEFAULT (unixepoch('subsec')),
    updated_at      REAL NOT NULL DEFAULT (unixepoch('subsec')),
    UNIQUE(service, flow)
);
CREATE INDEX IF NOT EXISTS idx_playbooks_service ON playbooks(service);

-- ════════════════════════════════════════════════════════════════════════════
-- Token cost tracking (per-run aggregation)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS costs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      TEXT NOT NULL,
    task_desc   TEXT,
    model       TEXT NOT NULL,
    tokens_in   INTEGER DEFAULT 0,
    tokens_out  INTEGER DEFAULT 0,
    tokens_cache INTEGER DEFAULT 0,
    cost_usd    REAL DEFAULT 0,
    duration_ms INTEGER DEFAULT 0,
    created_at  REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
CREATE INDEX IF NOT EXISTS idx_costs_run ON costs(run_id);
CREATE INDEX IF NOT EXISTS idx_costs_created ON costs(created_at);

-- ════════════════════════════════════════════════════════════════════════════
-- Service health check results
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS health (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    service     TEXT NOT NULL,
    check_type  TEXT NOT NULL,
    status      TEXT NOT NULL,
    message     TEXT,
    response_ms INTEGER,
    created_at  REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
CREATE INDEX IF NOT EXISTS idx_health_service ON health(service);
CREATE INDEX IF NOT EXISTS idx_health_created ON health(created_at);

-- ════════════════════════════════════════════════════════════════════════════
-- General key-value store
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS kv (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
"""

# ─── Colors for CLI output ───────────────────────────────────────────────────

GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[1;33m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
BOLD = "\033[1m"
DIM = "\033[2m"
NC = "\033[0m"


# ═════════════════════════════════════════════════════════════════════════════
# AutopilotMemory — the unified memory interface
# ═════════════════════════════════════════════════════════════════════════════

class AutopilotMemory:
    """Unified memory interface for all Autopilot subsystems.

    Usage:
        mem = AutopilotMemory()
        mem.log_trace(run_id="run1", step_num=1, action="deploy", ...)
        mem.save_procedure("deploy_vercel", "deploy to vercel", [...])
        mem.log_error("timeout", "connection timed out", service="supabase")
        mem.close()
    """

    def __init__(self, db_path: Path = DB_PATH):
        self.db_path = db_path
        self.db = sqlite3.connect(str(db_path))
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript(SCHEMA)
        self._migrate()

    def _migrate(self):
        """Apply incremental schema migrations (idempotent). Safe to run on every init."""
        cols = {r[1] for r in self.db.execute("PRAGMA table_info(procedures)").fetchall()}
        if "content_hash" not in cols:
            self.db.execute("ALTER TABLE procedures ADD COLUMN content_hash TEXT")
            self.db.execute("ALTER TABLE procedures ADD COLUMN integrity_status TEXT DEFAULT 'unverified'")
            self.db.commit()

    @staticmethod
    def _compute_procedure_hash(name: str, task_pattern: str, steps_json: str) -> str:
        """SHA256 over canonical procedure content. Detects memory poisoning across sessions."""
        return hashlib.sha256(
            f"{name}\x00{task_pattern}\x00{steps_json}".encode()
        ).hexdigest()

    def _verify_procedure_integrity(self, row: dict) -> bool:
        """Verify content_hash matches stored procedure data.

        If the hash mismatches (memory poisoning), marks the procedure quarantined
        and returns False so callers exclude it from results.
        """
        stored_hash = row.get("content_hash")
        if not stored_hash:
            return True  # Pre-migration data — no hash yet, allow through
        expected = self._compute_procedure_hash(
            row["name"], row["task_pattern"], row["steps_json"]
        )
        if stored_hash != expected:
            self.db.execute("""
                UPDATE procedures SET
                    integrity_status = 'quarantined',
                    deprecated = 1,
                    deprecated_reason = 'integrity check failed — possible memory poisoning',
                    updated_at = unixepoch('subsec')
                WHERE name = ?
            """, (row["name"],))
            self.db.commit()
            return False
        return True

    # ════════════════════════════════════════════════════════════════════════
    # TRACES
    # ════════════════════════════════════════════════════════════════════════

    def log_trace(self, run_id: str, step_num: int, action: str, **kwargs):
        """Log a single execution step."""
        cols = ["run_id", "step_num", "action"]
        vals = [run_id, step_num, action]
        allowed = {
            "task_desc", "tool", "service", "input_summary", "output_summary",
            "status", "error_msg", "duration_ms", "tokens_in", "tokens_out",
            "model", "cost_usd"
        }
        for k, v in kwargs.items():
            if k in allowed and v is not None:
                cols.append(k)
                vals.append(v)
        placeholders = ", ".join(["?"] * len(vals))
        col_str = ", ".join(cols)
        self.db.execute(f"INSERT INTO traces ({col_str}) VALUES ({placeholders})", vals)
        self.db.commit()

    def get_run(self, run_id: str) -> list[dict]:
        """Get all trace steps for a run."""
        rows = self.db.execute(
            "SELECT * FROM traces WHERE run_id = ? ORDER BY step_num", (run_id,)
        ).fetchall()
        return [dict(r) for r in rows]

    def get_recent_runs(self, limit: int = 20) -> list[dict]:
        """Get summary of recent runs."""
        rows = self.db.execute("""
            SELECT run_id, task_desc,
                   COUNT(*) as steps,
                   SUM(CASE WHEN status = 'ok' THEN 1 ELSE 0 END) as ok_steps,
                   SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as err_steps,
                   SUM(COALESCE(tokens_in, 0) + COALESCE(tokens_out, 0)) as total_tokens,
                   SUM(COALESCE(cost_usd, 0)) as total_cost,
                   MIN(created_at) as started_at,
                   MAX(created_at) as ended_at
            FROM traces
            GROUP BY run_id
            ORDER BY MAX(created_at) DESC
            LIMIT ?
        """, (limit,)).fetchall()
        return [dict(r) for r in rows]

    # ════════════════════════════════════════════════════════════════════════
    # PROCEDURES
    # ════════════════════════════════════════════════════════════════════════

    def save_procedure(self, name: str, task_pattern: str, steps: list,
                       services: list = None, domains: list = None,
                       summary: str = None, parent_id: int = None):
        """Save or update a learned procedure.

        Supports skill composition (Voyager-style): procedures can reference
        sub-procedures via parent_id for hierarchical composition. When a
        procedure succeeds 3+ times, it becomes a reusable "skill" that
        other procedures can invoke.

        Two-tier discovery: summary (short) is used for quick listing,
        task_pattern (full) for detailed matching.
        """
        steps_json = json.dumps(steps)
        content_hash = self._compute_procedure_hash(name, task_pattern, steps_json)
        self.db.execute("""
            INSERT INTO procedures (name, summary, task_pattern, services, domains,
                                    steps_json, parent_id, content_hash, integrity_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'ok')
            ON CONFLICT(name) DO UPDATE SET
                task_pattern = excluded.task_pattern,
                summary = COALESCE(excluded.summary, procedures.summary),
                steps_json = excluded.steps_json,
                services = COALESCE(excluded.services, procedures.services),
                domains = COALESCE(excluded.domains, procedures.domains),
                parent_id = COALESCE(excluded.parent_id, procedures.parent_id),
                content_hash = excluded.content_hash,
                integrity_status = 'ok',
                deprecated = 0,
                deprecated_reason = NULL,
                consec_fails = 0,
                version = version + 1,
                updated_at = unixepoch('subsec')
        """, (
            name, summary, task_pattern,
            json.dumps(services) if services else None,
            json.dumps(domains) if domains else None,
            steps_json, parent_id, content_hash
        ))
        self.db.commit()

    def get_skill(self, name: str) -> Optional[dict]:
        """Get a procedure that qualifies as a skill (3+ successes, >80% rate).

        Skills are mature procedures that can be referenced by other procedures.
        This enables Voyager-style progressive complexity.
        """
        row = self.db.execute("""
            SELECT *,
                CASE WHEN (success_count + fail_count) > 0
                     THEN (success_count * 1.0 / (success_count + fail_count))
                     ELSE 0 END as success_rate
            FROM procedures
            WHERE name = ? AND success_count >= 3
            AND (success_count * 1.0 / NULLIF(success_count + fail_count, 0)) >= 0.8
        """, (name,)).fetchone()
        if not row:
            return None
        row_dict = dict(row)
        if not self._verify_procedure_integrity(row_dict):
            return None
        return row_dict

    def list_skills(self) -> list[dict]:
        """List all procedures that qualify as reusable skills."""
        rows = self.db.execute("""
            SELECT name, task_pattern, services, success_count, fail_count,
                CASE WHEN (success_count + fail_count) > 0
                     THEN ROUND(success_count * 100.0 / (success_count + fail_count), 1)
                     ELSE 0 END as success_rate_pct,
                version
            FROM procedures
            WHERE success_count >= 3
            AND (success_count * 1.0 / NULLIF(success_count + fail_count, 0)) >= 0.8
            ORDER BY success_count DESC
        """).fetchall()
        return [dict(r) for r in rows]

    def find_procedure(self, task_desc: str = None, services: list = None,
                       min_success_rate: float = 0.0) -> list[dict]:
        """Find procedures matching a task or service list."""
        conditions = []
        params = []

        if task_desc:
            words = [w for w in task_desc.lower().split() if len(w) > 2][:5]
            for word in words:
                conditions.append("LOWER(task_pattern) LIKE ?")
                params.append(f"%{word}%")

        if services:
            for svc in services:
                conditions.append("services LIKE ?")
                params.append(f"%{svc}%")

        if not conditions:
            return []

        where = " OR ".join(conditions)
        rows = self.db.execute(f"""
            SELECT *,
                CASE WHEN (success_count + fail_count) > 0
                     THEN (success_count * 1.0 / (success_count + fail_count))
                     ELSE 0 END as success_rate
            FROM procedures
            WHERE ({where})
            AND deprecated = 0
            AND CASE WHEN (success_count + fail_count) > 0
                     THEN (success_count * 1.0 / (success_count + fail_count))
                     ELSE 0 END >= ?
            ORDER BY success_rate DESC, success_count DESC
            LIMIT 5
        """, params + [min_success_rate]).fetchall()
        verified = []
        for r in rows:
            row_dict = dict(r)
            if self._verify_procedure_integrity(row_dict):
                verified.append(row_dict)
        return verified

    def record_procedure_run(self, name: str, success: bool,
                             duration_ms: int = 0, cost_usd: float = 0):
        """Record success/failure for a procedure.

        Auto-deprecation: after 3 consecutive failures, the procedure is
        marked deprecated with reason 'auto: 3 consecutive failures'.
        Re-saving the procedure (via save_procedure) clears deprecation.
        """
        col = "success_count" if success else "fail_count"
        consec_update = "consec_fails = 0" if success else "consec_fails = consec_fails + 1"
        self.db.execute(f"""
            UPDATE procedures SET
                {col} = {col} + 1,
                {consec_update},
                last_run_at = unixepoch('subsec'),
                last_status = ?,
                avg_duration_ms = CASE
                    WHEN (success_count + fail_count) > 1
                    THEN (COALESCE(avg_duration_ms, 0) * (success_count + fail_count - 1) + ?) /
                         (success_count + fail_count)
                    ELSE ? END,
                avg_cost_usd = CASE
                    WHEN (success_count + fail_count) > 1
                    THEN (COALESCE(avg_cost_usd, 0) * (success_count + fail_count - 1) + ?) /
                         (success_count + fail_count)
                    ELSE ? END
            WHERE name = ?
        """, ("ok" if success else "error", duration_ms, duration_ms,
              cost_usd, cost_usd, name))

        # Auto-deprecate after 3 consecutive failures
        if not success:
            self.db.execute("""
                UPDATE procedures SET
                    deprecated = 1,
                    deprecated_reason = 'auto: 3 consecutive failures',
                    updated_at = unixepoch('subsec')
                WHERE name = ? AND consec_fails >= 3 AND deprecated = 0
            """, (name,))

        self.db.commit()

    def deprecate_procedure(self, name: str, reason: str = "manual"):
        """Manually deprecate a procedure."""
        self.db.execute("""
            UPDATE procedures SET deprecated = 1, deprecated_reason = ?,
                updated_at = unixepoch('subsec')
            WHERE name = ?
        """, (reason, name))
        self.db.commit()

    def list_deprecated(self) -> list[dict]:
        """List all deprecated procedures."""
        rows = self.db.execute("""
            SELECT name, summary, task_pattern, deprecated_reason,
                   success_count, fail_count, consec_fails, updated_at
            FROM procedures WHERE deprecated = 1
            ORDER BY updated_at DESC
        """).fetchall()
        return [dict(r) for r in rows]

    def get_children(self, parent_name: str) -> list[dict]:
        """Get child procedures (sub-steps) of a parent procedure."""
        parent = self.db.execute(
            "SELECT id FROM procedures WHERE name = ?", (parent_name,)
        ).fetchone()
        if not parent:
            return []
        rows = self.db.execute("""
            SELECT name, summary, task_pattern, success_count, fail_count,
                deprecated, version
            FROM procedures WHERE parent_id = ?
            ORDER BY name
        """, (parent["id"],)).fetchall()
        return [dict(r) for r in rows]

    def detect_meta_procedures(self, min_shared_steps: int = 3) -> list[dict]:
        """Detect potential meta-procedures from shared step patterns.

        Finds pairs of procedures that share >= min_shared_steps steps,
        suggesting they could be composed into a higher-level procedure.
        Inspired by MACLA hierarchical composition.
        """
        rows = self.db.execute("""
            SELECT id, name, steps_json FROM procedures
            WHERE deprecated = 0 AND steps_json IS NOT NULL
        """).fetchall()

        if len(rows) < 2:
            return []

        # Extract step action names for comparison
        proc_steps = {}
        for r in rows:
            try:
                steps = json.loads(r["steps_json"])
                # Extract action/description from each step
                actions = []
                for s in steps:
                    if isinstance(s, dict):
                        actions.append(s.get("action", s.get("description", str(s)))[:80])
                    else:
                        actions.append(str(s)[:80])
                proc_steps[r["name"]] = set(actions)
            except (json.JSONDecodeError, TypeError):
                continue

        # Find overlapping pairs
        candidates = []
        names = list(proc_steps.keys())
        for i in range(len(names)):
            for j in range(i + 1, len(names)):
                shared = proc_steps[names[i]] & proc_steps[names[j]]
                if len(shared) >= min_shared_steps:
                    candidates.append({
                        "proc_a": names[i],
                        "proc_b": names[j],
                        "shared_steps": len(shared),
                        "shared_actions": list(shared)[:5],
                    })

        candidates.sort(key=lambda x: x["shared_steps"], reverse=True)
        return candidates[:10]

    # ════════════════════════════════════════════════════════════════════════
    # ERRORS
    # ════════════════════════════════════════════════════════════════════════

    @staticmethod
    def normalize_error(pattern: str) -> str:
        """Normalize an error message for fingerprinting.

        Strips volatile content (paths, timestamps, IDs, ports, hashes)
        so structurally identical errors match the same fingerprint.
        This follows Sentry-style error grouping best practices.
        """
        import re
        s = pattern
        # Strip absolute paths (macOS/Linux)
        s = re.sub(r'/(?:Users|home|var|tmp|etc|opt|usr)/[\w./-]+', '<PATH>', s)
        # Strip Windows-style paths
        s = re.sub(r'[A-Z]:\\[\w.\\/-]+', '<PATH>', s)
        # Strip ISO timestamps
        s = re.sub(r'\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[\w.:+-]*', '<TIMESTAMP>', s)
        # Strip Unix timestamps (10+ digits)
        s = re.sub(r'\b\d{10,13}\b', '<TIMESTAMP>', s)
        # Strip UUIDs
        s = re.sub(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<UUID>', s, flags=re.IGNORECASE)
        # Strip hex hashes (SHA1, SHA256, etc.)
        s = re.sub(r'\b[0-9a-f]{20,64}\b', '<HASH>', s, flags=re.IGNORECASE)
        # Strip port numbers after host
        s = re.sub(r':\d{4,5}\b', ':<PORT>', s)
        # Strip IP addresses
        s = re.sub(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', '<IP>', s)
        # Strip line numbers
        s = re.sub(r'(?:line|Line|LINE)\s*\d+', 'line <N>', s)
        # Strip generic IDs (numeric or alphanumeric with dashes, adjacent to id= patterns)
        s = re.sub(r'(?:id|ID|Id)[=: ]+[a-zA-Z0-9_-]+', 'id=<ID>', s)
        # Collapse whitespace
        s = re.sub(r'\s+', ' ', s).strip()
        return s

    def log_error(self, error_type: str, pattern: str,
                  service: str = None, action: str = None,
                  resolution: str = None, resolution_type: str = None):
        """Log or increment a deduplicated error pattern.

        Automatically normalizes the pattern by stripping paths, timestamps,
        IDs, and hashes so structurally identical errors are grouped together.
        """
        normalized = self.normalize_error(pattern)
        error_hash = hashlib.sha256(
            f"{error_type}:{normalized}:{service or ''}".encode()
        ).hexdigest()[:16]

        self.db.execute("""
            INSERT INTO errors (error_hash, error_type, pattern, service, action,
                resolution, resolution_type)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(error_hash) DO UPDATE SET
                count = count + 1,
                last_seen = unixepoch('subsec'),
                resolution = COALESCE(excluded.resolution, errors.resolution),
                resolution_type = COALESCE(excluded.resolution_type, errors.resolution_type)
        """, (error_hash, error_type, normalized, service, action,
              resolution, resolution_type))
        self.db.commit()

    def check_known_error(self, error_msg: str, service: str = None) -> Optional[dict]:
        """Check if an error matches a known pattern with a resolution.

        Normalizes the input error message before matching, so structurally
        identical errors match even with different paths/timestamps/IDs.
        """
        conditions = ["resolution IS NOT NULL"]
        params = []

        if service:
            conditions.append("(service = ? OR service IS NULL)")
            params.append(service)

        where = " AND ".join(conditions)
        rows = self.db.execute(f"""
            SELECT * FROM errors WHERE {where}
            ORDER BY count DESC
        """, params).fetchall()

        # Normalize the incoming error for comparison
        normalized_msg = self.normalize_error(error_msg).lower()
        error_lower = error_msg.lower()

        for row in rows:
            pattern_lower = row["pattern"].lower()
            # Match against both normalized and raw versions
            if pattern_lower in normalized_msg or pattern_lower in error_lower:
                return dict(row)
        return None

    def resolve_error(self, error_type: str, pattern: str,
                      service: str, resolution: str,
                      resolution_type: str = "auto"):
        """Add a resolution to a known error pattern."""
        error_hash = hashlib.sha256(
            f"{error_type}:{pattern}:{service or ''}".encode()
        ).hexdigest()[:16]

        self.db.execute("""
            UPDATE errors SET
                resolution = ?,
                resolution_type = ?
            WHERE error_hash = ?
        """, (resolution, resolution_type, error_hash))
        self.db.commit()

    # ════════════════════════════════════════════════════════════════════════
    # SERVICES
    # ════════════════════════════════════════════════════════════════════════

    def cache_service(self, name: str, **kwargs):
        """Cache or update service metadata."""
        allowed = {
            "display_name", "category", "website", "docs_url", "cli_tool",
            "cli_install", "auth_method", "has_mcp", "mcp_package",
            "mcp_trust_score", "has_playbook", "has_registry", "dangerous_ops",
            "last_researched"
        }
        filtered = {k: v for k, v in kwargs.items() if k in allowed and v is not None}

        if not filtered:
            self.db.execute(
                "INSERT OR IGNORE INTO services (name) VALUES (?)", (name,)
            )
        else:
            cols = ["name"] + list(filtered.keys())
            vals = [name] + list(filtered.values())
            placeholders = ", ".join(["?"] * len(vals))
            col_str = ", ".join(cols)
            updates = ", ".join(f"{k} = excluded.{k}" for k in filtered.keys())
            self.db.execute(f"""
                INSERT INTO services ({col_str}) VALUES ({placeholders})
                ON CONFLICT(name) DO UPDATE SET {updates}, updated_at = unixepoch('subsec')
            """, vals)

        self.db.commit()

    def get_service(self, name: str) -> Optional[dict]:
        """Get cached service metadata."""
        row = self.db.execute(
            "SELECT * FROM services WHERE name = ?", (name,)
        ).fetchone()
        return dict(row) if row else None

    def list_services(self) -> list[dict]:
        """List all cached services."""
        rows = self.db.execute(
            "SELECT * FROM services ORDER BY name"
        ).fetchall()
        return [dict(r) for r in rows]

    # ════════════════════════════════════════════════════════════════════════
    # PLAYBOOKS
    # ════════════════════════════════════════════════════════════════════════

    def register_playbook(self, service: str, flow: str, file_path: str,
                          generated_by: str = "auto"):
        """Register a playbook in the metadata store."""
        self.db.execute("""
            INSERT INTO playbooks (service, flow, file_path, generated_by)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(service, flow) DO UPDATE SET
                file_path = excluded.file_path,
                version = version + 1,
                updated_at = unixepoch('subsec')
        """, (service, flow, file_path, generated_by))
        self.db.commit()

    def get_playbook(self, service: str, flow: str) -> Optional[dict]:
        """Get playbook metadata."""
        row = self.db.execute(
            "SELECT * FROM playbooks WHERE service = ? AND flow = ?",
            (service, flow)
        ).fetchone()
        return dict(row) if row else None

    def record_playbook_run(self, service: str, flow: str,
                            success: bool, duration_ms: int = 0):
        """Record playbook execution result."""
        col = "success_count" if success else "fail_count"
        self.db.execute(f"""
            UPDATE playbooks SET
                {col} = {col} + 1,
                last_run_at = unixepoch('subsec'),
                last_status = ?,
                avg_duration_ms = CASE
                    WHEN (success_count + fail_count) > 1
                    THEN (COALESCE(avg_duration_ms, 0) * (success_count + fail_count - 1) + ?) /
                         (success_count + fail_count)
                    ELSE ? END
            WHERE service = ? AND flow = ?
        """, ("ok" if success else "error", duration_ms, duration_ms,
              service, flow))
        self.db.commit()

    # ════════════════════════════════════════════════════════════════════════
    # COSTS
    # ════════════════════════════════════════════════════════════════════════

    def log_cost(self, run_id: str, model: str, tokens_in: int = 0,
                 tokens_out: int = 0, tokens_cache: int = 0,
                 cost_usd: float = 0, duration_ms: int = 0,
                 task_desc: str = None):
        """Log token usage and cost for a run."""
        self.db.execute("""
            INSERT INTO costs (run_id, task_desc, model, tokens_in, tokens_out,
                tokens_cache, cost_usd, duration_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (run_id, task_desc, model, tokens_in, tokens_out,
              tokens_cache, cost_usd, duration_ms))
        self.db.commit()

    def get_cost_summary(self, days: int = 7) -> dict:
        """Get aggregated cost summary for the last N days."""
        cutoff = time.time() - (days * 86400)
        row = self.db.execute("""
            SELECT
                COUNT(DISTINCT run_id) as tasks,
                SUM(COALESCE(tokens_in, 0)) as total_in,
                SUM(COALESCE(tokens_out, 0)) as total_out,
                SUM(COALESCE(tokens_cache, 0)) as total_cache,
                SUM(COALESCE(cost_usd, 0)) as total_cost,
                AVG(COALESCE(cost_usd, 0)) as avg_cost_per_run
            FROM costs
            WHERE created_at > ?
        """, (cutoff,)).fetchone()
        return dict(row) if row else {}

    def estimate_task_cost(self, task_desc: str, services: list = None) -> dict:
        """Estimate token cost before executing a task.

        Looks at historical costs for similar tasks and services to predict
        the likely cost of a new task. Returns estimated tokens, cost, and
        confidence level based on how many similar tasks exist.
        """
        estimates = {"tokens": 0, "cost_usd": 0.0, "confidence": "none",
                     "based_on_tasks": 0, "similar_tasks": []}

        conditions = []
        params = []

        if task_desc:
            words = [w for w in task_desc.lower().split() if len(w) > 2][:5]
            for word in words:
                conditions.append("LOWER(task_desc) LIKE ?")
                params.append(f"%{word}%")

        if services:
            for svc in services:
                conditions.append("LOWER(task_desc) LIKE ?")
                params.append(f"%{svc.lower()}%")

        if not conditions:
            return estimates

        where = " OR ".join(conditions)
        rows = self.db.execute(f"""
            SELECT task_desc,
                SUM(COALESCE(tokens_in, 0) + COALESCE(tokens_out, 0)) as total_tokens,
                SUM(COALESCE(cost_usd, 0)) as total_cost
            FROM costs
            WHERE ({where})
            GROUP BY run_id
            ORDER BY created_at DESC
            LIMIT 10
        """, params).fetchall()

        if not rows:
            return estimates

        total_tokens = sum(r["total_tokens"] or 0 for r in rows)
        total_cost = sum(r["total_cost"] or 0 for r in rows)
        n = len(rows)

        estimates["tokens"] = int(total_tokens / n)
        estimates["cost_usd"] = round(total_cost / n, 4)
        estimates["based_on_tasks"] = n
        estimates["similar_tasks"] = [(r["task_desc"] or "")[:50] for r in rows[:3]]

        if n >= 5:
            estimates["confidence"] = "high"
        elif n >= 2:
            estimates["confidence"] = "medium"
        else:
            estimates["confidence"] = "low"

        return estimates

    def get_cost_by_model(self, days: int = 7) -> list[dict]:
        """Get cost breakdown by model."""
        cutoff = time.time() - (days * 86400)
        rows = self.db.execute("""
            SELECT model,
                COUNT(*) as calls,
                SUM(COALESCE(tokens_in, 0) + COALESCE(tokens_out, 0)) as total_tokens,
                SUM(COALESCE(cost_usd, 0)) as total_cost
            FROM costs
            WHERE created_at > ?
            GROUP BY model
            ORDER BY total_cost DESC
        """, (cutoff,)).fetchall()
        return [dict(r) for r in rows]

    # ════════════════════════════════════════════════════════════════════════
    # HEALTH
    # ════════════════════════════════════════════════════════════════════════

    def log_health(self, service: str, check_type: str, status: str,
                   message: str = None, response_ms: int = None):
        """Log a health check result."""
        self.db.execute("""
            INSERT INTO health (service, check_type, status, message, response_ms)
            VALUES (?, ?, ?, ?, ?)
        """, (service, check_type, status, message, response_ms))
        self.db.commit()

    def get_health_status(self) -> list[dict]:
        """Get the latest health check for each service."""
        rows = self.db.execute("""
            SELECT h.* FROM health h
            INNER JOIN (
                SELECT service, check_type, MAX(created_at) as max_created
                FROM health GROUP BY service, check_type
            ) latest ON h.service = latest.service
                    AND h.check_type = latest.check_type
                    AND h.created_at = latest.max_created
            ORDER BY h.service, h.check_type
        """).fetchall()
        return [dict(r) for r in rows]

    # ════════════════════════════════════════════════════════════════════════
    # KV STORE
    # ════════════════════════════════════════════════════════════════════════

    def kv_set(self, key: str, value: str):
        self.db.execute("""
            INSERT INTO kv (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value,
                updated_at = unixepoch('subsec')
        """, (key, value))
        self.db.commit()

    def kv_get(self, key: str) -> Optional[str]:
        row = self.db.execute(
            "SELECT value FROM kv WHERE key = ?", (key,)
        ).fetchone()
        return row["value"] if row else None

    def kv_delete(self, key: str):
        self.db.execute("DELETE FROM kv WHERE key = ?", (key,))
        self.db.commit()

    # ════════════════════════════════════════════════════════════════════════
    # STATS
    # ════════════════════════════════════════════════════════════════════════

    def get_stats(self) -> dict:
        """Get overview statistics."""
        stats = {}
        for table in ["traces", "procedures", "errors", "services", "playbooks", "costs", "health"]:
            row = self.db.execute(f"SELECT COUNT(*) as cnt FROM {table}").fetchone()
            stats[table] = row["cnt"]
        return stats

    def close(self):
        self.db.close()


# ═════════════════════════════════════════════════════════════════════════════
# CLI Interface — for use from Claude Code agent mode
# ═════════════════════════════════════════════════════════════════════════════

def fmt_time(ts: float) -> str:
    """Format unix timestamp for display."""
    if not ts:
        return "never"
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M")


def cli_stats(mem: AutopilotMemory):
    stats = mem.get_stats()
    print(f"{BOLD}Autopilot Memory Stats{NC}")
    print(f"  DB: {mem.db_path}")
    print()
    for table, count in stats.items():
        print(f"  {table:12s}  {count:>6d} records")


def cli_runs(mem: AutopilotMemory, limit: int = 10):
    runs = mem.get_recent_runs(limit)
    if not runs:
        print("No runs recorded yet.")
        return
    print(f"{BOLD}Recent Runs{NC} (last {limit})")
    print()
    for r in runs:
        status_color = GREEN if r["err_steps"] == 0 else RED
        task = (r["task_desc"] or "unknown")[:45]
        tokens = r["total_tokens"] or 0
        cost = r["total_cost"] or 0
        print(f"  {DIM}{r['run_id'][:10]}{NC}  {task:45s}  "
              f"steps={r['steps']}  "
              f"{status_color}ok={r['ok_steps']} err={r['err_steps']}{NC}  "
              f"tokens={tokens:,}  ${cost:.3f}")


def cli_costs(mem: AutopilotMemory, days: int = 7):
    summary = mem.get_cost_summary(days)
    print(f"{BOLD}Cost Summary{NC} (last {days} days)")
    print()
    print(f"  Tasks:       {summary.get('tasks', 0) or 0}")
    print(f"  Tokens in:   {summary.get('total_in', 0) or 0:,}")
    print(f"  Tokens out:  {summary.get('total_out', 0) or 0:,}")
    print(f"  Cached:      {summary.get('total_cache', 0) or 0:,}")
    print(f"  Total cost:  ${summary.get('total_cost', 0) or 0:.4f}")
    print(f"  Avg/task:    ${summary.get('avg_cost_per_run', 0) or 0:.4f}")
    print()

    by_model = mem.get_cost_by_model(days)
    if by_model:
        print(f"  {BOLD}By Model:{NC}")
        for m in by_model:
            print(f"    {m['model'] or 'unknown':20s}  calls={m['calls']}  "
                  f"tokens={m['total_tokens']:,}  ${m['total_cost']:.4f}")


def cli_errors(mem: AutopilotMemory):
    rows = mem.db.execute(
        "SELECT * FROM errors ORDER BY count DESC LIMIT 20"
    ).fetchall()
    if not rows:
        print("No errors recorded yet.")
        return
    print(f"{BOLD}Known Error Patterns{NC} (top 20)")
    print()
    for r in rows:
        resolved = f"{GREEN}RESOLVED{NC}" if r["resolution"] else f"{YELLOW}OPEN{NC}"
        print(f"  [{r['count']:3d}x] {r['error_type']:15s} {r['service'] or '*':12s} "
              f"{resolved}  {r['pattern'][:55]}")
        if r["resolution"]:
            print(f"         {DIM}Fix: {r['resolution'][:70]}{NC}")


def cli_health(mem: AutopilotMemory):
    statuses = mem.get_health_status()
    if not statuses:
        print("No health checks recorded yet.")
        return
    print(f"{BOLD}Service Health{NC}")
    print()
    for s in statuses:
        icon = f"{GREEN}OK{NC}" if s["status"] == "ok" else f"{RED}FAIL{NC}"
        ms = f"{s['response_ms']}ms" if s.get("response_ms") else ""
        print(f"  [{icon:>14s}]  {s['service']:18s}  {s['check_type']:12s}  "
              f"{ms:>8s}  {s.get('message', '') or ''}")


def cli_services(mem: AutopilotMemory):
    rows = mem.list_services()
    if not rows:
        print("No services cached yet.")
        return
    print(f"{BOLD}Cached Services{NC}")
    print()
    for r in rows:
        flags = []
        if r.get("cli_tool"):
            flags.append(f"cli:{r['cli_tool']}")
        if r.get("has_mcp"):
            flags.append("mcp")
        if r.get("has_playbook"):
            flags.append("playbook")
        if r.get("has_registry"):
            flags.append("registry")
        cat = r.get("category") or ""
        print(f"  {r['name']:20s}  {cat:12s}  {', '.join(flags)}")


def cli_procedures(mem: AutopilotMemory):
    rows = mem.db.execute(
        "SELECT * FROM procedures ORDER BY success_count DESC LIMIT 20"
    ).fetchall()
    if not rows:
        print("No procedures learned yet.")
        return
    print(f"{BOLD}Learned Procedures{NC} (top 20)")
    print()
    for r in rows:
        total = r["success_count"] + r["fail_count"]
        rate = (r["success_count"] / total * 100) if total > 0 else 0
        avg_ms = r["avg_duration_ms"] or 0
        dep = f" {RED}[DEPRECATED]{NC}" if r["deprecated"] else ""
        s = r["summary"] if r["summary"] else None
        print(f"  {r['name']:35s}  "
              f"runs={total:3d}  rate={rate:5.1f}%  "
              f"avg={avg_ms/1000:.1f}s  v{r['version']}{dep}")
        if s:
            print(f"    {DIM}{s}{NC}")


def cli_log_error(mem: AutopilotMemory, args):
    mem.log_error(
        error_type=args.error_type,
        pattern=args.pattern,
        service=args.service,
        resolution=args.resolution,
    )
    print(f"{GREEN}Logged error:{NC} [{args.error_type}] {args.pattern[:60]}")


def cli_save_procedure(mem: AutopilotMemory, args):
    try:
        steps = json.loads(args.steps_json)
    except json.JSONDecodeError as e:
        print(f"{RED}Invalid JSON for steps:{NC} {e}", file=sys.stderr)
        sys.exit(1)
    services = args.services.split(",") if args.services else None
    mem.save_procedure(
        name=args.name,
        task_pattern=args.description,
        steps=steps,
        services=services,
        summary=getattr(args, 'summary', None),
        parent_id=getattr(args, 'parent_id', None),
    )
    print(f"{GREEN}Saved procedure:{NC} {args.name}")


def cli_deprecated(mem: AutopilotMemory):
    rows = mem.list_deprecated()
    if not rows:
        print("No deprecated procedures.")
        return
    print(f"{BOLD}Deprecated Procedures{NC}")
    print()
    for r in rows:
        total = r["success_count"] + r["fail_count"]
        print(f"  {RED}{r['name']:35s}{NC}  runs={total:3d}  "
              f"consec_fails={r['consec_fails']}  reason={r['deprecated_reason']}")


def cli_meta_procedures(mem: AutopilotMemory, min_shared: int = 3):
    candidates = mem.detect_meta_procedures(min_shared)
    if not candidates:
        print("No meta-procedure candidates found (need procedures with shared steps).")
        return
    print(f"{BOLD}Meta-Procedure Candidates{NC} (shared step patterns)")
    print()
    for c in candidates:
        print(f"  {c['proc_a']}  +  {c['proc_b']}")
        print(f"    {DIM}shared steps: {c['shared_steps']}  "
              f"actions: {', '.join(c['shared_actions'][:3])}{NC}")
        print()


def cli_check_error(mem: AutopilotMemory, args):
    result = mem.check_known_error(args.error_message, service=args.service)
    if result:
        print(f"{GREEN}Known error found:{NC}")
        print(f"  Type:       {result['error_type']}")
        print(f"  Pattern:    {result['pattern']}")
        print(f"  Service:    {result.get('service') or '*'}")
        print(f"  Seen:       {result['count']}x")
        print(f"  Resolution: {result['resolution']}")
    else:
        print(f"{YELLOW}No known resolution found.{NC}")


def cli_cache_service(mem: AutopilotMemory, args):
    kwargs = {}
    if args.cli:
        kwargs["cli_tool"] = args.cli
    if args.category:
        kwargs["category"] = args.category
    if args.website:
        kwargs["website"] = args.website
    if args.has_mcp:
        kwargs["has_mcp"] = 1
    if args.has_registry:
        kwargs["has_registry"] = 1
    if args.has_playbook:
        kwargs["has_playbook"] = 1
    mem.cache_service(args.service, **kwargs)
    print(f"{GREEN}Cached service:{NC} {args.service}")


def cli_record_run(mem: AutopilotMemory, args):
    import uuid
    run_id = str(uuid.uuid4())[:12]
    services_list = args.services.split(",") if args.services else []

    # Log a summary trace for this run
    mem.log_trace(
        run_id=run_id,
        step_num=1,
        action=args.task_name,
        task_desc=args.task_name,
        status=args.status,
        error_msg=args.error,
        duration_ms=int(args.duration * 1000) if args.duration else None,
        tokens_in=args.tokens,
        cost_usd=args.cost,
        service=services_list[0] if services_list else None,
    )

    # If cost info provided, also log to costs table
    if args.cost or args.tokens:
        mem.log_cost(
            run_id=run_id,
            model="autopilot",
            tokens_in=args.tokens or 0,
            cost_usd=args.cost or 0,
            duration_ms=int(args.duration * 1000) if args.duration else 0,
            task_desc=args.task_name,
        )

    status_color = GREEN if args.status == "ok" else RED
    print(f"{status_color}Recorded run:{NC} {run_id}  {args.task_name}  [{args.status}]")


def cli_find_procedure(mem: AutopilotMemory, args):
    results = mem.find_procedure(task_desc=args.task_description)
    if not results:
        print(f"{YELLOW}No matching procedures found.{NC}")
        return
    print(f"{BOLD}Matching Procedures{NC}")
    print()
    for r in results:
        total = r["success_count"] + r["fail_count"]
        rate = (r["success_count"] / total * 100) if total > 0 else 0
        print(f"  {r['name']:35s}  runs={total:3d}  rate={rate:5.1f}%  v{r['version']}")
        print(f"    {DIM}{r['task_pattern'][:70]}{NC}")
        if r.get("services"):
            print(f"    services: {r['services']}")


def cli_skills(mem: AutopilotMemory):
    skills = mem.list_skills()
    if not skills:
        print("No skills yet. Procedures become skills after 3+ successes with >80% rate.")
        return
    print(f"{BOLD}Reusable Skills{NC} (mature procedures)")
    print()
    for s in skills:
        print(f"  {s['name']:35s}  "
              f"runs={s['success_count']:3d}  "
              f"rate={s['success_rate_pct']:5.1f}%  "
              f"v{s['version']}")
        if s.get("services"):
            print(f"    {DIM}services: {s['services']}{NC}")


def cli_estimate_cost(mem: AutopilotMemory, args):
    services = args.services.split(",") if args.services else None
    est = mem.estimate_task_cost(args.task_description, services)
    print(f"{BOLD}Cost Estimate{NC}")
    print(f"  Task:       {args.task_description}")
    print(f"  Confidence: {est['confidence']}")
    print(f"  Est tokens: {est['tokens']:,}")
    print(f"  Est cost:   ${est['cost_usd']:.4f}")
    print(f"  Based on:   {est['based_on_tasks']} similar task(s)")
    if est["similar_tasks"]:
        print(f"  Examples:   {', '.join(est['similar_tasks'])}")


def build_parser():
    """Build the argparse parser with all subcommands."""
    import argparse

    parser = argparse.ArgumentParser(
        prog="memory.py",
        description="Autopilot Memory CLI — read and write to the unified memory store",
    )
    sub = parser.add_subparsers(dest="command")

    # ── Read subcommands (existing) ──────────────────────────────────────
    sub.add_parser("stats", help="Show memory database statistics")

    p_runs = sub.add_parser("runs", help="Show recent runs")
    p_runs.add_argument("limit", nargs="?", type=int, default=10, help="Max runs to show")

    p_costs = sub.add_parser("costs", help="Show cost summary")
    p_costs.add_argument("days", nargs="?", type=int, default=7, help="Number of days")

    sub.add_parser("errors", help="Show known error patterns")
    sub.add_parser("health", help="Show service health status")
    sub.add_parser("services", help="Show cached services")
    sub.add_parser("procedures", help="Show learned procedures")

    # ── Write subcommands (new) ──────────────────────────────────────────

    p_log_error = sub.add_parser("log-error", help="Log a deduplicated error pattern")
    p_log_error.add_argument("error_type", help="Error category (e.g. timeout, auth, rate_limit)")
    p_log_error.add_argument("pattern", help="Error pattern string to match on")
    p_log_error.add_argument("--service", help="Service that produced the error")
    p_log_error.add_argument("--resolution", help="Known resolution for this error")

    p_save_proc = sub.add_parser("save-procedure", help="Save a learned procedure")
    p_save_proc.add_argument("name", help="Unique procedure name")
    p_save_proc.add_argument("description", help="Task pattern description")
    p_save_proc.add_argument("steps_json", help="JSON string of procedure steps")
    p_save_proc.add_argument("--services", help="Comma-separated service names")
    p_save_proc.add_argument("--summary", help="Short summary for two-tier discovery")
    p_save_proc.add_argument("--parent-id", type=int, help="Parent procedure ID for composition")

    p_check_err = sub.add_parser("check-error", help="Check if an error has a known resolution")
    p_check_err.add_argument("error_message", help="The error message to look up")
    p_check_err.add_argument("--service", help="Filter to a specific service")

    p_cache_svc = sub.add_parser("cache-service", help="Cache service metadata")
    p_cache_svc.add_argument("service", help="Service name")
    p_cache_svc.add_argument("--cli", help="CLI tool name")
    p_cache_svc.add_argument("--category", help="Service category")
    p_cache_svc.add_argument("--website", help="Service website URL")
    p_cache_svc.add_argument("--has-mcp", action="store_true", help="Service has an MCP server")
    p_cache_svc.add_argument("--has-registry", action="store_true", help="Service is in the registry")
    p_cache_svc.add_argument("--has-playbook", action="store_true", help="Service has a playbook")

    p_record_run = sub.add_parser("record-run", help="Record an agent run")
    p_record_run.add_argument("task_name", help="Name/description of the task")
    p_record_run.add_argument("status", choices=["ok", "error", "partial"], help="Run outcome")
    p_record_run.add_argument("--services", help="Comma-separated service names")
    p_record_run.add_argument("--steps", type=int, help="Number of steps taken")
    p_record_run.add_argument("--duration", type=float, help="Duration in seconds")
    p_record_run.add_argument("--tokens", type=int, help="Total tokens used")
    p_record_run.add_argument("--cost", type=float, help="Total cost in USD")
    p_record_run.add_argument("--error", help="Error message if status is error")

    p_find_proc = sub.add_parser("find-procedure", help="Find procedures matching a task")
    p_find_proc.add_argument("task_description", help="Task description to search for")

    # ── Skill composition (Tier 2 SOTA) ─────────────────────────────────
    sub.add_parser("skills", help="List procedures that qualify as reusable skills (3+ successes, >80% rate)")

    # ── Token budget estimation (Tier 2 SOTA) ───────────────────────────
    p_estimate = sub.add_parser("estimate-cost", help="Estimate cost for a task based on history")
    p_estimate.add_argument("task_description", help="Task description to estimate cost for")
    p_estimate.add_argument("--services", help="Comma-separated service names")

    # ── Procedure lifecycle (Tier 5 SOTA) ───────────────────────────────
    sub.add_parser("deprecated", help="List deprecated procedures")

    p_deprecate = sub.add_parser("deprecate", help="Manually deprecate a procedure")
    p_deprecate.add_argument("name", help="Procedure name")
    p_deprecate.add_argument("--reason", default="manual", help="Deprecation reason")

    p_meta = sub.add_parser("meta-procedures", help="Detect meta-procedure candidates from shared steps")
    p_meta.add_argument("--min-shared", type=int, default=3, help="Minimum shared steps")

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    mem = AutopilotMemory()

    try:
        # Read subcommands (existing)
        if args.command == "stats":
            cli_stats(mem)
        elif args.command == "runs":
            cli_runs(mem, args.limit)
        elif args.command == "costs":
            cli_costs(mem, args.days)
        elif args.command == "errors":
            cli_errors(mem)
        elif args.command == "health":
            cli_health(mem)
        elif args.command == "services":
            cli_services(mem)
        elif args.command == "procedures":
            cli_procedures(mem)
        # Write subcommands (new)
        elif args.command == "log-error":
            cli_log_error(mem, args)
        elif args.command == "save-procedure":
            cli_save_procedure(mem, args)
        elif args.command == "check-error":
            cli_check_error(mem, args)
        elif args.command == "cache-service":
            cli_cache_service(mem, args)
        elif args.command == "record-run":
            cli_record_run(mem, args)
        elif args.command == "find-procedure":
            cli_find_procedure(mem, args)
        elif args.command == "skills":
            cli_skills(mem)
        elif args.command == "estimate-cost":
            cli_estimate_cost(mem, args)
        elif args.command == "deprecated":
            cli_deprecated(mem)
        elif args.command == "deprecate":
            mem.deprecate_procedure(args.name, args.reason)
            print(f"{YELLOW}Deprecated:{NC} {args.name} ({args.reason})")
        elif args.command == "meta-procedures":
            cli_meta_procedures(mem, args.min_shared)
    finally:
        mem.close()


if __name__ == "__main__":
    main()
