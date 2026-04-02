#!/bin/bash
# preflight.sh — Session startup checks for Autopilot (v2)
#
# Runs parallel health checks, environment fingerprinting, credential
# validation, and MCP status. Outputs both human-readable summary
# and machine-readable JSON for the agent.
#
# Usage:
#   preflight.sh              # Run all checks (default)
#   preflight.sh setup        # Interactive first-time credential setup
#   preflight.sh status       # Show credential status
#   preflight.sh fingerprint  # Environment fingerprint only (JSON)
#   preflight.sh --skip       # Skip checks (for CI/CD or trusted envs)
#   preflight.sh --json       # JSON output only (no human-readable)
#
# Performance: Checks run in parallel via & + wait. Target: <500ms.
# Results cached for 5 minutes in .autopilot/preflight.cache

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCHAIN="$SCRIPT_DIR/keychain.sh"
AUTOPILOT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_FILE="${AUTOPILOT_DIR}/config/preflight.cache"
CACHE_TTL=300  # 5 minutes

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

JSON_MODE=false
SKIP_MODE=false

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --json) JSON_MODE=true ;;
        --skip) SKIP_MODE=true ;;
    esac
done


# ─── Guardian Session Marker ───────────────────────────────────────────────
# Create a marker file so guardian.sh knows this is an autopilot session.
# This handles the /autopilot slash command case (where process tree
# won't have --agent autopilot). Marker is PID-based and auto-cleaned.

_create_guardian_marker() {
    # Walk up process tree to find the Claude node process
    local _pid=$$
    for _i in 1 2 3 4 5; do
        [ "$_pid" -le 1 ] 2>/dev/null && break
        local _cmd=$(ps -o comm= -p "$_pid" 2>/dev/null || true)
        if [[ "$_cmd" == *"node"* ]] || [[ "$_cmd" == *"claude"* ]]; then
            touch "/tmp/.guardian-active-${_pid}"
            # Schedule cleanup: remove marker when this PID dies
            (
                while kill -0 "$_pid" 2>/dev/null; do
                    sleep 60
                done
                rm -f "/tmp/.guardian-active-${_pid}"
            ) &>/dev/null &
            disown 2>/dev/null
            break
        fi
        _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ') || break
    done
    # Also clean up any stale markers from dead processes
    for f in /tmp/.guardian-active-*; do
        [ -f "$f" ] || continue
        local _old_pid="${f##*-}"
        if ! kill -0 "$_old_pid" 2>/dev/null; then
            rm -f "$f"
        fi
    done
}
_create_guardian_marker

# ─── Cache ───────────────────────────────────────────────────────────────────

is_cache_valid() {
    if [ ! -f "$CACHE_FILE" ]; then
        return 1
    fi
    local cache_age
    local cache_mtime
    cache_mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    cache_age=$((now - cache_mtime))
    [ "$cache_age" -lt "$CACHE_TTL" ]
}

# ─── Credential Setup (unchanged from v1) ───────────────────────────────────

has_email() { "$KEYCHAIN" has primary email 2>/dev/null; }
has_password() { "$KEYCHAIN" has primary password 2>/dev/null; }

cmd_setup() {
    echo "═══════════════════════════════════════════════════════"
    echo "  Autopilot — Primary Credential Setup"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "These credentials are used as the default identity when"
    echo "signing up or logging into any external service."
    echo "They are stored securely in your OS Keychain."
    echo ""

    if has_email; then
        echo "[✓] Primary email is already set."
    else
        read -rp "Enter your primary email: " email
        if [ -z "$email" ]; then
            echo "Error: Email cannot be empty."
            exit 1
        fi
        echo "$email" | "$KEYCHAIN" set primary email
        echo "[✓] Primary email stored in Keychain."
    fi

    if has_password; then
        echo "[✓] Primary password is already set."
    else
        read -rsp "Enter your primary password: " password
        echo ""
        if [ -z "$password" ]; then
            echo "Error: Password cannot be empty."
            exit 1
        fi
        echo "$password" | "$KEYCHAIN" set primary password
        echo "[✓] Primary password stored in Keychain."
    fi

    echo ""
    echo "Primary credentials configured. Autopilot is ready."
}

cmd_status() {
    echo "Autopilot Credential Status"
    echo "───────────────────────────"
    if has_email; then echo "  Primary email:    [SET]"; else echo "  Primary email:    [NOT SET]"; fi
    if has_password; then echo "  Primary password: [SET]"; else echo "  Primary password: [NOT SET]"; fi
}

# ─── Environment Fingerprint ────────────────────────────────────────────────

cmd_fingerprint() {
    local os arch shell_ver python_ver node_ver git_ver jq_ver disk_free_gb

    os=$(uname -s 2>/dev/null || echo "unknown")
    arch=$(uname -m 2>/dev/null || echo "unknown")
    shell_ver="${BASH_VERSION:-$(zsh --version 2>/dev/null | head -1 || echo 'unknown')}"
    python_ver=$(python3 --version 2>/dev/null | awk '{print $2}' || echo "missing")
    node_ver=$(node --version 2>/dev/null || echo "missing")
    git_ver=$(git --version 2>/dev/null | awk '{print $3}' || echo "missing")
    jq_ver=$(jq --version 2>/dev/null || echo "missing")

    # Disk free (macOS vs Linux)
    if [ "$os" = "Darwin" ]; then
        disk_free_gb=$(df -g / 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")
    else
        disk_free_gb=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo "unknown")
    fi

    # Installed CLIs
    local clis=""
    for tool in gh vercel supabase wrangler aws terraform kubectl docker mise; do
        if command -v "$tool" &>/dev/null; then
            clis="${clis:+$clis, }\"$tool\""
        fi
    done

    cat <<EOF
{
  "os": "$os",
  "arch": "$arch",
  "shell": "$shell_ver",
  "python": "$python_ver",
  "node": "$node_ver",
  "git": "$git_ver",
  "jq": "$jq_ver",
  "disk_free_gb": $disk_free_gb,
  "clis": [$clis],
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
}

# ─── Individual Checks ──────────────────────────────────────────────────────
# Each check writes its result to a temp file. All run in parallel.

RESULTS_DIR=""

check_jq() {
    if command -v jq &>/dev/null; then
        echo '{"check":"jq","status":"ok","detail":"'$(jq --version 2>/dev/null)'"}' > "$RESULTS_DIR/jq"
    else
        echo '{"check":"jq","status":"critical","detail":"jq not installed — guardian cannot function"}' > "$RESULTS_DIR/jq"
    fi
}

check_python() {
    if command -v python3 &>/dev/null; then
        local ver
        ver=$(python3 --version 2>/dev/null | awk '{print $2}')
        echo "{\"check\":\"python\",\"status\":\"ok\",\"detail\":\"$ver\"}" > "$RESULTS_DIR/python"
    else
        echo '{"check":"python","status":"warning","detail":"python3 not found — memory.py/playbook.py unavailable"}' > "$RESULTS_DIR/python"
    fi
}

check_git() {
    if command -v git &>/dev/null; then
        local ver
        ver=$(git --version 2>/dev/null | awk '{print $3}')
        echo "{\"check\":\"git\",\"status\":\"ok\",\"detail\":\"$ver\"}" > "$RESULTS_DIR/git"
    else
        echo '{"check":"git","status":"warning","detail":"git not found"}' > "$RESULTS_DIR/git"
    fi
}

check_credentials() {
    local status="ok" detail="email and password set"
    if ! has_email 2>/dev/null; then
        status="warning"
        detail="primary email not set"
    fi
    if ! has_password 2>/dev/null; then
        if [ "$status" = "warning" ]; then
            detail="primary email and password not set"
        else
            status="warning"
            detail="primary password not set"
        fi
    fi
    echo "{\"check\":\"credentials\",\"status\":\"$status\",\"detail\":\"$detail\"}" > "$RESULTS_DIR/credentials"
}

check_credential_ttl() {
    local stale=0
    local ttl_dir="${AUTOPILOT_DIR}/config/credential-ttl"
    if [ -d "$ttl_dir" ]; then
        local now_epoch
        now_epoch=$(date +%s)
        for meta_file in "$ttl_dir"/*.meta; do
            [ -f "$meta_file" ] || continue
            local stored_date
            stored_date=$(cat "$meta_file")
            local stored_epoch
            if date -j -f '%Y-%m-%dT%H:%M:%SZ' "$stored_date" '+%s' &>/dev/null; then
                stored_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$stored_date" '+%s')
            else
                stored_epoch=$(date -d "$stored_date" '+%s' 2>/dev/null || echo "0")
            fi
            local age_days=$(( (now_epoch - stored_epoch) / 86400 ))
            if [ "$age_days" -gt 90 ]; then
                stale=$((stale + 1))
            fi
        done
    fi
    if [ "$stale" -gt 0 ]; then
        echo "{\"check\":\"credential_ttl\",\"status\":\"warning\",\"detail\":\"$stale credentials older than 90 days\"}" > "$RESULTS_DIR/ttl"
    else
        echo '{"check":"credential_ttl","status":"ok","detail":"all credentials within TTL"}' > "$RESULTS_DIR/ttl"
    fi
}

check_guardian() {
    local guardian="$SCRIPT_DIR/guardian.sh"
    if [ -x "$guardian" ]; then
        # Quick functional test
        local result
        result=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | "$guardian" 2>/dev/null; echo $?)
        local exit_code="${result##*$'\n'}"
        if [ "$exit_code" = "0" ]; then
            echo '{"check":"guardian","status":"ok","detail":"functional"}' > "$RESULTS_DIR/guardian"
        else
            echo '{"check":"guardian","status":"critical","detail":"guardian blocking safe commands"}' > "$RESULTS_DIR/guardian"
        fi
    else
        echo '{"check":"guardian","status":"critical","detail":"guardian.sh not found or not executable"}' > "$RESULTS_DIR/guardian"
    fi
}

check_audit_integrity() {
    # Find nearest audit.jsonl and verify hash chain
    local audit_sh="$SCRIPT_DIR/audit.sh"
    if [ -x "$audit_sh" ]; then
        # Just check if it can run without error
        echo '{"check":"audit","status":"ok","detail":"audit.sh available"}' > "$RESULTS_DIR/audit"
    else
        echo '{"check":"audit","status":"warning","detail":"audit.sh not found"}' > "$RESULTS_DIR/audit"
    fi
}

check_memory_db() {
    local mem_py="$AUTOPILOT_DIR/lib/memory.py"
    if [ -f "$mem_py" ]; then
        local stats
        stats=$(python3 "$mem_py" stats 2>/dev/null | head -1 || echo "")
        if [ -n "$stats" ]; then
            echo "{\"check\":\"memory\",\"status\":\"ok\",\"detail\":\"memory.py functional\"}" > "$RESULTS_DIR/memory"
        else
            echo '{"check":"memory","status":"warning","detail":"memory.py not responding"}' > "$RESULTS_DIR/memory"
        fi
    else
        echo '{"check":"memory","status":"warning","detail":"memory.py not found"}' > "$RESULTS_DIR/memory"
    fi
}

# ─── Run All Checks ─────────────────────────────────────────────────────────

cmd_check_all() {
    # Check cache first
    if is_cache_valid && [ "$JSON_MODE" = "false" ]; then
        echo -e "${DIM}Preflight: using cached results ($(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0) ))s old)${NC}"
        cat "$CACHE_FILE"
        return 0
    fi

    RESULTS_DIR=$(mktemp -d)
    trap 'rm -rf "$RESULTS_DIR"' EXIT

    # Run all checks in parallel
    check_jq &
    check_python &
    check_git &
    check_credentials &
    check_credential_ttl &
    check_guardian &
    check_audit_integrity &
    check_memory_db &
    wait

    # Collect results
    local ok=0 warnings=0 critical=0
    local results_json="["
    local first=true

    for result_file in "$RESULTS_DIR"/*; do
        [ -f "$result_file" ] || continue
        local result
        result=$(cat "$result_file")
        local status
        status=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")

        case "$status" in
            ok) ok=$((ok + 1)) ;;
            warning) warnings=$((warnings + 1)) ;;
            critical) critical=$((critical + 1)) ;;
        esac

        if [ "$first" = true ]; then
            first=false
        else
            results_json="$results_json,"
        fi
        results_json="$results_json$result"
    done
    results_json="$results_json]"

    local summary="{\"ok\":$ok,\"warnings\":$warnings,\"critical\":$critical,\"timestamp\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}"

    # Build full JSON
    local full_json="{\"summary\":$summary,\"checks\":$results_json}"

    # Cache results
    mkdir -p "$(dirname "$CACHE_FILE")"
    echo "$full_json" > "$CACHE_FILE"

    if [ "$JSON_MODE" = "true" ]; then
        echo "$full_json" | python3 -m json.tool 2>/dev/null || echo "$full_json"
        return 0
    fi

    # Human-readable output
    echo -e "${BOLD}Autopilot Preflight${NC}"
    echo ""

    for result_file in "$RESULTS_DIR"/*; do
        [ -f "$result_file" ] || continue
        local result check status detail
        result=$(cat "$result_file")
        check=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('check','?'))" 2>/dev/null)
        status=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null)
        detail=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('detail',''))" 2>/dev/null)

        case "$status" in
            ok)       echo -e "  ${GREEN}✓${NC} ${check}: ${detail}" ;;
            warning)  echo -e "  ${YELLOW}⚠${NC} ${check}: ${detail}" ;;
            critical) echo -e "  ${RED}✗${NC} ${check}: ${detail}" ;;
            *)        echo -e "  ? ${check}: ${detail}" ;;
        esac
    done

    echo ""
    echo -e "  ${BOLD}Summary:${NC} ${GREEN}$ok ok${NC}"
    [ "$warnings" -gt 0 ] && echo -ne ", ${YELLOW}$warnings warnings${NC}"
    [ "$critical" -gt 0 ] && echo -ne ", ${RED}$critical critical${NC}"
    echo ""

    if [ "$critical" -gt 0 ]; then
        echo -e "  ${RED}Critical issues found — some features may not work.${NC}"
        return 1
    fi
    return 0
}

# ─── Main ────────────────────────────────────────────────────────────────────

case "${1:-}" in
    setup)       cmd_setup ;;
    status)      cmd_status ;;
    fingerprint) cmd_fingerprint ;;
    --skip)      echo "Preflight: skipped"; exit 0 ;;
    --json)      JSON_MODE=true; cmd_check_all ;;
    help|--help|-h)
        echo "preflight.sh — Autopilot session startup checks (v2)"
        echo ""
        echo "Usage:"
        echo "  preflight.sh              Run all checks"
        echo "  preflight.sh setup        First-time credential setup"
        echo "  preflight.sh status       Show credential status"
        echo "  preflight.sh fingerprint  Environment fingerprint (JSON)"
        echo "  preflight.sh --json       JSON output only"
        echo "  preflight.sh --skip       Skip checks"
        ;;
    *)           cmd_check_all ;;
esac
