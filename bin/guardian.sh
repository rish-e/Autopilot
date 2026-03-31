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

# =============================================================================
# FAIL CLOSED: If jq is not available, block everything
# =============================================================================

if ! command -v jq &>/dev/null; then
    echo "GUARDIAN BLOCKED [SAFETY]: jq is not installed. Guardian cannot parse commands safely — blocking all Bash execution." >&2
    echo "Install jq: brew install jq (macOS) / sudo apt install jq (Linux)" >&2
    exit 2
fi

# Read tool call from stdin
INPUT=$(cat)

# Parse tool name
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
if [ -z "$TOOL_NAME" ]; then
    # Failed to parse — fail closed
    echo "GUARDIAN BLOCKED [SAFETY]: Could not parse tool call JSON" >&2
    exit 2
fi

# =============================================================================
# WRITE/EDIT TOOL PROTECTION
# =============================================================================
# Protect critical files from modification via Write and Edit tools.
# These tools bypass Bash entirely, so we must check them here.

if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    if [ -n "$FILE_PATH" ]; then
        # Block modifications to guardian and safety-critical files
        case "$FILE_PATH" in
            */guardian.sh|*/guardian-custom-rules.txt)
                echo "GUARDIAN BLOCKED [SELF-PROTECT]: Cannot modify guardian safety files via $TOOL_NAME tool" >&2
                exit 2
                ;;
            */.claude/settings.json|*/.claude/settings.local.json)
                echo "GUARDIAN BLOCKED [SELF-PROTECT]: Cannot modify Claude Code settings via $TOOL_NAME tool (could disable guardian hook)" >&2
                exit 2
                ;;
        esac
    fi
    exit 0
fi

# Only inspect Bash commands — allow everything else through
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Extract the command
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -z "$COMMAND" ]; then
    echo "GUARDIAN BLOCKED [SAFETY]: Could not extract command from tool call" >&2
    exit 2
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
# CATEGORY 0: GUARDIAN SELF-PROTECTION
# =============================================================================
# The guardian must protect itself. If these files are modified, the entire
# safety system can be disabled. Block ALL modification attempts.

GUARDIAN_PROTECTED_FILES="guardian\.sh|guardian-custom-rules\.txt|settings\.json|settings\.local\.json"

# Block any modification of guardian or settings files via common tools
if echo "$COMMAND" | grep -qE "(sed|awk|perl|tee|truncate|mv|cp|chmod|chown|ln|install)\s.*($GUARDIAN_PROTECTED_FILES)"; then
    block "SELF-PROTECT" "Modifying guardian or settings files is not allowed"
fi
# Block rm/unlink on guardian files
if echo "$COMMAND" | grep -qE "(rm|unlink)\s.*($GUARDIAN_PROTECTED_FILES)"; then
    block "SELF-PROTECT" "Deleting guardian or settings files is not allowed"
fi
# Block redirect/overwrite (>) but ALLOW echo append (>>) to custom rules
if echo "$COMMAND" | grep -qE "[^>]>[^>].*($GUARDIAN_PROTECTED_FILES)"; then
    block "SELF-PROTECT" "Overwriting guardian or settings files is not allowed"
fi
# Allow ONLY echo/printf append (>>) to guardian-custom-rules.txt
if echo "$COMMAND" | grep -qE ">>\s*.*($GUARDIAN_PROTECTED_FILES)" && \
   ! echo "$COMMAND" | grep -qE "^(echo|printf)\s.*>>\s*.*guardian-custom-rules\.txt"; then
    block "SELF-PROTECT" "Only echo append (>>) to guardian-custom-rules.txt is allowed"
fi
# Block chmod -x on any .sh file in the autopilot bin directory
if echo "$COMMAND" | grep -qE "chmod\s+(-[a-zA-Z]*)?(a-x|u-x|-x|000|644)\s.*(autopilot|MCPs).*bin/.*\.sh"; then
    block "SELF-PROTECT" "Removing execute permission from autopilot scripts is not allowed"
fi

# =============================================================================
# CATEGORY 1: OBFUSCATION / INTERPRETER EVASION
# =============================================================================
# These block attempts to bypass the guardian by encoding commands or using
# alternative interpreters. Must come first — before pattern-specific checks.

# Base64 piped to bash/sh (encoding bypass)
if echo "$CMD_LOWER" | grep -qE 'base64.*\|\s*(bash|sh|zsh|dash)'; then
    block "EVASION" "Base64-encoded command piped to shell interpreter"
fi
if echo "$CMD_LOWER" | grep -qE 'base64\s+-d.*\|\s*(bash|sh)'; then
    block "EVASION" "Base64-decoded content piped to shell"
fi

# Subshell execution: bash -c, sh -c, eval
if echo "$CMD_LOWER" | grep -qE '(^|\s|;|&&|\|)(bash|sh|zsh|dash)\s+-c\s'; then
    block "EVASION" "Subshell execution via interpreter -c flag. Run the command directly instead."
fi
if echo "$CMD_LOWER" | grep -qE '(^|\s|;|&&|\|)eval\s'; then
    block "EVASION" "eval can execute arbitrary code. Run the command directly instead."
fi

# source / dot-source (can execute arbitrary scripts bypassing guardian)
if echo "$CMD_LOWER" | grep -qE '(^|\s|;|&&|\|)(source|\.) '; then
    block "EVASION" "source/dot-source can execute arbitrary scripts — bypasses guardian. Run commands directly instead."
fi

# Heredoc piped to shell interpreter
if echo "$CMD_LOWER" | grep -qE '<<.*\|\s*(bash|sh|zsh|dash)'; then
    block "EVASION" "Heredoc piped to shell interpreter — bypasses guardian"
fi
if echo "$CMD_LOWER" | grep -qE 'cat\s+<<.*\|\s*(bash|sh|zsh|dash)'; then
    block "EVASION" "Heredoc piped to shell interpreter — bypasses guardian"
fi

# Python/Node/Ruby/Perl os.system or exec (interpreter bypass)
if echo "$CMD_LOWER" | grep -qE 'python[23]?\s+-c\s.*\b(os\.|subprocess|system|exec|popen)'; then
    block "EVASION" "Python executing system commands — bypasses guardian"
fi
if echo "$CMD_LOWER" | grep -qE 'node\s+-e\s.*\b(exec|spawn|child_process)'; then
    block "EVASION" "Node.js executing system commands — bypasses guardian"
fi
if echo "$CMD_LOWER" | grep -qE '(ruby|perl)\s+-e\s.*\b(system|exec|`)'; then
    block "EVASION" "Interpreter executing system commands — bypasses guardian"
fi

# =============================================================================
# CATEGORY 2: SYSTEM DESTRUCTION
# =============================================================================

# Root/home directory deletion
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+|--force\s+)*(-[a-zA-Z]*r[a-zA-Z]*|--recursive)\s+(/|~|\$HOME|/Users)'; then
    block "SYSTEM" "Recursive deletion of system/home directory"
fi
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*\s+|--recursive\s+)*(-[a-zA-Z]*f[a-zA-Z]*|--force)\s+(/|~|\$HOME|/Users)'; then
    block "SYSTEM" "Forced recursive deletion of system/home directory"
fi
if echo "$COMMAND" | grep -qE 'rm\s+-rf\s+(/|~|\$HOME|/Users)\b'; then
    block "SYSTEM" "Catastrophic deletion: rm -rf on root or home"
fi
if echo "$COMMAND" | grep -qE 'rm\s+-rf\s+\.$'; then
    block "SYSTEM" "Deleting entire current directory"
fi
if echo "$COMMAND" | grep -qE 'sudo\s+rm\s+-rf'; then
    block "SYSTEM" "Privileged recursive forced deletion"
fi
if echo "$CMD_LOWER" | grep -qE '(mkfs|fdisk|diskutil\s+erase)'; then
    block "SYSTEM" "Disk/filesystem destructive operation"
fi
if echo "$COMMAND" | grep -qE 'dd\s+if=.*of=/dev/'; then
    block "SYSTEM" "Raw disk write operation"
fi
if echo "$COMMAND" | grep -qF ':(){ :|:&};'; then
    block "SYSTEM" "Fork bomb detected"
fi
if echo "$CMD_LOWER" | grep -qE '^\s*(sudo\s+)?(shutdown|reboot|halt|poweroff)\b'; then
    block "SYSTEM" "System shutdown/reboot command"
fi
if echo "$COMMAND" | grep -qE 'chmod\s+(-R\s+)?777\s+/'; then
    block "SYSTEM" "Setting world-writable permissions on root"
fi

# =============================================================================

# =============================================================================
# CATEGORY 3: CREDENTIAL EXFILTRATION
# =============================================================================
# Protect credential values from being exposed. The INTENDED pattern is:
#   VAR=$(keychain.sh get service key 2>/dev/null)
#   command --token "$VAR"
#   unset VAR
# Block anything that would print, send, or write the raw value.

# Block: echo/printf/cat directly wrapping a keychain get subshell
# e.g. echo "$(keychain.sh get ...)"  or  echo $(keychain.sh get ...)
if echo "$COMMAND" | grep -qE '(echo|printf|cat)\s+.*\$\(.*keychain\.sh\s+get'; then
    block "CREDENTIALS" "Credential value would be printed to stdout. Use subshell expansion: --token \"\$(keychain.sh get ...)\""
fi
# Block: piping keychain output directly to echo/cat
if echo "$COMMAND" | grep -qE 'keychain\.sh\s+get[^|;]*\|\s*(echo|cat|printf|tee|head|tail)'; then
    block "CREDENTIALS" "Credential value being piped to display command"
fi
# Block: sending credentials to external URLs via curl/wget
if echo "$COMMAND" | grep -qE '(curl|wget|http).*\$\(.*keychain\.sh\s+get'; then
    block "CREDENTIALS" "Credential value being sent to external URL"
fi
if echo "$COMMAND" | grep -qE '\$\(.*keychain\.sh\s+get.*\).*(curl|wget|http)'; then
    block "CREDENTIALS" "Credential value being sent to external URL"
fi
# Block: curl with data flags sending credentials
if echo "$COMMAND" | grep -qE 'curl\s.*(-d|--data|--data-binary|--data-raw|--data-urlencode)\s.*\$\(.*keychain\.sh'; then
    block "CREDENTIALS" "Credential value being sent via curl data flag"
fi
# Block: writing credentials to files via redirect (but ALLOW 2>/dev/null and 2>&1)
if echo "$COMMAND" | grep -qE 'keychain\.sh\s+get[^;|&]*[^2]>[^&/]'; then
    block "CREDENTIALS" "Credential value being written to a file"
fi
# Block: piping credentials to network tools
if echo "$COMMAND" | grep -qE 'keychain\.sh\s+get.*\|\s*(curl|wget|http|nc|ncat|netcat|socat|mail|sendmail)'; then
    block "CREDENTIALS" "Credential value being piped to network tool"
fi
# Block: env/printenv/set that could dump exported credentials
if echo "$CMD_LOWER" | grep -qE '(^|\s|;|&&|\|)(env|printenv|set)\s*($|\s*\||\s*>|;)'; then
    block "CREDENTIALS" "env/printenv/set can expose exported credential values"
fi

# CATEGORY 4: DATABASE DESTRUCTION
# =============================================================================

if echo "$CMD_LOWER" | grep -qE '(drop\s+database|drop\s+schema)'; then
    block "DATABASE" "Dropping entire database or schema"
fi
if echo "$CMD_LOWER" | grep -qE 'truncate\s+(table\s+)?[a-z]'; then
    block "DATABASE" "Truncating table (mass data deletion)"
fi
# DELETE without WHERE clause (mass deletion)
# Matches: DELETE FROM table, DELETE FROM table;, DELETE FROM table"
# The WHERE check ensures legitimate filtered deletes pass through
if echo "$CMD_LOWER" | grep -qE 'delete\s+from\s+\w+' && ! echo "$CMD_LOWER" | grep -qE 'where'; then
    block "DATABASE" "DELETE without WHERE clause (mass data deletion)"
fi

# =============================================================================
# CATEGORY 5: GIT / PUBLISHING DESTRUCTION
# =============================================================================

# Force push — but allow --force-with-lease (safer alternative)
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force-with-lease'; then
    : # Allow --force-with-lease through (safe alternative)
elif echo "$COMMAND" | grep -qE 'git\s+push\s+.*(-f\b|--force\b)'; then
    block "GIT" "Force push can destroy remote history. Use --force-with-lease if needed, or push normally."
fi
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
    block "GIT" "Hard reset discards all uncommitted changes. Commit or stash first."
fi
if echo "$COMMAND" | grep -qE 'git\s+clean\s+.*-f'; then
    block "GIT" "git clean -f permanently deletes untracked files"
fi
if echo "$CMD_LOWER" | grep -qE '(npm\s+publish|cargo\s+publish|twine\s+upload|gem\s+push|pip\s+.*upload)'; then
    block "PUBLISHING" "Publishing a package to a public registry"
fi

# =============================================================================
# CATEGORY 6: PRODUCTION DEPLOYMENTS
# =============================================================================

if echo "$COMMAND" | grep -qE 'vercel\s+(deploy\s+)?.*--prod'; then
    block "PRODUCTION" "Production deployment to Vercel. Review and run manually: ! vercel deploy --prod"
fi
if echo "$COMMAND" | grep -qE -- '--production( |$|")' && echo "$CMD_LOWER" | grep -qE '(deploy|push|migrate|release)'; then
    block "PRODUCTION" "Production operation detected. Review and confirm."
fi
if echo "$CMD_LOWER" | grep -qE 'terraform\s+destroy'; then
    block "PRODUCTION" "Terraform destroy will delete infrastructure"
fi

# =============================================================================
# CATEGORY 7: ACCOUNT / VISIBILITY CHANGES
# =============================================================================

if echo "$COMMAND" | grep -qE 'gh\s+repo\s+edit\s+.*--visibility\s+public'; then
    block "VISIBILITY" "Making repository public — this exposes all code"
fi
if echo "$COMMAND" | grep -qE 'gh\s+repo\s+delete'; then
    block "DESTRUCTIVE" "Deleting a GitHub repository"
fi
if echo "$COMMAND" | grep -qE 'vercel\s+(project\s+)?rm\b'; then
    block "DESTRUCTIVE" "Deleting a Vercel project"
fi
if echo "$CMD_LOWER" | grep -qE 'supabase\s+projects?\s+delete'; then
    block "DESTRUCTIVE" "Deleting a Supabase project"
fi

# =============================================================================
# CATEGORY 8: FINANCIAL / MESSAGING
# =============================================================================

if echo "$CMD_LOWER" | grep -qE 'curl.*api\.stripe\.com.*(charges|payment_intents).*-d'; then
    block "FINANCIAL" "Creating a real Stripe charge/payment"
fi
if echo "$CMD_LOWER" | grep -qE '(^|[|;&\s])(sendmail|mailx?|mutt)\s'; then
    block "MESSAGING" "Sending email to real recipients"
fi

# =============================================================================
# CUSTOM RULES (autopilot can append, never remove)
# Delimiter: ::: (three colons) to avoid conflicts with regex | characters
# Legacy format with | is also supported for backwards compatibility
# =============================================================================

# Resolve install dir dynamically (supports custom install locations)
AUTOPILOT_DIR="${AUTOPILOT_DIR:-$HOME/MCPs/autopilot}"
CUSTOM_RULES="$AUTOPILOT_DIR/config/guardian-custom-rules.txt"
if [ -f "$CUSTOM_RULES" ]; then
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [ -z "$line" ] && continue

        # Parse: try ::: delimiter first, fall back to | (legacy)
        if [[ "$line" == *":::"* ]]; then
            category="${line%%:::*}"
            rest="${line#*:::}"
            pattern="${rest%%:::*}"
            reason="${rest#*:::}"
        else
            # Legacy | delimiter — use cut for reliable field splitting
            local_field_count=$(echo "$line" | awk -F'|' '{print NF}')
            if [ "$local_field_count" -ge 3 ]; then
                category=$(echo "$line" | cut -d'|' -f1)
                pattern=$(echo "$line" | cut -d'|' -f2)
                reason=$(echo "$line" | cut -d'|' -f3-)
            elif [ "$local_field_count" -eq 2 ]; then
                category=$(echo "$line" | cut -d'|' -f1)
                pattern=$(echo "$line" | cut -d'|' -f2)
                reason="Blocked by custom rule"
            else
                continue
            fi
        fi

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
