#!/bin/bash
# mcp-manifest-check.sh — MCP tool rug-pull detector (PreToolUse hook)
#
# Warns when an MCP tool call uses a name not in config/mcp-tool-manifest.json.
# A compromised or swapped MCP server may register new tools beyond its expected set.
# This hook catches that expansion at call time.
#
# Installation (in ~/.claude/settings.json, hooks section):
#   {
#     "hooks": {
#       "PreToolUse": [
#         {"matcher": "mcp__*", "hooks": [{"type": "command", "command": "~/MCPs/autopilot/bin/mcp-manifest-check.sh"}]}
#       ]
#     }
#   }
#
# Note: guardian.sh also performs this check for autopilot sessions.
# This script enables the check in all Claude Code sessions.
#
# Exit codes:
#   0 — tool is trusted (or manifest not found — fail open)
#   1 — tool unknown, warning printed (does NOT block — rug-pull is a warning, not a halt)

set -uo pipefail

AUTOPILOT_DIR="${AUTOPILOT_DIR:-$HOME/MCPs/autopilot}"
MANIFEST="$AUTOPILOT_DIR/config/mcp-tool-manifest.json"

# Read tool call from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only check mcp__ tool calls
if [[ "$TOOL_NAME" != mcp__* ]]; then
    exit 0
fi

# If manifest doesn't exist or jq unavailable, fail open
if [ ! -f "$MANIFEST" ] || ! command -v jq &>/dev/null; then
    exit 0
fi

TRUSTED=$(jq -r --arg t "$TOOL_NAME" '.trusted_prefixes[] | select($t | startswith(.))' "$MANIFEST" 2>/dev/null | head -1)

if [ -z "$TRUSTED" ]; then
    echo "MCP_UNKNOWN: '$TOOL_NAME' is not in config/mcp-tool-manifest.json" >&2
    echo "Possible rug-pull or new MCP server added without updating the manifest." >&2
    echo "If legitimate, add the prefix to: $MANIFEST" >&2
    exit 1  # Warning exit — Claude Code shows this to the user but does NOT block the tool
fi

exit 0
