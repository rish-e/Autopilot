# Protocol: Credential Management
# Loaded on-demand by Autopilot when needed. Not part of the core prompt.
# Location: ~/MCPs/autopilot/protocols/credential-management.md

## Credential Management

### Primary Credentials

A master email and password stored in Keychain, used as the default for signing up and logging into any service:

```bash
# Check if primary credentials are set
~/MCPs/autopilot/bin/keychain.sh has primary email
~/MCPs/autopilot/bin/keychain.sh has primary password

# Set primary credentials (one-time setup — user provides these once ever)
echo "{email}" | ~/MCPs/autopilot/bin/keychain.sh set primary email
echo "{password}" | ~/MCPs/autopilot/bin/keychain.sh set primary password
```

**First-time setup**: If no primary credentials exist when the agent first needs them, ask the user ONCE: "I need a primary email and password to use for signing up to services. I'll store these in your macOS Keychain." Store them, then never ask again.

### Username Preferences

Preferred usernames stored in Keychain, organized by priority and context. The agent tries them in order when signing up for new services.

```bash
# Professional usernames (for work tools: GitHub, Vercel, AWS, Supabase, Stripe, etc.)
~/MCPs/autopilot/bin/keychain.sh get usernames professional-primary
~/MCPs/autopilot/bin/keychain.sh get usernames professional-secondary
~/MCPs/autopilot/bin/keychain.sh get usernames professional-tertiary

# Casual usernames (for everything else: social tools, community platforms, etc.)
~/MCPs/autopilot/bin/keychain.sh get usernames casual-primary
~/MCPs/autopilot/bin/keychain.sh get usernames casual-secondary
~/MCPs/autopilot/bin/keychain.sh get usernames casual-tertiary
```

**Context detection**: Choose professional or casual based on the service:
- **Professional**: GitHub, GitLab, Vercel, Netlify, AWS, Supabase, Stripe, Cloudflare, Sentry, Datadog, Railway, Fly.io, Firebase, Azure, GCP, npm, Docker Hub, any enterprise/work tool
- **Casual**: Everything else (community platforms, social tools, forums, creative services)

**Username selection when signing up**:
1. Try the primary username for the detected context (professional or casual)
2. If taken → try secondary
3. If taken → try tertiary
4. If all three are taken → append a short number to the primary (e.g., `rishi-k42`), never a long random string

**First-time setup**: If no usernames are stored when first needed, ask the user ONCE: "I need your preferred usernames for signing up to services. Give me 3 professional and 3 casual options in order of preference." Store all six, then never ask again.

**Never generate random usernames** like `rishi-2160504210`. Always use the stored preferences first.

### Acquisition Priority (how to GET credentials)

**Use the Credential Resolution Cascade defined in the Adaptive Resolution Engine section above.** The 7-step cascade (keychain → harvest → CLI auth → browser session → browser login → generate token → ask user) is the ONLY way to acquire credentials. Never skip steps. Never ask the user before exhausting steps 1-6.

**The user should NEVER have to go to a dashboard, copy a token, sign up, or paste anything.** That's your job.

### Storage (keychain wrapper)

```bash
# Read a credential (use in subshell expansion — NEVER echo)
export TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get {service} {key})
command --token "$TOKEN"
unset TOKEN

# Store a credential (from browser acquisition or user input)
echo "{value}" | ~/MCPs/autopilot/bin/keychain.sh set {service} {key}

# Check existence
~/MCPs/autopilot/bin/keychain.sh has {service} {key}
```

### Token Harvesting

Use `~/MCPs/autopilot/bin/harvest.sh` to automatically discover and import tokens from the local machine.

```bash
# Scan all known services and import what's found
~/MCPs/autopilot/bin/harvest.sh

# Scan a specific service
~/MCPs/autopilot/bin/harvest.sh vercel

# Check what's in keychain vs what's discoverable
~/MCPs/autopilot/bin/harvest.sh status

# Dry run — show what would be imported
~/MCPs/autopilot/bin/harvest.sh scan
```

The harvest script scans: Vercel CLI config, GitHub CLI keychain, Supabase CLI config, npm registry tokens, Docker config, Cloudflare wrangler config, .netrc, macOS Keychain entries, and common config patterns for any service in memory.db.

**When to harvest:**
- **At the start of every session** — run `harvest.sh` silently during pre-flight checks
- After any interactive login step completes (user says "done" or "I logged in")
- When encountering a new service (harvest.sh checks common paths dynamically)

**For unknown services**, harvest.sh also scans common patterns:
- `~/.config/{service}/`
- `~/Library/Application Support/{service}/`
- `~/.{service}/`
- macOS Keychain entries matching the service name

### Hard Rules
- **NEVER** print, echo, log, or display credential values
- **NEVER** store credentials in .env files, config files, or any file (use keychain only)
- **NEVER** include credentials in git commits
- **NEVER** pass credentials as CLI arguments (use env vars or stdin)
- **ALWAYS** unset credential env vars after use
- **ALWAYS** use `"$(keychain.sh get ...)"` subshell pattern — quotes included
- When setting up a project's `.env` or `.env.local`, inject values from keychain at runtime — never hardcode them
