#!/bin/bash
# audit.sh — Terminal dashboard for the Autopilot execution log
# Reads .autopilot/log.md and displays it in a formatted, scannable way
#
# Usage:
#   audit.sh [show]              Show latest session's actions
#   audit.sh all                 Show all sessions
#   audit.sh search <term>       Search across all logs
#   audit.sh accounts            Show ACCOUNT CREATED / LOGGED IN / TOKEN STORED entries
#   audit.sh failures            Show FAILED entries
#   audit.sh summary             One-line-per-session summary
#   --path <dir>                 Specify project path manually

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Parse flags ─────────────────────────────────────────────────────────────

PROJECT_PATH=""
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            PROJECT_PATH="$2"
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

set -- "${ARGS[@]+"${ARGS[@]}"}"

# ─── Find project root ──────────────────────────────────────────────────────

find_project_root() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/.autopilot/log.md" ]; then
            echo "$dir"
            return 0
        fi
        if [ -d "$dir/.git" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

resolve_log_file() {
    if [ -n "$PROJECT_PATH" ]; then
        ROOT="$PROJECT_PATH"
    elif ROOT=$(find_project_root "$(pwd)"); then
        true
    else
        echo -e "${RED}No .autopilot/log.md found.${NC} Searched from $(pwd) upward."
        echo "Use --path <dir> to specify the project directory."
        exit 1
    fi

    LOG_FILE="$ROOT/.autopilot/log.md"

    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${DIM}No execution log yet.${NC} ($LOG_FILE)"
        exit 0
    fi
}

LOG_FILE=""
ROOT=""

# ─── Helpers ─────────────────────────────────────────────────────────────────

colorize_result() {
    local line="$1"
    # Apply color based on result column content
    if echo "$line" | grep -qiE 'FAILED'; then
        echo -e "${RED}${line}${NC}"
    elif echo "$line" | grep -qiE 'ACCOUNT CREATED'; then
        echo -e "${YELLOW}${line}${NC}"
    elif echo "$line" | grep -qiE 'LOGGED IN'; then
        echo -e "${BLUE}${line}${NC}"
    elif echo "$line" | grep -qiE 'TOKEN STORED'; then
        echo -e "${CYAN}${line}${NC}"
    elif echo "$line" | grep -qiE '\bdone\b'; then
        echo -e "${GREEN}${line}${NC}"
    else
        echo "$line"
    fi
}

print_session() {
    local in_session=false
    local session_header=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^##\ Session: ]]; then
            in_session=true
            session_header="$line"
            echo ""
            echo -e "${BOLD}${line}${NC}"
            continue
        fi
        if $in_session; then
            if [[ "$line" =~ ^\|.*\| ]]; then
                # Table header/separator
                if [[ "$line" =~ ^\|[-\ \|]+\|$ ]] || [[ "$line" =~ ^\|\ *#\ *\| ]]; then
                    echo -e "${DIM}${line}${NC}"
                else
                    colorize_result "$line"
                fi
            elif [[ -z "$line" ]]; then
                echo ""
            else
                echo "$line"
            fi
        fi
    done
}

get_sessions() {
    # Extract session header line numbers
    grep -n "^## Session:" "$LOG_FILE" 2>/dev/null | cut -d: -f1
}

get_last_session_start() {
    local lines
    lines=$(get_sessions)
    if [ -z "$lines" ]; then
        echo "1"
        return
    fi
    echo "$lines" | tail -1
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_show() {
    local start
    start=$(get_last_session_start)
    local total
    total=$(wc -l < "$LOG_FILE" | tr -d ' ')
    sed -n "${start},${total}p" "$LOG_FILE" | print_session
}

cmd_all() {
    print_session < "$LOG_FILE"
}

cmd_search() {
    local term="$1"
    echo -e "${BOLD}Search: ${NC}${term}"
    echo ""
    local found=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^##\ Session: ]]; then
            local header="$line"
        fi
        if echo "$line" | grep -qi "$term"; then
            if [ -n "${header:-}" ]; then
                echo -e "${DIM}${header}${NC}"
                header=""
            fi
            colorize_result "$line"
            found=true
        fi
    done < "$LOG_FILE"
    if ! $found; then
        echo -e "${DIM}No matches found.${NC}"
    fi
}

cmd_accounts() {
    echo -e "${BOLD}Account Activity${NC}"
    echo ""
    local found=false
    local header=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^##\ Session: ]]; then
            header="$line"
        fi
        if echo "$line" | grep -qiE 'ACCOUNT CREATED|LOGGED IN|TOKEN STORED'; then
            if [ -n "$header" ]; then
                echo -e "${DIM}${header}${NC}"
                header=""
            fi
            colorize_result "$line"
            found=true
        fi
    done < "$LOG_FILE"
    if ! $found; then
        echo -e "${DIM}No account activity found.${NC}"
    fi
}

cmd_failures() {
    echo -e "${BOLD}Failures${NC}"
    echo ""
    local found=false
    local header=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^##\ Session: ]]; then
            header="$line"
        fi
        if echo "$line" | grep -qiE 'FAILED'; then
            if [ -n "$header" ]; then
                echo -e "${DIM}${header}${NC}"
                header=""
            fi
            colorize_result "$line"
            found=true
        fi
    done < "$LOG_FILE"
    if ! $found; then
        echo -e "${GREEN}No failures found.${NC}"
    fi
}

cmd_summary() {
    echo -e "${BOLD}Session Summary${NC}"
    echo ""
    local current_session=""
    local actions=0
    local failures=0

    print_summary_line() {
        if [ -n "$current_session" ]; then
            local fail_str=""
            if [ "$failures" -gt 0 ]; then
                fail_str="  ${RED}${failures} failed${NC}"
            fi
            echo -e "${DIM}${current_session}${NC}  ${GREEN}${actions} actions${NC}${fail_str}"
        fi
    }

    while IFS= read -r line; do
        if [[ "$line" =~ ^##\ Session: ]]; then
            print_summary_line
            current_session="${line#\#\# }"
            actions=0
            failures=0
        elif [[ "$line" =~ ^\|\ *[0-9] ]]; then
            ((actions++)) || true
            if echo "$line" | grep -qiE 'FAILED'; then
                ((failures++)) || true
            fi
        fi
    done < "$LOG_FILE"
    print_summary_line
}

cmd_help() {
    echo -e "${BOLD}audit.sh${NC} — Autopilot execution log viewer"
    echo ""
    echo "Usage:"
    echo "  audit.sh [show]              Show latest session"
    echo "  audit.sh all                 Show all sessions"
    echo "  audit.sh search <term>       Search logs"
    echo "  audit.sh accounts            Account activity only"
    echo "  audit.sh failures            Failed actions only"
    echo "  audit.sh summary             One-line-per-session summary"
    echo ""
    echo "Flags:"
    echo "  --path <dir>                 Specify project path"
}

# ─── Main ────────────────────────────────────────────────────────────────────

COMMAND="${1:-show}"

case "$COMMAND" in
    help|--help|-h) cmd_help ;;
    show)       resolve_log_file; cmd_show ;;
    all)        resolve_log_file; cmd_all ;;
    search)
        if [ -z "${2:-}" ]; then
            echo -e "${RED}Usage: audit.sh search <term>${NC}"
            exit 1
        fi
        resolve_log_file
        cmd_search "$2"
        ;;
    accounts)   resolve_log_file; cmd_accounts ;;
    failures)   resolve_log_file; cmd_failures ;;
    summary)    resolve_log_file; cmd_summary ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NC}"
        cmd_help
        exit 1
        ;;
esac
