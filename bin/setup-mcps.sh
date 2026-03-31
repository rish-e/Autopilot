#!/bin/bash
# setup-mcps.sh — Install and verify all MCPs that Autopilot requires
#
# Reads config/required-mcps.yaml and ensures each MCP is installed.
# Run this during initial setup or whenever required-mcps.yaml is updated.
#
# Usage:
#   setup-mcps.sh              Install/verify all required MCPs
#   setup-mcps.sh status       Show status of all MCPs (no changes)
#   setup-mcps.sh install      Install missing MCPs only
#   setup-mcps.sh <name>       Install/verify a specific MCP
#
# Future-proof: When adding a new MCP, just add it to config/required-mcps.yaml
# and run this script. No code changes needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOPILOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$AUTOPILOT_DIR/config/required-mcps.yaml"

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
setup-mcps.sh — Install and verify Autopilot's required MCPs

Commands:
  (no args)    Install/verify all required MCPs
  status       Show status of all MCPs (read-only)
  install      Install missing MCPs only
  <name>       Install/verify a specific MCP

Examples:
  setup-mcps.sh                 # full setup
  setup-mcps.sh status          # check what's installed
  setup-mcps.sh playwright      # install/verify playwright only

Config: ~/MCPs/autopilot/config/required-mcps.yaml
To add a new MCP: add it to the config file, then run this script.
EOF
}

check_prerequisites() {
    if ! command -v python3 &>/dev/null; then
        echo -e "${RED}Error: python3 required${NC}" >&2
        exit 1
    fi
    if ! command -v claude &>/dev/null; then
        echo -e "${RED}Error: claude CLI required${NC}" >&2
        exit 1
    fi
    if [[ ! -f "$CONFIG" ]]; then
        echo -e "${RED}Error: Config not found: $CONFIG${NC}" >&2
        exit 1
    fi
}

# Parse the YAML config and return MCP info as JSON lines
parse_config() {
    python3 -c "
import yaml, json, sys

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

mcps = data.get('mcps', {})
filter_name = sys.argv[2] if len(sys.argv) > 2 else None

for name, info in mcps.items():
    if filter_name and name != filter_name:
        continue
    info['name'] = name
    print(json.dumps(info))
" "$CONFIG" "${1:-}" 2>/dev/null
}

# Check if an MCP is installed by looking at claude mcp list output
is_mcp_installed() {
    local name="$1"
    claude mcp list 2>/dev/null | grep -qi "$name" 2>/dev/null
    return $?
}

# ─── MCP Handlers ────────────────────────────────────────────────────────────

handle_npm_mcp() {
    local name="$1" package="$2" required="$3" description="$4"
    local args_json="${5:-[]}" setup_note="${6:-}"

    # Check if already installed
    if is_mcp_installed "$name"; then
        echo -e "  ${GREEN}installed${NC}  $name — $description"
        return 0
    fi

    if [[ "$MODE" == "status" ]]; then
        if [[ "$required" == "true" ]]; then
            echo -e "  ${RED}MISSING${NC}    $name — $description (REQUIRED)"
        else
            echo -e "  ${YELLOW}missing${NC}    $name — $description (optional)"
        fi
        return 0
    fi

    # Install
    echo -e "  ${CYAN}installing${NC} $name..."

    # Build the claude mcp add command
    local -a cmd=(claude mcp add "$name" -s user -- npx -y "$package")

    # Add extra args if any
    local extra_args
    extra_args=$(python3 -c "
import json, sys
args = json.loads(sys.argv[1])
print(' '.join(args))
" "$args_json" 2>/dev/null)

    if [[ -n "$extra_args" ]]; then
        cmd=(claude mcp add "$name" -s user -- npx -y "$package" $extra_args)
    fi

    if "${cmd[@]}" 2>/dev/null; then
        echo -e "  ${GREEN}installed${NC}  $name"
    else
        if [[ "$required" == "true" ]]; then
            echo -e "  ${RED}FAILED${NC}     $name — installation failed (REQUIRED)"
            [[ -n "$setup_note" ]] && echo -e "             ${DIM}Note: $setup_note${NC}"
        else
            echo -e "  ${YELLOW}skipped${NC}    $name — installation failed (optional)"
        fi
    fi
}

handle_hosted_mcp() {
    local name="$1" service="$2" required="$3" description="$4" setup_note="${5:-}" verify_tool="${6:-}"

    # For hosted MCPs, we can only check if the tools are available
    # We can't install them — user must connect via claude.ai settings
    if [[ "$required" == "true" ]]; then
        echo -e "  ${YELLOW}verify${NC}     $name — $description"
        echo -e "             ${DIM}$setup_note${NC}"
    else
        echo -e "  ${DIM}optional${NC}   $name — $description"
        echo -e "             ${DIM}$setup_note${NC}"
    fi
}

handle_builtin_mcp() {
    local name="$1" required="$2" description="$3" setup_note="${4:-}"

    echo -e "  ${DIM}builtin${NC}    $name — $description"
    [[ -n "$setup_note" ]] && echo -e "             ${DIM}$setup_note${NC}"
}

# ─── Main Logic ──────────────────────────────────────────────────────────────

MODE="${1:-install}"

case "$MODE" in
    -h|--help|help) usage; exit 0 ;;
    status|install) ;;
    *)
        # Specific MCP name — install just that one
        check_prerequisites
        echo -e "${BOLD}Setting up MCP: $MODE${NC}"
        echo ""
        parse_config "$MODE" | while IFS= read -r line; do
            name=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['name'])")
            type=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['type'])")
            package=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('package',''))")
            required=$(echo "$line" | python3 -c "import json,sys; print(str(json.loads(sys.stdin.read()).get('required',False)).lower())")
            description=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('description',''))")
            args=$(echo "$line" | python3 -c "import json,sys; print(json.dumps(json.loads(sys.stdin.read()).get('args',[])))")
            setup_note=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('setup_note',''))")
            service=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('service',''))")
            verify_tool=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('verify_tool',''))")

            case "$type" in
                npm)     handle_npm_mcp "$name" "$package" "$required" "$description" "$args" "$setup_note" ;;
                hosted)  handle_hosted_mcp "$name" "$service" "$required" "$description" "$setup_note" "$verify_tool" ;;
                builtin) handle_builtin_mcp "$name" "$required" "$description" "$setup_note" ;;
            esac
        done
        exit 0
        ;;
esac

check_prerequisites

echo -e "${BOLD}Autopilot MCP Setup${NC}"
echo -e "${DIM}Config: $CONFIG${NC}"
echo ""

# Count totals
TOTAL=0
INSTALLED=0
MISSING=0
HOSTED=0

echo -e "${BOLD}Self-hosted MCPs (npm packages)${NC}"
parse_config | while IFS= read -r line; do
    type=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['type'])")
    [[ "$type" != "npm" ]] && continue

    name=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['name'])")
    package=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('package',''))")
    required=$(echo "$line" | python3 -c "import json,sys; print(str(json.loads(sys.stdin.read()).get('required',False)).lower())")
    description=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('description',''))")
    args=$(echo "$line" | python3 -c "import json,sys; print(json.dumps(json.loads(sys.stdin.read()).get('args',[])))")
    setup_note=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('setup_note',''))")

    handle_npm_mcp "$name" "$package" "$required" "$description" "$args" "$setup_note"
done

echo ""
echo -e "${BOLD}Anthropic-hosted MCPs (connect via claude.ai)${NC}"
parse_config | while IFS= read -r line; do
    type=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['type'])")
    [[ "$type" != "hosted" ]] && continue

    name=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['name'])")
    service=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('service',''))")
    required=$(echo "$line" | python3 -c "import json,sys; print(str(json.loads(sys.stdin.read()).get('required',False)).lower())")
    description=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('description',''))")
    setup_note=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('setup_note',''))")
    verify_tool=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('verify_tool',''))")

    handle_hosted_mcp "$name" "$service" "$required" "$description" "$setup_note" "$verify_tool"
done

echo ""
echo -e "${BOLD}Built-in capabilities${NC}"
parse_config | while IFS= read -r line; do
    type=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['type'])")
    [[ "$type" != "builtin" ]] && continue

    name=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['name'])")
    required=$(echo "$line" | python3 -c "import json,sys; print(str(json.loads(sys.stdin.read()).get('required',False)).lower())")
    description=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('description',''))")
    setup_note=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('setup_note',''))")

    handle_builtin_mcp "$name" "$required" "$description" "$setup_note"
done

echo ""
echo -e "${DIM}To add a new MCP: edit config/required-mcps.yaml and re-run this script${NC}"
