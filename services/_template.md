# {Service Name}

> Category: {deployment | database | payments | hosting | cdn | auth | monitoring | registry}

## Credentials Required

| Key | Description | How to Obtain |
|-----|-------------|---------------|
| `api-token` | API access token | {URL or instructions} |
| `email` | Account email | User provides |
| `password` | Account password | User provides (only if browser login needed) |

## CLI Tool

- **Name**: `{tool-name}`
- **Install**: `{brew install x | npm install -g x}`
- **Auth setup**: `{command to authenticate}`
- **Verify**: `{command to verify auth works}`

## Common Operations

### {Operation Name}
```bash
# {description}
{exact command with keychain.sh integration}
```

### {Operation Name}
```bash
{exact command}
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
4. If 2FA appears: **ESCALATE to user**
5. {Continue with specific steps}

## 2FA Handling

- **Type**: {email code | authenticator app | SMS | none}
- **Action**: {ESCALATE to user | not applicable}

## MCP Integration

- **Available**: {yes — already configured | yes — installable | no}
- **Server name**: `{mcp server name if applicable}`
- **Notes**: {what the MCP can/can't do vs CLI}

## Notes

{Any service-specific quirks, gotchas, or tips}
