#!/bin/bash
# Autopilot Uninstaller — Cleanly removes the autopilot system
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="$HOME/MCPs/autopilot"
AGENT_FILE="$HOME/.claude/agents/autopilot.md"
SETTINGS_FILE="$HOME/.claude/settings.json"
SETTINGS_LOCAL="$HOME/.claude/settings.local.json"

echo ""
echo -e "${BOLD}Uninstalling Autopilot${NC}"
echo ""

# Remove agent definition
if [ -f "$AGENT_FILE" ]; then
    rm "$AGENT_FILE"
    echo -e "${GREEN}[OK]${NC} Removed agent definition"
fi

# Remove guardian hook from settings.json
if [ -f "$SETTINGS_FILE" ]; then
    if jq -e '.hooks.PreToolUse' "$SETTINGS_FILE" &>/dev/null; then
        jq '.hooks.PreToolUse = [.hooks.PreToolUse[] | select(.hooks[].command | contains("guardian.sh") | not)]' \
            "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
        # Clean up empty hooks
        jq 'if .hooks.PreToolUse == [] then del(.hooks.PreToolUse) else . end | if .hooks == {} then del(.hooks) else . end' \
            "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
        echo -e "${GREEN}[OK]${NC} Removed guardian hook from settings.json"
    fi
fi

echo ""
echo -e "${YELLOW}Note:${NC} The following were NOT removed (may contain your data):"
echo "  - $INSTALL_DIR/ (service registry, credentials config, custom rules)"
echo "  - Permissions in $SETTINGS_LOCAL (Bash auto-approve)"
echo "  - Any credentials stored in macOS Keychain (under 'claude-autopilot/' prefix)"
echo "  - Installed CLIs (gh, vercel, supabase)"
echo ""
echo "To fully remove everything:"
echo "  rm -rf $INSTALL_DIR"
echo "  # Remove 'Bash' from permissions.allow in $SETTINGS_LOCAL"
echo "  # Keychain entries: security delete-generic-password -s 'claude-autopilot/SERVICE' -a 'KEY'"
echo ""
echo -e "${GREEN}${BOLD}Autopilot uninstalled.${NC}"
