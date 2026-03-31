# Protocol: Tools Reference
# Loaded on-demand by Autopilot when needed. Not part of the core prompt.
# Location: ~/MCPs/autopilot/protocols/tools-reference.md

## Sprint 1 Tools — New Capabilities

### TOTP / 2FA Code Generation

Use `~/MCPs/autopilot/bin/totp.sh` for all 2FA operations.

**When setting up 2FA on a new service:**
1. During browser automation, detect the TOTP setup page (look for QR code or "manual entry" link)
2. Click "manual entry" or "can't scan QR code" to reveal the base32 seed
3. Capture the seed text from the page via `browser_snapshot`
4. Store it: `echo "THE_SEED" | ~/MCPs/autopilot/bin/totp.sh store {service}`
5. Generate the initial code: `CODE=$(~/MCPs/autopilot/bin/totp.sh generate {service})`
6. Enter the code in the verification field via `browser_type`
7. Save backup codes if provided: `echo "codes..." | ~/MCPs/autopilot/bin/keychain.sh set {service} backup-codes`

**When logging into a service that requires 2FA:**
1. After entering email/password, detect the 2FA prompt via `browser_snapshot`
2. Check if TOTP seed exists: `~/MCPs/autopilot/bin/totp.sh has {service}`
3. If yes: `CODE=$(~/MCPs/autopilot/bin/totp.sh generate {service})` → enter in form
4. If no: **ESCALATE** to user (Level 5) — "Enter the 6-digit code from your authenticator app"

### Email Verification Flow

Use `~/MCPs/autopilot/bin/verify-email.sh` + Gmail MCP during signup flows.

**When a service sends a verification email:**
1. Note the service's noreply sender address (visible on the signup page or common pattern like `noreply@{service}.com`)
2. Generate search query: `~/MCPs/autopilot/bin/verify-email.sh query --from "noreply@service.com" --subject "verify" --minutes 5`
3. Wait 15-30 seconds for email delivery
4. Search Gmail: call `mcp__claude_ai_Gmail__gmail_search_messages` with the query string and `maxResults: 3`
5. If no results, wait 20 seconds and retry (up to 3 retries total)
6. Read the email: call `mcp__claude_ai_Gmail__gmail_read_message` with the messageId from search
7. Extract verification:
   - For codes: `echo "$EMAIL_BODY" | ~/MCPs/autopilot/bin/verify-email.sh parse --type code`
   - For links: `echo "$EMAIL_BODY" | ~/MCPs/autopilot/bin/verify-email.sh parse --type link`
8. If code: enter it in the browser form via `browser_type`
9. If link: navigate to it with `browser_navigate`
10. `browser_snapshot` to verify success

### Terminal Notifications

Use `~/MCPs/autopilot/bin/notify.sh` for status updates. Currently outputs to terminal; will support push notifications when configured.

**When to notify:**
- Task completion: `~/MCPs/autopilot/bin/notify.sh send --message "Done: {summary}" --tag "white_check_mark"`
- Task failure: `~/MCPs/autopilot/bin/notify.sh send --message "Failed: {error}" --priority high --tag "x"`
- Account created: `~/MCPs/autopilot/bin/notify.sh send --message "Created account on {service}" --tag "key"`
- Credential acquired: `~/MCPs/autopilot/bin/notify.sh send --message "Token stored for {service}" --tag "lock"`

Check if a channel is configured before sending: `~/MCPs/autopilot/bin/notify.sh channels`

### Memory Store

Use `python3 ~/MCPs/autopilot/lib/memory.py` for persistent intelligence across sessions.

**View current state:**
- `python3 ~/MCPs/autopilot/lib/memory.py stats` — overview of all tables
- `python3 ~/MCPs/autopilot/lib/memory.py runs` — recent task executions
- `python3 ~/MCPs/autopilot/lib/memory.py procedures` — learned reusable patterns
- `python3 ~/MCPs/autopilot/lib/memory.py errors` — known error patterns and fixes
- `python3 ~/MCPs/autopilot/lib/memory.py services` — cached service metadata
- `python3 ~/MCPs/autopilot/lib/memory.py costs` — token usage and cost breakdown
- `python3 ~/MCPs/autopilot/lib/memory.py health` — service health check results

**Procedural Memory — Recording (after every successful multi-step task):**
After completing a task, record the pattern for future reuse by writing a Python snippet:
```python
python3 -c "
import sys; sys.path.insert(0, '$HOME/MCPs/autopilot/lib')
from memory import AutopilotMemory
mem = AutopilotMemory()
mem.save_procedure('{name}', '{task_description}',
    [{step_dicts}], services=['{service1}', '{service2}'])
mem.close()
"
```

**Procedural Memory — Retrieval (before starting any task):**
Before planning a complex task, check if a similar procedure exists:
```python
python3 -c "
import sys, json; sys.path.insert(0, '$HOME/MCPs/autopilot/lib')
from memory import AutopilotMemory
mem = AutopilotMemory()
results = mem.find_procedure(task_desc='{task_description}')
for r in results:
    print(f\"{r['name']}: {r['success_count']} successes, rate={r.get('success_rate', 0):.0%}\")
    print(f\"  Steps: {r['steps_json'][:200]}\")
mem.close()
"
```
If a high-confidence match exists (success_rate > 80%, success_count > 2), follow that procedure instead of reasoning from scratch.

**Error Memory — Recording (on every failure):**
```python
python3 -c "
import sys; sys.path.insert(0, '$HOME/MCPs/autopilot/lib')
from memory import AutopilotMemory
mem = AutopilotMemory()
mem.log_error('{error_type}', '{normalized_error_pattern}',
    service='{service}', resolution='{what_fixed_it}')
mem.close()
"
```

**Error Memory — Preemptive Check (before executing commands):**
Before running a command for a service where errors have occurred before:
```python
python3 -c "
import sys; sys.path.insert(0, '$HOME/MCPs/autopilot/lib')
from memory import AutopilotMemory
mem = AutopilotMemory()
match = mem.check_known_error('{error_message}', service='{service}')
if match: print(f\"Known fix: {match['resolution']}\")
else: print('No known fix')
mem.close()
"
```
If a known fix exists, apply it preemptively before the error occurs again.

### Dynamic Playbook Engine

Use `python3 ~/MCPs/autopilot/lib/playbook.py` for browser automation playbooks.

**Check if playbook exists:**
`python3 ~/MCPs/autopilot/lib/playbook.py has {service} {flow}` (exit 0 = exists)

**View a playbook:**
`python3 ~/MCPs/autopilot/lib/playbook.py get {service} {flow}`

**Generate a new playbook skeleton:**
`python3 ~/MCPs/autopilot/lib/playbook.py generate {service} {flow}`
This creates a YAML file with pre-populated steps at `~/MCPs/autopilot/playbooks/{service}/{flow}.yaml`.
The steps contain placeholder selectors marked with "AGENT:" notes.
After generating, use `browser_navigate` + `browser_snapshot` to fill in actual selectors from the live page.

**List all cached playbooks:**
`python3 ~/MCPs/autopilot/lib/playbook.py list`

**When browser automation is needed for any service:**
1. Check: `python3 ~/MCPs/autopilot/lib/playbook.py has {service} {flow}`
2. If exists: load it with `get`, execute steps sequentially with `browser_snapshot` verification after each
3. If not: `generate` a skeleton, navigate to the page, fill in selectors from snapshot, execute, then the playbook auto-saves to cache
4. After successful execution: the playbook is cached and reused next time — no research needed
5. If a step fails: check error memory for known fix, try Computer Use vision fallback, update the playbook if selectors changed
