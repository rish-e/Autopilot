#!/bin/bash
# budget.sh — Session spend cap and resource guard for Autopilot
#
# Tracks service signups, estimated token spend, and tool call volume per session.
# Hard-halts the session when limits are exceeded to prevent runaway costs.
#
# Usage:
#   budget.sh init                        # Start a new session budget
#   budget.sh check                       # Check current spend (exits 2 if over limit)
#   budget.sh record signup <service>     # Record a service signup
#   budget.sh record cost <usd_estimate>  # Record an estimated cost
#   budget.sh record call                 # Record one tool call
#   budget.sh status                      # Print current budget status
#   budget.sh reset                       # Reset session budget

set -uo pipefail

AUTOPILOT_DIR="${AUTOPILOT_DIR:-$HOME/MCPs/autopilot}"
BUDGET_FILE="${TMPDIR:-/tmp}/.autopilot-budget-${PPID}.json"

# ─── Hard Limits ─────────────────────────────────────────────────────────────

MAX_SIGNUPS=5          # Max new service account creations per session
MAX_COST_USD=20.0      # Max estimated cumulative spend per session
MAX_TOOL_CALLS=500     # Max tool calls per session (loop guard)
WARN_COST_USD=10.0     # Warn (but continue) at this spend level
WARN_SIGNUPS=3         # Warn at this many signups

# ─── Helpers ─────────────────────────────────────────────────────────────────

now_ts() { date +%s; }

read_budget() {
    if [ ! -f "$BUDGET_FILE" ]; then
        echo '{"signups":0,"cost_usd":0,"tool_calls":0,"services":[],"started_at":0}'
        return
    fi
    cat "$BUDGET_FILE"
}

write_budget() {
    echo "$1" > "$BUDGET_FILE"
}

jq_get() {
    echo "$1" | jq -r "$2" 2>/dev/null || echo "0"
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_init() {
    local budget
    budget=$(jq -n --arg ts "$(now_ts)" \
        '{"signups":0,"cost_usd":0.0,"tool_calls":0,"services":[],"started_at":($ts|tonumber)}')
    write_budget "$budget"
    echo "[budget] Session initialized. Limits: ${MAX_SIGNUPS} signups, \$${MAX_COST_USD} spend, ${MAX_TOOL_CALLS} tool calls" >&2
}

cmd_check() {
    if ! command -v jq &>/dev/null; then
        exit 0  # Can't check without jq — allow through
    fi

    local budget
    budget=$(read_budget)

    local signups cost tool_calls
    signups=$(jq_get "$budget" '.signups')
    cost=$(jq_get "$budget" '.cost_usd')
    tool_calls=$(jq_get "$budget" '.tool_calls')

    # Hard limits — exit 2 to halt
    if [ "$signups" -ge "$MAX_SIGNUPS" ] 2>/dev/null; then
        echo "BUDGET HALT: Reached signup limit (${signups}/${MAX_SIGNUPS} service accounts created this session)." >&2
        echo "This is a safety limit to prevent runaway account creation. Start a new session to continue." >&2
        exit 2
    fi

    if (( $(echo "$cost >= $MAX_COST_USD" | bc -l 2>/dev/null || echo 0) )); then
        echo "BUDGET HALT: Reached spend limit (\$${cost}/\$${MAX_COST_USD} estimated this session)." >&2
        echo "This is a safety limit to prevent runaway costs. Start a new session to continue." >&2
        exit 2
    fi

    if [ "$tool_calls" -ge "$MAX_TOOL_CALLS" ] 2>/dev/null; then
        echo "BUDGET HALT: Reached tool call limit (${tool_calls}/${MAX_TOOL_CALLS} this session)." >&2
        echo "This may indicate a loop. Check logs and start a new session." >&2
        exit 2
    fi

    # Warnings — exit 0 (continue but notify)
    if [ "$signups" -ge "$WARN_SIGNUPS" ] 2>/dev/null; then
        echo "BUDGET WARN: ${signups} service signups this session (limit: ${MAX_SIGNUPS})" >&2
    fi
    if (( $(echo "$cost >= $WARN_COST_USD" | bc -l 2>/dev/null || echo 0) )); then
        echo "BUDGET WARN: Estimated \$${cost} spent this session (limit: \$${MAX_COST_USD})" >&2
    fi

    exit 0
}

cmd_record() {
    if ! command -v jq &>/dev/null; then return; fi

    local budget
    budget=$(read_budget)

    case "${1:-}" in
        signup)
            local service="${2:-unknown}"
            budget=$(echo "$budget" | jq \
                --arg svc "$service" \
                '.signups += 1 | .services += [$svc]')
            echo "[budget] Signup recorded: $service (total: $(jq_get "$budget" '.signups')/${MAX_SIGNUPS})" >&2
            ;;
        cost)
            local amount="${2:-0}"
            budget=$(echo "$budget" | jq --argjson amt "$amount" '.cost_usd += $amt')
            local total
            total=$(jq_get "$budget" '.cost_usd')
            echo "[budget] Cost recorded: \$${amount} (total: \$${total}/\$${MAX_COST_USD})" >&2
            ;;
        call)
            budget=$(echo "$budget" | jq '.tool_calls += 1')
            ;;
    esac

    write_budget "$budget"
    cmd_check || exit $?
}

cmd_status() {
    if ! command -v jq &>/dev/null; then
        echo "[budget] jq not available — budget tracking disabled" >&2
        return
    fi

    local budget
    budget=$(read_budget)
    local signups cost tool_calls services started_at
    signups=$(jq_get "$budget" '.signups')
    cost=$(jq_get "$budget" '.cost_usd')
    tool_calls=$(jq_get "$budget" '.tool_calls')
    services=$(echo "$budget" | jq -r '.services | join(", ")' 2>/dev/null || echo "none")
    started_at=$(jq_get "$budget" '.started_at')

    echo "=== Session Budget ==="
    echo "  Signups:    ${signups}/${MAX_SIGNUPS}   services: ${services:-none}"
    echo "  Est. cost:  \$${cost}/\$${MAX_COST_USD}"
    echo "  Tool calls: ${tool_calls}/${MAX_TOOL_CALLS}"
    if [ "$started_at" -gt 0 ] 2>/dev/null; then
        local elapsed=$(( $(now_ts) - started_at ))
        echo "  Session age: ${elapsed}s"
    fi
}

cmd_reset() {
    rm -f "$BUDGET_FILE"
    echo "[budget] Session budget reset" >&2
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

case "${1:-status}" in
    init)   cmd_init ;;
    check)  cmd_check ;;
    record) shift; cmd_record "$@" ;;
    status) cmd_status ;;
    reset)  cmd_reset ;;
    *)
        echo "Usage: budget.sh <init|check|record signup <svc>|record cost <usd>|record call|status|reset>" >&2
        exit 1
        ;;
esac
