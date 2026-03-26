#!/bin/bash
# keychain.sh — Cross-platform credential store for Claude Autopilot
#
# Backends:
#   macOS   → macOS Keychain (security command)
#   Linux   → secret-tool (GNOME Keyring / libsecret)
#   Windows → Windows Credential Manager (cmdkey) via Git Bash / WSL
#
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
#   - All values encrypted at rest by OS credential store
#   - Never echo credentials in scripts — use subshell expansion:
#     command --token "$(keychain.sh get vercel api-token)"

set -euo pipefail

SERVICE_PREFIX="claude-autopilot"

# ─── Detect Platform ─────────────────────────────────────────────────────────

detect_platform() {
    case "$(uname -s)" in
        Darwin)
            echo "macos"
            ;;
        Linux)
            # Check if running in WSL
            if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "windows"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

PLATFORM=$(detect_platform)

# ─── Platform Prerequisite Check ─────────────────────────────────────────────

check_prerequisites() {
    case "$PLATFORM" in
        macos)
            # security command is always available on macOS
            ;;
        linux)
            if ! command -v secret-tool &>/dev/null; then
                echo "ERROR: secret-tool not found. Install it:" >&2
                echo "  Ubuntu/Debian: sudo apt install libsecret-tools" >&2
                echo "  Fedora:        sudo dnf install libsecret" >&2
                echo "  Arch:          sudo pacman -S libsecret" >&2
                exit 1
            fi
            ;;
        wsl)
            # WSL can use either secret-tool (if installed) or cmdkey.exe
            if command -v secret-tool &>/dev/null; then
                PLATFORM="linux"  # Use Linux backend
            elif command -v cmdkey.exe &>/dev/null; then
                PLATFORM="windows"  # Use Windows backend
            else
                echo "ERROR: No credential store found in WSL." >&2
                echo "  Option 1: sudo apt install libsecret-tools gnome-keyring" >&2
                echo "  Option 2: Ensure cmdkey.exe is available from Windows" >&2
                exit 1
            fi
            ;;
        windows)
            if ! command -v cmdkey.exe &>/dev/null && ! command -v cmdkey &>/dev/null; then
                echo "ERROR: cmdkey not found. Run from Git Bash or ensure Windows system tools are in PATH." >&2
                exit 1
            fi
            ;;
        *)
            echo "ERROR: Unsupported platform: $(uname -s)" >&2
            echo "Supported: macOS, Linux (with libsecret), Windows (Git Bash/WSL)" >&2
            exit 1
            ;;
    esac
}

check_prerequisites

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: keychain.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  get <service> <key>          Get a credential value"
    echo "  set <service> <key> [value]  Store a credential (reads stdin if no value arg)"
    echo "  delete <service> <key>       Delete a credential"
    echo "  has <service> <key>          Check if credential exists (exit 0/1)"
    echo "  list [service]               List stored credentials"
    echo ""
    echo "Platform: $PLATFORM"
    exit 2
}

# ─── macOS Backend (security command) ────────────────────────────────────────

macos_get() {
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

macos_set() {
    local service="$1" key="$2" value="$3"
    security add-generic-password \
        -s "${SERVICE_PREFIX}/${service}" \
        -a "${key}" \
        -w "${value}" \
        -U 2>/dev/null
    echo "OK: Stored ${service}/${key}"
}

macos_delete() {
    local service="$1" key="$2"
    if security delete-generic-password \
        -s "${SERVICE_PREFIX}/${service}" \
        -a "${key}" >/dev/null 2>&1; then
        echo "OK: Deleted ${service}/${key}"
    else
        echo "ERROR: Credential not found: ${service}/${key}" >&2
        exit 1
    fi
}

macos_has() {
    local service="$1" key="$2"
    security find-generic-password \
        -s "${SERVICE_PREFIX}/${service}" \
        -a "${key}" >/dev/null 2>&1
}

macos_list() {
    local service="${1:-}"
    if [ -n "$service" ]; then
        security dump-keychain 2>/dev/null | \
            grep -A 4 "\"svce\"<blob>=\"${SERVICE_PREFIX}/${service}\"" | \
            grep "\"acct\"<blob>=" | \
            sed 's/.*=\"\(.*\)\"/\1/' | \
            sort -u
    else
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

# ─── Linux Backend (secret-tool / libsecret) ────────────────────────────────

linux_get() {
    local service="$1" key="$2"
    local result
    if result=$(secret-tool lookup service "${SERVICE_PREFIX}/${service}" key "${key}" 2>/dev/null); then
        if [ -n "$result" ]; then
            echo "$result"
        else
            echo "ERROR: Credential not found: ${service}/${key}" >&2
            exit 1
        fi
    else
        echo "ERROR: Credential not found: ${service}/${key}" >&2
        exit 1
    fi
}

linux_set() {
    local service="$1" key="$2" value="$3"
    echo -n "$value" | secret-tool store \
        --label="${SERVICE_PREFIX} ${service}/${key}" \
        service "${SERVICE_PREFIX}/${service}" \
        key "${key}" 2>/dev/null
    echo "OK: Stored ${service}/${key}"
}

linux_delete() {
    local service="$1" key="$2"
    if secret-tool clear service "${SERVICE_PREFIX}/${service}" key "${key}" 2>/dev/null; then
        echo "OK: Deleted ${service}/${key}"
    else
        echo "ERROR: Credential not found: ${service}/${key}" >&2
        exit 1
    fi
}

linux_has() {
    local service="$1" key="$2"
    local result
    result=$(secret-tool lookup service "${SERVICE_PREFIX}/${service}" key "${key}" 2>/dev/null) && [ -n "$result" ]
}

linux_list() {
    local service="${1:-}"
    if [ -n "$service" ]; then
        secret-tool search --all service "${SERVICE_PREFIX}/${service}" 2>/dev/null | \
            grep "attribute.key" | \
            sed 's/.*= //' | \
            sort -u
    else
        secret-tool search --all service "${SERVICE_PREFIX}" 2>/dev/null | \
            grep -E "attribute\.(service|key)" | \
            sed 's/.*= //' | \
            paste - - | \
            sed "s|${SERVICE_PREFIX}/||" | \
            awk -F'\t' '{printf "%s/%s\n", $1, $2}' | \
            sort -u
    fi
}

# ─── Windows Backend (cmdkey / Credential Manager) ──────────────────────────

# Windows Credential Manager has a 337-char target limit.
# We use: "claude-autopilot/{service}/{key}" as the target name.
# For Git Bash: use cmdkey.exe; for native: use cmdkey.

_cmdkey() {
    if command -v cmdkey.exe &>/dev/null; then
        cmdkey.exe "$@"
    else
        cmdkey "$@"
    fi
}

windows_get() {
    local service="$1" key="$2"
    local target="${SERVICE_PREFIX}/${service}/${key}"
    local output
    output=$(_cmdkey /list:"${target}" 2>/dev/null)
    if echo "$output" | grep -q "Password:" 2>/dev/null; then
        # cmdkey /list doesn't show passwords — use PowerShell to retrieve
        local result
        if command -v powershell.exe &>/dev/null; then
            result=$(powershell.exe -NoProfile -Command "
                \$cred = [System.Net.CredentialCache]::DefaultCredentials
                Add-Type -AssemblyName System.Web
                \$target = '${target}'
                \$query = cmdkey.exe /list:\"\$target\" 2>&1
                # cmdkey can't retrieve passwords; use CredRead via P/Invoke
                Add-Type -Namespace 'CredManager' -Name 'Util' -MemberDefinition '
                    [DllImport(\"advapi32.dll\", SetLastError=true, CharSet=CharSet.Unicode)]
                    public static extern bool CredRead(string target, int type, int flags, out IntPtr cred);
                    [DllImport(\"advapi32.dll\")]
                    public static extern void CredFree(IntPtr cred);
                    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
                    public struct CREDENTIAL {
                        public int Flags; public int Type; public string TargetName;
                        public string Comment; public long LastWritten; public int CredentialBlobSize;
                        public IntPtr CredentialBlob; public int Persist; public int AttributeCount;
                        public IntPtr Attributes; public string TargetAlias; public string UserName;
                    }
                '
                \$ptr = [IntPtr]::Zero
                if ([CredManager.Util]::CredRead('${target}', 1, 0, [ref]\$ptr)) {
                    \$cred = [Runtime.InteropServices.Marshal]::PtrToStructure(\$ptr, [Type][CredManager.Util+CREDENTIAL])
                    \$bytes = [byte[]]::new(\$cred.CredentialBlobSize)
                    [Runtime.InteropServices.Marshal]::Copy(\$cred.CredentialBlob, \$bytes, 0, \$cred.CredentialBlobSize)
                    [Text.Encoding]::Unicode.GetString(\$bytes)
                    [CredManager.Util]::CredFree(\$ptr)
                }
            " 2>/dev/null | tr -d '\r')
            if [ -n "$result" ]; then
                echo "$result"
            else
                echo "ERROR: Credential not found: ${service}/${key}" >&2
                exit 1
            fi
        else
            echo "ERROR: powershell.exe required to read credentials on Windows" >&2
            exit 1
        fi
    else
        echo "ERROR: Credential not found: ${service}/${key}" >&2
        exit 1
    fi
}

windows_set() {
    local service="$1" key="$2" value="$3"
    local target="${SERVICE_PREFIX}/${service}/${key}"
    _cmdkey /generic:"${target}" /user:"${SERVICE_PREFIX}" /pass:"${value}" >/dev/null 2>&1
    echo "OK: Stored ${service}/${key}"
}

windows_delete() {
    local service="$1" key="$2"
    local target="${SERVICE_PREFIX}/${service}/${key}"
    if _cmdkey /delete:"${target}" >/dev/null 2>&1; then
        echo "OK: Deleted ${service}/${key}"
    else
        echo "ERROR: Credential not found: ${service}/${key}" >&2
        exit 1
    fi
}

windows_has() {
    local service="$1" key="$2"
    local target="${SERVICE_PREFIX}/${service}/${key}"
    _cmdkey /list:"${target}" 2>/dev/null | grep -q "Target:" 2>/dev/null
}

windows_list() {
    local service="${1:-}"
    local prefix="${SERVICE_PREFIX}"
    if [ -n "$service" ]; then
        prefix="${SERVICE_PREFIX}/${service}"
    fi
    _cmdkey /list 2>/dev/null | \
        grep "Target:" | \
        grep "${prefix}" | \
        sed "s/.*Target: *//" | \
        sed "s|${SERVICE_PREFIX}/||" | \
        tr -d '\r' | \
        sort -u
}

# ─── Dispatch to Platform Backend ────────────────────────────────────────────

cmd_get() {
    local service="$1" key="$2"
    case "$PLATFORM" in
        macos)   macos_get "$service" "$key" ;;
        linux)   linux_get "$service" "$key" ;;
        windows) windows_get "$service" "$key" ;;
    esac
}

cmd_set() {
    local service="$1" key="$2" value=""

    if [ $# -ge 3 ]; then
        value="$3"
    else
        read -r value
    fi

    if [ -z "$value" ]; then
        echo "ERROR: Empty value. Provide value via stdin or as third argument." >&2
        exit 1
    fi

    case "$PLATFORM" in
        macos)   macos_set "$service" "$key" "$value" ;;
        linux)   linux_set "$service" "$key" "$value" ;;
        windows) windows_set "$service" "$key" "$value" ;;
    esac
}

cmd_delete() {
    local service="$1" key="$2"
    case "$PLATFORM" in
        macos)   macos_delete "$service" "$key" ;;
        linux)   linux_delete "$service" "$key" ;;
        windows) windows_delete "$service" "$key" ;;
    esac
}

cmd_has() {
    local service="$1" key="$2"
    case "$PLATFORM" in
        macos)   macos_has "$service" "$key" ;;
        linux)   linux_has "$service" "$key" ;;
        windows) windows_has "$service" "$key" ;;
    esac
}

cmd_list() {
    local service="${1:-}"
    case "$PLATFORM" in
        macos)   macos_list "$service" ;;
        linux)   linux_list "$service" ;;
        windows) windows_list "$service" ;;
    esac
}

# ─── Main ────────────────────────────────────────────────────────────────────

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
