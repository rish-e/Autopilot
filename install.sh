#!/bin/bash
# Autopilot Installer — Sets up the fully autonomous Claude Code agent
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rish-e/autopilot/main/install.sh | bash
#   OR
#   git clone https://github.com/rish-e/autopilot.git && cd autopilot && ./install.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

REPO_URL="https://github.com/rish-e/autopilot.git"
INSTALL_DIR="$HOME/MCPs/autopilot"
AGENT_DIR="$HOME/.claude/agents"
SETTINGS_FILE="$HOME/.claude/settings.json"
SETTINGS_LOCAL="$HOME/.claude/settings.local.json"

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; }

echo ""
echo -e "${BOLD}  ___        _              _ _       _   ${NC}"
echo -e "${BOLD} / _ \      | |            (_) |     | |  ${NC}"
echo -e "${BOLD}/ /_\ \_   _| |_ ___  _ __  _| | ___ | |_ ${NC}"
echo -e "${BOLD}|  _  | | | | __/ _ \| '_ \| | |/ _ \| __|${NC}"
echo -e "${BOLD}| | | | |_| | || (_) | |_) | | | (_) | |_ ${NC}"
echo -e "${BOLD}\_| |_/\__,_|\__\___/| .__/|_|_|\___/ \__|${NC}"
echo -e "${BOLD}                     | |                    ${NC}"
echo -e "${BOLD}                     |_|                    ${NC}"
echo ""
echo -e "${BOLD}Fully Autonomous Claude Code Agent${NC}"
echo -e "Self-expanding | Browser automation | Hard safety rails"
echo ""

# ─── Preflight Checks ─────────────────────────────────────────────────────────

info "Checking prerequisites..."

# Check OS
if [[ "$(uname)" != "Darwin" ]]; then
    fail "Autopilot currently supports macOS only (uses macOS Keychain)."
    exit 1
fi
ok "macOS detected"

# Check Claude Code
if ! command -v claude &>/dev/null; then
    fail "Claude Code not found. Install it first: https://claude.ai/code"
    exit 1
fi
ok "Claude Code installed"

# Check Homebrew
if ! command -v brew &>/dev/null; then
    warn "Homebrew not found. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
ok "Homebrew available"

# Check Node.js
if ! command -v node &>/dev/null; then
    warn "Node.js not found. Installing via Homebrew..."
    brew install node
fi
ok "Node.js $(node --version)"

# Check jq
if ! command -v jq &>/dev/null; then
    info "Installing jq..."
    brew install jq
fi
ok "jq available"

# ─── Install Files ─────────────────────────────────────────────────────────────

info "Installing Autopilot..."

# Determine source: if running from cloned repo or via curl
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/agent/autopilot.md" ]; then
    # Running from cloned repo
    SOURCE_DIR="$SCRIPT_DIR"
    info "Installing from local clone: $SOURCE_DIR"
else
    # Running via curl — clone first
    info "Cloning repository..."
    TMP_DIR=$(mktemp -d)
    git clone --depth 1 "$REPO_URL" "$TMP_DIR/autopilot" 2>/dev/null
    SOURCE_DIR="$TMP_DIR/autopilot"
fi

# Create directories
mkdir -p "$INSTALL_DIR"/{bin,config,services}
mkdir -p "$AGENT_DIR"

# Copy core files
cp -f "$SOURCE_DIR/bin/keychain.sh" "$INSTALL_DIR/bin/"
cp -f "$SOURCE_DIR/bin/guardian.sh" "$INSTALL_DIR/bin/"
cp -f "$SOURCE_DIR/bin/setup-clis.sh" "$INSTALL_DIR/bin/"
cp -f "$SOURCE_DIR/bin/test-guardian.sh" "$INSTALL_DIR/bin/"
ok "Scripts installed"

cp -f "$SOURCE_DIR/config/decision-framework.md" "$INSTALL_DIR/config/"
cp -f "$SOURCE_DIR/config/trusted-mcps.yaml" "$INSTALL_DIR/config/"
ok "Config installed"

# Only create custom rules file if it doesn't exist (preserve user additions)
if [ ! -f "$INSTALL_DIR/config/guardian-custom-rules.txt" ]; then
    cp "$SOURCE_DIR/config/guardian-custom-rules.txt" "$INSTALL_DIR/config/"
fi
ok "Guardian custom rules preserved"

# Copy service registry (don't overwrite user modifications)
for svc in "$SOURCE_DIR/services/"*.md; do
    basename=$(basename "$svc")
    if [ ! -f "$INSTALL_DIR/services/$basename" ] || [ "$basename" = "_template.md" ]; then
        cp "$svc" "$INSTALL_DIR/services/"
    fi
done
ok "Service registry installed"

# Copy agent definition
cp -f "$SOURCE_DIR/agent/autopilot.md" "$AGENT_DIR/autopilot.md"
ok "Agent definition installed at $AGENT_DIR/autopilot.md"

# Make scripts executable
chmod +x "$INSTALL_DIR/bin/"*.sh
ok "Scripts made executable"

# ─── Configure Guardian Hook ──────────────────────────────────────────────────

info "Configuring guardian hook..."

if [ -f "$SETTINGS_FILE" ]; then
    # Check if hook already exists
    if jq -e '.hooks.PreToolUse' "$SETTINGS_FILE" &>/dev/null; then
        # Check if our guardian is already in there
        if jq -e '.hooks.PreToolUse[] | select(.hooks[].command | contains("guardian.sh"))' "$SETTINGS_FILE" &>/dev/null; then
            ok "Guardian hook already configured"
        else
            # Add our hook to existing PreToolUse array
            jq '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"'"$INSTALL_DIR"'/bin/guardian.sh","timeout":10}]}]' \
                "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
            ok "Guardian hook added to existing hooks"
        fi
    else
        # Add hooks section
        jq '. + {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"'"$INSTALL_DIR"'/bin/guardian.sh","timeout":10}]}]}}' \
            "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
        ok "Guardian hook configured"
    fi
else
    # Create settings.json with hook
    cat > "$SETTINGS_FILE" << SETTINGS
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$INSTALL_DIR/bin/guardian.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
SETTINGS
    ok "Guardian hook configured (new settings.json)"
fi

# ─── Configure Permissions ─────────────────────────────────────────────────────

info "Configuring smart permissions..."

if [ -f "$SETTINGS_LOCAL" ]; then
    # Check if "Bash" is already in allow list
    if jq -e '.permissions.allow | index("Bash")' "$SETTINGS_LOCAL" &>/dev/null; then
        ok "Bash auto-approve already configured"
    else
        # Add Bash to existing allow list
        jq '.permissions.allow = ((.permissions.allow // []) + ["Bash","Read","Edit","Write","Glob","Grep","WebFetch","WebSearch","Agent","NotebookEdit"] | unique)' \
            "$SETTINGS_LOCAL" > "$SETTINGS_LOCAL.tmp" && mv "$SETTINGS_LOCAL.tmp" "$SETTINGS_LOCAL"
        ok "Smart permissions added"
    fi
else
    # Create settings.local.json with permissions
    cat > "$SETTINGS_LOCAL" << 'PERMS'
{
  "permissions": {
    "allow": [
      "Bash",
      "Read",
      "Edit",
      "Write",
      "Glob",
      "Grep",
      "WebFetch",
      "WebSearch",
      "Agent",
      "NotebookEdit"
    ]
  }
}
PERMS
    ok "Smart permissions configured (new settings.local.json)"
fi

# ─── Run Guardian Tests ────────────────────────────────────────────────────────

info "Running guardian test suite..."
if "$INSTALL_DIR/bin/test-guardian.sh" &>/dev/null; then
    ok "All guardian tests passed"
else
    warn "Some guardian tests failed — check $INSTALL_DIR/bin/test-guardian.sh"
fi

# ─── Optional: Install CLIs ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Optional: Install recommended CLIs?${NC}"
echo "  This installs: gh (GitHub), vercel, supabase"
echo "  Autopilot can also install these on-demand when needed."
echo ""
read -p "Install CLIs now? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    "$INSTALL_DIR/bin/setup-clis.sh"
fi

# ─── Clean Up ──────────────────────────────────────────────────────────────────

if [ -n "${TMP_DIR:-}" ] && [ -d "${TMP_DIR:-}" ]; then
    rm -rf "$TMP_DIR"
fi

# ─── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}Autopilot installed successfully!${NC}"
echo ""
echo "  Start it:  claude --agent autopilot"
echo ""
echo "  What's installed:"
echo "    Agent:     $AGENT_DIR/autopilot.md"
echo "    System:    $INSTALL_DIR/"
echo "    Guardian:  Active (PreToolUse hook in settings.json)"
echo "    Perms:     Bash auto-approved (guardian provides safety)"
echo ""
echo "  First run:"
echo "    The first time Autopilot needs a service, it will ask for"
echo "    your login credentials once and handle everything else."
echo ""
echo "  Uninstall:  ~/MCPs/autopilot/uninstall.sh"
echo ""
