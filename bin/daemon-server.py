#!/usr/bin/env python3
"""
daemon-server.py — Autopilot webhook HTTP server

Accepts task triggers via HTTP and spawns `claude --agent autopilot`.
Spawned by daemon.sh — do not run directly.

Endpoints:
  GET  /status       — health check + task running state
  POST /task         — generic task trigger (Authorization: Bearer <secret>)
  POST /github       — GitHub webhook handler (push, PR merged, workflow failure)
"""

import hashlib
import hmac
import json
import logging
import os
import signal
import subprocess
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Optional

# ─── Config ──────────────────────────────────────────────────────────────────

AUTOPILOT_DIR = Path(os.environ.get("AUTOPILOT_DIR", Path.home() / "MCPs/autopilot"))
LOG_FILE = Path.home() / ".autopilot" / "daemon.log"
LOCK_FILE = Path("/tmp/.autopilot-daemon-task.lock")
PORT = int(os.environ.get("AUTOPILOT_DAEMON_PORT", "7891"))
SECRET = os.environ.get("AUTOPILOT_DAEMON_SECRET", "")

# ─── Logging ─────────────────────────────────────────────────────────────────

LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    filename=str(LOG_FILE),
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)

# ─── Task management ─────────────────────────────────────────────────────────

def is_task_running() -> bool:
    """Check if a task is currently running by validating the lock file PID."""
    if not LOCK_FILE.exists():
        return False
    try:
        pid = int(LOCK_FILE.read_text().strip())
        os.kill(pid, 0)  # Signal 0 = existence check only
        return True
    except (ProcessLookupError, ValueError, OSError):
        LOCK_FILE.unlink(missing_ok=True)
        return False


def spawn_task(task: str, source: str = "api") -> tuple:
    """Spawn autopilot with a task string. Non-blocking."""
    if is_task_running():
        msg = "Another task is already running — try again when it completes"
        logging.warning(f"[{source}] Rejected (busy): {task[:60]}")
        return False, msg

    # Sanitize: strip shell metacharacters that could cause injection
    safe_task = task.replace('"', "'").replace("`", "").replace("$", "").strip()[:500]
    if not safe_task:
        return False, "Empty task after sanitization"

    logging.info(f"[{source}] Spawning: {safe_task[:80]}")

    try:
        with open(LOG_FILE, "a") as log_fh:
            proc = subprocess.Popen(
                ["claude", "--agent", "autopilot", safe_task],
                stdout=log_fh,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        LOCK_FILE.write_text(str(proc.pid))
        logging.info(f"[{source}] Started PID {proc.pid}")
        return True, f"Task started (PID {proc.pid})"
    except FileNotFoundError:
        msg = "claude CLI not found — is Claude Code installed?"
        logging.error(msg)
        return False, msg
    except Exception as e:
        logging.error(f"Failed to spawn: {e}")
        return False, str(e)


# ─── GitHub event → task string ──────────────────────────────────────────────

def github_to_task(event: str, payload: dict) -> Optional[str]:
    """Convert a GitHub webhook event to an Autopilot task string. Returns None to ignore."""
    repo = payload.get("repository", {}).get("full_name", "unknown")

    if event == "push":
        branch = payload.get("ref", "").removeprefix("refs/heads/")
        if branch not in ("main", "master"):
            return None  # Only act on default branch pushes
        commits = payload.get("commits", [])
        msg = commits[-1].get("message", "").split("\n")[0][:60] if commits else ""
        return (
            f"The {repo} repo just received a push to {branch} with commit: '{msg}'. "
            f"Check if a deploy is needed and run it."
        )

    if event == "pull_request":
        action = payload.get("action", "")
        pr = payload.get("pull_request", {})
        if action == "closed" and pr.get("merged"):
            title = pr.get("title", "")[:60]
            number = pr.get("number", "?")
            base = pr.get("base", {}).get("ref", "main")
            return (
                f"PR #{number} '{title}' was merged to {base} in {repo}. "
                f"Run the deployment pipeline."
            )
        return None

    if event == "workflow_run":
        run = payload.get("workflow_run", {})
        if run.get("conclusion") == "failure":
            name = run.get("name", "unknown workflow")
            return (
                f"GitHub Actions workflow '{name}' failed in {repo}. "
                f"Investigate the failure and fix it."
            )
        return None

    if event == "issues":
        action = payload.get("action", "")
        issue = payload.get("issue", {})
        labels = [l.get("name", "") for l in issue.get("labels", [])]
        if action == "labeled" and "autopilot" in labels:
            title = issue.get("title", "")[:60]
            number = issue.get("number", "?")
            body = issue.get("body", "")[:200]
            return (
                f"Issue #{number} '{title}' in {repo} was labeled 'autopilot'. "
                f"Complete the task described in the issue: {body}"
            )
        return None

    return None


# ─── HTTP handler ─────────────────────────────────────────────────────────────

class DaemonHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        logging.info(f"{self.client_address[0]} — {fmt % args}")

    def send_json(self, code: int, data: dict):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length else b""

    def verify_bearer(self) -> bool:
        if not SECRET:
            return True  # No secret configured — localhost-only is assumed safe
        auth = self.headers.get("Authorization", "")
        token = auth.removeprefix("Bearer ").strip()
        return hmac.compare_digest(token.encode(), SECRET.encode())

    def verify_github_sig(self, raw_body: bytes) -> bool:
        sig_header = self.headers.get("X-Hub-Signature-256", "")
        if not SECRET:
            return True
        if not sig_header:
            return False
        expected = "sha256=" + hmac.new(SECRET.encode(), raw_body, hashlib.sha256).hexdigest()
        return hmac.compare_digest(sig_header, expected)

    def do_GET(self):
        if self.path == "/status":
            running = is_task_running()
            pid = LOCK_FILE.read_text().strip() if running else None
            self.send_json(200, {
                "status": "ok",
                "task_running": running,
                "pid": pid,
                "port": PORT,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            })
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        raw_body = self.read_body()

        if self.path == "/task":
            if not self.verify_bearer():
                self.send_json(401, {"error": "unauthorized"})
                return
            try:
                data = json.loads(raw_body)
            except Exception:
                self.send_json(400, {"error": "invalid JSON"})
                return
            task = data.get("task", "").strip()
            if not task:
                self.send_json(400, {"error": "task field required"})
                return
            ok, msg = spawn_task(task, source="http")
            self.send_json(200 if ok else 503, {"ok": ok, "message": msg})

        elif self.path == "/github":
            if not self.verify_github_sig(raw_body):
                self.send_json(401, {"error": "invalid signature"})
                return
            event = self.headers.get("X-GitHub-Event", "ping")
            if event == "ping":
                self.send_json(200, {"ok": True, "message": "pong"})
                return
            try:
                payload = json.loads(raw_body)
            except Exception:
                self.send_json(400, {"error": "invalid JSON"})
                return
            task = github_to_task(event, payload)
            if not task:
                self.send_json(200, {"ok": True, "message": f"event '{event}' ignored"})
                return
            ok, msg = spawn_task(task, source=f"github/{event}")
            self.send_json(200 if ok else 503, {"ok": ok, "message": msg})

        else:
            self.send_json(404, {"error": "not found"})


# ─── Entry point ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    logging.info(f"Autopilot daemon starting on 127.0.0.1:{PORT}")

    server = HTTPServer(("127.0.0.1", PORT), DaemonHandler)

    def _shutdown(sig, frame):
        logging.info("Daemon shutting down")
        server.shutdown()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    print(f"Autopilot daemon listening on http://127.0.0.1:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    logging.info("Daemon stopped")
