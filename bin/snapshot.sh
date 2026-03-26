#!/bin/bash
# snapshot.sh — Snapshot & rollback for Autopilot using git stash
# Creates named snapshots before the agent makes changes, allows rollback.
#
# Usage:
#   snapshot.sh create <label>    Create a named snapshot
#   snapshot.sh list              List all autopilot snapshots
#   snapshot.sh rollback [label]  Rollback to a snapshot (latest if no label)
#   snapshot.sh diff [label]      Show what changed since the snapshot
#   snapshot.sh clean             Remove all autopilot snapshots

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

STASH_PREFIX="autopilot-snapshot:"

# ─── Verify git repo ────────────────────────────────────────────────────────

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo -e "${RED}Not inside a git repository.${NC} Snapshots require git."
    exit 1
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
SNAPSHOTS_FILE="$PROJECT_ROOT/.autopilot/snapshots.json"

# ─── Helpers ─────────────────────────────────────────────────────────────────

ensure_autopilot_dir() {
    mkdir -p "$PROJECT_ROOT/.autopilot"
}

ensure_snapshots_file() {
    ensure_autopilot_dir
    if [ ! -f "$SNAPSHOTS_FILE" ]; then
        echo '[]' > "$SNAPSHOTS_FILE"
    fi
}

get_iso_timestamp() {
    if date --version &>/dev/null 2>&1; then
        # GNU date (Linux)
        date -u +"%Y-%m-%dT%H:%M:%SZ"
    else
        # BSD date (macOS)
        date -u +"%Y-%m-%dT%H:%M:%SZ"
    fi
}

find_stash_index() {
    local label="$1"
    local search_msg="${STASH_PREFIX} ${label}"
    local match
    match=$(git stash list | grep -F "$search_msg" | head -1 || true)
    if [ -n "$match" ]; then
        echo "$match" | sed 's/stash@{\([0-9]*\)}.*/\1/'
    fi
}

list_changed_files() {
    # List tracked modified + untracked files
    local files=""
    local tracked
    tracked=$(git diff --name-only 2>/dev/null || true)
    local staged
    staged=$(git diff --cached --name-only 2>/dev/null || true)
    local untracked
    untracked=$(git ls-files --others --exclude-standard 2>/dev/null || true)

    # Combine and deduplicate
    echo -e "${tracked}\n${staged}\n${untracked}" | sort -u | grep -v '^$' || true
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_create() {
    local label="${1:-}"
    if [ -z "$label" ]; then
        echo -e "${RED}Usage: snapshot.sh create <label>${NC}"
        exit 1
    fi

    # Get list of affected files before stashing
    local files_list
    files_list=$(list_changed_files)

    if [ -z "$files_list" ] && git diff --quiet && git diff --cached --quiet; then
        echo -e "${YELLOW}No changes to snapshot.${NC} Working tree is clean."
        # Still record the snapshot as a checkpoint
        ensure_snapshots_file
        local timestamp
        timestamp=$(get_iso_timestamp)
        local entry
        entry=$(jq -n \
            --arg label "$label" \
            --arg ts "$timestamp" \
            --argjson files '[]' \
            --arg note "clean-tree" \
            '{label: $label, timestamp: $ts, files: $files, note: $note}')

        local updated
        updated=$(jq --argjson entry "$entry" '. += [$entry]' "$SNAPSHOTS_FILE")
        echo "$updated" > "$SNAPSHOTS_FILE"
        echo -e "${DIM}Recorded checkpoint: ${label}${NC}"
        return 0
    fi

    # Create the stash (includes untracked files)
    local stash_msg="${STASH_PREFIX} ${label}"
    git stash push -u -m "$stash_msg" --quiet

    # Restore working tree but KEEP the stash entry for rollback
    git stash apply --quiet

    # Record metadata AFTER pop (stash -u removes untracked files temporarily)
    ensure_snapshots_file
    local timestamp
    timestamp=$(get_iso_timestamp)
    local files_json
    files_json=$(echo "$files_list" | jq -R -s 'split("\n") | map(select(. != ""))')

    local entry
    entry=$(jq -n \
        --arg label "$label" \
        --arg ts "$timestamp" \
        --argjson files "$files_json" \
        '{label: $label, timestamp: $ts, files: $files}')

    local updated
    updated=$(jq --argjson entry "$entry" '. += [$entry]' "$SNAPSHOTS_FILE")
    echo "$updated" > "$SNAPSHOTS_FILE"

    local file_count
    file_count=$(echo "$files_list" | wc -l | tr -d ' ')
    echo -e "${GREEN}Snapshot created:${NC} ${BOLD}${label}${NC} (${file_count} files)"
}

cmd_list() {
    echo -e "${BOLD}Autopilot Snapshots${NC}"
    echo ""

    local stashes
    stashes=$(git stash list | grep -F "$STASH_PREFIX" || true)

    if [ -z "$stashes" ]; then
        # Check metadata file for clean-tree snapshots
        if [ -f "$SNAPSHOTS_FILE" ] && [ "$(jq length "$SNAPSHOTS_FILE")" -gt 0 ]; then
            echo -e "${DIM}Snapshots in metadata (no stash — clean tree at time of snapshot):${NC}"
            jq -r '.[] | "  \(.timestamp)  \(.label)  (\(.files | length) files)"' "$SNAPSHOTS_FILE"
        else
            echo -e "${DIM}No snapshots found.${NC}"
        fi
        return 0
    fi

    while IFS= read -r line; do
        local ref label
        ref=$(echo "$line" | sed 's/\(stash@{[0-9]*}\).*/\1/')
        label=$(echo "$line" | sed "s/.*${STASH_PREFIX} //" | sed 's/:.*//')
        echo -e "  ${BLUE}${ref}${NC}  ${BOLD}${label}${NC}"
    done <<< "$stashes"

    # Also show metadata
    if [ -f "$SNAPSHOTS_FILE" ] && [ "$(jq length "$SNAPSHOTS_FILE")" -gt 0 ]; then
        echo ""
        echo -e "${DIM}Metadata:${NC}"
        jq -r '.[] | "  \(.timestamp)  \(.label)  (\(.files | length) files)"' "$SNAPSHOTS_FILE"
    fi
}

cmd_rollback() {
    local label="${1:-}"
    local index=""
    local display_label=""

    if [ -n "$label" ]; then
        index=$(find_stash_index "$label")
        display_label="$label"
        if [ -z "$index" ]; then
            echo -e "${RED}Snapshot not found:${NC} ${label}"
            echo "Available snapshots:"
            cmd_list
            exit 1
        fi
    else
        # Find the latest autopilot snapshot
        local latest_match
        latest_match=$(git stash list | grep -F "$STASH_PREFIX" | head -1 || true)
        if [ -z "$latest_match" ]; then
            echo -e "${RED}No autopilot snapshots to rollback.${NC}"
            exit 1
        fi
        index=$(echo "$latest_match" | sed 's/stash@{\([0-9]*\)}.*/\1/')
        display_label=$(echo "$latest_match" | sed "s/.*${STASH_PREFIX} //")
    fi

    # Try pop first; if conflicts, report them
    if git stash pop "stash@{${index}}" --quiet 2>/dev/null; then
        echo -e "${GREEN}Rolled back to:${NC} ${BOLD}${display_label}${NC}"
    else
        # Conflicts detected — stash is kept, working tree has conflict markers
        echo -e "${YELLOW}Rolled back with conflicts:${NC} ${BOLD}${display_label}${NC}"
        echo -e "${DIM}Some files had conflicting changes. Resolve conflicts manually.${NC}"
        echo -e "${DIM}The snapshot stash is preserved — run 'git stash drop stash@{${index}}' after resolving.${NC}"
    fi

    # Remove from metadata
    if [ -f "$SNAPSHOTS_FILE" ]; then
        if [ -n "$label" ]; then
            local updated
            updated=$(jq --arg label "$label" 'map(select(.label != $label))' "$SNAPSHOTS_FILE")
            echo "$updated" > "$SNAPSHOTS_FILE"
        else
            # Remove the last entry
            local updated
            updated=$(jq '.[:-1]' "$SNAPSHOTS_FILE")
            echo "$updated" > "$SNAPSHOTS_FILE"
        fi
    fi
}

cmd_diff() {
    local label="${1:-}"

    if [ -n "$label" ]; then
        local index
        index=$(find_stash_index "$label")
        if [ -z "$index" ]; then
            echo -e "${RED}Snapshot not found:${NC} ${label}"
            exit 1
        fi
        echo -e "${BOLD}Changes since snapshot:${NC} ${label}"
        echo ""
        git stash show -p "stash@{${index}}" || true
    else
        # Diff against latest autopilot snapshot
        local latest_match
        latest_match=$(git stash list | grep -F "$STASH_PREFIX" | head -1 || true)
        if [ -z "$latest_match" ]; then
            echo -e "${RED}No autopilot snapshots to diff against.${NC}"
            exit 1
        fi
        local latest_index
        latest_index=$(echo "$latest_match" | sed 's/stash@{\([0-9]*\)}.*/\1/')
        local latest_label
        latest_label=$(echo "$latest_match" | sed "s/.*${STASH_PREFIX} //")
        echo -e "${BOLD}Changes since snapshot:${NC} ${latest_label}"
        echo ""
        git stash show -p "stash@{${latest_index}}" || true
    fi
}

cmd_clean() {
    local count=0
    while true; do
        local match
        match=$(git stash list | grep -F "$STASH_PREFIX" | head -1 || true)
        if [ -z "$match" ]; then
            break
        fi
        local index
        index=$(echo "$match" | sed 's/stash@{\([0-9]*\)}.*/\1/')
        git stash drop "stash@{${index}}" --quiet
        ((count++)) || true
    done

    # Clear metadata
    if [ -f "$SNAPSHOTS_FILE" ]; then
        echo '[]' > "$SNAPSHOTS_FILE"
    fi

    if [ "$count" -gt 0 ]; then
        echo -e "${GREEN}Cleaned ${count} autopilot snapshot(s).${NC}"
    else
        echo -e "${DIM}No autopilot snapshots to clean.${NC}"
    fi
}

cmd_help() {
    echo -e "${BOLD}snapshot.sh${NC} — Autopilot snapshot & rollback"
    echo ""
    echo "Usage:"
    echo "  snapshot.sh create <label>    Create a named snapshot"
    echo "  snapshot.sh list              List all snapshots"
    echo "  snapshot.sh rollback [label]  Rollback (latest if no label)"
    echo "  snapshot.sh diff [label]      Show changes since snapshot"
    echo "  snapshot.sh clean             Remove all autopilot snapshots"
}

# ─── Main ────────────────────────────────────────────────────────────────────

COMMAND="${1:-help}"

case "$COMMAND" in
    create)     cmd_create "${2:-}" ;;
    list)       cmd_list ;;
    rollback)   cmd_rollback "${2:-}" ;;
    diff)       cmd_diff "${2:-}" ;;
    clean)      cmd_clean ;;
    help|--help|-h) cmd_help ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NC}"
        cmd_help
        exit 1
        ;;
esac
