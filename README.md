<p align="center">
  <img src="https://img.shields.io/badge/Claude_Code-Agent-blueviolet?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxwYXRoIGQ9Ik0xMiAyQzYuNDggMiAyIDYuNDggMiAxMnM0LjQ4IDEwIDEwIDEwIDEwLTQuNDggMTAtMTBTMTcuNTIgMiAxMiAyem0wIDE4Yy00LjQyIDAtOC0zLjU4LTgtOHMzLjU4LTggOC04IDggMy41OCA4IDgtMy41OCA4LTggOHoiLz48L3N2Zz4=&logoColor=white" alt="Claude Code Agent" />
  <img src="https://img.shields.io/badge/Platform-macOS_|_Linux_|_Windows-success?style=for-the-badge" alt="Cross-platform" />
  <img src="https://img.shields.io/badge/Safety-Guardian_Hook-red?style=for-the-badge" alt="Guardian" />
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="MIT License" />
  <img src="https://img.shields.io/badge/Tests-55_passing-brightgreen?style=for-the-badge" alt="Tests" />
  <img src="https://img.shields.io/badge/Security_Audit-35_Principles-orange?style=for-the-badge" alt="Security" />
</p>

<h1 align="center">Autopilot</h1>

<p align="center">
  <strong>The first self-expanding autonomous coding agent with hard safety rails.</strong>
</p>

<p align="center">
  <em>Fully autonomous &bull; Self-expanding &bull; Browser automation &bull; Cross-platform &bull; Hard safety rails &bull; 35-principle security audit</em>
</p>

---

> AI coding agents today are either autonomous but unsafe (Devin, Cursor — sandbox-only safety) or safe but constantly asking for permission (vanilla Claude Code). Autopilot is the third option: fully autonomous, with a deterministic safety layer the AI cannot override, and it teaches itself new services as it encounters them.

<br>

<details>
<summary><b>See it in action</b> (click to expand)</summary>
<br>

```
claude --agent autopilot
> Set up Supabase for this project with user auth, deploy to Vercel, and configure Razorpay payments.

Autopilot: Here's the plan:
  1. Install Supabase CLI
  2. Sign up & create project
  3. Run migrations (users, api_keys, usage_logs)
  4. Install Vercel CLI & deploy to preview
  5. Set environment variables from Supabase
  6. Get Razorpay API keys (needs 2FA)
  7. Configure webhook

Proceed? yes

[1/7] Supabase CLI installed via brew
[2/7] Signed up at supabase.com .................. ACCOUNT CREATED
[3/7] Migrations complete — 3 tables created
[4/7] Deploying to preview ....................... https://myapp-abc123.vercel.app
[5/7] Environment variables set from Supabase
[6/7] Opening Razorpay dashboard... "Enter the OTP sent to your phone."
> [user enters OTP]
[7/7] Razorpay keys stored, webhook configured

Done. Preview: https://myapp-abc123.vercel.app
All actions logged to .autopilot/log.md
```

</details>

---

## What Can It Do?

Autopilot is a **general-purpose autonomous agent** — not limited to any specific service or workflow:

| Category | Examples |
|:---------|:---------|
| **Deploy code** | Vercel, Netlify, Railway, Cloudflare Workers, Fly.io |
| **Set up databases** | Supabase, PostgreSQL, Firebase, Redis |
| **Manage infrastructure** | R2 buckets, KV stores, DNS, SSL, CDN |
| **Configure services** | Stripe, Razorpay, SendGrid, Resend, Sentry, Auth0, Clerk |
| **Handle git** | Commits, branches, PRs, issues, Actions, releases |
| **Browse the web** | Login to dashboards, fill forms, get API tokens |
| **Control native apps** | Open/focus/quit macOS apps, click dialogs, read/write clipboard (AppleScript) |
| **Install tools** | CLIs, MCP servers, dependencies |
| **Teach itself** | Unknown service? Researches docs, creates registry, installs CLI, keeps going |

The 5 pre-built service files are just a head start. Autopilot self-expands when it encounters anything new.

---

## How It Works

```
  You give a task
       |
       v
  +--------------------------+
  |    Autopilot Agent       |      Reads: decision framework,
  |    Plan > Confirm >      |      service registry, MCP whitelist
  |    Execute All           |
  +--------------------------+
       |
       +----------+----------+-----------+
       |          |          |           |
       v          v          v           v
  +--------+ +--------+ +--------+ +---------+
  |  MCP   | |  CLI   | |  API   | | Browser |
  | Tools  | | Tools  | | (curl) | |  (CDP)  |
  +--------+ +--------+ +--------+ +---------+
       |          |          |           |
       +----------+----------+-----------+
       |                                 |
       v                                 v
  +--------------------------+  +--------------------------+
  |   Credential Store       |  |   Guardian Hook          |
  |   (OS-native encrypted)  |  |   (blocks dangerous      |
  |                          |  |    commands before they   |
  |   macOS Keychain         |  |    execute)               |
  |   Linux: libsecret       |  |                          |
  |   Windows: Cred Manager  |  |   55 tested patterns     |
  +--------------------------+  +--------------------------+
```

**Priority:** MCP > CLI > API > Browser > **AppleScript** > Computer Use > Ask user

---

## Features

### Fully Autonomous
> Autopilot acts first, asks only when the decision framework says to. It deploys code, configures databases, manages infrastructure, and obtains credentials — all without you leaving the terminal.

### Plan > Confirm > Execute All
> For complex tasks: numbered plan, single "proceed", then runs every step without pausing. Simple tasks execute immediately. **Never stops to ask "what next?"**

### Project-Local Execution Log
> Every action logged to `{project}/.autopilot/log.md` — timestamped, with decision level and result. Account creations, logins, and token acquisitions are tracked with special markers.

### Zero-Touch Credentials
> Set your primary email and password once. Autopilot uses them for all new service signups. Stored in your OS credential store (Keychain / libsecret / Credential Manager).

### Self-Expanding
> Unknown service? Researches docs, creates registry file, installs CLI, adds safety rules, keeps going — all inline, no stopping.

### Hard Safety Rails (35-Principle Audit)

```
  Command Entered
       |
       v
  [Claude Code Sandbox]        kernel-enforced network allowlist
       |                        filesystem denyRead (ssh, aws, gnupg...)
       v
  [Guardian Hook]              exit code 2 = HARD BLOCK
       |                        (overrides all permissions)
       |-- rm -rf / ?           BLOCKED  [SYSTEM]
       |-- bash -c "evil" ?     BLOCKED  [EVASION]
       |-- npm publish ?        BLOCKED  [PUBLISHING]
       |-- git push --force ?   BLOCKED  [GIT]
       |-- vercel --prod ?      BLOCKED  [PRODUCTION]
       |-- DROP DATABASE ?      BLOCKED  [DATABASE]
       |-- base64 | bash ?      BLOCKED  [EVASION]
       |-- pip install http:// ? BLOCKED [SUPPLY_CHAIN]
       |-- hardcoded API key ?  BLOCKED  [SECRET_EXFIL]
       |-- same cmd 3× ?        BLOCKED  [LOOP]
       |-- npm install ?        ALLOWED
       v
  [Content Sanitizer]          wraps web/tool output in UNTRUSTED_CONTENT
       |                        strips 22 injection patterns + zero-width chars
       v
  [Memory Integrity]           SHA256 hash on every learned procedure
       |                        tampered entries auto-quarantined
       v
  [Budget Cap]                 5 signups / $20 / 500 tool calls per session
       |
       v
  Command Executes (no prompt)
```

### AppleScript GUI Automation (macOS)

> Native app control via AppleScript — faster and more reliable than pixel-clicking for scriptable apps.

```bash
# Open and focus an app
osascript.sh run app-control open "Figma"

# Get context: what's frontmost?
osascript.sh run frontmost-info
# → {"app":"Figma","bundle_id":"com.figma.Desktop","window_title":"My Design","pid":5432}

# Click a system dialog button
osascript.sh run handle-system-dialog "Replace"

# Read/write clipboard
osascript.sh run clipboard set "text to paste"
```

**Built-in scripts:** `app-control`, `frontmost-info`, `handle-system-dialog`, `clipboard`. Add new `.applescript` files to `applescripts/` — guardian auto-whitelists them.

**Security:** Guardian blocks all inline `osascript -e` (shell escape via `do shell script`), JXA, and non-whitelisted paths. Only `.applescript` files from `applescripts/` are allowed. macOS-only; skips gracefully on other platforms.

**When used:** Between Playwright (browser) and Computer Use (pixel-clicking) in the priority order. Faster and more reliable than Computer Use for any app with a scripting dictionary.

---

### Persistent Browser

```
  Chrome (background)  <-- CDP -->  Playwright MCP  <-->  Claude Code
        |                                 |
    Always alive                    Dies with session
    Sessions persist                Reconnects on start
```

Two modes:

- **Persistent** (default, port 9222) — reuses sessions across tasks. Start once, stays running.
- **Ephemeral** (port 9223) — fresh isolated profile per task, auto-wiped on stop. Used for signups, OAuth flows, and any task where prior browser state shouldn't carry over.

```bash
chrome-debug.sh ephemeral-start signup-task   # isolated profile
chrome-debug.sh ephemeral-stop                # stop + wipe
```

Three layers: (1) persistent + ephemeral Chrome via CDP, (2) auto-retry on tab crashes, (3) smart browser avoidance.

### Decision Framework

| Level | Action | Examples |
|:------|:-------|:---------|
| 1 — Just do it | Execute immediately | Everything: deploys, DB ops, DNS, signups, logins, publishing |
| 2 — Flag cost | Note the cost, keep going | Spending real money (>$5). Pause only if >$50 |
| 3 — Escalate | Cannot proceed | 2FA codes, CAPTCHAs, physical device confirmation |

---

## Installation

```bash
# One command
curl -fsSL https://raw.githubusercontent.com/rish-e/autopilot/main/install.sh | bash

# Or clone and install
git clone https://github.com/rish-e/autopilot.git
cd autopilot && ./install.sh
```

<details>
<summary><b>Requirements</b></summary>

- **macOS, Linux, or Windows** (Git Bash / WSL)
- **Claude Code** installed
- **Node.js** (installer handles it)
- **Google Chrome** (for browser automation via CDP)
- **Credential store**: macOS Keychain (auto) / `secret-tool` on Linux (installer installs it) / Windows Credential Manager (built-in)
- **Package manager**: Homebrew (macOS), apt/dnf/pacman (Linux), choco/winget/scoop (Windows)

</details>

---

## Usage

### `/autopilot` — Slash Command (recommended)

Use from any Claude Code session — no separate terminal needed:

```bash
/autopilot deploy this to Vercel with environment variables from Supabase
/autopilot set up Supabase with user auth tables and API keys
/autopilot configure Stripe payments with webhooks
/autopilot create a Cloudflare R2 bucket for image storage
```

### Agent Mode — Full Sessions

For big multi-service orchestrations:

```bash
claude --agent autopilot --dangerously-skip-permissions

> I need this running in production with a Postgres database, Stripe payments, and Sentry monitoring
```

### When to use which

| Situation | Use |
|:----------|:----|
| Quick deploy, get an API key | `/autopilot` |
| Full project setup from scratch | Agent mode |
| Mid-coding infrastructure task | `/autopilot` |
| Multi-service orchestration (5+ services) | Agent mode |
| Triggered by GitHub push / PR merge | Webhook daemon |

### Webhook Daemon — Event-Driven Triggers

Run Autopilot headlessly; GitHub pushes, PR merges, or CI failures wake it automatically:

```bash
# One-time setup: generate secret + print GitHub webhook config
bin/daemon.sh setup

# Start / stop
bin/daemon.sh start
bin/daemon.sh stop

# Check status
bin/daemon.sh status

# Fire a one-off task from the CLI
bin/daemon.sh trigger "deploy the latest main branch to Vercel staging"

# Watch the log
bin/daemon.sh logs 100
```

**Supported GitHub events** (configure in repo Settings → Webhooks):

| Event | Trigger condition | Task generated |
|:------|:-----------------|:---------------|
| `push` | Commit lands on `main`/`master` | Check if deploy needed and run it |
| `pull_request` | PR merged | Run the deployment pipeline |
| `workflow_run` | CI job fails | Investigate and fix |
| `issues` | Labeled `autopilot` | Complete the described task |

The daemon binds to `127.0.0.1:7891`. Use [ngrok](https://ngrok.com) or a reverse proxy to expose it to GitHub.

---

## Execution Log

Every action is tracked in your project:

```
your-project/.autopilot/log.md
```

```markdown
## Session: 2026-03-25 14:05 — Set up Supabase and deploy to Vercel

| # | Time  | Action                                     | Level | Service  | Result              |
|---|-------|--------------------------------------------|-------|----------|---------------------|
| 1 | 14:05 | Installed Supabase CLI via brew             | L1    | supabase | done                |
| 2 | 14:06 | Signed up at supabase.com (primary email)   | L2    | supabase | ACCOUNT CREATED     |
| 3 | 14:06 | Stored Supabase API token in keychain       | L1    | supabase | TOKEN STORED        |
| 4 | 14:07 | Created project (ref: abc123)               | L2    | supabase | done                |
| 5 | 14:08 | Ran migration: create users table           | L2    | supabase | done                |
| 6 | 14:09 | Logged in to vercel.com (primary email)     | L2    | vercel   | LOGGED IN           |
| 7 | 14:10 | Deployed to preview                         | L2    | vercel   | done — https://...  |
```

---

## Audit Dashboard

View the execution log from the terminal with `audit.sh`:

```bash
audit.sh                     # Latest session
audit.sh all                 # All sessions
audit.sh search supabase     # Search logs
audit.sh accounts            # Account activity (signups, logins, tokens)
audit.sh failures            # Failed actions only
audit.sh summary             # One-line-per-session overview
audit.sh --path ~/myproject  # Specify project path
```

Color-coded output: green = done, red = FAILED, yellow = ACCOUNT CREATED, blue = LOGGED IN, cyan = TOKEN STORED.

---

## Snapshot & Rollback

Before executing a plan, Autopilot snapshots the current state using `git stash`. If something goes wrong, roll back instantly.

```bash
snapshot.sh create pre-deploy   # Create a named snapshot
snapshot.sh list                # List all autopilot snapshots
snapshot.sh rollback            # Rollback to latest snapshot
snapshot.sh rollback pre-deploy # Rollback to a specific snapshot
snapshot.sh diff                # Show what changed since snapshot
snapshot.sh clean               # Remove all autopilot snapshots
```

Snapshots are automatic during complex tasks (Flow B). The agent creates one before executing any plan and mentions rollback availability in the completion report. Metadata is stored in `.autopilot/snapshots.json`.

---

## Session Persistence

Work survives rate limits and crashes. Autopilot saves progress after each step so it can resume where it left off.

```bash
session.sh save "Deploy to Vercel"  # Save session state
session.sh status                    # Check if a saved session exists
session.sh resume                    # Show full saved session for pickup
session.sh update '{"current_step": 3, "notes": "Step 2 done"}'  # Update progress
session.sh clear                     # Remove saved session
```

On startup (Flow B), the agent checks for a saved session and offers to resume. Session data is stored in `.autopilot/session.json` and includes the task, plan, completed steps, services used, and notes.

---

## What's Included

```
~/MCPs/autopilot/
  bin/
    keychain.sh           Cross-platform credential store
    guardian.sh            PreToolUse safety hook (autopilot-only, 55 tested patterns)
    chrome-debug.sh        Persistent Chrome manager (CDP)
    setup-clis.sh          CLI installer (gh, vercel, supabase, etc.)
    test-guardian.sh        Guardian test suite
    audit.sh               Execution log viewer (terminal dashboard)
    token-report.sh        Unified token savings dashboard (RTK + TokenPilot)
    repo-context.sh        Cached project summary for fast onboarding
    guardian-compile.sh    YAML → compiled rules cache + validation
    lockfile.sh            File-based lock coordination for parallel agents
    mcp-compress.sh        Wrap MCP servers for ~97% schema token savings
    snapshot.sh            Snapshot & rollback (git stash wrapper, auto for L3+)
    session.sh             Session persistence (save/resume state)
    osascript.sh           Safe AppleScript runner (macOS only, whitelist-enforced)
    content-sanitizer.sh   Injection defense — wraps external content, strips 22 patterns
    budget.sh              Session spend cap (5 signups / $20 / 500 calls)
    mcp-manifest-check.sh  MCP rug-pull detector (standalone PreToolUse hook)
    daemon-server.py        Webhook HTTP server (GitHub / generic POST triggers)
    daemon.sh              Daemon lifecycle manager (start/stop/status/trigger/setup)
  applescripts/            AppleScript playbooks (macOS GUI automation)
    app-control.applescript       Open / focus / quit / status apps
    handle-system-dialog.applescript  Click buttons on dialogs and sheets
    clipboard.applescript          Read / write / clear clipboard
    frontmost-info.applescript     Frontmost app JSON (name, bundle ID, title, PID)
  config/
    decision-framework.md  When to act vs. ask (5 levels)
    guardian-rules.yaml    Declarative safety rules (auditable, versioned)
    guardian-custom-rules.txt  Append-only blocklist (supplements YAML)
    trusted-mcps.yaml      MCP whitelist (20+ pre-vetted)
    mcp-tool-manifest.json  Trusted MCP tool name prefixes (rug-pull detection)
    playwright-config.json  CDP endpoint config
  browser-profile/         Persistent browser sessions
  services/                Service registry (5 built-in + template)
  commands/                /autopilot slash command
  agent/                   Full agent definition

# Per-project (created automatically):
your-project/.autopilot/
  log.md                   Execution log (audit trail)
  snapshots.json           Snapshot metadata
  session.json             Saved session state (if interrupted)
```

---

## Safety Model

<table>
<tr>
<td width="50%">

### What Gets Blocked (70+ patterns)

| Category | Examples |
|:---------|:---------|
| System destruction | `rm -rf /`, `sudo rm -rf`, `mkfs` |
| Credential leak | `echo $(keychain get)`, pipe to curl |
| Database destruction | `DROP DATABASE`, `TRUNCATE` |
| Git/publishing | `git push --force`, `npm publish` |
| Production deploys | `vercel --prod`, `terraform destroy` |
| Account changes | `gh repo --visibility public` |
| Financial | Stripe charges, sending emails |
| MCP process termination | Targeting Playwright/MCP servers |
| Obfuscation | `base64\|bash`, `bash -c`, `eval` |
| AppleScript inline | `osascript -e`, JXA, non-whitelisted paths |
| Supply chain | `pip install http://…`, non-PyPI indexes |
| Secret exfiltration | Hardcoded AWS/OpenAI/GitHub/Anthropic keys in network commands |
| Stuck loops | Same command repeated 3× in a session |

</td>
<td width="50%">

### The Safety Contract

| Layer | Can AI bypass? |
|:------|:--------------|
| Claude Code sandbox (kernel) | **No** — OS-enforced |
| Guardian hook (shell script) | **No** — deterministic |
| Content sanitizer | **No** — wraps all external input |
| Memory integrity (SHA256) | **No** — detects poisoning |
| Budget caps | **No** — halts session |
| Permission allowlist | **No** — evaluated by Claude Code |
| MCP tool manifest | Warns — not hard-blocked |
| Credential store | **No** — OS-level encryption |

### Autopilot-Scoped

Guardian is installed as a global hook but **only activates during autopilot sessions** — regular Claude Code sessions skip it entirely with zero overhead. Detection uses two methods:
- **Process tree**: detects `claude --agent autopilot` in ancestor processes
- **Session marker**: `preflight.sh` creates `/tmp/.guardian-active-<PID>` for `/autopilot` slash command sessions (auto-cleaned on exit)

### Self-Tightening

The system only gets **more restrictive**:
- Custom rules are **append-only**
- Guardian script is **immutable**
- MCP whitelist is **additive only**

</td>
</tr>
</table>

---

## Self-Expansion

```
Unknown service detected
        |
        v
  Check MCP whitelist ──> Install silently if whitelisted
        |
        v
  WebSearch CLI + API docs
        |
        v
  Create service registry file
        |
        v
  Append Guardian safety rules
        |
        v
  Install CLI tool
        |
        v
  Acquire credentials (browser or primary email)
        |
        v
  Continue with original task
```

No interruption. Only pauses for 2FA codes and first-time primary credentials.

---

## How It Compares

| Capability | Autopilot | Devin | Cursor Agents | Claude Code (vanilla) |
|:-----------|:----------|:------|:--------------|:---------------------|
| Autonomous deployment | Yes (CLI + browser) | Yes (sandbox) | Yes (VM) | Needs permission |
| Browser credential acquisition | Yes (Playwright CDP) | Partial | Partial | No |
| Hard safety rails | Yes (Guardian) | Sandbox only | Sandbox only | Permission prompts |
| Self-expanding knowledge | Yes | No | No | No |
| MCP auto-discovery | Yes (whitelist) | No | Partial | No |
| Credential vault | Yes (OS-native) | Session-scoped | VM-scoped | No |
| Append-only safety | Yes | No | No | No |
| Cross-platform | macOS, Linux, Windows | Cloud only | Cloud only | Yes |
| Open source | Yes (MIT) | No | No | CLI only |

---

## Limitations

**Hard blockers** (cannot automate):
- 2FA/MFA codes — sent to your phone
- CAPTCHAs — can't solve image challenges
- Email verification — requires inbox access
- PCI-compliant payment forms — resist automation

**Technical:**
- Chrome CDP needs to be running (`chrome-debug.sh start` — installer does this automatically)
- Browser UIs change — Playwright steps can break when dashboards redesign
- New MCPs need a session restart to take effect

---

## Contributing

| Contribution | Impact |
|:-------------|:-------|
| **Add a service** | Copy `services/_template.md`, fill in CLI commands, auth flow |
| **Expand Guardian** | Add patterns to `bin/guardian.sh` or `config/guardian-custom-rules.txt` |
| **Add trusted MCPs** | Add to `whitelisted` section in `config/trusted-mcps.yaml` |
| **Improve tests** | Add test cases to `bin/test-guardian.sh` |

---

<p align="center">
  <strong>MIT License</strong> &bull; Built for developers who'd rather code than configure
</p>
