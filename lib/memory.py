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
    task_pattern    TEXT NOT NULL,
    services        TEXT,
    domains         TEXT,
    steps_json      TEXT NOT NULL,
    success_count   INTEGER DEFAULT 0,
    fail_count      INTEGER DEFAULT 0,
    last_run_at     REAL,
    last_status     TEXT,
    avg_duration_ms INTEGER,
    avg_cost_usd    REAL,
    version         INTEGER DEFAULT 1,
    created_at      REAL NOT NULL DEFAULT (unixepoch('subsec')),
    updated_at      REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
CREATE INDEX IF NOT EXISTS idx_procedures_services ON procedures(services);
CREATE INDEX IF NOT EXISTS idx_procedures_name ON procedures(name);

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
                       services: list = None, domains: list = None):
        """Save or update a learned procedure."""
        self.db.execute("""
            INSERT INTO procedures (name, task_pattern, services, domains, steps_json)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(name) DO UPDATE SET
                task_pattern = excluded.task_pattern,
                steps_json = excluded.steps_json,
                services = COALESCE(excluded.services, services),
                domains = COALESCE(excluded.domains, domains),
                version = version + 1,
                updated_at = unixepoch('subsec')
        """, (
            name, task_pattern,
            json.dumps(services) if services else None,
            json.dumps(domains) if domains else None,
            json.dumps(steps)
        ))
        self.db.commit()

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
            AND CASE WHEN (success_count + fail_count) > 0
                     THEN (success_count * 1.0 / (success_count + fail_count))
                     ELSE 0 END >= ?
            ORDER BY success_rate DESC, success_count DESC
            LIMIT 5
        """, params + [min_success_rate]).fetchall()
        return [dict(r) for r in rows]

    def record_procedure_run(self, name: str, success: bool,
                             duration_ms: int = 0, cost_usd: float = 0):
        """Record success/failure for a procedure."""
        col = "success_count" if success else "fail_count"
        self.db.execute(f"""
            UPDATE procedures SET
                {col} = {col} + 1,
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
        self.db.commit()

    # ════════════════════════════════════════════════════════════════════════
    # ERRORS
    # ════════════════════════════════════════════════════════════════════════

    def log_error(self, error_type: str, pattern: str,
                  service: str = None, action: str = None,
                  resolution: str = None, resolution_type: str = None):
        """Log or increment a deduplicated error pattern."""
        error_hash = hashlib.sha256(
            f"{error_type}:{pattern}:{service or ''}".encode()
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
        """, (error_hash, error_type, pattern, service, action,
              resolution, resolution_type))
        self.db.commit()

    def check_known_error(self, error_msg: str, service: str = None) -> Optional[dict]:
        """Check if an error matches a known pattern with a resolution."""
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

        error_lower = error_msg.lower()
        for row in rows:
            if row["pattern"].lower() in error_lower:
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
        print(f"  {r['name']:35s}  "
              f"runs={total:3d}  rate={rate:5.1f}%  "
              f"avg={avg_ms/1000:.1f}s  v{r['version']}")


def main():
    if len(sys.argv) < 2:
        print(f"Usage: python3 memory.py <command>")
        print(f"Commands: stats, runs, costs, errors, health, services, procedures")
        sys.exit(1)

    mem = AutopilotMemory()
    cmd = sys.argv[1]

    try:
        if cmd == "stats":
            cli_stats(mem)
        elif cmd == "runs":
            limit = int(sys.argv[2]) if len(sys.argv) > 2 else 10
            cli_runs(mem, limit)
        elif cmd == "costs":
            days = int(sys.argv[2]) if len(sys.argv) > 2 else 7
            cli_costs(mem, days)
        elif cmd == "errors":
            cli_errors(mem)
        elif cmd == "health":
            cli_health(mem)
        elif cmd == "services":
            cli_services(mem)
        elif cmd == "procedures":
            cli_procedures(mem)
        else:
            print(f"Error: Unknown command '{cmd}'", file=sys.stderr)
            print("Commands: stats, runs, costs, errors, health, services, procedures",
                  file=sys.stderr)
            sys.exit(1)
    finally:
        mem.close()


if __name__ == "__main__":
    main()
