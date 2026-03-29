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

set -euo pipefail

CDP_PORT="${CDP_PORT:-9222}"
PROFILE_DIR="$HOME/MCPs/autopilot/browser-profile"
PID_FILE="$HOME/MCPs/autopilot/.chrome-debug.pid"

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
        --disable-features=CalculateNativeWinOcclusion \
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
        local pids
        pids=$(lsof -ti ":${CDP_PORT}" 2>/dev/null || true)
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
        echo "Start it: ~/MCPs/autopilot/bin/chrome-debug.sh start"
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

    # Clean Playwright MCP's managed browser lock files
    local pw_cache="$HOME/Library/Caches/ms-playwright"
    if [ -d "$pw_cache" ]; then
        find "$pw_cache" -name "SingletonLock" -delete 2>/dev/null && ((cleaned++)) || true
        find "$pw_cache" -name "SingletonSocket" -delete 2>/dev/null && ((cleaned++)) || true
        find "$pw_cache" -name "SingletonCookie" -delete 2>/dev/null && ((cleaned++)) || true
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

# ─── Main ────────────────────────────────────────────────────────────────────

case "${1:-status}" in
    start)       cmd_start ;;
    stop)        cmd_stop ;;
    status)      cmd_status ;;
    restart)     cmd_restart ;;
    url)         cmd_url ;;
    clean-locks) cmd_clean_locks ;;
    *)
        echo "Usage: chrome-debug.sh {start|stop|status|restart|url|clean-locks}"
        echo ""
        echo "Manages a persistent Chrome instance with Chrome DevTools Protocol."
        echo "Playwright MCP connects to this instead of launching its own browser."
        exit 2
        ;;
esac
