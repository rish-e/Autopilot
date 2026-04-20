#!/usr/bin/env bash
# daemon.sh — Autopilot webhook daemon lifecycle manager
#
# Usage:
#   daemon.sh start           — start the daemon in background
#   daemon.sh stop            — gracefully stop the daemon
#   daemon.sh status          — show running state + /status endpoint
#   daemon.sh logs [N]        — tail daemon log (default 50 lines)
#   daemon.sh trigger "task"  — send a task via POST /task
#   daemon.sh setup           — generate secret + print GitHub webhook instructions

set -euo pipefail

AUTOPILOT_DIR="${AUTOPILOT_DIR:-$HOME/MCPs/autopilot}"
DAEMON_SCRIPT="$AUTOPILOT_DIR/bin/daemon-server.py"
PID_FILE="${TMPDIR:-/tmp}/.autopilot-daemon.pid"
LOG_FILE="$HOME/.autopilot/daemon.log"
PORT="${AUTOPILOT_DAEMON_PORT:-7891}"
KEYCHAIN="$AUTOPILOT_DIR/bin/keychain.sh"

# ─── Helpers ──────────────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

is_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
    kill -0 "$pid" 2>/dev/null
}

get_secret() {
    if [ -x "$KEYCHAIN" ]; then
        "$KEYCHAIN" get autopilot-daemon secret 2>/dev/null || true
    fi
}

require_running() {
    is_running || die "Daemon is not running. Start it with: daemon.sh start"
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_start() {
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE")
        info "Daemon already running (PID $pid) on port $PORT"
        return 0
    fi

    [ -f "$DAEMON_SCRIPT" ] || die "daemon-server.py not found at $DAEMON_SCRIPT"
    command -v python3 >/dev/null 2>&1 || die "python3 not found"

    mkdir -p "$(dirname "$LOG_FILE")"

    local secret
    secret=$(get_secret)

    info "Starting Autopilot daemon on port $PORT..."

    AUTOPILOT_DIR="$AUTOPILOT_DIR" \
    AUTOPILOT_DAEMON_PORT="$PORT" \
    AUTOPILOT_DAEMON_SECRET="$secret" \
        nohup python3 "$DAEMON_SCRIPT" >> "$LOG_FILE" 2>&1 &

    local pid=$!
    echo "$pid" > "$PID_FILE"

    # Brief settle + verify
    sleep 0.5
    if kill -0 "$pid" 2>/dev/null; then
        info "Daemon started (PID $pid)"
        info "Endpoint: http://127.0.0.1:$PORT"
        info "Log:      $LOG_FILE"
    else
        rm -f "$PID_FILE"
        die "Daemon exited immediately — check $LOG_FILE"
    fi
}

cmd_stop() {
    if ! is_running; then
        info "Daemon is not running"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")
    info "Stopping daemon (PID $pid)..."
    kill -TERM "$pid" 2>/dev/null || true

    local i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 20 ]; do
        sleep 0.25
        i=$((i + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        info "Still running after 5s — sending SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    info "Daemon stopped"
}

cmd_status() {
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE")
        info "Daemon running (PID $pid) on port $PORT"
        if command -v curl >/dev/null 2>&1; then
            local response
            response=$(curl -sf "http://127.0.0.1:$PORT/status" 2>/dev/null) || {
                info "WARNING: process alive but /status unreachable"
                return 0
            }
            echo "$response" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"  task_running: {d.get('task_running', '?')}\")
print(f\"  pid:          {d.get('pid', 'none')}\")
print(f\"  timestamp:    {d.get('timestamp', '?')}\")
" 2>/dev/null || echo "  $response"
        fi
    else
        info "Daemon is NOT running"
        [ -f "$PID_FILE" ] && { rm -f "$PID_FILE"; info "(stale PID file cleaned up)"; }
    fi
}

cmd_logs() {
    local n="${1:-50}"
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    tail -n "$n" "$LOG_FILE"
}

cmd_trigger() {
    local task="${1:-}"
    [ -n "$task" ] || die "Usage: daemon.sh trigger \"task description\""
    require_running

    local secret
    secret=$(get_secret)
    [ -n "$secret" ] || die "No secret configured. Run: daemon.sh setup"

    command -v curl >/dev/null 2>&1 || die "curl not found"

    local response http_code
    response=$(curl -sf -w "\n%{http_code}" \
        -X POST "http://127.0.0.1:$PORT/task" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $secret" \
        -d "{\"task\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$task")}" \
        2>/dev/null) || die "Request failed — is the daemon running?"

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -n -1)

    echo "$body" | python3 -c "
import json, sys
d = json.load(sys.stdin)
status = 'OK' if d.get('ok') else 'FAILED'
print(f\"  {status}: {d.get('message', '')}\")
" 2>/dev/null || echo "  $body"

    [ "$http_code" = "200" ] || die "Server returned HTTP $http_code"
}

cmd_setup() {
    command -v python3 >/dev/null 2>&1 || die "python3 required for secret generation"

    # Generate a 32-byte hex secret
    local secret
    secret=$(python3 -c "import secrets; print(secrets.token_hex(32))")

    if [ -x "$KEYCHAIN" ]; then
        "$KEYCHAIN" set autopilot-daemon secret "$secret"
        info "Secret stored in keychain (service=autopilot-daemon, key=secret)"
    else
        info "WARNING: keychain.sh not found — store this secret manually:"
        echo ""
        echo "  AUTOPILOT_DAEMON_SECRET=$secret"
        echo ""
    fi

    local public_ip
    public_ip=$(curl -sf https://api.ipify.org 2>/dev/null || echo "<your-server-ip>")

    echo ""
    echo "─────────────────────────────────────────────────────────"
    echo "  GitHub Webhook Configuration"
    echo "─────────────────────────────────────────────────────────"
    echo "  Payload URL:   http://$public_ip:$PORT/github"
    echo "                 (or your ngrok/tunnel URL + /github)"
    echo "  Content type:  application/json"
    echo "  Secret:        $secret"
    echo "  Events:        push, pull_request, workflow_run, issues"
    echo "─────────────────────────────────────────────────────────"
    echo ""
    echo "  After configuring GitHub, start the daemon:"
    echo "    daemon.sh start"
    echo ""
    echo "  To expose locally with ngrok:"
    echo "    ngrok http $PORT"
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────

CMD="${1:-help}"
shift || true

case "$CMD" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    logs)    cmd_logs "${1:-50}" ;;
    trigger) cmd_trigger "$*" ;;
    setup)   cmd_setup ;;
    help|--help|-h)
        echo "Usage: daemon.sh <command>"
        echo ""
        echo "  start             Start the daemon (background)"
        echo "  stop              Stop the daemon"
        echo "  status            Show running state"
        echo "  logs [N]          Tail log (default 50 lines)"
        echo "  trigger \"task\"    POST a task via HTTP"
        echo "  setup             Generate secret + print GitHub webhook config"
        ;;
    *)
        die "Unknown command: $CMD  (try: daemon.sh help)"
        ;;
esac
