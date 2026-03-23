#!/bin/bash
# guardian.sh — Safety hook for Claude Code Autopilot
#
# PreToolUse hook that blocks dangerous Bash commands.
# Combined with "Bash" in the permission allowlist, this gives you
# the speed of --dangerously-skip-permissions with a hard safety net.
#
# How it works:
#   - Receives tool call JSON on stdin
#   - Checks Bash commands against blocklist patterns
#   - Exit 0 = allow (auto-approved by permission rules)
#   - Exit 2 = BLOCK (overrides permission rules, command never runs)
#
# To test: echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | guardian.sh

set -uo pipefail

# Read tool call from stdin
INPUT=$(cat)

# Only inspect Bash commands — allow everything else through
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Extract the command (try jq first, fall back to raw input for robustness)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -z "$COMMAND" ]; then
    # If jq fails (malformed JSON), use the raw input as the command
    # This ensures we still catch dangerous patterns even with bad JSON
    COMMAND="$INPUT"
fi

# Normalize: lowercase for case-insensitive matching
CMD_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')

block() {
    local category="$1"
    local reason="$2"
    echo "GUARDIAN BLOCKED [$category]: $reason" >&2
    echo "Command was: $COMMAND" >&2
    echo "" >&2
    echo "If you need to run this, ask the user to execute it directly with: ! <command>" >&2
    exit 2
}

# =============================================================================
# CATEGORY 1: SYSTEM DESTRUCTION
# =============================================================================

# Root/home directory deletion
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+|--force\s+)*(-[a-zA-Z]*r[a-zA-Z]*|--recursive)\s+(/|~|\$HOME|/Users)'; then
    block "SYSTEM" "Recursive deletion of system/home directory"
fi
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*\s+|--recursive\s+)*(-[a-zA-Z]*f[a-zA-Z]*|--force)\s+(/|~|\$HOME|/Users)'; then
    block "SYSTEM" "Forced recursive deletion of system/home directory"
fi
# Shorthand: rm -rf / or rm -rf ~
if echo "$COMMAND" | grep -qE 'rm\s+-rf\s+(/|~|\$HOME|/Users)\b'; then
    block "SYSTEM" "Catastrophic deletion: rm -rf on root or home"
fi
# rm -rf . (delete entire current directory)
if echo "$COMMAND" | grep -qE 'rm\s+-rf\s+\.$'; then
    block "SYSTEM" "Deleting entire current directory"
fi
# sudo rm -rf anything
if echo "$COMMAND" | grep -qE 'sudo\s+rm\s+-rf'; then
    block "SYSTEM" "Privileged recursive forced deletion"
fi
# Disk/filesystem destruction
if echo "$CMD_LOWER" | grep -qE '(mkfs|fdisk|diskutil\s+erase)'; then
    block "SYSTEM" "Disk/filesystem destructive operation"
fi
# Raw disk write
if echo "$COMMAND" | grep -qE 'dd\s+if=.*of=/dev/'; then
    block "SYSTEM" "Raw disk write operation"
fi
# Fork bomb
if echo "$COMMAND" | grep -qF ':(){ :|:&};'; then
    block "SYSTEM" "Fork bomb detected"
fi
# System shutdown/reboot
if echo "$CMD_LOWER" | grep -qE '^\s*(sudo\s+)?(shutdown|reboot|halt|poweroff)\b'; then
    block "SYSTEM" "System shutdown/reboot command"
fi
# World-writable root
if echo "$COMMAND" | grep -qE 'chmod\s+(-R\s+)?777\s+/'; then
    block "SYSTEM" "Setting world-writable permissions on root"
fi

# =============================================================================
# CATEGORY 2: CREDENTIAL EXFILTRATION
# =============================================================================

# Printing credentials to stdout
if echo "$COMMAND" | grep -qE '(echo|printf|cat)\s.*keychain\.sh\s+get'; then
    block "CREDENTIALS" "Credential value would be printed to stdout. Use subshell expansion instead: --token \"\$(keychain.sh get ...)\""
fi
# Piping/sending credentials to external URLs
if echo "$COMMAND" | grep -qE '(curl|wget|http).*\$\(.*keychain\.sh\s+get'; then
    block "CREDENTIALS" "Credential value being sent to external URL. Use env var + CLI flag instead."
fi
# Writing credentials to files (detecting keychain get output redirected to file)
if echo "$COMMAND" | grep -qE 'keychain\.sh\s+get.*[>|]\s*(.*\.env|.*\.json|.*\.yaml|.*\.yml|.*\.toml|.*\.cfg|.*\.conf|.*\.ini)'; then
    block "CREDENTIALS" "Credential value being written to config file. Use keychain at runtime instead."
fi

# =============================================================================
# CATEGORY 3: DATABASE DESTRUCTION
# =============================================================================

if echo "$CMD_LOWER" | grep -qE '(drop\s+database|drop\s+schema)'; then
    block "DATABASE" "Dropping entire database or schema"
fi
if echo "$CMD_LOWER" | grep -qE 'truncate\s+(table\s+)?[a-z]'; then
    block "DATABASE" "Truncating table (mass data deletion)"
fi
# DELETE without WHERE clause (mass deletion)
if echo "$CMD_LOWER" | grep -qE 'delete\s+from\s+\w+\s*;' | grep -qvE 'where'; then
    block "DATABASE" "DELETE without WHERE clause (mass data deletion)"
fi

# =============================================================================
# CATEGORY 4: GIT / PUBLISHING DESTRUCTION
# =============================================================================

# Force push (any branch)
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*(-f|--force)\b'; then
    block "GIT" "Force push can destroy remote history. Use --force-with-lease if needed, or push normally."
fi
# Force push shorthand
if echo "$COMMAND" | grep -qE 'git\s+push\s+-f\b'; then
    block "GIT" "Force push can destroy remote history"
fi
# Hard reset (can lose uncommitted work)
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
    block "GIT" "Hard reset discards all uncommitted changes. Commit or stash first."
fi
# Clean -f (delete untracked files)
if echo "$COMMAND" | grep -qE 'git\s+clean\s+.*-f'; then
    block "GIT" "git clean -f permanently deletes untracked files"
fi
# Package publishing
if echo "$CMD_LOWER" | grep -qE '(npm\s+publish|cargo\s+publish|twine\s+upload|gem\s+push|pip\s+.*upload)'; then
    block "PUBLISHING" "Publishing a package to a public registry"
fi

# =============================================================================
# CATEGORY 5: PRODUCTION DEPLOYMENTS
# =============================================================================

# Vercel production deploy
if echo "$COMMAND" | grep -qE 'vercel\s+(deploy\s+)?.*--prod'; then
    block "PRODUCTION" "Production deployment to Vercel. Review and run manually: ! vercel deploy --prod"
fi
# Generic --production flag
if echo "$COMMAND" | grep -qE -- '--production( |$|")' && echo "$CMD_LOWER" | grep -qE '(deploy|push|migrate|release)'; then
    block "PRODUCTION" "Production operation detected. Review and confirm."
fi
# Terraform destroy
if echo "$CMD_LOWER" | grep -qE 'terraform\s+destroy'; then
    block "PRODUCTION" "Terraform destroy will delete infrastructure"
fi

# =============================================================================
# CATEGORY 6: ACCOUNT / VISIBILITY CHANGES
# =============================================================================

# Making repo public
if echo "$COMMAND" | grep -qE 'gh\s+repo\s+edit\s+.*--visibility\s+public'; then
    block "VISIBILITY" "Making repository public — this exposes all code"
fi
# Deleting a repository
if echo "$COMMAND" | grep -qE 'gh\s+repo\s+delete'; then
    block "DESTRUCTIVE" "Deleting a GitHub repository"
fi
# Deleting a Vercel project
if echo "$COMMAND" | grep -qE 'vercel\s+(project\s+)?rm\b'; then
    block "DESTRUCTIVE" "Deleting a Vercel project"
fi
# Deleting a Supabase project
if echo "$CMD_LOWER" | grep -qE 'supabase\s+projects?\s+delete'; then
    block "DESTRUCTIVE" "Deleting a Supabase project"
fi

# =============================================================================
# CATEGORY 7: FINANCIAL / MESSAGING
# =============================================================================

# Stripe charges (via curl)
if echo "$CMD_LOWER" | grep -qE 'curl.*api\.stripe\.com.*(charges|payment_intents).*-d'; then
    block "FINANCIAL" "Creating a real Stripe charge/payment"
fi
# Sending emails via CLI
if echo "$CMD_LOWER" | grep -qE '(^|[|;&\s])(sendmail|mailx?|mutt)\s'; then
    block "MESSAGING" "Sending email to real recipients"
fi

# =============================================================================
# CUSTOM RULES (autopilot can append, never remove)
# =============================================================================

CUSTOM_RULES="$HOME/MCPs/autopilot/config/guardian-custom-rules.txt"
if [ -f "$CUSTOM_RULES" ]; then
    while IFS='|' read -r category pattern reason; do
        # Skip comments and empty lines
        [[ "$category" =~ ^#.*$ ]] && continue
        [ -z "$category" ] && continue
        [ -z "$pattern" ] && continue

        if echo "$CMD_LOWER" | grep -qiE "$pattern"; then
            block "$category" "${reason:-Blocked by custom rule}"
        fi
    done < "$CUSTOM_RULES"
fi

# =============================================================================
# ALL CLEAR — allow the command
# =============================================================================

exit 0
