---
name: "GitHub"
category: "source-control, ci-cd"
credentials:
  - key: "token"
    description: "GitHub Personal Access Token"
    obtain: "https://github.com/settings/tokens → Generate new token"
    rotation_days: 90
auth_pattern: "cli-login"
2fa: "authenticator"
mcp: "installed"
cli: "gh"
rate_limits: "5000 API requests/hour authenticated, 2000 Actions minutes/month free"
related_services: ["vercel", "cloudflare"]
decision_levels:
  read: 1
  branch: 2
  merge-main: 3
  delete-repo: 4
---

# GitHub

## Credentials Required

| Key | Description | How to Obtain |
|-----|-------------|---------------|
| `token` | GitHub Personal Access Token | https://github.com/settings/tokens → Generate new token (classic) |

## CLI Tool

- **Name**: `gh`
- **Install**: `brew install gh`
- **Auth setup**:
  ```bash
  # Login with stored token
  echo "$(~/MCPs/autopilot/bin/keychain.sh get github token)" | gh auth login --with-token
  ```
- **Verify**: `gh auth status`

## Existing MCP Integration

GitHub MCP is already configured and authenticated in Claude Code. **Use MCP tools first** before falling back to CLI.

### MCP Capabilities (preferred)
- Read/write issues and PRs
- Search code, issues, repos
- Create/update files in repos
- Create branches, commits
- Manage releases and tags
- Read file contents

### When to use CLI instead of MCP
- Complex git operations (rebase, cherry-pick, stash)
- Running GitHub Actions workflows
- Managing repo settings (visibility, branch protection)
- Cloning/forking repos locally
- Viewing CI/CD status and logs

## Common Operations

### Create Repository
```bash
gh repo create <name> --public --source . --remote origin --push
# Or private:
gh repo create <name> --private --source . --remote origin --push
```

### Create Pull Request
```bash
gh pr create --title "Title" --body "Description" --base main
```

### View PR Status / Checks
```bash
gh pr status
gh pr checks <pr-number>
```

### Merge Pull Request
```bash
# DECISION: Level 2 — Do it, notify (for feature branches)
# DECISION: Level 1 — Just do it (for main/production branches)
gh pr merge <pr-number> --squash --delete-branch
```

### Run Workflow
```bash
gh workflow run <workflow-name> --ref <branch>
```

### View Workflow Runs
```bash
gh run list --limit 5
gh run view <run-id> --log
```

### Create Release
```bash
# DECISION: Level 1 — Just do it
gh release create v1.0.0 --title "v1.0.0" --notes "Release notes"
```

### Clone Repository
```bash
gh repo clone <owner/repo>
```

### Fork Repository
```bash
gh repo fork <owner/repo> --clone
```

### View/Create Issues
```bash
gh issue list
gh issue create --title "Title" --body "Description"
```

## Browser Fallback

Generally not needed — between MCP and CLI, all GitHub operations are covered programmatically.

If browser needed:
1. Navigate to `https://github.com`
2. Already logged in via persistent sessions (usually)
3. If not: ESCALATE to user (GitHub uses device verification)

### Get Personal Access Token via Browser
1. Navigate to `https://github.com/settings/tokens?type=beta`
2. Click "Generate new token"
3. Set name, expiration, permissions (repo, workflow)
4. Click "Generate token"
5. Copy token
6. Store: `echo "TOKEN" | ~/MCPs/autopilot/bin/keychain.sh set github token`

## 2FA Handling

- **Type**: Authenticator app, SMS, or security key (user-configurable)
- **Action**: ESCALATE to user — GitHub enforces 2FA on token creation

## MCP Integration

- **Available**: Yes — already configured as `github` MCP server
- **Notes**: MCP handles most read/write operations. Use `gh` CLI for git operations, workflow management, and repo settings.

## Notes

- MCP is already authenticated — prefer MCP tools over CLI when possible
- `gh` CLI respects the `GH_TOKEN` env var if set, or uses `gh auth login` session
- For CI/CD workflows, use `gh workflow run` and `gh run watch`
- GitHub Actions minutes: 2,000/month on free tier
- Branch protection rules can only be set via web UI or API, not `gh` CLI directly
