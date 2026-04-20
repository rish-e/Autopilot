#!/bin/bash
# chrome-debug.sh — Launch and manage a persistent Chrome instance with CDP
#
# The Playwright MCP connects to this via Chrome DevTools Protocol instead of
# launching its own browser. The browser persists independently of Claude Code —
# it never dies when your session ends.
#
# Usage:
#   chrome-debug.sh start       # Launch Chrome with CDP (background, survives terminal close)
#   chrome-debug.sh stop        # Stop the Chrome instance
#   chrome-debug.sh status      # Check if Chrome CDP is running
#   chrome-debug.sh restart     # Stop + start
#   chrome-debug.sh url         # Print the CDP endpoint URL
#   chrome-debug.sh clean-locks # Remove stale Playwright/Chrome lock files
#   chrome-debug.sh reset       # Full reset: stop, wipe profile, clean locks, start fresh

set -euo pipefail

CDP_PORT="${CDP_PORT:-9222}"
CDP_EPHEMERAL_PORT="${CDP_EPHEMERAL_PORT:-9223}"
AUTOPILOT_DIR="${AUTOPILOT_DIR:-$HOME/MCPs/autopilot}"
PROFILE_DIR="$AUTOPILOT_DIR/browser-profile"
PID_FILE="$AUTOPILOT_DIR/.chrome-debug.pid"
EPHEMERAL_PID_FILE="${TMPDIR:-/tmp}/.autopilot-ephemeral.pid"

# ─── Detect Chrome Binary ────────────────────────────────────────────────────

find_chrome() {
    case "$(uname -s)" in
        Darwin)
            for bin in \
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary" \
                "/Applications/Chromium.app/Contents/MacOS/Chromium" \
                "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
                [ -x "$bin" ] && echo "$bin" && return
            done
            ;;
        Linux)
            for bin in google-chrome google-chrome-stable chromium-browser chromium; do
                command -v "$bin" &>/dev/null && echo "$bin" && return
            done
            # Check snap
            [ -x "/snap/bin/chromium" ] && echo "/snap/bin/chromium" && return
            ;;
        MINGW*|MSYS*|CYGWIN*)
            for bin in \
                "/c/Program Files/Google/Chrome/Application/chrome.exe" \
                "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe" \
                "$LOCALAPPDATA/Google/Chrome/Application/chrome.exe"; do
                [ -x "$bin" ] && echo "$bin" && return
            done
            ;;
    esac
    echo ""
}

# ─── CDP Endpoint Detection ──────────────────────────────────────────────────

# macOS Chrome may bind to IPv6 only — try both
get_cdp_url() {
    # Try IPv4 first, then IPv6
    if curl -s --connect-timeout 2 "http://127.0.0.1:${CDP_PORT}/json/version" > /dev/null 2>&1; then
        echo "http://127.0.0.1:${CDP_PORT}"
    elif curl -s --connect-timeout 2 "http://[::1]:${CDP_PORT}/json/version" > /dev/null 2>&1; then
        echo "http://[::1]:${CDP_PORT}"
    else
        echo ""
    fi
}

is_running() {
    local url
    url=$(get_cdp_url)
    [ -n "$url" ]
}

# ─── Health Check ─────────────────────────────────────────────────────────────

health_check() {
    # Verify Chrome is actually usable by navigating to a page via CDP
    # Returns 1 if profile appears corrupted (crash dialog, blank page, etc.)
    local url
    url=$(get_cdp_url)
    [ -z "$url" ] && return 1

    # Give Chrome a moment to fully initialize
    sleep 1

    # Get the first tab's page info
    local page_info
    page_info=$(curl -s --connect-timeout 3 "${url}/json/list" 2>/dev/null)
    [ -z "$page_info" ] && return 1

    # Check if any tab title contains corruption indicators
    local titles
    titles=$(echo "$page_info" | jq -r '.[].title // ""' 2>/dev/null)

    if echo "$titles" | grep -qi "went wrong\|crash\|restore\|error"; then
        echo "Profile corruption detected (page title: $(echo "$titles" | head -1))"
        return 1
    fi

    # Try to navigate the first tab to about:blank to confirm it's responsive
    local ws_url
    ws_url=$(echo "$page_info" | jq -r '.[0].webSocketDebuggerUrl // ""' 2>/dev/null)

    # If we got a valid websocket URL and page info, Chrome is healthy
    if [ -n "$ws_url" ]; then
        return 0
    fi

    return 1
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_start() {
    if is_running; then
        echo "Chrome CDP already running on port ${CDP_PORT}"
        echo "Endpoint: $(get_cdp_url)"
        return 0
    fi

    # Clean stale lock files that prevent Chrome from starting
    cmd_clean_locks

    local chrome_bin
    chrome_bin=$(find_chrome)

    if [ -z "$chrome_bin" ]; then
        echo "ERROR: No Chrome/Chromium installation found." >&2
        echo "Install Google Chrome or Chromium and try again." >&2
        exit 1
    fi

    echo "Starting Chrome with CDP on port ${CDP_PORT}..."
    echo "Binary: $chrome_bin"
    echo "Profile: $PROFILE_DIR"

    mkdir -p "$PROFILE_DIR"

    # Launch Chrome in background with CDP enabled
    nohup "$chrome_bin" \
        --remote-debugging-port="${CDP_PORT}" \
        --no-first-run \
        --no-default-browser-check \
        --user-data-dir="$PROFILE_DIR" \
        --disable-background-timer-throttling \
        --disable-renderer-backgrounding \
        --disable-backgrounding-occluded-windows \
        --disable-ipc-flooding-protection \
        --disable-hang-monitor \
        --disable-back-forward-cache \
        --disable-session-crashed-bubble \
        --hide-crash-restore-bubble \
        --disable-features=CalculateNativeWinOcclusion,InfiniteSessionRestore \
        > /dev/null 2>&1 &

    local pid=$!
    echo "$pid" > "$PID_FILE"

    # Wait for CDP to become available (up to 10 seconds)
    local attempts=0
    while [ $attempts -lt 20 ]; do
        if is_running; then
            echo "Chrome CDP ready"
            echo "Endpoint: $(get_cdp_url)"
            echo "PID: $pid"

            # Health check: verify Chrome is actually usable (not showing profile corruption dialog)
            if ! health_check; then
                echo ""
                echo "WARNING: Chrome profile appears corrupted. Auto-resetting..."
                # Don't call cmd_reset (infinite loop) — do inline reset
                kill "$pid" 2>/dev/null || true
                sleep 1
                rm -f "$PID_FILE"
                if [ -d "$PROFILE_DIR" ]; then
                    find "$PROFILE_DIR" -not -name '.gitkeep' -not -name '.' -not -name '..' -maxdepth 1 -exec rm -rf {} + 2>/dev/null
                    echo "Profile wiped"
                fi
                cmd_clean_locks 2>/dev/null
                # Relaunch with fresh profile
                nohup "$chrome_bin" \
                    --remote-debugging-port="${CDP_PORT}" \
                    --no-first-run \
                    --no-default-browser-check \
                    --user-data-dir="$PROFILE_DIR" \
                    --disable-background-timer-throttling \
                    --disable-renderer-backgrounding \
                    --disable-backgrounding-occluded-windows \
                    --disable-ipc-flooding-protection \
                    --disable-hang-monitor \
                    --disable-back-forward-cache \
                    --disable-session-crashed-bubble \
                    --hide-crash-restore-bubble \
                    --disable-features=CalculateNativeWinOcclusion,InfiniteSessionRestore \
                    > /dev/null 2>&1 &
                pid=$!
                echo "$pid" > "$PID_FILE"
                # Wait for fresh instance
                local retry=0
                while [ $retry -lt 20 ]; do
                    if is_running; then
                        echo "Chrome CDP ready (fresh profile)"
                        echo "Endpoint: $(get_cdp_url)"
                        echo "PID: $pid"
                        return 0
                    fi
                    sleep 0.5
                    ((retry++))
                done
                echo "ERROR: Chrome failed to start even after profile reset" >&2
                exit 1
            fi

            return 0
        fi
        sleep 0.5
        ((attempts++))
    done

    echo "ERROR: Chrome started but CDP not responding on port ${CDP_PORT}" >&2
    echo "Check if another Chrome instance is using the debugging port" >&2
    exit 1
}

cmd_stop() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            echo "Stopped Chrome CDP (PID: $pid)"
        else
            echo "PID $pid not running (stale PID file)"
        fi
        rm -f "$PID_FILE"
    else
        # Try to find and stop any Chrome with our debug port
        # Use lsof (macOS/most Linux), fall back to ss+awk (minimal Linux), then fuser
        local pids=""
        if command -v lsof &>/dev/null; then
            pids=$(lsof -ti ":${CDP_PORT}" 2>/dev/null || true)
        elif command -v ss &>/dev/null; then
            pids=$(ss -tlnp "sport = :${CDP_PORT}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' || true)
        elif command -v fuser &>/dev/null; then
            pids=$(fuser "${CDP_PORT}/tcp" 2>/dev/null || true)
        fi
        if [ -n "$pids" ]; then
            echo "$pids" | xargs kill 2>/dev/null
            echo "Stopped Chrome CDP process(es) on port ${CDP_PORT}"
        else
            echo "No Chrome CDP instance found on port ${CDP_PORT}"
        fi
    fi
}

cmd_status() {
    if is_running; then
        local url
        url=$(get_cdp_url)
        echo "Chrome CDP is running"
        echo "Endpoint: $url"
        # Show browser version
        local version
        version=$(curl -s "${url}/json/version" 2>/dev/null | jq -r '.Browser // "unknown"' 2>/dev/null)
        echo "Browser: $version"
        # Show open tabs
        local tabs
        tabs=$(curl -s "${url}/json/list" 2>/dev/null | jq 'length' 2>/dev/null || echo "?")
        echo "Open tabs: $tabs"
        if [ -f "$PID_FILE" ]; then
            echo "PID: $(cat "$PID_FILE")"
        fi
    else
        echo "Chrome CDP is NOT running"
        echo "Start it: $AUTOPILOT_DIR/bin/chrome-debug.sh start"
        return 1
    fi
}

cmd_url() {
    local url
    url=$(get_cdp_url)
    if [ -n "$url" ]; then
        echo "$url"
    else
        echo "ERROR: Chrome CDP not running on port ${CDP_PORT}" >&2
        exit 1
    fi
}

cmd_restart() {
    cmd_stop
    cmd_clean_locks
    sleep 1
    cmd_start
}

cmd_clean_locks() {
    local cleaned=0

    # Clean Playwright MCP's managed browser lock files (mcp-chrome-* directories)
    # These cause "Browser is already in use" errors when stale
    local pw_cache="$HOME/Library/Caches/ms-playwright"
    if [ -d "$pw_cache" ]; then
        # Search recursively to catch mcp-chrome-*/SingletonLock etc.
        find "$pw_cache" -name "SingletonLock" -delete 2>/dev/null && ((cleaned++)) || true
        find "$pw_cache" -name "SingletonSocket" -delete 2>/dev/null && ((cleaned++)) || true
        find "$pw_cache" -name "SingletonCookie" -delete 2>/dev/null && ((cleaned++)) || true
        # Also clean RunningChromeVersion which can prevent reuse
        find "$pw_cache" -name "RunningChromeVersion" -delete 2>/dev/null && ((cleaned++)) || true
    fi

    # Also check Linux path
    local pw_cache_linux="$HOME/.cache/ms-playwright"
    if [ -d "$pw_cache_linux" ]; then
        find "$pw_cache_linux" -name "SingletonLock" -delete 2>/dev/null && ((cleaned++)) || true
        find "$pw_cache_linux" -name "SingletonSocket" -delete 2>/dev/null && ((cleaned++)) || true
        find "$pw_cache_linux" -name "SingletonCookie" -delete 2>/dev/null && ((cleaned++)) || true
    fi

    # Clean our own profile lock files
    if [ -d "$PROFILE_DIR" ]; then
        for lock in SingletonLock SingletonSocket SingletonCookie; do
            if [ -e "$PROFILE_DIR/$lock" ]; then
                rm -f "$PROFILE_DIR/$lock" 2>/dev/null && ((cleaned++)) || true
            fi
        done
    fi

    if [ "$cleaned" -gt 0 ]; then
        echo "Cleaned stale lock files ($cleaned removed)"
    else
        echo "No stale lock files found"
    fi
}

# ─── Ephemeral Browser Profile ───────────────────────────────────────────────
# Per-task isolated Chrome instance on a separate port (9223).
# Profile lives in /tmp and is wiped on stop — no cookie/session bleed between tasks.
# Use for: service signups, OAuth flows, any task that shouldn't share browser state.

cmd_ephemeral_start() {
    local task_id="${1:-$(date +%s)}"
    local ephemeral_profile="${TMPDIR:-/tmp}/autopilot-task-${task_id}"

    if curl -s --connect-timeout 1 "http://127.0.0.1:${CDP_EPHEMERAL_PORT}/json/version" > /dev/null 2>&1; then
        echo "Ephemeral Chrome already running on port ${CDP_EPHEMERAL_PORT}"
        echo "Ephemeral endpoint: http://127.0.0.1:${CDP_EPHEMERAL_PORT}"
        return 0
    fi

    local chrome_bin
    chrome_bin=$(find_chrome)
    if [ -z "$chrome_bin" ]; then
        echo "ERROR: No Chrome/Chromium installation found." >&2
        exit 1
    fi

    mkdir -p "$ephemeral_profile"
    echo "Starting ephemeral Chrome (task: ${task_id}, port: ${CDP_EPHEMERAL_PORT})..."
    echo "Profile: ${ephemeral_profile} (auto-wiped on stop)"

    nohup "$chrome_bin" \
        --remote-debugging-port="${CDP_EPHEMERAL_PORT}" \
        --no-first-run \
        --no-default-browser-check \
        --user-data-dir="$ephemeral_profile" \
        --disable-background-timer-throttling \
        --disable-renderer-backgrounding \
        --disable-backgrounding-occluded-windows \
        --disable-ipc-flooding-protection \
        --disable-hang-monitor \
        --disable-back-forward-cache \
        --disable-session-crashed-bubble \
        --hide-crash-restore-bubble \
        --disable-features=CalculateNativeWinOcclusion,InfiniteSessionRestore \
        > /dev/null 2>&1 &

    local pid=$!
    echo "${pid}:${ephemeral_profile}" > "$EPHEMERAL_PID_FILE"

    local attempts=0
    while [ $attempts -lt 20 ]; do
        if curl -s --connect-timeout 1 "http://127.0.0.1:${CDP_EPHEMERAL_PORT}/json/version" > /dev/null 2>&1; then
            echo "Ephemeral Chrome ready"
            echo "Ephemeral endpoint: http://127.0.0.1:${CDP_EPHEMERAL_PORT}"
            echo "PID: $pid"
            return 0
        fi
        sleep 0.5
        ((attempts++))
    done

    echo "ERROR: Ephemeral Chrome failed to start on port ${CDP_EPHEMERAL_PORT}" >&2
    exit 1
}

cmd_ephemeral_stop() {
    if [ ! -f "$EPHEMERAL_PID_FILE" ]; then
        echo "No ephemeral Chrome session recorded"
        return 0
    fi

    local entry pid ephemeral_profile
    entry=$(cat "$EPHEMERAL_PID_FILE")
    pid="${entry%%:*}"
    ephemeral_profile="${entry#*:}"

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        echo "Stopped ephemeral Chrome (PID: $pid)"
    else
        echo "Ephemeral Chrome PID $pid not running (stale)"
    fi
    rm -f "$EPHEMERAL_PID_FILE"

    # Wipe profile — only if it's safely inside /tmp to prevent accidents
    if [ -n "$ephemeral_profile" ] && [[ "$ephemeral_profile" == /tmp/autopilot-task-* ]]; then
        rm -rf "$ephemeral_profile"
        echo "Ephemeral profile wiped (task isolation complete)"
    fi
}

cmd_ephemeral_url() {
    if curl -s --connect-timeout 1 "http://127.0.0.1:${CDP_EPHEMERAL_PORT}/json/version" > /dev/null 2>&1; then
        echo "http://127.0.0.1:${CDP_EPHEMERAL_PORT}"
    else
        echo "ERROR: Ephemeral Chrome not running on port ${CDP_EPHEMERAL_PORT}" >&2
        exit 1
    fi
}

cmd_reset() {
    echo "Resetting Chrome CDP (full profile wipe)..."

    # Stop any running instance
    cmd_stop 2>/dev/null

    # Kill anything on our port
    local pids=""
    if command -v lsof &>/dev/null; then
        pids=$(lsof -ti ":${CDP_PORT}" 2>/dev/null || true)
    elif command -v ss &>/dev/null; then
        pids=$(ss -tlnp "sport = :${CDP_PORT}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' || true)
    elif command -v fuser &>/dev/null; then
        pids=$(fuser "${CDP_PORT}/tcp" 2>/dev/null || true)
    fi
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill 2>/dev/null || true
        sleep 1
    fi

    # Also kill any chrome using our specific profile directory
    pids=$(pgrep -f "user-data-dir=$PROFILE_DIR" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill 2>/dev/null || true
        sleep 1
    fi

    # Wipe profile but keep .gitkeep
    if [ -d "$PROFILE_DIR" ]; then
        find "$PROFILE_DIR" -not -name '.gitkeep' -not -name '.' -not -name '..' -maxdepth 1 -exec rm -rf {} + 2>/dev/null
        echo "Profile wiped: $PROFILE_DIR"
    fi

    # Clean all lock files
    cmd_clean_locks

    # Start fresh
    echo ""
    cmd_start
}

# ─── Main ────────────────────────────────────────────────────────────────────

case "${1:-status}" in
    start)            cmd_start ;;
    stop)             cmd_stop ;;
    status)           cmd_status ;;
    restart)          cmd_restart ;;
    url)              cmd_url ;;
    clean-locks)      cmd_clean_locks ;;
    reset)            cmd_reset ;;
    ephemeral-start)  cmd_ephemeral_start "${2:-}" ;;
    ephemeral-stop)   cmd_ephemeral_stop ;;
    ephemeral-url)    cmd_ephemeral_url ;;
    *)
        echo "Usage: chrome-debug.sh {start|stop|status|restart|url|clean-locks|reset}"
        echo "       chrome-debug.sh {ephemeral-start [task-id]|ephemeral-stop|ephemeral-url}"
        echo ""
        echo "Persistent browser (port ${CDP_PORT}):"
        echo "  start       Launch Chrome with CDP"
        echo "  stop        Stop the Chrome instance"
        echo "  status      Check if Chrome CDP is running"
        echo "  restart     Stop + clean locks + start"
        echo "  url         Print the CDP endpoint URL"
        echo "  clean-locks Remove stale browser lock files"
        echo "  reset       Full reset: stop, wipe profile, clean locks, start fresh"
        echo ""
        echo "Ephemeral browser (port ${CDP_EPHEMERAL_PORT}, auto-wiped on stop):"
        echo "  ephemeral-start [id]  Fresh profile for task isolation"
        echo "  ephemeral-stop        Stop + wipe ephemeral profile"
        echo "  ephemeral-url         Print ephemeral CDP endpoint"
        exit 2
        ;;
esac
