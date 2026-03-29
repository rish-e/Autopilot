# Supabase

> Category: database

## Credentials Required

| Key | Description | How to Obtain |
|-----|-------------|---------------|
| `access-token` | Supabase CLI access token | https://supabase.com/dashboard/account/tokens → Generate new token |
| `db-password` | Database password (per-project) | Set during project creation, store per-project as `db-password-{project-ref}` |

## CLI Tool

- **Name**: `supabase`
- **Install**: `brew install supabase/tap/supabase`
- **Auth setup**:
  ```bash
  export SUPABASE_ACCESS_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get supabase access-token)
  ```
- **Verify**: `supabase projects list`

## Common Operations

### List Projects
```bash
export SUPABASE_ACCESS_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get supabase access-token)
supabase projects list
unset SUPABASE_ACCESS_TOKEN
```

### Create New Project
```bash
# DECISION: Level 2 — Do it, notify user (creates a free-tier resource)
export SUPABASE_ACCESS_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get supabase access-token)
supabase projects create "project-name" \
  --org-id "org-id" \
  --db-password "$(openssl rand -base64 24)" \
  --region us-east-1
unset SUPABASE_ACCESS_TOKEN
# Store the generated db password in keychain for later use
```

### Initialize Supabase in Project
```bash
supabase init
```

### Link to Existing Project
```bash
export SUPABASE_ACCESS_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get supabase access-token)
supabase link --project-ref <project-ref>
unset SUPABASE_ACCESS_TOKEN
```

### Create Migration
```bash
supabase migration new <migration-name>
# Then edit the generated SQL file in supabase/migrations/
```

### Push Migrations (Dev/Staging)
```bash
# DECISION: Level 2 — Do it, notify user
export SUPABASE_ACCESS_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get supabase access-token)
supabase db push
unset SUPABASE_ACCESS_TOKEN
```

### Push Migrations (Production)
```bash
# DECISION: Level 3 — Ask first
export SUPABASE_ACCESS_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get supabase access-token)
supabase db push --linked
unset SUPABASE_ACCESS_TOKEN
```

### Run SQL Directly
```bash
export SUPABASE_ACCESS_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get supabase access-token)
supabase db execute --sql "SELECT * FROM users LIMIT 10;"
unset SUPABASE_ACCESS_TOKEN
```

### Generate TypeScript Types
```bash
export SUPABASE_ACCESS_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get supabase access-token)
supabase gen types typescript --linked > src/types/database.ts
unset SUPABASE_ACCESS_TOKEN
```

### Start Local Development
```bash
supabase start
# Returns local URLs for Studio, API, DB, etc.
```

### Get Project Connection String
```bash
export SUPABASE_ACCESS_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get supabase access-token)
supabase db url --linked
unset SUPABASE_ACCESS_TOKEN
```

### Get API Keys (anon + service role)
```bash
export SUPABASE_ACCESS_TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get supabase access-token)
supabase status --linked
# Output includes: API URL, anon key, service_role key
unset SUPABASE_ACCESS_TOKEN
```

## Browser Fallback

When CLI is unavailable or for dashboard-only operations:

1. Navigate to `https://supabase.com/dashboard`
2. Check if logged in (look for project list)
3. If login needed:
   a. Get email: `~/MCPs/autopilot/bin/keychain.sh get supabase email`
   b. Fill email field, fill password field
   c. Click "Sign In"
4. If 2FA: **ESCALATE to user**

### Get API Keys via Browser
1. Navigate to `https://supabase.com/dashboard/project/{ref}/settings/api`
2. Copy "anon public" key and "service_role secret" key
3. Store: `echo "KEY" | ~/MCPs/autopilot/bin/keychain.sh set supabase anon-key-{project-ref}`

### SQL Editor via Browser
1. Navigate to `https://supabase.com/dashboard/project/{ref}/sql/new`
2. Type SQL into the editor
3. Click "Run" button

## 2FA Handling

- **Type**: Email verification or TOTP (user-configurable)
- **Action**: ESCALATE to user

## MCP Integration

- **Available**: `@supabase/mcp-server` (whitelisted — auto-installs when needed)
- **Notes**: MCP provides project management, database operations, and edge functions. CLI is also comprehensive. Use browser fallback only for visual SQL editing or complex RLS policy configuration.

## Notes

- Supabase CLI uses `SUPABASE_ACCESS_TOKEN` env var — no explicit `--token` flag needed
- Local development via `supabase start` requires Docker (check if Docker is installed)
- Free tier: 2 projects, 500MB database, 1GB file storage
- Project ref is a short alphanumeric ID (e.g., "abcdefghijkl") found in the project URL
- When creating a project, generate a strong db password and store it in keychain immediately
- The anon key is safe to expose in client-side code; the service_role key must be kept secret
