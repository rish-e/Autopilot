# Changelog

All notable changes to Autopilot are documented here.

---

## [3.6] — 2026-04-29 — Browser Navigation Fix

### Fixed

**`open` vs `browser_navigate` confusion** — autopilot was using `Bash: open "https://..."` to navigate to pages it then needed to interact with. The macOS `open` command opens the URL in the user's default browser (no CDP connection), so Playwright has no handle on the page and cannot click or read anything.

**`protocols/browser-automation.md`** — added a prominent "Critical Rule" table at the top of the Browser Automation Steps section:
- `open "url"` → user's default browser, no Playwright connection, **cannot interact**
- `browser_navigate` → Playwright-controlled Chrome via CDP, **can interact**
- Rule: if you need to click, fill, snapshot, or read the page → use `browser_navigate`; `open` is only for surfacing a URL to the user with no further automation

**`~/.claude/agents/autopilot.md`** — added explicit inline warning in Service Interaction Priority step 5 (Browser Automation): never use `Bash: open`, always use `browser_navigate`

**`commands/autopilot.md`** — same rule added to the browser navigation rule in the Rules section

---

## [3.5] — 2026-04-21 — Parallelism, Sandbox Allowlist, Budget Config, Chrome Status

Four targeted fixes wired end-to-end.

### Added

**`bin/sandbox-allowlist.sh`** — append-only domain manager for the Claude Code sandbox network allowlist:
- `add <domain>` — validates domain format (rejects shell injection), appends to `settings.json` idempotently
- `list` — print all allowed domains sorted
- `has <domain>` — exit 0 if present, 1 if not
- Called automatically by `self-expansion.md` step 9.5 after new service registry creation

**`config/budget.conf`** — per-project spend cap overrides:
- Sourced by `budget.sh` at runtime via `source`
- Commented-out defaults for `MAX_SIGNUPS`, `MAX_COST_USD`, `MAX_TOOL_CALLS`, `WARN_COST_USD`, `WARN_SIGNUPS`
- Lets projects raise/lower limits without editing `budget.sh`

### Changed

**`bin/budget.sh`** — two improvements:
- Loads `config/budget.conf` overrides via `source` (after setting defaults)
- Halt messages now include explicit recovery instruction: `session.sh save "budget halt — <reason>"` + start new session. Previously the agent had no actionable path forward on budget halt.

**`bin/preflight.sh`** — `check_chrome()` added to the parallel health-check block:
- Reports Chrome status on port 9222 (running with version, or not running)
- Never auto-starts Chrome — start-on-demand is handled by `browser-automation.md`
- Both states report `status: ok` — "not running" is normal, not a failure

**`protocols/self-expansion.md`** — two updates:
- Step 9.5: call `sandbox-allowlist.sh add <api-domain>` after creating service registry and guardian rules
- "Cannot do" list: clarified that `sandbox-allowlist.sh add` is the permitted path for network allowlist additions; direct settings.json edits still prohibited

**`~/.claude/agents/autopilot.md`** — Flow B step 2 and 7 updated:
- Step 2: explicitly identify parallel groups during analysis; read `parallel-execution.md` for wave-based pattern
- Step 3: mark independent steps as `[parallel wave N]` in the plan
- Step 7: launch parallel waves using Agent tool with lockfile.sh coordination
- Key Paths: added `sandbox-allowlist.sh` and `budget.conf`

---

## [3.4] — 2026-04-20 — Webhook Daemon

Event-driven task triggering: Autopilot can now be woken by GitHub webhooks, direct HTTP calls, or any system that can POST JSON.

### Added

**`bin/daemon-server.py`** — lightweight Python HTTP server (127.0.0.1:7891):
- `GET /status` — health check; reports `task_running` + PID
- `POST /task` — generic trigger authenticated with Bearer token
- `POST /github` — GitHub webhook handler with HMAC-SHA256 signature verification
- Translates four GitHub events into autopilot tasks automatically:
  - `push` to main/master → deploy check
  - `pull_request` merged → run deployment pipeline
  - `workflow_run` failure → investigate and fix
  - `issues` labeled `autopilot` → complete the described task
- PID-based lock file prevents concurrent task execution
- Sanitizes task strings (strips shell metacharacters) before passing to `claude --agent autopilot`

**`bin/daemon.sh`** — lifecycle manager:
- `start` — spawns daemon-server.py in background, loads secret from keychain
- `stop` — SIGTERM with 5s grace period before SIGKILL
- `status` — PID check + live `/status` curl
- `logs [N]` — tail `~/.autopilot/daemon.log`
- `trigger "task"` — POST a one-off task via HTTP with Bearer auth
- `setup` — generate 32-byte hex secret, store in keychain, print GitHub webhook config

---

## [3.3] — 2026-04-20 — Security Hardening

Full security audit against 35 principles from OWASP LLM Top 10 v2, Willison's lethal trifecta, Greshake et al. (arXiv:2302.12173), Invariant Labs MCP research, and community incident reports. Result: 7 new defenses, 0 capability regressions.

### Added

**Guardian new categories:**
- `SUPPLY_CHAIN` — blocks `pip install` from HTTP URLs and non-PyPI indexes
- `SECRET_EXFIL` — detects hardcoded AWS/OpenAI/GitHub/Anthropic/Slack keys in network commands; only keychain subshell expansion is legitimate
- `LOOP` — halts session if the same Bash command repeats 3× (stuck-agent guard), keyed to the stable Claude process PID

**Memory integrity:**
- SHA256 `content_hash` stored on every `save_procedure` call
- Hash verified on every `find_procedure` / `get_skill` call
- Tampered procedures auto-quarantined and deprecated (prevents cross-session memory poisoning)
- Idempotent `_migrate()` adds columns to existing databases

**Session hardening:**
- `bin/content-sanitizer.sh` — wraps all external web/tool output in `[UNTRUSTED_CONTENT]` delimiters; scans for 22 injection patterns, strips zero-width chars, detects large base64 blocks
- `bin/budget.sh` — per-session spend cap: 5 signups / $20 / 500 tool calls; `preflight.sh` calls `budget.sh init` at every session start
- `.claude/settings.json` — Claude Code sandbox config: `denyRead` on credential dirs (`~/.ssh`, `~/.aws`, etc.), network allowlist at kernel level

**MCP rug-pull detection:**
- `config/mcp-tool-manifest.json` — trusted `mcp__` tool name prefixes
- Guardian warns on any MCP tool call whose prefix isn't in the manifest
- `bin/mcp-manifest-check.sh` — standalone hook for non-autopilot sessions

**Ephemeral browser profiles:**
- `chrome-debug.sh ephemeral-start [task-id]` — fresh Chrome profile in `/tmp`, port 9223
- `chrome-debug.sh ephemeral-stop` — kills browser and wipes profile (no trace)
- Used for: signups, OAuth flows, cross-service tasks

**Agent identity & drift:**
- `preflight.sh` writes `~/.autopilot/gitconfig` (`user.name = autopilot-bot`) on first run; agent commits with `GIT_CONFIG_GLOBAL=~/.autopilot/gitconfig`
- Goal drift checkpoint: re-read original task every 10 Bash calls, course-correct if drifted
- ToS review step 5.5 in self-expansion: scan ToS before registering any new service
- `tos_automated` field added to service registry template

---

## [3.2] — 2026-04-15 — AppleScript GUI Automation (macOS)

### Added
- `bin/osascript.sh` — safe AppleScript runner with path traversal protection, 30s timeout, structured exit codes
- `applescripts/frontmost-info.applescript` — active app JSON (name, bundle ID, window title, PID)
- `applescripts/app-control.applescript` — open / focus / quit / status / relaunch apps
- `applescripts/clipboard.applescript` — read / write / clear clipboard
- `applescripts/handle-system-dialog.applescript` — click named buttons on sheets and dialogs
- Guardian Category 10 (APPLESCRIPT): blocks inline `osascript -e`, JXA, non-whitelisted paths
- `protocols/gui-automation.md` — when to use AppleScript vs Playwright vs Computer Use
- Service interaction priority updated: AppleScript sits between Playwright and Computer Use

---

## [3.1] — 2026-04-10 — Compiler, Parallel Agents, Sandbox, Compression

### Added
- `bin/guardian-compile.sh` — YAML → compiled rules cache with validation
- `bin/lockfile.sh` — file-based lock coordinator for parallel agent execution
- `bin/mcp-compress.sh` — wraps MCP servers for ~97% schema token savings
- `protocols/sandboxing.md` — macOS sandbox-exec profiles for L3+ operations
- `protocols/parallel-execution.md` — splitting multi-service plans into parallel groups

---

## [3.0] — 2026-04-05 — Fully Autonomous

### Changed
- Decision framework collapsed from 5 levels to 3 (L1/L2/L3)
- L1: everything that was L1-L3 before — just do it
- L2: flag cost but keep going
- L3: escalate (2FA, CAPTCHA only)
- No more "ask first" level — agent acts on all non-destructive operations

### Added
- `bin/repo-context.sh` — cached project summary for fast codebase onboarding
- `protocols/model-routing.md` — delegate to Haiku/Sonnet when Opus not needed
- `protocols/review-gate.md` — cross-model review gate for L3+ operations

---

## [2.0] — 2026-03-25 — Sprint 1: Memory, TOTP, Email

### Added
- `lib/memory.py` — unified SQLite memory store (traces, procedures, errors, services, costs, health)
- `lib/playbook.py` — browser automation playbook store
- `bin/totp.sh` — TOTP code generator (2FA automation)
- `bin/verify-email.sh` — email verification link extractor
- `bin/token-report.sh` — token savings dashboard
- `bin/harvest.sh` — credential harvester from service dashboards
- `bin/audit.sh` — execution log terminal dashboard
- `bin/snapshot.sh` — snapshot & rollback (git stash wrapper)
- `bin/session.sh` — session persistence (save/resume across rate limits)
- Voyager-style skill composition — procedures become reusable skills after 3+ successes

---

## [1.0] — 2026-03-10 — Initial Release

### Added
- `bin/guardian.sh` — PreToolUse safety hook (autopilot-scoped, 55 tested patterns)
- `bin/keychain.sh` — cross-platform credential store (macOS Keychain / libsecret / Credential Manager)
- `bin/chrome-debug.sh` — persistent Chrome manager with CDP
- `bin/preflight.sh` — session startup checks and credential validation
- `bin/setup-clis.sh` — automated CLI installer
- `bin/notify.sh` — Telegram notification integration
- `agent/autopilot.md` — full agent definition with decision framework
- `config/trusted-mcps.yaml` — MCP whitelist (20+ pre-vetted servers)
- `services/` — service registry (Vercel, Supabase, Stripe, Cloudflare, GitHub + template)
- `protocols/` — adaptive resolution, credential management, browser automation, self-expansion
- `/autopilot` slash command integration
