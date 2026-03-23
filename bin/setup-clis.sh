#!/bin/bash
# setup-clis.sh — Install CLI tools for Claude Autopilot
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
NC='\033[0m' # No Color

# Check if a command exists
has() {
    command -v "$1" >/dev/null 2>&1
}

install_if_missing() {
    local name="$1" check_cmd="$2" install_cmd="$3"
    if has "$check_cmd"; then
        echo -e "${GREEN}[OK]${NC} $name ($(which "$check_cmd"))"
    else
        echo -e "${YELLOW}[INSTALLING]${NC} $name..."
        eval "$install_cmd"
        if has "$check_cmd"; then
            echo -e "${GREEN}[OK]${NC} $name installed"
        else
            echo -e "${RED}[FAILED]${NC} $name — install manually: $install_cmd"
        fi
    fi
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
tier1() {
    echo "=== Tier 1: Essential ==="
    install_if_missing "GitHub CLI (gh)" "gh" "brew install gh"
    install_if_missing "Vercel CLI" "vercel" "npm install -g vercel"
    install_if_missing "Supabase CLI" "supabase" "brew install supabase/tap/supabase"
}

# --- Tier 2: Cloud/Infrastructure ---
tier2() {
    echo "=== Tier 2: Cloud/Infrastructure ==="
    install_if_missing "Cloudflare Wrangler" "wrangler" "npm install -g wrangler"
    install_if_missing "AWS CLI" "aws" "brew install awscli"
    install_if_missing "jq (JSON processor)" "jq" "brew install jq"
}

# --- Tier 3: Alternative Platforms ---
tier3() {
    echo "=== Tier 3: Alternative Platforms ==="
    install_if_missing "Railway CLI" "railway" "npm install -g @railway/cli"
    install_if_missing "Netlify CLI" "netlify" "npm install -g netlify-cli"
    install_if_missing "Fly.io CLI" "fly" "brew install flyctl"
    install_if_missing "Firebase CLI" "firebase" "npm install -g firebase-tools"
}

# --- Check mode ---
check_all() {
    echo "=== Autopilot CLI Status ==="
    echo ""
    echo "--- Core ---"
    check_only "Node.js" "node"
    check_only "npm" "npm"
    check_only "npx" "npx"
    check_only "Homebrew" "brew"
    check_only "Python 3" "python3"
    check_only "Claude CLI" "claude"
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
    check_only "1Password CLI" "op"
}

# --- Main ---
case "${1:-}" in
    --check)
        check_all
        ;;
    --all)
        tier1
        echo ""
        tier2
        echo ""
        tier3
        ;;
    --tier)
        case "${2:-1}" in
            1) tier1 ;;
            2) tier2 ;;
            3) tier3 ;;
            *) echo "Unknown tier: $2. Use 1, 2, or 3." ;;
        esac
        ;;
    *)
        tier1
        ;;
esac
