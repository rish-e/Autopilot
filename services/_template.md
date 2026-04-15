---
name: "{Service Name}"
category: "{deployment | database | payments | hosting | cdn | auth | monitoring | messaging | trading}"
credentials:
  - key: "api-token"
    description: "API access token"
    obtain: "{URL or instructions}"
    rotation_days: 90
auth_pattern: "{token-env | token-flag | cli-login | oauth | api-key-header}"
2fa: "{none | email | authenticator | sms | device-verification}"
mcp: "{installed | installable | none}"
cli: "{tool-name | none}"
rate_limits: "{free tier limits, e.g. 100 deploys/day}"
related_services: ["{other-service}"]
decision_levels:
  read: 1
  write: 1
  production: 1
  money: 2
  escalate: 3
---

# {Service Name}

## Credentials Required

| Key | Description | How to Obtain | Rotation |
|-----|-------------|---------------|----------|
| `api-token` | API access token | {URL or instructions} | 90 days |

## CLI Tool

- **Name**: `{tool-name}`
- **Install**: `{brew install x | npm install -g x}`
- **Auth setup**: `{command to authenticate}`
- **Verify**: `{command to verify auth works}`

## Common Operations

### {Operation Name}
```bash
# Decision Level: L{n} — {description}
{exact command with keychain.sh integration}
```

## Browser Fallback

When CLI is unavailable or insufficient:

1. Navigate to `{dashboard URL}`
2. Check if logged in (look for `{indicator}`)
3. If login needed:
   a. Get email: `~/MCPs/autopilot/bin/keychain.sh get {service} email`
   b. Fill email field
   c. Fill password field
   d. Click sign in
4. If 2FA appears: **ESCALATE only the code** — handle everything else yourself

## 2FA Handling

- **Type**: {email code | authenticator app | SMS | none}
- **Action**: {ESCALATE only the 2FA code | not applicable}

## MCP Integration

- **Available**: {yes — already configured | yes — installable | no}
- **Server name**: `{mcp server name if applicable}`
- **Notes**: {what the MCP can/can't do vs CLI}

## Notes

{Any service-specific quirks, gotchas, or tips}
