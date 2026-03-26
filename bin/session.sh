#!/bin/bash
# session.sh — Session persistence for Autopilot
# Save and resume session state so work survives rate limits and crashes.
#
# Usage:
#   session.sh save <task>         Save current session state
#   session.sh resume              Output saved session for agent pickup
#   session.sh clear               Remove saved session
#   session.sh status              Check if a saved session exists
#   session.sh update <json-patch> Update specific fields in the session

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Find project root ──────────────────────────────────────────────────────

find_project_root() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.autopilot" ]; then
            echo "$dir"
            return 0
        fi
        if [ -d "$dir/.git" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    # Fall back to cwd
    echo "$1"
}

PROJECT_ROOT=$(find_project_root "$(pwd)")
SESSION_DIR="$PROJECT_ROOT/.autopilot"
SESSION_FILE="$SESSION_DIR/session.json"

# ─── Helpers ─────────────────────────────────────────────────────────────────

ensure_dir() {
    mkdir -p "$SESSION_DIR"
}

get_iso_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_save() {
    local task="${1:-}"
    if [ -z "$task" ]; then
        echo -e "${RED}Usage: session.sh save <task-description>${NC}"
        exit 1
    fi

    ensure_dir

    local timestamp
    timestamp=$(get_iso_timestamp)

    # If session already exists, preserve plan/completed/services/snapshot and update task+timestamp
    if [ -f "$SESSION_FILE" ]; then
        local updated
        updated=$(jq \
            --arg task "$task" \
            --arg ts "$timestamp" \
            '.task = $task | .timestamp = $ts' "$SESSION_FILE")
        echo "$updated" > "$SESSION_FILE"
    else
        # Create new session
        local session
        session=$(jq -n \
            --arg task "$task" \
            --arg ts "$timestamp" \
            '{
                task: $task,
                plan: [],
                completed: [],
                current_step: 1,
                services_used: [],
                snapshot_label: "",
                timestamp: $ts,
                notes: ""
            }')
        echo "$session" > "$SESSION_FILE"
    fi

    echo -e "${GREEN}Session saved:${NC} ${task}"
}

cmd_resume() {
    if [ ! -f "$SESSION_FILE" ]; then
        echo -e "${DIM}No saved session.${NC}"
        exit 0
    fi

    echo -e "${BOLD}Saved Session${NC}"
    echo ""

    local task current_step total_steps notes timestamp
    task=$(jq -r '.task' "$SESSION_FILE")
    current_step=$(jq -r '.current_step' "$SESSION_FILE")
    total_steps=$(jq -r '.plan | length' "$SESSION_FILE")
    notes=$(jq -r '.notes // ""' "$SESSION_FILE")
    timestamp=$(jq -r '.timestamp' "$SESSION_FILE")

    echo -e "  ${BOLD}Task:${NC}     $task"
    echo -e "  ${BOLD}Saved:${NC}    $timestamp"
    echo -e "  ${BOLD}Progress:${NC} Step $current_step of $total_steps"

    local completed_count
    completed_count=$(jq -r '.completed | length' "$SESSION_FILE")
    if [ "$completed_count" -gt 0 ]; then
        echo -e "  ${BOLD}Done:${NC}     $completed_count steps completed"
    fi

    local services
    services=$(jq -r '.services_used | join(", ")' "$SESSION_FILE")
    if [ -n "$services" ] && [ "$services" != "" ]; then
        echo -e "  ${BOLD}Services:${NC} $services"
    fi

    local snapshot
    snapshot=$(jq -r '.snapshot_label // ""' "$SESSION_FILE")
    if [ -n "$snapshot" ] && [ "$snapshot" != "" ]; then
        echo -e "  ${BOLD}Snapshot:${NC} $snapshot"
    fi

    if [ -n "$notes" ] && [ "$notes" != "" ]; then
        echo ""
        echo -e "  ${BOLD}Notes:${NC}    $notes"
    fi

    echo ""
    echo -e "${DIM}Full session data:${NC}"
    jq '.' "$SESSION_FILE"
}

cmd_clear() {
    if [ -f "$SESSION_FILE" ]; then
        rm -f "$SESSION_FILE"
        echo -e "${GREEN}Session cleared.${NC}"
    else
        echo -e "${DIM}No saved session to clear.${NC}"
    fi
}

cmd_status() {
    if [ ! -f "$SESSION_FILE" ]; then
        echo "none"
        exit 0
    fi

    local task current_step total_steps timestamp
    task=$(jq -r '.task' "$SESSION_FILE")
    current_step=$(jq -r '.current_step' "$SESSION_FILE")
    total_steps=$(jq -r '.plan | length' "$SESSION_FILE")
    timestamp=$(jq -r '.timestamp' "$SESSION_FILE")

    echo -e "${YELLOW}Saved session found${NC}"
    echo -e "  Task: $task"
    echo -e "  Progress: Step $current_step of $total_steps"
    echo -e "  Saved: $timestamp"
}

cmd_update() {
    local patch="${1:-}"
    if [ -z "$patch" ]; then
        echo -e "${RED}Usage: session.sh update '<json-patch>'${NC}"
        echo "  Example: session.sh update '{\"current_step\": 3, \"notes\": \"Step 2 done\"}'"
        exit 1
    fi

    if [ ! -f "$SESSION_FILE" ]; then
        echo -e "${RED}No session to update.${NC} Run 'session.sh save <task>' first."
        exit 1
    fi

    local timestamp
    timestamp=$(get_iso_timestamp)

    local updated
    updated=$(jq --argjson patch "$patch" --arg ts "$timestamp" '. * $patch | .timestamp = $ts' "$SESSION_FILE")
    echo "$updated" > "$SESSION_FILE"

    echo -e "${GREEN}Session updated.${NC}"
}

cmd_help() {
    echo -e "${BOLD}session.sh${NC} — Autopilot session persistence"
    echo ""
    echo "Usage:"
    echo "  session.sh save <task>         Save session state"
    echo "  session.sh resume              Show saved session"
    echo "  session.sh clear               Remove saved session"
    echo "  session.sh status              Check for saved session"
    echo "  session.sh update '<json>'     Update session fields"
}

# ─── Main ────────────────────────────────────────────────────────────────────

COMMAND="${1:-help}"

case "$COMMAND" in
    save)       cmd_save "${2:-}" ;;
    resume)     cmd_resume ;;
    clear)      cmd_clear ;;
    status)     cmd_status ;;
    update)     cmd_update "${2:-}" ;;
    help|--help|-h) cmd_help ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NC}"
        cmd_help
        exit 1
        ;;
esac
