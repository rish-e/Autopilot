#!/bin/bash
# keychain.sh — macOS Keychain wrapper for Claude Autopilot
#
# All credentials stored encrypted in the login keychain.
# Convention: service="claude-autopilot/{SERVICE}", account="{KEY}"
#
# Usage:
#   keychain.sh get <service> <key>          # prints value to stdout
#   keychain.sh set <service> <key>          # reads value from stdin (secure)
#   keychain.sh set <service> <key> <value>  # value as argument (less secure, convenience)
#   keychain.sh delete <service> <key>
#   keychain.sh has <service> <key>           # exit 0 if exists, 1 if not
#   keychain.sh list [service]                # list stored credentials
#
# Security:
#   - 'set' via stdin: value never appears in process list or shell history
#   - All values encrypted at rest by macOS Keychain
#   - Never echo credentials in scripts — use subshell expansion:
#     command --token "$(keychain.sh get vercel api-token)"

set -euo pipefail

SERVICE_PREFIX="claude-autopilot"

usage() {
    echo "Usage: keychain.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  get <service> <key>          Get a credential value"
    echo "  set <service> <key> [value]  Store a credential (reads stdin if no value arg)"
    echo "  delete <service> <key>       Delete a credential"
    echo "  has <service> <key>          Check if credential exists (exit 0/1)"
    echo "  list [service]               List stored credentials"
    exit 2
}

cmd_get() {
    local service="$1" key="$2"
    local result
    if result=$(security find-generic-password \
        -s "${SERVICE_PREFIX}/${service}" \
        -a "${key}" \
        -w 2>/dev/null); then
        echo "$result"
    else
        echo "ERROR: Credential not found: ${service}/${key}" >&2
        exit 1
    fi
}

cmd_set() {
    local service="$1" key="$2" value=""

    if [ $# -ge 3 ]; then
        # Value provided as argument
        value="$3"
    else
        # Read value from stdin (more secure — never in process list)
        read -r value
    fi

    if [ -z "$value" ]; then
        echo "ERROR: Empty value. Provide value via stdin or as third argument." >&2
        exit 1
    fi

    # -U flag: update if exists, create if not
    security add-generic-password \
        -s "${SERVICE_PREFIX}/${service}" \
        -a "${key}" \
        -w "${value}" \
        -U 2>/dev/null

    if [ $? -eq 0 ]; then
        echo "OK: Stored ${service}/${key}"
    else
        echo "ERROR: Failed to store ${service}/${key}" >&2
        exit 1
    fi
}

cmd_delete() {
    local service="$1" key="$2"
    security delete-generic-password \
        -s "${SERVICE_PREFIX}/${service}" \
        -a "${key}" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "OK: Deleted ${service}/${key}"
    else
        echo "ERROR: Credential not found: ${service}/${key}" >&2
        exit 1
    fi
}

cmd_has() {
    local service="$1" key="$2"
    security find-generic-password \
        -s "${SERVICE_PREFIX}/${service}" \
        -a "${key}" >/dev/null 2>&1
}

cmd_list() {
    local service="${1:-}"

    if [ -n "$service" ]; then
        # List keys for a specific service
        security dump-keychain 2>/dev/null | \
            grep -A 4 "\"svce\"<blob>=\"${SERVICE_PREFIX}/${service}\"" | \
            grep "\"acct\"<blob>=" | \
            sed 's/.*=\"\(.*\)\"/\1/' | \
            sort -u
    else
        # List all autopilot credentials (service/key pairs)
        security dump-keychain 2>/dev/null | \
            grep -A 4 "\"svce\"<blob>=\"${SERVICE_PREFIX}/" | \
            grep -E "(\"svce\"|\"acct\")" | \
            sed 's/.*=\"\(.*\)\"/\1/' | \
            paste - - | \
            sed "s|${SERVICE_PREFIX}/||" | \
            awk -F'\t' '{printf "%s/%s\n", $1, $2}' | \
            sort -u
    fi
}

# --- Main ---

if [ $# -lt 1 ]; then
    usage
fi

command="$1"
shift

case "$command" in
    get)
        [ $# -lt 2 ] && usage
        cmd_get "$@"
        ;;
    set)
        [ $# -lt 2 ] && usage
        cmd_set "$@"
        ;;
    delete)
        [ $# -lt 2 ] && usage
        cmd_delete "$@"
        ;;
    has)
        [ $# -lt 2 ] && usage
        cmd_has "$@"
        ;;
    list)
        cmd_list "$@"
        ;;
    *)
        echo "ERROR: Unknown command: $command" >&2
        usage
        ;;
esac
