---
name: "Vercel"
category: "deployment"
credentials:
  - key: "api-token"
    description: "Vercel API token"
    obtain: "https://vercel.com/account/tokens → Create Token"
    rotation_days: 90
auth_pattern: "token-flag"
2fa: "email"
mcp: "installable"
cli: "vercel"
rate_limits: "100 deploys/day free tier, 6000 build minutes/month"
related_services: ["github"]
decision_levels:
  read: 1
  preview: 2
  production: 3
  delete: 4
---

# Vercel

## Credentials Required

| Key | Description | How to Obtain |
|-----|-------------|---------------|
| `api-token` | Vercel API token | https://vercel.com/account/tokens → Create Token |

## CLI Tool

- **Name**: `vercel`
- **Install**: `npm install -g vercel`
- **Auth setup**: Token-based (no interactive login needed)
  ```bash
  export VERCEL_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get vercel api-token)
  ```
- **Verify**: `vercel whoami --token "$VERCEL_TOKEN"`

## Common Operations

### Deploy to Preview
```bash
export VERCEL_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get vercel api-token)
vercel deploy --yes --token "$VERCEL_TOKEN"
unset VERCEL_TOKEN
```

### Deploy to Production
```bash
# DECISION: Level 1 — Just do it
export VERCEL_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get vercel api-token)
vercel deploy --prod --yes --token "$VERCEL_TOKEN"
unset VERCEL_TOKEN
```

### List Projects
```bash
export VERCEL_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get vercel api-token)
vercel ls --token "$VERCEL_TOKEN"
unset VERCEL_TOKEN
```

### Set Environment Variable
```bash
export VERCEL_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get vercel api-token)
# For production:
echo "value_here" | vercel env add KEY_NAME production --token "$VERCEL_TOKEN"
# For preview:
echo "value_here" | vercel env add KEY_NAME preview --token "$VERCEL_TOKEN"
# For development:
echo "value_here" | vercel env add KEY_NAME development --token "$VERCEL_TOKEN"
unset VERCEL_TOKEN
```

### Pull Environment Variables Locally
```bash
export VERCEL_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get vercel api-token)
vercel env pull .env.local --token "$VERCEL_TOKEN"
unset VERCEL_TOKEN
```

### Link Project to Directory
```bash
export VERCEL_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get vercel api-token)
vercel link --yes --token "$VERCEL_TOKEN"
unset VERCEL_TOKEN
```

### View Deployment Logs
```bash
export VERCEL_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get vercel api-token)
vercel logs <deployment-url> --token "$VERCEL_TOKEN"
unset VERCEL_TOKEN
```

## Browser Fallback

When CLI is unavailable or for operations not supported by CLI:

1. Navigate to `https://vercel.com/dashboard`
2. Check if logged in (look for project list or user avatar)
3. If login needed:
   a. Get email: `~/MCPs/autopilot/bin/keychain.sh get vercel email`
   b. Fill email field, click Continue
   c. Check for email verification or password prompt
4. If 2FA/email verification: **ESCALATE to user**

### Get API Token via Browser
1. Navigate to `https://vercel.com/account/tokens`
2. Click "Create" button
3. Set token name (e.g., "claude-autopilot")
4. Set scope to "Full Account"
5. Click "Create Token"
6. Copy the token value from the page
7. Store: `echo "TOKEN_VALUE" | ~/MCPs/autopilot/bin/keychain.sh set vercel api-token`

## 2FA Handling

- **Type**: Email verification for new logins
- **Action**: ESCALATE to user — Vercel sends a verification email on new device login

## MCP Integration

- **Available**: `@vercel/mcp` (whitelisted — auto-installs when needed)
- **Notes**: MCP provides project management, deployments, and env var operations. CLI with `--token` and `--yes` flags also works for all operations.

## Notes

- Always use `--yes` flag to skip interactive confirmations
- Always use `--token` flag for non-interactive auth (never `vercel login`)
- Vercel auto-detects framework (Next.js, Vite, etc.) — usually no config needed
- For monorepos, use `--cwd` to specify the subdirectory
- Environment variables set via CLI are encrypted at rest by Vercel
