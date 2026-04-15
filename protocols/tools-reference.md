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
7. Save backup codes if provided (one per line via stdin):
   `echo -e "code1\ncode2\ncode3..." | ~/MCPs/autopilot/bin/totp.sh backup-store {service}`
8. Verify backup codes were stored: `~/MCPs/autopilot/bin/totp.sh backup-count {service}`

**When logging into a service that requires 2FA:**
1. After entering email/password, detect the 2FA prompt via `browser_snapshot`
2. Check if TOTP seed exists: `~/MCPs/autopilot/bin/totp.sh has {service}`
3. If yes: `CODE=$(~/MCPs/autopilot/bin/totp.sh generate {service})` → enter in form
4. If TOTP fails (wrong code): try a backup code: `CODE=$(~/MCPs/autopilot/bin/totp.sh backup-use {service})`
5. If no seed AND no backup codes: **ESCALATE** to user (L3) — "Enter the 6-digit code from your authenticator app"

**Backup code monitoring:**
- Check status across all services: `~/MCPs/autopilot/bin/totp.sh backup-status`
- Alerts automatically when < 3 codes remaining
- Critical alert when all codes exhausted — prompt user to regenerate

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
- `python3 ~/MCPs/autopilot/lib/memory.py skills` — mature procedures (3+ successes, >80% rate) usable as building blocks
- `python3 ~/MCPs/autopilot/lib/memory.py errors` — known error patterns and fixes (auto-fingerprinted)
- `python3 ~/MCPs/autopilot/lib/memory.py services` — cached service metadata
- `python3 ~/MCPs/autopilot/lib/memory.py costs` — token usage and cost breakdown
- `python3 ~/MCPs/autopilot/lib/memory.py health` — service health check results
- `python3 ~/MCPs/autopilot/lib/memory.py estimate-cost "{task}" --services "{svc}"` — predict cost before executing

**Procedural Memory — Recording (after every successful multi-step task):**
After completing a task, record the pattern for future reuse:
```bash
python3 ~/MCPs/autopilot/lib/memory.py save-procedure "{name}" "{task_description}" '{steps_json}' --services "{service1},{service2}"
```

**Procedural Memory — Retrieval (before starting any task):**
Before planning a complex task, check if a similar procedure exists:
```bash
python3 ~/MCPs/autopilot/lib/memory.py find-procedure "{task_description}"
```
If a high-confidence match exists (success_rate > 80%, success_count > 2), follow that procedure instead of reasoning from scratch.

**Error Memory — Recording (on every failure):**
```bash
python3 ~/MCPs/autopilot/lib/memory.py log-error "{error_type}" "{normalized_error_pattern}" --service "{service}" --resolution "{what_fixed_it}"
```

**Error Memory — Preemptive Check (before executing commands):**
Before running a command for a service where errors have occurred before:
```bash
python3 ~/MCPs/autopilot/lib/memory.py check-error "{error_message}" --service "{service}"
```
If a known fix exists, apply it preemptively before the error occurs again.

### Structured Audit Log

Use `~/MCPs/autopilot/bin/audit.sh` for tamper-evident logging with SHA-256 hash chain.

**Log an action (do this for EVERY action during a task):**
```bash
~/MCPs/autopilot/bin/audit.sh log "{action}" --level {1-5} --service {service} --result {result} --session "{session_name}"
```

**View entries:**
- `~/MCPs/autopilot/bin/audit.sh show [N]` — last N entries (default 20)
- `~/MCPs/autopilot/bin/audit.sh search {term}` — search all entries
- `~/MCPs/autopilot/bin/audit.sh accounts` — credential/account activity
- `~/MCPs/autopilot/bin/audit.sh failures` — failed actions only
- `~/MCPs/autopilot/bin/audit.sh summary` — one-line-per-session overview

**Integrity:**
- `~/MCPs/autopilot/bin/audit.sh verify` — verify hash chain (tamper detection)

**Export:**
- `~/MCPs/autopilot/bin/audit.sh export markdown` — Markdown table format
- `~/MCPs/autopilot/bin/audit.sh export csv` — CSV format

The audit log is stored at `{project}/.autopilot/audit.jsonl` (JSONL format). Each entry contains a `prev_hash` field linking to the SHA-256 of the previous entry, forming a tamper-evident chain.

### Credential TTL

**Check credential age:**
- `~/MCPs/autopilot/bin/keychain.sh age {service} {key}` — show days since stored
- `~/MCPs/autopilot/bin/keychain.sh check-ttl [max-days]` — show stale credentials (default: 90 days)
- `~/MCPs/autopilot/bin/harvest.sh age [max-days]` — shortcut for TTL report

TTL metadata is stored in `~/MCPs/autopilot/config/credential-ttl/` as simple date files. Updated automatically on every `keychain.sh set`.

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
5. If a step fails: check error memory for known fix, retry with alternative selectors from browser_snapshot, update the playbook if selectors changed

**Playbook step format** — each step has an `intent` field describing what the step is trying to achieve:
```yaml
- id: fill_email
  intent: "Enter account email address"
  action: browser_type
  params: {field: email, text: "{{email}}"}
```
The `intent` enables the agent to find alternative approaches when the specific action fails.

**Wait/timing healing:**
`python3 ~/MCPs/autopilot/lib/playbook.py heal-timing {service} {flow} {step_id} {actual_ms} {success}`
Tracks actual wait durations and auto-adjusts timeouts to p90 * 1.5x of successful waits.

### Procedure Learning v2

`python3 ~/MCPs/autopilot/lib/memory.py` — enhanced procedure commands:

**Save with summary (two-tier discovery):**
```bash
python3 ~/MCPs/autopilot/lib/memory.py save-procedure "deploy_vercel" \
  "Deploy Next.js app to Vercel" '[...]' \
  --services vercel --summary "Deploy to Vercel with env vars"
```

**View deprecated procedures:**
`python3 ~/MCPs/autopilot/lib/memory.py deprecated`

**Manually deprecate:**
`python3 ~/MCPs/autopilot/lib/memory.py deprecate "old_proc" --reason "replaced by new_proc"`

**Detect meta-procedures (shared step patterns):**
`python3 ~/MCPs/autopilot/lib/memory.py meta-procedures --min-shared 3`

**Auto-deprecation:** Procedures are automatically deprecated after 3 consecutive failures.
Re-saving a procedure clears deprecation and resets the failure counter.

### Service Registry

Service registries live at `~/MCPs/autopilot/services/`. Each file has YAML frontmatter with structured metadata:
```yaml
---
name: "Vercel"
category: "deployment"
auth_pattern: "token-flag"
2fa: "email"
mcp: "installable"
cli: "vercel"
decision_levels:
  read: 1
  preview: 2
  production: 3
  delete: 4
---
```

Quick-reference index: `~/MCPs/autopilot/services/INDEX.md`

### Preflight System (v2)

`~/MCPs/autopilot/bin/preflight.sh` — runs 8 parallel health checks at session start.

**Commands:**
- `preflight.sh` — run all checks (human-readable output)
- `preflight.sh --json` — JSON output only
- `preflight.sh fingerprint` — environment fingerprint (OS, arch, tools, CLIs)
- `preflight.sh status` — credential status check
- `preflight.sh setup` — interactive first-time credential setup
- `preflight.sh --skip` — skip checks (for CI/CD)

Results are cached for 5 minutes in `config/preflight.cache`.
