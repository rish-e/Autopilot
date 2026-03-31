#!/usr/bin/env python3
"""
playbook.py — Dynamic Playbook Engine for Autopilot

Generator → Cache → Engine pattern:
  1. Check cache for existing playbook (disk YAML + memory.db metadata)
  2. If not found, generate a skeleton for the agent to fill in
  3. After successful execution, cache the playbook for reuse
  4. Track success/failure rates per playbook

Designed to work in BOTH modes:
  - Agent mode:  `python3 lib/playbook.py <command>` from Claude Code
  - Daemon mode:  `from lib.playbook import PlaybookEngine`

Playbook YAML files stored at: ~/MCPs/autopilot/playbooks/{service}/{flow}.yaml
Playbook metadata stored in:   ~/.autopilot/memory.db (playbooks table)
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import yaml

# ─── Configuration ───────────────────────────────────────────────────────────

AUTOPILOT_DIR = Path(os.environ.get(
    "AUTOPILOT_DIR",
    Path.home() / "MCPs" / "autopilot"
))
PLAYBOOKS_DIR = AUTOPILOT_DIR / "playbooks"
TEMPLATE_PATH = AUTOPILOT_DIR / "config" / "playbook-template.yaml"

PLAYBOOKS_DIR.mkdir(parents=True, exist_ok=True)

# Import memory store (same directory)
sys.path.insert(0, str(Path(__file__).parent))
from memory import AutopilotMemory

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[1;33m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
BOLD = "\033[1m"
DIM = "\033[2m"
NC = "\033[0m"


# ═════════════════════════════════════════════════════════════════════════════
# PlaybookEngine
# ═════════════════════════════════════════════════════════════════════════════

class PlaybookEngine:
    """Generate, cache, and manage browser automation playbooks.

    Usage:
        engine = PlaybookEngine()

        # Check if playbook exists
        pb = engine.get("vercel", "signup")

        # Generate skeleton for a new service
        skeleton = engine.generate("render", "signup",
            urls={"signup": "https://render.com/register"})

        # Save a playbook (after agent fills in steps)
        engine.save("render", "signup", playbook_dict)

        # Record execution result
        engine.record_run("render", "signup", success=True, duration_ms=15000)

        # List all cached playbooks
        engine.list_all()
    """

    def __init__(self, mem: AutopilotMemory = None):
        self.mem = mem or AutopilotMemory()
        self._owns_mem = mem is None  # track if we created it

    def close(self):
        if self._owns_mem:
            self.mem.close()

    # ════════════════════════════════════════════════════════════════════════
    # GET — check cache for existing playbook
    # ════════════════════════════════════════════════════════════════════════

    def get(self, service: str, flow: str) -> Optional[dict]:
        """Get a cached playbook. Returns None if not found.

        Checks disk YAML first, then memory.db metadata.
        """
        # Check disk
        yaml_path = PLAYBOOKS_DIR / service / f"{flow}.yaml"
        if yaml_path.exists():
            try:
                with open(yaml_path) as f:
                    return yaml.safe_load(f)
            except Exception:
                pass  # corrupt file, fall through

        # Check memory.db for file_path
        meta = self.mem.get_playbook(service, flow)
        if meta and meta.get("file_path"):
            fp = Path(meta["file_path"])
            if fp.exists():
                try:
                    with open(fp) as f:
                        return yaml.safe_load(f)
                except Exception:
                    pass

        return None

    def has(self, service: str, flow: str) -> bool:
        """Check if a playbook exists."""
        return self.get(service, flow) is not None

    # ════════════════════════════════════════════════════════════════════════
    # GENERATE — create a playbook skeleton
    # ════════════════════════════════════════════════════════════════════════

    def generate(self, service: str, flow: str,
                 urls: dict = None,
                 cli_info: dict = None,
                 extra_vars: dict = None) -> dict:
        """Generate a playbook skeleton for the agent to fill in.

        The agent calls this, then uses browser_snapshot to fill in
        actual selectors, URLs, and field mappings.

        Args:
            service:   Service name (e.g., "vercel", "render")
            flow:      Flow type: "signup", "login", "get_api_key", or custom
            urls:      Dict of known URLs for this service
            cli_info:  Dict with CLI details if available
            extra_vars: Additional template variables

        Returns:
            A playbook dict with pre-populated steps based on flow type.
        """
        now = datetime.now(timezone.utc).isoformat()

        playbook = {
            "service": service,
            "flow": flow,
            "version": 1,
            "generated_at": now,
            "last_verified": None,
            "config": {
                "timeout_ms": 30000,
                "retry_on_failure": True,
                "max_retries": 2,
                "screenshot_on_error": True,
                "cli_available": bool(cli_info),
                "cli_tool": cli_info.get("tool") if cli_info else None,
                "cli_install": cli_info.get("install") if cli_info else None,
                "prefer_cli": True,
            },
            "urls": urls or {
                "home": f"https://{service}.com",
                "signup": f"https://{service}.com/signup",
                "login": f"https://{service}.com/login",
                "dashboard": f"https://{service}.com/dashboard",
                "api_keys": f"https://{service}.com/settings/tokens",
            },
            "vars": {
                "email": "{{primary_email}}",
                "password": "{{primary_password}}",
                "username": "{{professional_primary}}",
            },
            "steps": [],
            "on_error": [
                {
                    "condition": "snapshot_contains:captcha",
                    "action": "escalate",
                    "level": 5,
                    "message": f"CAPTCHA detected on {service}",
                },
                {
                    "condition": "snapshot_contains:rate limit",
                    "action": "wait",
                    "duration_ms": 60000,
                    "then": "retry",
                },
                {
                    "condition": "element_not_found",
                    "action": "vision_fallback",
                },
                {
                    "condition": "timeout",
                    "action": "screenshot_and_escalate",
                },
            ],
            "on_success": [
                {
                    "action": "log",
                    "message": f"{flow} completed for {service}",
                },
            ],
        }

        if extra_vars:
            playbook["vars"].update(extra_vars)

        # Pre-populate steps based on flow type
        playbook["steps"] = self._generate_steps(service, flow, urls or {})

        return playbook

    def _generate_steps(self, service: str, flow: str, urls: dict) -> list:
        """Generate default steps based on flow type."""

        if flow == "signup":
            return [
                {
                    "id": "navigate_signup",
                    "action": "browser_navigate",
                    "params": {"url": urls.get("signup", f"https://{service}.com/signup")},
                    "expect": {"snapshot_contains": "sign up|create account|register|get started"},
                    "note": "AGENT: verify URL from research",
                },
                {
                    "id": "fill_email",
                    "action": "browser_type",
                    "params": {"field": "email", "text": "{{email}}"},
                    "note": "AGENT: update field ref from browser_snapshot",
                },
                {
                    "id": "fill_password",
                    "action": "browser_type",
                    "params": {"field": "password", "text": "{{password}}"},
                    "note": "AGENT: update field ref from browser_snapshot",
                },
                {
                    "id": "submit_signup",
                    "action": "browser_click",
                    "params": {"target": "submit/signup button"},
                    "note": "AGENT: update button ref from browser_snapshot",
                },
                {
                    "id": "check_result",
                    "action": "browser_snapshot",
                    "expect": {"one_of": ["dashboard", "verify your email", "welcome", "confirm"]},
                },
                {
                    "id": "handle_email_verification",
                    "action": "verify_email",
                    "params": {
                        "sender": f"noreply@{service}.com",
                        "timeout_ms": 120000,
                    },
                    "condition": "previous_contains:verify|confirm your email",
                },
            ]

        elif flow == "login":
            return [
                {
                    "id": "navigate_login",
                    "action": "browser_navigate",
                    "params": {"url": urls.get("login", f"https://{service}.com/login")},
                    "expect": {"snapshot_contains": "sign in|log in|email|password"},
                },
                {
                    "id": "fill_email",
                    "action": "browser_type",
                    "params": {"field": "email", "text": "{{email}}"},
                },
                {
                    "id": "fill_password",
                    "action": "browser_type",
                    "params": {"field": "password", "text": "{{password}}"},
                },
                {
                    "id": "submit_login",
                    "action": "browser_click",
                    "params": {"target": "sign in button"},
                },
                {
                    "id": "handle_2fa",
                    "action": "totp",
                    "params": {"service": service},
                    "condition": "snapshot_contains:verification code|two-factor|2fa|authenticator",
                },
                {
                    "id": "verify_logged_in",
                    "action": "browser_snapshot",
                    "expect": {"snapshot_contains": "dashboard|home|overview|settings"},
                },
            ]

        elif flow == "get_api_key":
            return [
                {
                    "id": "ensure_logged_in",
                    "action": "run_flow",
                    "params": {"flow": "login"},
                    "condition": "not_logged_in",
                },
                {
                    "id": "navigate_tokens",
                    "action": "browser_navigate",
                    "params": {"url": urls.get("api_keys", f"https://{service}.com/settings/tokens")},
                    "expect": {"snapshot_contains": "token|api key|access key"},
                    "note": "AGENT: update URL from research",
                },
                {
                    "id": "click_create",
                    "action": "browser_click",
                    "params": {"target": "create token/key button"},
                    "note": "AGENT: update button ref from browser_snapshot",
                },
                {
                    "id": "name_token",
                    "action": "browser_type",
                    "params": {"field": "token name", "text": "autopilot-{{timestamp}}"},
                    "condition": "snapshot_contains:name|label|description",
                },
                {
                    "id": "submit_create",
                    "action": "browser_click",
                    "params": {"target": "create/generate button"},
                },
                {
                    "id": "capture_token",
                    "action": "browser_snapshot",
                    "note": "AGENT: extract token value from snapshot text, store via keychain",
                },
                {
                    "id": "store_in_keychain",
                    "action": "keychain_set",
                    "params": {"service": service, "key": "api-token"},
                    "note": "AGENT: pass captured token value",
                },
            ]

        else:
            # Unknown flow — return empty steps for agent to fill
            return [
                {
                    "id": "step_1",
                    "action": "browser_navigate",
                    "params": {"url": f"https://{service}.com"},
                    "note": f"AGENT: research {service} {flow} flow and fill in steps",
                },
            ]

    # ════════════════════════════════════════════════════════════════════════
    # SAVE — cache a playbook to disk and memory.db
    # ════════════════════════════════════════════════════════════════════════

    def save(self, service: str, flow: str, playbook: dict,
             generated_by: str = "auto"):
        """Save a playbook to disk and register in memory.db."""
        # Ensure directory exists
        service_dir = PLAYBOOKS_DIR / service
        service_dir.mkdir(parents=True, exist_ok=True)

        # Write YAML
        yaml_path = service_dir / f"{flow}.yaml"
        with open(yaml_path, "w") as f:
            yaml.dump(playbook, f, default_flow_style=False, sort_keys=False,
                      allow_unicode=True, width=120)

        # Register in memory.db
        self.mem.register_playbook(service, flow, str(yaml_path), generated_by)

        return str(yaml_path)

    # ════════════════════════════════════════════════════════════════════════
    # RECORD — track execution results
    # ════════════════════════════════════════════════════════════════════════

    def record_run(self, service: str, flow: str,
                   success: bool, duration_ms: int = 0):
        """Record a playbook execution result."""
        self.mem.record_playbook_run(service, flow, success, duration_ms)

        # If the playbook succeeded, update last_verified
        if success:
            yaml_path = PLAYBOOKS_DIR / service / f"{flow}.yaml"
            if yaml_path.exists():
                try:
                    with open(yaml_path) as f:
                        pb = yaml.safe_load(f)
                    pb["last_verified"] = datetime.now(timezone.utc).isoformat()
                    with open(yaml_path, "w") as f:
                        yaml.dump(pb, f, default_flow_style=False,
                                  sort_keys=False, allow_unicode=True, width=120)
                except Exception:
                    pass  # non-critical

    # ════════════════════════════════════════════════════════════════════════
    # LIST — show all cached playbooks
    # ════════════════════════════════════════════════════════════════════════

    def list_all(self) -> list[dict]:
        """List all playbooks with metadata from memory.db."""
        rows = self.mem.db.execute("""
            SELECT service, flow, version, success_count, fail_count,
                   last_status, last_run_at, generated_by, file_path
            FROM playbooks
            ORDER BY service, flow
        """).fetchall()
        return [dict(r) for r in rows]

    def list_services(self) -> list[str]:
        """List services that have cached playbooks."""
        # Combine disk and DB
        services = set()

        # From disk
        if PLAYBOOKS_DIR.exists():
            for d in PLAYBOOKS_DIR.iterdir():
                if d.is_dir() and d.name != ".gitkeep":
                    services.add(d.name)

        # From DB
        rows = self.mem.db.execute(
            "SELECT DISTINCT service FROM playbooks"
        ).fetchall()
        for r in rows:
            services.add(r["service"])

        return sorted(services)

    def list_flows(self, service: str) -> list[str]:
        """List available flows for a service."""
        flows = set()

        # From disk
        service_dir = PLAYBOOKS_DIR / service
        if service_dir.exists():
            for f in service_dir.glob("*.yaml"):
                flows.add(f.stem)

        # From DB
        rows = self.mem.db.execute(
            "SELECT DISTINCT flow FROM playbooks WHERE service = ?", (service,)
        ).fetchall()
        for r in rows:
            flows.add(r["flow"])

        return sorted(flows)

    def get_stats(self) -> dict:
        """Get overall playbook statistics."""
        row = self.mem.db.execute("""
            SELECT
                COUNT(DISTINCT service) as services,
                COUNT(*) as total_playbooks,
                SUM(success_count) as total_successes,
                SUM(fail_count) as total_failures
            FROM playbooks
        """).fetchone()
        return dict(row) if row else {}


# ═════════════════════════════════════════════════════════════════════════════
# CLI Interface
# ═════════════════════════════════════════════════════════════════════════════

def cli_list(engine: PlaybookEngine):
    playbooks = engine.list_all()
    if not playbooks:
        print("No playbooks cached yet.")
        print(f"\nPlaybook directory: {PLAYBOOKS_DIR}")
        print("Generate one: python3 playbook.py generate <service> <flow>")
        return

    print(f"{BOLD}Cached Playbooks{NC}")
    print()
    current_service = ""
    for pb in playbooks:
        if pb["service"] != current_service:
            current_service = pb["service"]
            print(f"  {BOLD}{current_service}{NC}")

        total = (pb["success_count"] or 0) + (pb["fail_count"] or 0)
        if total > 0:
            rate = (pb["success_count"] or 0) / total * 100
            status = f"runs={total} rate={rate:.0f}%"
        else:
            status = "never run"

        gen = pb.get("generated_by", "auto")
        print(f"    {pb['flow']:20s}  v{pb['version']}  {status:20s}  ({gen})")


def cli_get(engine: PlaybookEngine, service: str, flow: str):
    pb = engine.get(service, flow)
    if pb:
        print(yaml.dump(pb, default_flow_style=False, sort_keys=False,
                        allow_unicode=True, width=120))
    else:
        print(f"No playbook found for {service}/{flow}", file=sys.stderr)
        print(f"\nGenerate one: python3 playbook.py generate {service} {flow}",
              file=sys.stderr)
        sys.exit(1)


def cli_generate(engine: PlaybookEngine, service: str, flow: str):
    # Check if already exists
    existing = engine.get(service, flow)
    if existing:
        print(f"Playbook already exists for {service}/{flow} (v{existing.get('version', '?')})",
              file=sys.stderr)
        print(f"Use 'get' to view it, or delete the file to regenerate.",
              file=sys.stderr)
        sys.exit(1)

    # Generate skeleton
    pb = engine.generate(service, flow)

    # Save to disk
    path = engine.save(service, flow, pb, generated_by="cli")

    print(f"{GREEN}Generated{NC}: {path}")
    print()
    print(f"Steps ({len(pb['steps'])} pre-populated for '{flow}' flow):")
    for step in pb["steps"]:
        note = f"  {DIM}← {step['note']}{NC}" if step.get("note") else ""
        print(f"  {step['id']:30s}  {step['action']}{note}")
    print()
    print(f"Next: edit the YAML to fill in actual selectors from browser_snapshot")


def cli_stats(engine: PlaybookEngine):
    stats = engine.get_stats()
    print(f"{BOLD}Playbook Stats{NC}")
    print(f"  Services:    {stats.get('services', 0) or 0}")
    print(f"  Playbooks:   {stats.get('total_playbooks', 0) or 0}")
    print(f"  Successes:   {stats.get('total_successes', 0) or 0}")
    print(f"  Failures:    {stats.get('total_failures', 0) or 0}")
    print(f"  Directory:   {PLAYBOOKS_DIR}")


def cli_services(engine: PlaybookEngine):
    services = engine.list_services()
    if not services:
        print("No services with playbooks yet.")
        return
    print(f"{BOLD}Services with Playbooks{NC}")
    for svc in services:
        flows = engine.list_flows(svc)
        print(f"  {svc:20s}  flows: {', '.join(flows)}")


def main():
    usage = f"""Usage: python3 playbook.py <command> [args]

Commands:
  list                          List all cached playbooks
  get <service> <flow>          Show a playbook's YAML
  generate <service> <flow>     Generate a playbook skeleton
  services                      List services with playbooks
  stats                         Show playbook statistics
  has <service> <flow>          Check if playbook exists (exit 0/1)

Examples:
  python3 playbook.py generate vercel signup
  python3 playbook.py get vercel signup
  python3 playbook.py list
"""

    if len(sys.argv) < 2:
        print(usage)
        sys.exit(1)

    engine = PlaybookEngine()
    cmd = sys.argv[1]

    try:
        if cmd == "list":
            cli_list(engine)
        elif cmd == "get":
            if len(sys.argv) < 4:
                print("Usage: playbook.py get <service> <flow>", file=sys.stderr)
                sys.exit(1)
            cli_get(engine, sys.argv[2], sys.argv[3])
        elif cmd == "generate":
            if len(sys.argv) < 4:
                print("Usage: playbook.py generate <service> <flow>", file=sys.stderr)
                sys.exit(1)
            cli_generate(engine, sys.argv[2], sys.argv[3])
        elif cmd == "services":
            cli_services(engine)
        elif cmd == "stats":
            cli_stats(engine)
        elif cmd == "has":
            if len(sys.argv) < 4:
                print("Usage: playbook.py has <service> <flow>", file=sys.stderr)
                sys.exit(1)
            sys.exit(0 if engine.has(sys.argv[2], sys.argv[3]) else 1)
        else:
            print(f"Unknown command: {cmd}", file=sys.stderr)
            print(usage, file=sys.stderr)
            sys.exit(1)
    finally:
        engine.close()


if __name__ == "__main__":
    main()
