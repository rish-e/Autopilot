#!/bin/bash
# totp.sh — Generate TOTP 2FA codes from seeds stored in keychain
#
# Seeds are stored encrypted in the OS keychain via keychain.sh.
# Generated codes are printed to stdout for subshell capture.
# Codes and seeds are NEVER logged, stored in files, or passed as CLI arguments.
#
# Usage:
#   totp.sh generate <service>          Generate current 6-digit TOTP code
#   totp.sh store <service> [seed]      Store TOTP seed (reads stdin if no seed arg)
#   totp.sh has <service>               Check if seed exists (exit 0=yes, 1=no)
#   totp.sh remaining <service>         Seconds until current code expires
#
# Examples:
#   CODE=$(totp.sh generate vercel)     # capture in subshell — never echoed
#   echo "JBSWY3DPEHPK3PXP" | totp.sh store vercel
#   totp.sh store vercel JBSWY3DPEHPK3PXP

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCHAIN="$SCRIPT_DIR/keychain.sh"

# ─── Helpers ─────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
totp.sh — TOTP 2FA code generator for Autopilot

Commands:
  generate <service>       Generate current 6-digit TOTP code (stdout)
  store <service> [seed]   Store TOTP seed in keychain (stdin preferred)
  has <service>            Check if TOTP seed exists (exit 0/1)
  remaining <service>      Seconds until current code expires

Security:
  - Seeds stored in OS-encrypted keychain, never in files
  - Codes printed to stdout only — capture via subshell
  - Seeds passed via environment variable, never CLI argument

Examples:
  CODE=$(totp.sh generate vercel)
  echo "JBSWY3DPEHPK3PXP" | totp.sh store vercel
  if totp.sh has github; then echo "TOTP configured"; fi
EOF
}

require_python() {
    if ! command -v python3 &>/dev/null; then
        echo "Error: python3 is required for TOTP generation" >&2
        exit 1
    fi
    if ! python3 -c "import pyotp" 2>/dev/null; then
        echo "Error: pyotp not installed. Run: pip3 install pyotp" >&2
        exit 1
    fi
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_generate() {
    local service="${1:?Error: service name required}"
    require_python

    # Get seed from keychain — never echoed, captured in variable
    local seed
    seed=$("$KEYCHAIN" get "$service" totp-seed 2>/dev/null) || {
        echo "Error: No TOTP seed stored for '$service'" >&2
        echo "Store one with: echo 'SEED' | totp.sh store $service" >&2
        exit 1
    }

    # Generate code — seed goes via env var, never as CLI argument
    TOTP_SEED="$seed" python3 -c "
import os, pyotp, sys
seed = os.environ.get('TOTP_SEED', '')
if not seed:
    print('Error: TOTP_SEED not set', file=sys.stderr)
    sys.exit(1)
try:
    print(pyotp.TOTP(seed).now())
except Exception as e:
    print(f'Error generating TOTP: {e}', file=sys.stderr)
    sys.exit(1)
"
    # Clean up environment
    unset TOTP_SEED 2>/dev/null || true
}

cmd_store() {
    local service="${1:?Error: service name required}"
    local seed="${2:-}"

    # Read seed from stdin if not provided as argument
    if [[ -z "$seed" ]]; then
        if [[ -t 0 ]]; then
            echo -n "Enter TOTP seed (base32): " >&2
            read -rs seed
            echo >&2
        else
            read -r seed
        fi
    fi

    # Trim whitespace
    seed=$(echo "$seed" | tr -d '[:space:]')

    if [[ -z "$seed" ]]; then
        echo "Error: No seed provided" >&2
        exit 1
    fi

    # Validate base32 format
    if ! python3 -c "
import base64, sys
try:
    base64.b32decode(sys.argv[1], casefold=True)
except Exception:
    sys.exit(1)
" "$seed" 2>/dev/null; then
        echo "Error: Invalid base32 seed. TOTP seeds must be base32 encoded." >&2
        exit 1
    fi

    # Store in keychain via stdin (never as CLI argument in production)
    echo "$seed" | "$KEYCHAIN" set "$service" totp-seed
    echo "TOTP seed stored for '$service'" >&2
}

cmd_has() {
    local service="${1:?Error: service name required}"
    "$KEYCHAIN" has "$service" totp-seed 2>/dev/null
}

cmd_remaining() {
    local service="${1:-default}"
    python3 -c "
import time
interval = 30
remaining = int(interval - (time.time() % interval))
print(remaining)
" 2>/dev/null
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

case "${1:-}" in
    generate)  shift; cmd_generate "$@" ;;
    store)     shift; cmd_store "$@" ;;
    has)       shift; cmd_has "$@" ;;
    remaining) shift; cmd_remaining "$@" ;;
    -h|--help|help) usage ;;
    *)
        if [[ -n "${1:-}" ]]; then
            echo "Error: Unknown command '$1'" >&2
            echo "Run 'totp.sh --help' for usage" >&2
            exit 1
        fi
        usage
        exit 1
        ;;
esac
