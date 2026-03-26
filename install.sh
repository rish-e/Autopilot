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

# ─── Detect Platform ────────────────────────────────────────────────────────

detect_platform() {
    case "$(uname -s)" in
        Darwin)  echo "macos" ;;
        Linux)
            if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *)       echo "unknown" ;;
    esac
}

PLATFORM=$(detect_platform)
info "Detected platform: $PLATFORM"

# ─── Package Manager Helper ─────────────────────────────────────────────────

pkg_install() {
    local pkg="$1"
    case "$PLATFORM" in
        macos)
            brew install "$pkg"
            ;;
        linux|wsl)
            if command -v apt-get &>/dev/null; then
                sudo apt-get install -y "$pkg"
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y "$pkg"
            elif command -v pacman &>/dev/null; then
                sudo pacman -S --noconfirm "$pkg"
            elif command -v brew &>/dev/null; then
                brew install "$pkg"
            else
                fail "No supported package manager found. Install '$pkg' manually."
                return 1
            fi
            ;;
        windows)
            if command -v choco &>/dev/null; then
                choco install -y "$pkg"
            elif command -v winget &>/dev/null; then
                winget install --accept-package-agreements --accept-source-agreements "$pkg"
            elif command -v scoop &>/dev/null; then
                scoop install "$pkg"
            else
                fail "No supported package manager found. Install '$pkg' manually (choco, winget, or scoop)."
                return 1
            fi
            ;;
    esac
}

# ─── Preflight Checks ──────────────────────────────────────────────────────

info "Checking prerequisites..."

if [ "$PLATFORM" = "unknown" ]; then
    fail "Unsupported platform: $(uname -s). Autopilot supports macOS, Linux, and Windows (Git Bash/WSL)."
    exit 1
fi
ok "Platform: $PLATFORM"

# Check Claude Code
if ! command -v claude &>/dev/null; then
    fail "Claude Code not found. Install it first: https://claude.ai/code"
    exit 1
fi
ok "Claude Code installed"

# Platform-specific prerequisites
case "$PLATFORM" in
    macos)
        if ! command -v brew &>/dev/null; then
            warn "Homebrew not found. Installing..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        ok "Homebrew available"
        ;;
    linux|wsl)
        # Check for credential store
        if ! command -v secret-tool &>/dev/null; then
            warn "secret-tool not found. Installing libsecret-tools..."
            if command -v apt-get &>/dev/null; then
                sudo apt-get install -y libsecret-tools
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y libsecret
            elif command -v pacman &>/dev/null; then
                sudo pacman -S --noconfirm libsecret
            else
                warn "Could not install secret-tool automatically. Install libsecret-tools manually."
            fi
        fi
        if command -v secret-tool &>/dev/null; then
            ok "secret-tool available (credential store)"
        else
            warn "secret-tool not available — credentials will need manual configuration"
        fi
        ;;
    windows)
        # cmdkey is built into Windows
        if command -v cmdkey.exe &>/dev/null || command -v cmdkey &>/dev/null; then
            ok "Windows Credential Manager available"
        else
            warn "cmdkey not found — ensure Windows system tools are in PATH"
        fi
        ;;
esac

# Check Node.js
if ! command -v node &>/dev/null; then
    warn "Node.js not found. Installing..."
    case "$PLATFORM" in
        macos) brew install node ;;
        linux|wsl) pkg_install "nodejs" || pkg_install "node" ;;
        windows) pkg_install "nodejs" ;;
    esac
fi
ok "Node.js $(node --version)"

# Check jq
if ! command -v jq &>/dev/null; then
    info "Installing jq..."
    pkg_install "jq" || warn "Could not install jq — install manually"
fi
if command -v jq &>/dev/null; then
    ok "jq available"
fi

# ─── Install Files ──────────────────────────────────────────────────────────

info "Installing Autopilot..."

# Determine source: running from cloned repo or via curl pipe?
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "bash" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || true
fi

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/agent/autopilot.md" ]; then
    SOURCE_DIR="$SCRIPT_DIR"
    info "Installing from local clone: $SOURCE_DIR"
else
    info "Downloading Autopilot..."

    if ! command -v git &>/dev/null; then
        case "$PLATFORM" in
            macos)
                info "Installing git via Xcode Command Line Tools..."
                xcode-select --install 2>/dev/null || true
                until command -v git &>/dev/null; do sleep 2; done
                ;;
            linux|wsl) pkg_install "git" ;;
            windows) pkg_install "git" ;;
        esac
    fi

    TMP_DIR=$(mktemp -d)
    git clone --depth 1 "$REPO_URL" "$TMP_DIR/autopilot"
    SOURCE_DIR="$TMP_DIR/autopilot"
    ok "Downloaded from GitHub"
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
cp -f "$SOURCE_DIR/config/playwright-config.json" "$INSTALL_DIR/config/"
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

# ─── Configure Guardian Hook ───────────────────────────────────────────────

info "Configuring guardian hook..."

if [ -f "$SETTINGS_FILE" ]; then
    if jq -e '.hooks.PreToolUse' "$SETTINGS_FILE" &>/dev/null; then
        if jq -e '.hooks.PreToolUse[] | select(.hooks[].command | contains("guardian.sh"))' "$SETTINGS_FILE" &>/dev/null; then
            ok "Guardian hook already configured"
        else
            jq '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"'"$INSTALL_DIR"'/bin/guardian.sh","timeout":10}]}]' \
                "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
            ok "Guardian hook added to existing hooks"
        fi
    else
        jq '. + {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"'"$INSTALL_DIR"'/bin/guardian.sh","timeout":10}]}]}}' \
            "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
        ok "Guardian hook configured"
    fi
else
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

# ─── Configure Permissions ─────────────────────────────────────────────────

info "Configuring smart permissions..."

if [ -f "$SETTINGS_LOCAL" ]; then
    if jq -e '.permissions.allow | index("Bash")' "$SETTINGS_LOCAL" &>/dev/null; then
        ok "Bash auto-approve already configured"
    else
        jq '.permissions.allow = ((.permissions.allow // []) + ["Bash","Read","Edit","Write","Glob","Grep","WebFetch","WebSearch","Agent","NotebookEdit"] | unique)' \
            "$SETTINGS_LOCAL" > "$SETTINGS_LOCAL.tmp" && mv "$SETTINGS_LOCAL.tmp" "$SETTINGS_LOCAL"
        ok "Smart permissions added"
    fi
else
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

# ─── Configure Playwright MCP ──────────────────────────────────────────────

info "Configuring Playwright MCP for browser stability..."

PLAYWRIGHT_CONFIG="$INSTALL_DIR/config/playwright-config.json"
BROWSER_PROFILE="$INSTALL_DIR/browser-profile"
CLAUDE_JSON="$HOME/.claude.json"

mkdir -p "$BROWSER_PROFILE"
ok "Browser profile directory: $BROWSER_PROFILE"

if [ -f "$CLAUDE_JSON" ]; then
    if jq -e '.mcpServers.playwright' "$CLAUDE_JSON" &>/dev/null; then
        CURRENT_ARGS=$(jq -r '.mcpServers.playwright.args // [] | join(" ")' "$CLAUDE_JSON")
        if echo "$CURRENT_ARGS" | grep -q "playwright-config.json"; then
            ok "Playwright MCP already using autopilot config"
        else
            jq --arg config "$PLAYWRIGHT_CONFIG" --arg profile "$BROWSER_PROFILE" \
                '.mcpServers.playwright.args = (.mcpServers.playwright.args + ["--config", $config]) | .mcpServers.playwright.env.PLAYWRIGHT_MCP_USER_DATA_DIR = $profile' \
                "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
            ok "Playwright MCP updated with stability config"
        fi
    else
        jq --arg config "$PLAYWRIGHT_CONFIG" --arg profile "$BROWSER_PROFILE" \
            '.mcpServers.playwright = {"type":"stdio","command":"npx","args":["@playwright/mcp@latest","--config",$config],"env":{"PLAYWRIGHT_MCP_USER_DATA_DIR":$profile}}' \
            "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
        ok "Playwright MCP added with stability config"
    fi
else
    cat > "$CLAUDE_JSON" << CLAUDEJSON
{
  "mcpServers": {
    "playwright": {
      "type": "stdio",
      "command": "npx",
      "args": ["@playwright/mcp@latest", "--config", "$PLAYWRIGHT_CONFIG"],
      "env": {
        "PLAYWRIGHT_MCP_USER_DATA_DIR": "$BROWSER_PROFILE"
      }
    }
  }
}
CLAUDEJSON
    ok "Playwright MCP configured (new .claude.json)"
fi

# ─── Run Guardian Tests ────────────────────────────────────────────────────

info "Running guardian test suite..."
if "$INSTALL_DIR/bin/test-guardian.sh" &>/dev/null; then
    ok "All guardian tests passed"
else
    warn "Some guardian tests failed — check $INSTALL_DIR/bin/test-guardian.sh"
fi

# ─── Install CLIs ─────────────────────────────────────────────────────────

info "Installing recommended CLIs..."
"$INSTALL_DIR/bin/setup-clis.sh" || warn "Some CLIs failed to install — Autopilot will retry on-demand"

# ─── Clean Up ─────────────────────────────────────────────────────────────

if [ -n "${TMP_DIR:-}" ] && [ -d "${TMP_DIR:-}" ]; then
    rm -rf "$TMP_DIR"
fi

# ─── Done ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}Autopilot installed successfully!${NC}"
echo ""
echo "  Platform: $PLATFORM"
echo "  Start it: claude --agent autopilot"
echo ""
echo "  What's installed:"
echo "    Agent:     $AGENT_DIR/autopilot.md"
echo "    System:    $INSTALL_DIR/"
echo "    Guardian:  Active (PreToolUse hook in settings.json)"
echo "    Perms:     Bash auto-approved (guardian provides safety)"
echo "    Browser:   Playwright optimized for stability (config in $INSTALL_DIR/config/)"
echo "    Creds:     $PLATFORM credential store ($(case $PLATFORM in macos) echo "macOS Keychain";; linux|wsl) echo "GNOME Keyring / libsecret";; windows) echo "Windows Credential Manager";; esac))"
echo ""
echo "  First run:"
echo "    Autopilot will ask for your primary email and password once."
echo "    After that, it handles all service signups and logins automatically."
echo ""
echo "  Uninstall:  ~/MCPs/autopilot/uninstall.sh"
echo ""
