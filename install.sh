#!/bin/bash
# Autopilot Installer — Sets up the fully autonomous Claude Code agent
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rish-e/autopilot/main/install.sh | bash
#   OR
#   git clone https://github.com/rish-e/autopilot.git && cd autopilot && ./install.sh

set -euo pipefail

# Clean up temp files on exit (even on failure)
TMP_DIR=""
cleanup() { [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

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

# ─── Install Core Dependencies ────────────────────────────────────────────
# Everything Autopilot needs gets installed here. The user should never have
# to install anything manually.

info "Installing dependencies (this may take a minute on first run)..."

# --- Package Manager ---
case "$PLATFORM" in
    macos)
        if ! command -v brew &>/dev/null; then
            info "Installing Homebrew..."
            # Use NONINTERACTIVE to avoid prompts
            NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" 2>/dev/null || true
            # Add brew to PATH for Apple Silicon and Intel
            if [ -f /opt/homebrew/bin/brew ]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [ -f /usr/local/bin/brew ]; then
                eval "$(/usr/local/bin/brew shellenv)"
            fi
        fi
        if command -v brew &>/dev/null; then
            ok "Homebrew available"
            HAS_BREW=true
        else
            warn "Homebrew could not be installed (may need admin access)"
            warn "Autopilot will use npm and direct downloads as fallback"
            HAS_BREW=false
        fi
        ;;
    linux|wsl)
        # Check for credential store
        if ! command -v secret-tool &>/dev/null; then
            info "Installing credential store (libsecret-tools)..."
            if command -v apt-get &>/dev/null; then
                sudo apt-get install -y libsecret-tools 2>/dev/null || true
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y libsecret 2>/dev/null || true
            elif command -v pacman &>/dev/null; then
                sudo pacman -S --noconfirm libsecret 2>/dev/null || true
            fi
        fi
        if command -v secret-tool &>/dev/null; then
            ok "Credential store available (secret-tool)"
        else
            warn "secret-tool not available — credentials will need manual configuration"
        fi
        HAS_BREW=false
        if command -v brew &>/dev/null; then HAS_BREW=true; fi
        ;;
    windows)
        if command -v cmdkey.exe &>/dev/null || command -v cmdkey &>/dev/null; then
            ok "Credential store available (Windows Credential Manager)"
        else
            warn "cmdkey not found — ensure Windows system tools are in PATH"
        fi
        HAS_BREW=false
        ;;
esac

# --- Node.js ---
if ! command -v node &>/dev/null; then
    info "Installing Node.js..."
    case "$PLATFORM" in
        macos)
            if [ "$HAS_BREW" = true ]; then
                brew install node 2>/dev/null
            else
                # Direct download fallback
                curl -fsSL https://nodejs.org/dist/v20.18.0/node-v20.18.0.pkg -o /tmp/node.pkg && \
                    sudo installer -pkg /tmp/node.pkg -target / 2>/dev/null && rm -f /tmp/node.pkg || true
            fi
            ;;
        linux|wsl)
            # Try NodeSource first (most reliable), then package managers
            curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | sudo -E bash - 2>/dev/null && \
                sudo apt-get install -y nodejs 2>/dev/null || \
                pkg_install "nodejs" || pkg_install "node" || true
            ;;
        windows) pkg_install "nodejs" || true ;;
    esac
fi
if command -v node &>/dev/null; then
    ok "Node.js $(node --version)"
else
    fail "Node.js could not be installed. Install it from https://nodejs.org and re-run the installer."
    exit 1
fi

# --- jq ---
if ! command -v jq &>/dev/null; then
    info "Installing jq..."
    case "$PLATFORM" in
        macos)
            if [ "$HAS_BREW" = true ]; then
                brew install jq 2>/dev/null
            else
                # Direct binary download
                curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-arm64" -o /usr/local/bin/jq 2>/dev/null && \
                    chmod +x /usr/local/bin/jq || \
                curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64" -o /usr/local/bin/jq 2>/dev/null && \
                    chmod +x /usr/local/bin/jq || true
            fi
            ;;
        linux|wsl)
            if command -v apt-get &>/dev/null; then
                sudo apt-get install -y jq 2>/dev/null
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y jq 2>/dev/null
            elif command -v pacman &>/dev/null; then
                sudo pacman -S --noconfirm jq 2>/dev/null
            else
                # Direct binary
                curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64" -o /usr/local/bin/jq 2>/dev/null && \
                    chmod +x /usr/local/bin/jq || true
            fi
            ;;
        windows) pkg_install "jq" || true ;;
    esac
fi
if command -v jq &>/dev/null; then
    ok "jq available"
else
    fail "jq could not be installed. The guardian safety hook requires it."
    fail "Install it from https://jqlang.github.io/jq/download/ and re-run the installer."
    exit 1
fi

# --- Google Chrome (needed for browser automation) ---
find_chrome() {
    case "$PLATFORM" in
        macos)
            if [ -d "/Applications/Google Chrome.app" ]; then echo "found"; return; fi
            if [ -d "$HOME/Applications/Google Chrome.app" ]; then echo "found"; return; fi
            ;;
        linux|wsl)
            if command -v google-chrome &>/dev/null || command -v google-chrome-stable &>/dev/null || command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null; then
                echo "found"; return
            fi
            ;;
        windows)
            if [ -f "/c/Program Files/Google/Chrome/Application/chrome.exe" ] || [ -f "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe" ]; then
                echo "found"; return
            fi
            if command -v chrome.exe &>/dev/null; then echo "found"; return; fi
            ;;
    esac
    echo "missing"
}

if [ "$(find_chrome)" = "found" ]; then
    ok "Google Chrome found"
else
    info "Installing Google Chrome (needed for browser automation)..."
    case "$PLATFORM" in
        macos)
            if [ "$HAS_BREW" = true ]; then
                brew install --cask google-chrome 2>/dev/null && ok "Chrome installed via brew" || true
            fi
            # Fallback: direct DMG download
            if [ "$(find_chrome)" = "missing" ]; then
                curl -fsSL "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg" -o /tmp/chrome.dmg 2>/dev/null && \
                    hdiutil attach /tmp/chrome.dmg -quiet 2>/dev/null && \
                    cp -R "/Volumes/Google Chrome/Google Chrome.app" /Applications/ 2>/dev/null && \
                    hdiutil detach "/Volumes/Google Chrome" -quiet 2>/dev/null && \
                    rm -f /tmp/chrome.dmg && \
                    ok "Chrome installed via direct download" || true
            fi
            ;;
        linux|wsl)
            if command -v apt-get &>/dev/null; then
                curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb 2>/dev/null && \
                    sudo apt-get install -y /tmp/chrome.deb 2>/dev/null && \
                    rm -f /tmp/chrome.deb && \
                    ok "Chrome installed" || true
            fi
            # Fallback to chromium
            if [ "$(find_chrome)" = "missing" ]; then
                if command -v apt-get &>/dev/null; then
                    sudo apt-get install -y chromium-browser 2>/dev/null || sudo apt-get install -y chromium 2>/dev/null || true
                elif command -v dnf &>/dev/null; then
                    sudo dnf install -y chromium 2>/dev/null || true
                elif command -v pacman &>/dev/null; then
                    sudo pacman -S --noconfirm chromium 2>/dev/null || true
                fi
                if [ "$(find_chrome)" = "found" ]; then ok "Chromium installed as Chrome alternative"; fi
            fi
            ;;
        windows)
            if command -v winget &>/dev/null; then
                winget install --accept-package-agreements --accept-source-agreements Google.Chrome 2>/dev/null && \
                    ok "Chrome installed via winget" || true
            elif command -v choco &>/dev/null; then
                choco install -y googlechrome 2>/dev/null && ok "Chrome installed via choco" || true
            fi
            ;;
    esac

    if [ "$(find_chrome)" = "found" ]; then
        ok "Google Chrome ready"
    else
        warn "Chrome could not be installed automatically"
        warn "Install it from https://google.com/chrome — browser automation won't work without it"
        warn "Autopilot will still work for CLI-only tasks"
    fi
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
                # Wait up to 5 minutes for Xcode CLT installation
                local xcode_wait=0
                until command -v git &>/dev/null; do
                    sleep 2
                    xcode_wait=$((xcode_wait + 2))
                    if [ "$xcode_wait" -ge 300 ]; then
                        fail "Xcode Command Line Tools installation timed out after 5 minutes"
                        fail "Complete the installation manually, then re-run this installer"
                        exit 1
                    fi
                done
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
COMMANDS_DIR="$HOME/.claude/commands"
mkdir -p "$INSTALL_DIR"/{bin,config,services}
mkdir -p "$AGENT_DIR"
mkdir -p "$COMMANDS_DIR"

# Copy core files
cp -f "$SOURCE_DIR/bin/keychain.sh" "$INSTALL_DIR/bin/"
cp -f "$SOURCE_DIR/bin/guardian.sh" "$INSTALL_DIR/bin/"
cp -f "$SOURCE_DIR/bin/setup-clis.sh" "$INSTALL_DIR/bin/"
cp -f "$SOURCE_DIR/bin/test-guardian.sh" "$INSTALL_DIR/bin/"
cp -f "$SOURCE_DIR/bin/chrome-debug.sh" "$INSTALL_DIR/bin/"
cp -f "$SOURCE_DIR/bin/audit.sh" "$INSTALL_DIR/bin/"
cp -f "$SOURCE_DIR/bin/snapshot.sh" "$INSTALL_DIR/bin/"
cp -f "$SOURCE_DIR/bin/session.sh" "$INSTALL_DIR/bin/"
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

# Copy slash command
cp -f "$SOURCE_DIR/commands/autopilot.md" "$COMMANDS_DIR/autopilot.md"
ok "Slash command installed (/autopilot)"

# Make scripts executable
chmod +x "$INSTALL_DIR/bin/"*.sh
ok "Scripts made executable"

# ─── Configure Guardian Hook ───────────────────────────────────────────────

info "Configuring guardian hook..."

# Guardian hooks for Bash, Write, and Edit tools
GUARDIAN_CMD="$INSTALL_DIR/bin/guardian.sh"
GUARDIAN_HOOKS='[
  {"matcher":"Bash","hooks":[{"type":"command","command":"GUARDIAN_PATH","timeout":10}]},
  {"matcher":"Write","hooks":[{"type":"command","command":"GUARDIAN_PATH","timeout":10}]},
  {"matcher":"Edit","hooks":[{"type":"command","command":"GUARDIAN_PATH","timeout":10}]}
]'
GUARDIAN_HOOKS=$(echo "$GUARDIAN_HOOKS" | sed "s|GUARDIAN_PATH|$GUARDIAN_CMD|g")

if [ -f "$SETTINGS_FILE" ]; then
    if jq -e '.hooks.PreToolUse' "$SETTINGS_FILE" &>/dev/null; then
        # Check if guardian is already configured
        if jq -e '.hooks.PreToolUse[] | select(.hooks[].command | contains("guardian.sh"))' "$SETTINGS_FILE" &>/dev/null; then
            # Check if Write/Edit hooks exist too
            HOOK_COUNT=$(jq '[.hooks.PreToolUse[] | select(.hooks[].command | contains("guardian.sh"))] | length' "$SETTINGS_FILE")
            if [ "$HOOK_COUNT" -ge 3 ]; then
                ok "Guardian hooks already configured (Bash + Write + Edit)"
            else
                # Remove old guardian hooks, add all three
                jq --argjson hooks "$GUARDIAN_HOOKS" \
                    '.hooks.PreToolUse = ([.hooks.PreToolUse[] | select(.hooks[].command | contains("guardian.sh") | not)] + $hooks)' \
                    "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
                ok "Guardian hooks updated (added Write + Edit protection)"
            fi
        else
            jq --argjson hooks "$GUARDIAN_HOOKS" \
                '.hooks.PreToolUse += $hooks' \
                "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
            ok "Guardian hooks added (Bash + Write + Edit)"
        fi
    else
        jq --argjson hooks "$GUARDIAN_HOOKS" \
            '. + {"hooks":{"PreToolUse":$hooks}}' \
            "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
        ok "Guardian hooks configured (Bash + Write + Edit)"
    fi
else
    cat > "$SETTINGS_FILE" << SETTINGS
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "$GUARDIAN_CMD", "timeout": 10}]
      },
      {
        "matcher": "Write",
        "hooks": [{"type": "command", "command": "$GUARDIAN_CMD", "timeout": 10}]
      },
      {
        "matcher": "Edit",
        "hooks": [{"type": "command", "command": "$GUARDIAN_CMD", "timeout": 10}]
      }
    ]
  }
}
SETTINGS
    ok "Guardian hooks configured (new settings.json)"
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

info "Configuring Playwright MCP with persistent Chrome (CDP)..."

PLAYWRIGHT_CONFIG="$INSTALL_DIR/config/playwright-config.json"
BROWSER_PROFILE="$INSTALL_DIR/browser-profile"
CLAUDE_JSON="$HOME/.claude.json"
CHROME_DEBUG="$INSTALL_DIR/bin/chrome-debug.sh"

mkdir -p "$BROWSER_PROFILE"

# Start persistent Chrome with CDP (if not already running)
if "$CHROME_DEBUG" status > /dev/null 2>&1; then
    ok "Chrome CDP already running"
else
    info "Starting persistent Chrome with CDP..."
    "$CHROME_DEBUG" start || warn "Could not start Chrome CDP — start manually: $CHROME_DEBUG start"
fi

# Detect the CDP endpoint URL (handles IPv4 vs IPv6)
CDP_URL=$("$CHROME_DEBUG" url 2>/dev/null || echo "http://127.0.0.1:9222")

# Update the playwright config with detected CDP URL
jq --arg url "$CDP_URL" '.browser.cdpEndpoint = $url' \
    "$PLAYWRIGHT_CONFIG" > "$PLAYWRIGHT_CONFIG.tmp" && mv "$PLAYWRIGHT_CONFIG.tmp" "$PLAYWRIGHT_CONFIG"
ok "Playwright config updated with CDP endpoint: $CDP_URL"

# Configure Playwright MCP in Claude Code to connect via CDP
if [ -f "$CLAUDE_JSON" ]; then
    if jq -e '.mcpServers.playwright' "$CLAUDE_JSON" &>/dev/null; then
        CURRENT_ARGS=$(jq -r '.mcpServers.playwright.args // [] | join(" ")' "$CLAUDE_JSON")
        if echo "$CURRENT_ARGS" | grep -q "cdp-endpoint"; then
            ok "Playwright MCP already using CDP endpoint"
        else
            jq --arg url "$CDP_URL" \
                '.mcpServers.playwright = {"type":"stdio","command":"npx","args":["@playwright/mcp@latest","--cdp-endpoint",$url],"env":{}}' \
                "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
            ok "Playwright MCP updated with CDP endpoint"
        fi
    else
        jq --arg url "$CDP_URL" \
            '.mcpServers.playwright = {"type":"stdio","command":"npx","args":["@playwright/mcp@latest","--cdp-endpoint",$url],"env":{}}' \
            "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
        ok "Playwright MCP added with CDP endpoint"
    fi
else
    cat > "$CLAUDE_JSON" << CLAUDEJSON
{
  "mcpServers": {
    "playwright": {
      "type": "stdio",
      "command": "npx",
      "args": ["@playwright/mcp@latest", "--cdp-endpoint", "$CDP_URL"],
      "env": {}
    }
  }
}
CLAUDEJSON
    ok "Playwright MCP configured (new .claude.json)"
fi

# Verify CDP connection actually works
info "Verifying Chrome CDP connection..."
if curl -sf "$CDP_URL/json/version" > /dev/null 2>&1; then
    ok "CDP connection verified at $CDP_URL"
else
    # Try alternate URL (IPv6)
    ALT_URL="http://[::1]:9222"
    if curl -sf "$ALT_URL/json/version" > /dev/null 2>&1; then
        CDP_URL="$ALT_URL"
        # Re-update config with working URL
        jq --arg url "$CDP_URL" \
            '.mcpServers.playwright.args = ["@playwright/mcp@latest","--cdp-endpoint",$url]' \
            "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
        ok "CDP connection verified at $CDP_URL (IPv6)"
    else
        warn "Could not verify CDP connection — browser automation may not work until Chrome CDP is started"
    fi
fi

# Validate the final .claude.json config is correct
FINAL_ARGS=$(jq -r '.mcpServers.playwright.args | join(" ")' "$CLAUDE_JSON" 2>/dev/null)
if echo "$FINAL_ARGS" | grep -q "\-\-cdp-endpoint"; then
    ok "Playwright MCP config validated (uses --cdp-endpoint)"
else
    warn "Playwright MCP config may be incorrect — expected --cdp-endpoint flag"
    warn "Fix manually: claude mcp remove playwright && claude mcp add playwright -- npx @playwright/mcp@latest --cdp-endpoint $CDP_URL"
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

# ─── Done ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}Autopilot installed successfully!${NC}"
echo ""
echo "  Platform: $PLATFORM"
echo "  Quick use: /autopilot <task>  (from any Claude Code session)"
echo "  Full mode: claude --agent autopilot --dangerously-skip-permissions"
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
