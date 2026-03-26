#!/bin/bash
# setup-clis.sh — Install CLI tools for Claude Autopilot (cross-platform)
#
# Usage:
#   setup-clis.sh                  # Install all tier 1 (essential) CLIs
#   setup-clis.sh --all            # Install all tiers
#   setup-clis.sh --tier 2         # Install specific tier
#   setup-clis.sh --check          # Check what's installed

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Detect platform
case "$(uname -s)" in
    Darwin)  PLATFORM="macos" ;;
    Linux)   PLATFORM="linux" ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
    *)       PLATFORM="unknown" ;;
esac

has() {
    command -v "$1" >/dev/null 2>&1
}

# Cross-platform install helper
pkg_install() {
    local name="$1" check_cmd="$2" npm_pkg="${3:-}" brew_pkg="${4:-}" apt_pkg="${5:-}"

    if has "$check_cmd"; then
        echo -e "${GREEN}[OK]${NC} $name ($(which "$check_cmd"))"
        return
    fi

    echo -e "${YELLOW}[INSTALLING]${NC} $name..."

    # Try npm first if npm package is specified (works everywhere)
    if [ -n "$npm_pkg" ] && has npm; then
        npm install -g "$npm_pkg" 2>/dev/null && { echo -e "${GREEN}[OK]${NC} $name installed via npm"; return; }
    fi

    # Platform-specific fallbacks
    case "$PLATFORM" in
        macos)
            if [ -n "$brew_pkg" ] && has brew; then
                brew install "$brew_pkg" 2>/dev/null && { echo -e "${GREEN}[OK]${NC} $name installed via brew"; return; }
            fi
            ;;
        linux)
            if [ -n "$apt_pkg" ]; then
                if has apt-get; then
                    sudo apt-get install -y "$apt_pkg" 2>/dev/null && { echo -e "${GREEN}[OK]${NC} $name installed via apt"; return; }
                elif has dnf; then
                    sudo dnf install -y "$apt_pkg" 2>/dev/null && { echo -e "${GREEN}[OK]${NC} $name installed via dnf"; return; }
                elif has pacman; then
                    sudo pacman -S --noconfirm "$apt_pkg" 2>/dev/null && { echo -e "${GREEN}[OK]${NC} $name installed via pacman"; return; }
                fi
            fi
            if [ -n "$brew_pkg" ] && has brew; then
                brew install "$brew_pkg" 2>/dev/null && { echo -e "${GREEN}[OK]${NC} $name installed via brew"; return; }
            fi
            ;;
        windows)
            if [ -n "$brew_pkg" ] && has scoop; then
                scoop install "$brew_pkg" 2>/dev/null && { echo -e "${GREEN}[OK]${NC} $name installed via scoop"; return; }
            fi
            ;;
    esac

    echo -e "${RED}[FAILED]${NC} $name — install manually"
}

check_only() {
    local name="$1" check_cmd="$2"
    if has "$check_cmd"; then
        echo -e "${GREEN}[OK]${NC} $name ($(which "$check_cmd"))"
    else
        echo -e "${RED}[MISSING]${NC} $name"
    fi
}

# --- Tier 1: Essential ---
# Args: name, check_cmd, npm_pkg, brew_pkg, apt_pkg
tier1() {
    echo "=== Tier 1: Essential ==="
    pkg_install "GitHub CLI (gh)" "gh" "" "gh" "gh"
    pkg_install "Vercel CLI" "vercel" "vercel" "" ""
    case "$PLATFORM" in
        macos)  pkg_install "Supabase CLI" "supabase" "" "supabase/tap/supabase" "" ;;
        linux)  pkg_install "Supabase CLI" "supabase" "" "supabase/tap/supabase" "" ;;
        windows) pkg_install "Supabase CLI" "supabase" "" "supabase" "" ;;
    esac
}

# --- Tier 2: Cloud/Infrastructure ---
tier2() {
    echo "=== Tier 2: Cloud/Infrastructure ==="
    pkg_install "Cloudflare Wrangler" "wrangler" "wrangler" "" ""
    pkg_install "AWS CLI" "aws" "" "awscli" "awscli"
    pkg_install "jq (JSON processor)" "jq" "" "jq" "jq"
}

# --- Tier 3: Alternative Platforms ---
tier3() {
    echo "=== Tier 3: Alternative Platforms ==="
    pkg_install "Railway CLI" "railway" "@railway/cli" "" ""
    pkg_install "Netlify CLI" "netlify" "netlify-cli" "" ""
    pkg_install "Fly.io CLI" "fly" "" "flyctl" ""
    pkg_install "Firebase CLI" "firebase" "firebase-tools" "" ""
}

# --- Check mode ---
check_all() {
    echo "=== Autopilot CLI Status (platform: $PLATFORM) ==="
    echo ""
    echo "--- Core ---"
    check_only "Node.js" "node"
    check_only "npm" "npm"
    check_only "npx" "npx"
    check_only "Python 3" "python3"
    check_only "Claude CLI" "claude"
    case "$PLATFORM" in
        macos)   check_only "Homebrew" "brew" ;;
        linux)   check_only "Homebrew (optional)" "brew" ;;
        windows) check_only "Scoop (optional)" "scoop" ;;
    esac
    echo ""
    echo "--- Tier 1: Essential ---"
    check_only "GitHub CLI (gh)" "gh"
    check_only "Vercel CLI" "vercel"
    check_only "Supabase CLI" "supabase"
    echo ""
    echo "--- Tier 2: Cloud/Infrastructure ---"
    check_only "Cloudflare Wrangler" "wrangler"
    check_only "AWS CLI" "aws"
    check_only "jq" "jq"
    echo ""
    echo "--- Tier 3: Alternative Platforms ---"
    check_only "Railway CLI" "railway"
    check_only "Netlify CLI" "netlify"
    check_only "Fly.io CLI" "fly"
    check_only "Firebase CLI" "firebase"
    echo ""
    echo "--- Optional ---"
    check_only "Docker" "docker"
}

# --- Main ---
case "${1:-}" in
    --check)  check_all ;;
    --all)    tier1; echo ""; tier2; echo ""; tier3 ;;
    --tier)
        case "${2:-1}" in
            1) tier1 ;; 2) tier2 ;; 3) tier3 ;;
            *) echo "Unknown tier: $2. Use 1, 2, or 3." ;;
        esac
        ;;
    *)        tier1 ;;
esac
