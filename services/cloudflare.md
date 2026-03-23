# Cloudflare

> Category: cdn, hosting, storage

## Credentials Required

| Key | Description | How to Obtain |
|-----|-------------|---------------|
| `api-token` | Cloudflare API token | https://dash.cloudflare.com/profile/api-tokens → Create Token |
| `account-id` | Cloudflare Account ID | Dashboard → any domain → Overview → right sidebar |

## CLI Tool

- **Name**: `wrangler` (Cloudflare Workers CLI)
- **Install**: `npm install -g wrangler`
- **Auth setup**:
  ```bash
  export CLOUDFLARE_API_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get cloudflare api-token)
  export CLOUDFLARE_ACCOUNT_ID=$(~/MCPs/autopilot/bin/keychain.sh get cloudflare account-id)
  ```
- **Verify**: `wrangler whoami`

## Common Operations

### Deploy a Worker
```bash
export CLOUDFLARE_API_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get cloudflare api-token)
wrangler deploy
unset CLOUDFLARE_API_TOKEN
```

### Create R2 Bucket
```bash
export CLOUDFLARE_API_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get cloudflare api-token)
wrangler r2 bucket create <bucket-name>
unset CLOUDFLARE_API_TOKEN
```

### Upload to R2
```bash
export CLOUDFLARE_API_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get cloudflare api-token)
wrangler r2 object put <bucket-name>/<key> --file <local-file>
unset CLOUDFLARE_API_TOKEN
```

### List R2 Buckets
```bash
export CLOUDFLARE_API_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get cloudflare api-token)
wrangler r2 bucket list
unset CLOUDFLARE_API_TOKEN
```

### Manage KV Namespaces
```bash
export CLOUDFLARE_API_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get cloudflare api-token)
wrangler kv namespace list
wrangler kv namespace create <name>
wrangler kv key put --namespace-id <ns-id> <key> <value>
unset CLOUDFLARE_API_TOKEN
```

### Set Worker Secrets
```bash
export CLOUDFLARE_API_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get cloudflare api-token)
echo "secret_value" | wrangler secret put SECRET_NAME
unset CLOUDFLARE_API_TOKEN
```

### Tail Worker Logs
```bash
export CLOUDFLARE_API_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get cloudflare api-token)
wrangler tail
unset CLOUDFLARE_API_TOKEN
```

## Browser Fallback

For dashboard-only operations (DNS management, domain setup, analytics):

1. Navigate to `https://dash.cloudflare.com`
2. Check if logged in (look for account dashboard)
3. If login needed:
   a. Get email: `~/MCPs/autopilot/bin/keychain.sh get cloudflare email`
   b. Fill email, fill password
   c. Click "Log in"
4. If 2FA: **ESCALATE to user**

### DNS Management via Browser
1. Navigate to `https://dash.cloudflare.com/{account-id}/{domain}/dns`
2. Click "Add record"
3. Fill type (A, CNAME, etc.), name, value
4. Click "Save"

### Get API Token via Browser
1. Navigate to `https://dash.cloudflare.com/profile/api-tokens`
2. Click "Create Token"
3. Use "Edit Cloudflare Workers" template (or custom)
4. Configure permissions as needed
5. Click "Continue to summary" → "Create Token"
6. Copy token
7. Store: `echo "TOKEN" | ~/MCPs/autopilot/bin/keychain.sh set cloudflare api-token`

## 2FA Handling

- **Type**: Authenticator app or security key
- **Action**: ESCALATE to user

## MCP Integration

- **Available**: No dedicated MCP server configured
- **Notes**: `wrangler` CLI with API token covers Workers, R2, KV, D1, and Queues. DNS management requires the dashboard or direct API calls.

## Notes

- Wrangler uses `CLOUDFLARE_API_TOKEN` env var — no `--token` flag needed
- For R2 (S3-compatible storage), useful for RenderKit image storage
- Free tier: 100k Worker requests/day, 10GB R2 storage, unlimited bandwidth
- Workers can replace traditional serverless functions (Lambda, Vercel Functions)
- D1 is Cloudflare's SQL database (SQLite at edge) — alternative to Supabase for simple use cases
- Pages (static site hosting) deploys via `wrangler pages deploy`
