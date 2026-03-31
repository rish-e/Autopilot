#!/bin/bash
# harvest.sh — Credential discovery and import for Autopilot
#
# Scans the local machine for existing auth tokens from CLI tools,
# config files, and OS keychains. Imports discovered tokens into
# the Autopilot keychain so they're available for all operations.
#
# This script NEVER prints token values. It reports what was found
# and whether it was imported. Tokens go straight into keychain.
#
# Scan strategy (per service):
#   1. Check if already in Autopilot keychain → skip if present
#   2. Check well-known file paths for that service
#   3. Check OS keychain for that service
#   4. Check common patterns (~/.config/{service}/, etc.)
#   5. Import if found, report if not
#
# Usage:
#   harvest.sh              Scan all known services
#   harvest.sh <service>    Scan a specific service
#   harvest.sh status       Show what's in keychain vs what's discoverable
#   harvest.sh scan         Scan but don't import (dry run)
#
# The scan list is NOT static — it checks memory.db for any services
# the agent has encountered and adds their known token locations.

set -uo pipefail
# Note: NOT using set -e because scan functions intentionally handle
# failures (missing files, empty grep results) via conditionals

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCHAIN="$SCRIPT_DIR/keychain.sh"
AUTOPILOT_DIR="$(dirname "$SCRIPT_DIR")"

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

DRY_RUN=false
IMPORTED=0
SKIPPED=0
NOT_FOUND=0

# ─── Helpers ─────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
harvest.sh — Credential discovery and import for Autopilot

Commands:
  (no args)      Scan all known services and import tokens
  <service>      Scan a specific service only
  status         Show what's in keychain vs what's discoverable
  scan           Dry run — show what would be imported
  list           List all scannable services

Examples:
  harvest.sh              # scan everything, import what's found
  harvest.sh vercel       # scan vercel only
  harvest.sh scan         # dry run
  harvest.sh status       # show inventory
EOF
}

# Import a token into keychain if not already there
# Args: service, key, value
import_token() {
    local service="$1" key="$2" value="$3" source="$4"

    if "$KEYCHAIN" has "$service" "$key" 2>/dev/null; then
        echo -e "  ${DIM}SKIP${NC}  $service/$key — already in keychain"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${CYAN}FOUND${NC} $service/$key — from $source (dry run, not imported)"
        IMPORTED=$((IMPORTED + 1))
        return 0
    fi

    echo "$value" | "$KEYCHAIN" set "$service" "$key" 2>/dev/null
    echo -e "  ${GREEN}IMPORTED${NC} $service/$key — from $source"
    IMPORTED=$((IMPORTED + 1))
}

not_found() {
    local service="$1" key="$2"
    echo -e "  ${DIM}---${NC}    $service/$key — not found on machine"
    NOT_FOUND=$((NOT_FOUND + 1))
}

# ─── Service Scanners ────────────────────────────────────────────────────────
# Each function scans one service. Add new services by adding new functions.

scan_vercel() {
    local auth_file="$HOME/Library/Application Support/com.vercel.cli/auth.json"

    # Also check Linux/alternate paths
    if [[ ! -f "$auth_file" ]]; then
        auth_file="$HOME/.local/share/com.vercel.cli/auth.json"
    fi
    if [[ ! -f "$auth_file" ]]; then
        auth_file="$HOME/.vercel/auth.json"
    fi

    if [[ -f "$auth_file" ]]; then
        local token
        token=$(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get('token', ''))
except: pass
" "$auth_file" 2>/dev/null)

        if [[ -n "$token" ]]; then
            import_token "vercel" "api-token" "$token" "$auth_file"
            unset token
            return 0
        fi
    fi

    not_found "vercel" "api-token"
}

scan_github() {
    # Method 1: gh CLI (reads from OS keychain)
    local token
    token=$(gh auth token 2>/dev/null) || token=""

    if [[ -n "$token" ]]; then
        import_token "github" "auth-token" "$token" "gh auth token (OS keychain)"
        unset token
        return 0
    fi

    # Method 2: macOS Keychain directly
    token=$(security find-generic-password -s "gh:github.com" -w 2>/dev/null) || token=""

    if [[ -n "$token" ]]; then
        import_token "github" "auth-token" "$token" "macOS Keychain (gh:github.com)"
        unset token
        return 0
    fi

    # Method 3: .claude.json MCP config
    if [[ -f "$HOME/.claude.json" ]]; then
        token=$(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    auth = data.get('mcpServers', {}).get('github', {}).get('headers', {}).get('Authorization', '')
    if auth.startswith('Bearer '):
        print(auth[7:])
    elif auth:
        print(auth)
except: pass
" "$HOME/.claude.json" 2>/dev/null) || token=""

        if [[ -n "$token" ]]; then
            import_token "github" "auth-token" "$token" "~/.claude.json (GitHub MCP)"
            unset token
            return 0
        fi
    fi

    not_found "github" "auth-token"
}

scan_supabase() {
    # Supabase CLI stores token at ~/.config/supabase/access-token
    local token_file="$HOME/.config/supabase/access-token"

    if [[ -f "$token_file" ]]; then
        local token
        token=$(cat "$token_file" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$token" ]]; then
            import_token "supabase" "access-token" "$token" "$token_file"
            unset token
            return 0
        fi
    fi

    not_found "supabase" "access-token"
}

scan_npm() {
    # npm stores auth token in ~/.npmrc
    local npmrc="$HOME/.npmrc"

    if [[ -f "$npmrc" ]]; then
        local token
        token=$(grep '//registry.npmjs.org/:_authToken=' "$npmrc" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        if [[ -n "$token" ]]; then
            import_token "npm" "auth-token" "$token" "~/.npmrc"
            unset token
            return 0
        fi
    fi

    not_found "npm" "auth-token"
}

scan_docker() {
    local config="$HOME/.docker/config.json"

    if [[ -f "$config" ]]; then
        local has_auths
        has_auths=$(python3 -c "
import json
data = json.load(open('$config'))
auths = data.get('auths', {})
if auths:
    for registry in auths:
        print(registry)
" 2>/dev/null)

        if [[ -n "$has_auths" ]]; then
            # Docker config exists with auths — store the whole config reference
            import_token "docker" "config-path" "$config" "~/.docker/config.json"
            return 0
        fi
    fi

    not_found "docker" "config"
}

scan_cloudflare() {
    # Wrangler stores config in ~/.config/.wrangler/ or ~/.wrangler/
    local config_dir="$HOME/.config/.wrangler"
    [[ -d "$config_dir" ]] || config_dir="$HOME/.wrangler"

    if [[ -d "$config_dir" ]]; then
        local token
        token=$(python3 -c "
import json, os
for f in ['config/default.toml', 'config.toml', 'auth.json']:
    path = os.path.join('$config_dir', f)
    if os.path.exists(path):
        content = open(path).read()
        # Look for api_token or oauth_token
        for line in content.split('\n'):
            if 'api_token' in line or 'oauth_token' in line:
                val = line.split('=')[-1].strip().strip('\"').strip(\"'\")
                if val:
                    print(val)
                    break
" 2>/dev/null)

        if [[ -n "${token:-}" ]]; then
            import_token "cloudflare" "api-token" "$token" "$config_dir"
            unset token
            return 0
        fi
    fi

    # Check: wrangler whoami (if installed)
    if command -v wrangler &>/dev/null; then
        if wrangler whoami &>/dev/null 2>&1; then
            echo -e "  ${YELLOW}NOTE${NC}  cloudflare — wrangler is authed but token location unknown"
            return 0
        fi
    fi

    not_found "cloudflare" "api-token"
}

scan_netrc() {
    # .netrc can contain tokens for various services
    local netrc="$HOME/.netrc"

    if [[ -f "$netrc" ]]; then
        echo -e "  ${YELLOW}NOTE${NC}  .netrc exists — may contain service credentials"
        # Parse machine/login/password entries
        python3 -c "
import netrc, sys
try:
    n = netrc.netrc('$netrc')
    for host in n.hosts:
        login, _, _ = n.authenticators(host)
        print(f'  Found: {host} (login: {login})')
except Exception as e:
    print(f'  Could not parse: {e}', file=sys.stderr)
" 2>/dev/null
        return 0
    fi

    not_found "netrc" "file"
}

# ─── Dynamic Scanner ─────────────────────────────────────────────────────────
# For services discovered by the agent but not in the static list above,
# try common patterns.

scan_dynamic() {
    local service="$1"

    # Already have a static scanner? Use it
    if declare -f "scan_${service}" &>/dev/null; then
        "scan_${service}"
        return
    fi

    echo -e "  ${DIM}Scanning common paths for '$service'...${NC}"

    local found=false

    # Check common config directories
    for dir in \
        "$HOME/.config/$service" \
        "$HOME/Library/Application Support/$service" \
        "$HOME/Library/Application Support/com.${service}.cli" \
        "$HOME/.$service" \
    ; do
        if [[ -d "$dir" ]]; then
            # Look for files containing "token", "key", "auth", "secret"
            local token_file
            token_file=$(find "$dir" -maxdepth 2 -type f \( -name "*.json" -o -name "*.toml" -o -name "*.yaml" -o -name "*.yml" -o -name "auth*" -o -name "token*" -o -name "access*" -o -name "credentials*" \) 2>/dev/null | head -1)

            if [[ -n "$token_file" ]]; then
                echo -e "  ${YELLOW}FOUND${NC} $service — config at $token_file (needs manual extraction)"
                found=true
                break
            fi
        fi
    done

    # Check macOS Keychain
    if [[ "$found" == "false" ]] && security find-generic-password -l "$service" &>/dev/null 2>&1; then
        echo -e "  ${YELLOW}FOUND${NC} $service — entry in macOS Keychain"
        found=true
    fi

    if [[ "$found" == "false" ]]; then
        not_found "$service" "credentials"
    fi
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_harvest_all() {
    echo -e "${BOLD}Credential Harvest${NC}"
    echo -e "${DIM}Scanning local machine for existing auth tokens...${NC}"
    echo ""

    echo -e "${BOLD}Vercel${NC}"
    scan_vercel

    echo -e "${BOLD}GitHub${NC}"
    scan_github

    echo -e "${BOLD}Supabase${NC}"
    scan_supabase

    echo -e "${BOLD}npm${NC}"
    scan_npm

    echo -e "${BOLD}Docker${NC}"
    scan_docker

    echo -e "${BOLD}Cloudflare${NC}"
    scan_cloudflare

    echo -e "${BOLD}.netrc${NC}"
    scan_netrc

    # Scan any services from memory.db that aren't in the static list
    if command -v python3 &>/dev/null && [[ -f "$HOME/.autopilot/memory.db" ]]; then
        local extra_services
        extra_services=$(python3 -c "
import sqlite3, os
db = os.path.expanduser('~/.autopilot/memory.db')
if os.path.exists(db):
    conn = sqlite3.connect(db)
    rows = conn.execute('SELECT name FROM services WHERE name NOT IN (\"vercel\",\"github\",\"supabase\",\"npm\",\"docker\",\"cloudflare\")').fetchall()
    for r in rows:
        print(r[0])
    conn.close()
" 2>/dev/null)

        if [[ -n "${extra_services:-}" ]]; then
            echo ""
            echo -e "${BOLD}Dynamic (from memory.db)${NC}"
            while IFS= read -r svc; do
                [[ -z "$svc" ]] && continue
                scan_dynamic "$svc"
            done <<< "$extra_services"
        fi
    fi

    echo ""
    echo -e "${BOLD}Summary${NC}"
    echo -e "  Imported:  ${GREEN}$IMPORTED${NC}"
    echo -e "  Skipped:   ${DIM}$SKIPPED${NC} (already in keychain)"
    echo -e "  Not found: ${DIM}$NOT_FOUND${NC}"
}

cmd_harvest_single() {
    local service="$1"
    echo -e "${BOLD}Scanning: $service${NC}"

    if declare -f "scan_${service}" &>/dev/null; then
        "scan_${service}"
    else
        scan_dynamic "$service"
    fi

    echo ""
    if [[ $IMPORTED -gt 0 ]]; then
        echo -e "${GREEN}Imported $IMPORTED credential(s)${NC}"
    elif [[ $SKIPPED -gt 0 ]]; then
        echo -e "${DIM}Already in keychain${NC}"
    else
        echo -e "${YELLOW}No credentials found for '$service'${NC}"
    fi
}

cmd_status() {
    echo -e "${BOLD}Credential Inventory${NC}"
    echo ""

    local services=("vercel" "github" "supabase" "cloudflare" "npm" "docker")

    printf "  ${BOLD}%-15s %-20s %-15s${NC}\n" "Service" "Key" "Status"
    printf "  ${DIM}%-15s %-20s %-15s${NC}\n" "───────" "───" "──────"

    for svc in "${services[@]}"; do
        # Define expected keys per service
        local keys=()
        case "$svc" in
            vercel)     keys=("api-token") ;;
            github)     keys=("auth-token") ;;
            supabase)   keys=("access-token") ;;
            cloudflare) keys=("api-token") ;;
            npm)        keys=("auth-token") ;;
            docker)     keys=("config-path") ;;
        esac

        for key in "${keys[@]}"; do
            if "$KEYCHAIN" has "$svc" "$key" 2>/dev/null; then
                printf "  %-15s %-20s ${GREEN}%-15s${NC}\n" "$svc" "$key" "in keychain"
            else
                printf "  %-15s %-20s ${YELLOW}%-15s${NC}\n" "$svc" "$key" "not stored"
            fi
        done
    done

    # Check for TOTP seeds
    echo ""
    echo -e "  ${BOLD}TOTP Seeds:${NC}"
    local totp_found=false
    for svc in "${services[@]}"; do
        if "$KEYCHAIN" has "$svc" "totp-seed" 2>/dev/null; then
            printf "  %-15s %-20s ${GREEN}%-15s${NC}\n" "$svc" "totp-seed" "stored"
            totp_found=true
        fi
    done
    if [[ "$totp_found" == "false" ]]; then
        echo -e "  ${DIM}  No TOTP seeds stored${NC}"
    fi

    # Check primary credentials
    echo ""
    echo -e "  ${BOLD}Primary Credentials:${NC}"
    if "$KEYCHAIN" has "primary" "email" 2>/dev/null; then
        printf "  %-15s %-20s ${GREEN}%-15s${NC}\n" "primary" "email" "set"
    else
        printf "  %-15s %-20s ${YELLOW}%-15s${NC}\n" "primary" "email" "not set"
    fi
    if "$KEYCHAIN" has "primary" "password" 2>/dev/null; then
        printf "  %-15s %-20s ${GREEN}%-15s${NC}\n" "primary" "password" "set"
    else
        printf "  %-15s %-20s ${YELLOW}%-15s${NC}\n" "primary" "password" "not set"
    fi
}

cmd_list() {
    echo -e "${BOLD}Scannable Services${NC}"
    echo ""
    echo "  Static scanners (built-in):"
    echo "    vercel, github, supabase, npm, docker, cloudflare"
    echo ""
    echo "  Dynamic scanning:"
    echo "    Any service name — checks common paths + macOS Keychain"
    echo ""

    if [[ -f "$HOME/.autopilot/memory.db" ]]; then
        local count
        count=$(python3 -c "
import sqlite3, os
db = os.path.expanduser('~/.autopilot/memory.db')
if os.path.exists(db):
    conn = sqlite3.connect(db)
    rows = conn.execute('SELECT name FROM services').fetchall()
    for r in rows: print(f'    {r[0]}')
    print(f'\n  Total: {len(rows)} services in memory.db')
    conn.close()
" 2>/dev/null)
        if [[ -n "${count:-}" ]]; then
            echo "  From memory.db:"
            echo "$count"
        fi
    fi
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

case "${1:-}" in
    scan)
        DRY_RUN=true
        cmd_harvest_all
        ;;
    status)
        cmd_status
        ;;
    list)
        cmd_list
        ;;
    -h|--help|help)
        usage
        ;;
    "")
        cmd_harvest_all
        ;;
    *)
        cmd_harvest_single "$1"
        ;;
esac
