# Autopilot

**The first self-expanding autonomous coding agent with hard safety rails.**

AI coding agents today are either autonomous but unsafe (Devin, Cursor — sandbox-only safety) or safe but constantly asking for permission (vanilla Claude Code). Autopilot is the third option: fully autonomous, with a deterministic safety layer the AI cannot override, and it teaches itself new services as it encounters them.

```
claude --agent autopilot
> Set up Supabase for this project with user auth, deploy to Vercel, and configure Razorpay payments.

Autopilot: Installing Supabase CLI... done.
Autopilot: Opening Supabase dashboard to generate access token... [browser automation]
Autopilot: Token stored in keychain. Creating project...
Autopilot: Running migrations... Tables created: users, api_keys, usage_logs.
Autopilot: Installing Vercel CLI... done.
Autopilot: Deploying to preview... https://myapp-abc123.vercel.app
Autopilot: Setting environment variables from Supabase connection...
Autopilot: Opening Razorpay dashboard for API keys... [needs 2FA]
Autopilot: "Enter the OTP sent to your phone in the browser."
> [user enters OTP]
Autopilot: Razorpay keys stored. Webhook configured.
Autopilot: Done. Preview: https://myapp-abc123.vercel.app
```

No copying API keys. No switching between terminals and dashboards. No "please paste your token here." Autopilot handles it.

---

## What Can It Do?

Autopilot is a **general-purpose autonomous agent** — not limited to any specific service or workflow. It handles anything you'd normally do outside your code editor:

- **Deploy code** — Vercel, Netlify, Railway, Cloudflare, Fly.io, any platform
- **Set up databases** — Create Supabase projects, write migrations, run SQL, configure auth and RLS
- **Manage infrastructure** — Cloudflare Workers, R2 buckets, KV stores, DNS records, SSL certificates
- **Configure services** — Payment providers (Stripe, Razorpay), email (SendGrid, Resend), monitoring (Sentry, Datadog), auth (Clerk, Auth0), or anything with a CLI or web dashboard
- **Handle git workflows** — Commits, branches, PRs, issues, GitHub Actions, releases
- **Browse the web** — Logs into dashboards, fills forms, clicks buttons, reads pages, navigates settings via Playwright
- **Install and configure tools** — CLIs, MCP servers, dependencies, environment setup
- **Acquire credentials autonomously** — Logs into service dashboards via browser, generates API tokens, stores them in macOS Keychain
- **Teach itself new services** — Encounters something unknown? Researches the docs, creates a registry file, installs the CLI, adds safety rules, keeps going

The 5 pre-built service files (Vercel, Supabase, GitHub, Cloudflare, Razorpay) are just a head start. When Autopilot encounters any service not in the registry, it researches it, learns it, and expands itself — all inline, without stopping to ask.

---

## How It Works

```
  You give a task
       |
       v
  +---------------------------+
  | Autopilot Agent           |     Reads: decision framework,
  | (~/.claude/agents/        |     service registry, MCP whitelist
  |  autopilot.md)            |
  +---------------------------+
       |
       +----------+----------+-----------+
       |          |          |           |
       v          v          v           v
  +--------+ +--------+ +--------+ +---------+
  |  MCP   | |  CLI   | |  API   | |Playwright|
  | Tools  | | Tools  | | (curl) | | Browser  |
  |        | |        | |        | |          |
  |GitHub  | |vercel  | |Razorpay| |Login to  |
  |Supabase| |supabase| |Stripe  | |dashboards|
  |Postgres| |gh, etc | |any API | |Get tokens|
  +--------+ +--------+ +--------+ +---------+
       |          |          |           |
       +----------+----------+-----------+
       |
       v
  +---------------------------+       +---------------------------+
  | macOS Keychain            |       | Guardian Hook             |
  | (encrypted credentials)   |       | (blocks dangerous cmds)   |
  |                           |       |                           |
  | Stores: API tokens,       |       | Hard-blocks: rm -rf /,    |
  | login credentials,        |       | DROP DATABASE, npm publish,|
  | webhook secrets           |       | force push, prod deploys  |
  +---------------------------+       +---------------------------+
```

**Priority order:** MCP integration > CLI tool > REST API > Browser automation > Ask user

---

## Features

### Fully Autonomous
Autopilot acts first, asks only when the decision framework says to. It deploys code, configures databases, manages infrastructure, and obtains credentials — all without you leaving the terminal.

### Browser-Based Credential Acquisition
Need an API key? Autopilot opens Playwright, logs into the dashboard, navigates to the tokens page, creates one, copies it, stores it in Keychain. You provide your email and password once per service. Autopilot handles everything else.

### Self-Expanding
Encounter a service not in the registry? Autopilot researches the docs (WebSearch + WebFetch), creates a service registry file, installs the CLI, adds safety rules, and continues — all inline, without stopping to ask.

### Hard Safety Rails (Guardian)
A PreToolUse hook that runs before every Bash command. It's a shell script — deterministic code, not AI instructions. The AI cannot reason around it, override it, or decide to ignore it. If the pattern matches the blocklist, the command is blocked. Period.

```
  Command Entered
       |
       v
  [Guardian Hook]         <-- exit code 2 = HARD BLOCK
       |                       (overrides all permissions)
       |-- rm -rf / ?          -> BLOCKED
       |-- npm publish ?       -> BLOCKED
       |-- git push --force ?  -> BLOCKED
       |-- vercel --prod ?     -> BLOCKED
       |-- DROP DATABASE ?     -> BLOCKED
       |-- npm install ?       -> ALLOWED
       v
  [Permission Allowlist]  <-- auto-approve safe commands
       |
       v
  Command Executes (no prompt)
```

### Smart Permissions
All tools auto-approved (same speed as `--dangerously-skip-permissions`), with the Guardian catching dangerous patterns. Safe commands fly through with zero prompts. Dangerous commands are hard-blocked before they execute.

### MCP Auto-Discovery
Maintains a whitelist of trusted MCP servers. Whitelisted MCPs install silently when needed. Unknown MCPs: Autopilot explains what it found, why it's useful, and asks once. Approved MCPs are whitelisted forever.

### Decision Framework

| Level | Action | Examples |
|-------|--------|---------|
| 1 — Just do it | No notification | `npm install`, `git push`, read files, install CLIs |
| 2 — Do it, notify | Brief note | Preview deploys, create branches, generate API tokens |
| 3 — Ask first | Wait for approval | Production deploys, destructive DB ops, paid resources |
| 4 — Must ask | Show exact command | Spending money, sending messages, publishing packages |
| 5 — Escalate | Cannot proceed | 2FA codes, CAPTCHAs, first-time login credentials |

---

## Installation

### One Command

```bash
curl -fsSL https://raw.githubusercontent.com/rish-e/autopilot/main/install.sh | bash
```

### Or Clone and Install

```bash
git clone https://github.com/rish-e/autopilot.git
cd autopilot
./install.sh
```

### Requirements

- **macOS** (uses macOS Keychain for credential storage)
- **Claude Code** installed
- **Homebrew** (installer will set it up if missing)
- **Node.js** (installer will set it up if missing)

---

## Usage

```bash
# Start Autopilot
claude --agent autopilot

# Deploy and host
> Deploy this to Vercel with environment variables from Supabase

# Databases
> Set up Supabase with user auth tables, API keys, and usage tracking

# Payments
> Configure Stripe payments with webhooks for subscription billing

# Infrastructure
> Create a Cloudflare R2 bucket for image storage and set up a Worker for resizing

# CI/CD
> Set up GitHub Actions to run tests on PR and deploy to Vercel on merge to main

# Multiple services at once
> I need this running in production with a Postgres database, Stripe payments, and Sentry monitoring

# Services it's never seen before
> Set up Resend for transactional emails and Upstash for Redis caching
```

Autopilot figures out the rest. If it's a service it hasn't seen before, it researches the docs, creates a registry file, installs the CLI, and keeps going. First time with a service, it asks for your login credentials once. Every subsequent interaction is fully autonomous (except 2FA codes — those need your phone).

---

## What's Included

```
~/MCPs/autopilot/
  bin/
    keychain.sh          # macOS Keychain wrapper (get/set/delete/list/has)
    guardian.sh           # PreToolUse safety hook (hard-blocks dangerous commands)
    setup-clis.sh         # CLI installer (gh, vercel, supabase, wrangler, etc.)
    test-guardian.sh      # 41-test suite for the guardian
  config/
    decision-framework.md # When to act vs. ask (5 levels)
    guardian-custom-rules.txt  # Append-only blocklist (expands with new services)
    trusted-mcps.yaml     # MCP whitelist (20+ pre-vetted servers)
  services/
    _template.md          # Template for new service registry entries
    vercel.md             # Vercel: deploy, env vars, domains
    supabase.md           # Supabase: projects, migrations, SQL, types
    github.md             # GitHub: repos, PRs, issues, Actions
    cloudflare.md         # Cloudflare: Workers, R2, KV, DNS
    razorpay.md           # Razorpay: payments, subscriptions, webhooks
  agent/
    autopilot.md          # The agent definition (installed to ~/.claude/agents/)
```

---

## Safety Model

Autopilot's safety is layered. The Guardian provides **hard enforcement** that the AI cannot bypass. The Decision Framework provides **intelligent classification** that the AI follows.

### What the Guardian Blocks (41 tested patterns)

| Category | Examples |
|----------|---------|
| **System destruction** | `rm -rf /`, `rm -rf ~`, `sudo rm -rf`, `mkfs`, `dd`, `shutdown` |
| **Credential exfiltration** | `echo $(keychain.sh get ...)`, piping secrets to curl/files |
| **Database destruction** | `DROP DATABASE`, `DROP SCHEMA`, `TRUNCATE` |
| **Git/publishing** | `git push --force`, `git reset --hard`, `npm publish`, `cargo publish` |
| **Production deploys** | `vercel deploy --prod`, `terraform destroy` |
| **Account changes** | `gh repo edit --visibility public`, `gh repo delete` |
| **Financial** | Creating Stripe charges, sending emails |

### What's Auto-Approved (zero prompt)

Everything not in the Guardian's blocklist. `npm install`, `git commit`, `vercel deploy` (preview), `supabase db push`, `curl`, `brew install`, file reads/writes — all execute instantly.

### The Safety Contract

| Layer | Enforcement | Can AI bypass? |
|-------|-------------|----------------|
| Guardian hook | Shell script, exit code 2 | **No** — runs before the command, blocks deterministically |
| Permission allowlist | Claude Code settings | **No** — evaluated by Claude Code, not the AI |
| Decision framework | Agent instructions | In theory yes, but Guardian catches the dangerous cases |
| Credential isolation | macOS Keychain encryption | **No** — OS-level encryption |

### Self-Tightening Safety

When Autopilot learns a new service, it appends safety rules to the Guardian's custom rules file. The system can only get **more restrictive**, never less:
- Custom rules are **append-only** — the AI can add rules but never remove them
- The Guardian script itself is **immutable** — the AI cannot modify it
- The MCP whitelist is **additive** — entries are added, never removed

---

## Self-Expansion

Autopilot grows its own capabilities. When it encounters a service not in the registry:

```
1. Detects missing service registry file
2. Checks MCP whitelist — installs silently if whitelisted
3. WebSearches the service's CLI and API docs
4. Fetches official documentation
5. Creates a new service registry file from template
6. Identifies dangerous operations -> appends Guardian rules
7. Installs CLI tool if one exists
8. Acquires credentials via browser automation
9. Continues with the original task
```

No interruption. The only pause points are first-time login credentials and 2FA codes.

### Adding a Service Manually

Copy the template and fill it in:

```bash
cp ~/MCPs/autopilot/services/_template.md ~/MCPs/autopilot/services/my-service.md
```

Each service file documents: credentials needed, CLI tool, common operations, browser fallback steps, and 2FA handling.

### Adding Guardian Rules

Append to the custom rules file (the AI does this automatically for new services):

```bash
echo 'CATEGORY|regex_pattern|Human-readable reason' >> ~/MCPs/autopilot/config/guardian-custom-rules.txt
```

### Adding Trusted MCPs

Edit `~/MCPs/autopilot/config/trusted-mcps.yaml` and add to the `whitelisted` section. Autopilot installs whitelisted MCPs silently when needed.

---

## How It Compares

| Capability | Autopilot | Devin | Cursor Agents | Claude Code (vanilla) |
|---|---|---|---|---|
| Autonomous deployment | Yes (CLI + browser) | Yes (sandbox) | Yes (VM) | Needs permission each time |
| Browser credential acquisition | Yes (Playwright) | Partial | Partial | No |
| Hard safety rails | Yes (Guardian hook) | No (sandbox only) | No (sandbox only) | Partial (permission prompts) |
| Self-expanding service knowledge | Yes | No | No | No |
| MCP auto-discovery | Yes (whitelist-based) | No (no MCP) | Partial | No |
| Credential vault | Yes (macOS Keychain) | Session-scoped | VM-scoped | No built-in |
| Smart auto-approve | Yes (Guardian + allowlist) | N/A (sandbox) | N/A (sandbox) | Manual approval |
| Append-only safety expansion | Yes | No | No | No |
| Open source | Yes (MIT) | No | No | Yes (CLI, not agents) |

---

## Limitations

### Hard Blockers (cannot automate)
- **2FA/MFA codes** — sent to your phone, no way to intercept
- **CAPTCHAs** — can't solve image challenges
- **Account creation** — requires email verification
- **Payment method setup** — PCI-compliant forms resist automation

### Technical
- **macOS only** — uses macOS Keychain (Linux/Windows support welcome as PRs)
- **Browser UIs change** — Playwright steps in service registry can break when dashboards redesign
- **New MCPs need a restart** — installed MCPs take effect next Claude Code session
- **No automatic rollback** — if a deploy goes wrong, you fix it manually

---

## Contributing

### Add a Service

The most impactful contribution. Copy `services/_template.md`, fill in the CLI commands, browser steps, and auth flow for a service you use.

### Expand the Guardian

Find a dangerous command pattern that isn't caught? Add it to the test suite in `bin/test-guardian.sh` and either add it to `bin/guardian.sh` (built-in) or `config/guardian-custom-rules.txt` (custom).

### Add Trusted MCPs

Found a well-maintained MCP server from a verified publisher? Add it to the `whitelisted` section in `config/trusted-mcps.yaml`.

### Port to Linux/Windows

The main blocker is `keychain.sh` which uses macOS `security` command. A Linux port would use `secret-tool` (libsecret) or `pass`. Windows would use Windows Credential Manager.

---

## License

MIT
