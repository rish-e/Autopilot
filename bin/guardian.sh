#!/bin/bash
# guardian.sh — Safety hook for Claude Code Autopilot (v3 — high-performance)
#
# PreToolUse hook that blocks dangerous Bash commands.
# Combined with "Bash" in the permission allowlist, this gives you
# the speed of --dangerously-skip-permissions with a hard safety net.
#
# How it works:
#   - Receives tool call JSON on stdin
#   - Checks Bash commands against blocklist patterns
#   - Exit 0 = allow (auto-approved by permission rules)
#   - Exit 2 = BLOCK (overrides permission rules, command never runs)
#
# Performance (v3):
#   - Uses bash =~ builtin instead of grep subprocesses (20-50x faster)
#   - Tiered matching: literal checks → compound regex → awk for complex
#   - Target: <5ms per command (vs ~100ms in v2 with 50 grep spawns)
#
# To test: echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | guardian.sh

set -uo pipefail

# =============================================================================
# AUTOPILOT-ONLY: Guardian only runs inside autopilot agent sessions
# Regular Claude Code sessions skip guardian entirely (exit 0 = allow all)
# Detection: (1) process tree for --agent autopilot, (2) session marker file
# =============================================================================

_is_autopilot=false

# Method 1: Check process tree for `claude --agent autopilot`
_gpid=$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')
if [ -n "$_gpid" ]; then
    _gcmd=$(ps -o args= -p "$_gpid" 2>/dev/null || true)
    if [[ "$_gcmd" == *"--agent autopilot"* ]]; then
        _is_autopilot=true
    else
        # Check one more level up in case of intermediate shell
        _ggpid=$(ps -o ppid= -p "$_gpid" 2>/dev/null | tr -d ' ')
        if [ -n "$_ggpid" ]; then
            _ggcmd=$(ps -o args= -p "$_ggpid" 2>/dev/null || true)
            if [[ "$_ggcmd" == *"--agent autopilot"* ]]; then
                _is_autopilot=true
            fi
        fi
    fi
fi

# Method 2: Check for session marker file (set by preflight.sh for /autopilot slash command)
if [ "$_is_autopilot" = false ]; then
    # Find the Claude node process (ancestor) and check for its marker
    _check_pid="$PPID"
    for _i in 1 2 3 4; do
        [ -z "$_check_pid" ] || [ "$_check_pid" -le 1 ] 2>/dev/null && break
        if [ -f "/tmp/.guardian-active-${_check_pid}" ]; then
            _is_autopilot=true
            break
        fi
        _check_pid=$(ps -o ppid= -p "$_check_pid" 2>/dev/null | tr -d ' ') || break
    done
fi

if [ "$_is_autopilot" = false ]; then
    exit 0  # Not an autopilot session — allow everything
fi

# =============================================================================
# FAIL CLOSED: If jq is not available, block everything
# =============================================================================

if ! command -v jq &>/dev/null; then
    echo "GUARDIAN BLOCKED [SAFETY]: jq is not installed. Guardian cannot parse commands safely — blocking all Bash execution." >&2
    echo "Install jq: brew install jq (macOS) / sudo apt install jq (Linux)" >&2
    exit 2
fi

# Read tool call from stdin
INPUT=$(cat)

# Parse tool name
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
if [ -z "$TOOL_NAME" ]; then
    echo "GUARDIAN BLOCKED [SAFETY]: Could not parse tool call JSON" >&2
    exit 2
fi

# =============================================================================
# WRITE/EDIT TOOL PROTECTION
# =============================================================================

if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    if [ -n "$FILE_PATH" ]; then
        case "$FILE_PATH" in
            */guardian.sh|*/guardian-custom-rules.txt)
                echo "GUARDIAN BLOCKED [SELF-PROTECT]: Cannot modify guardian safety files via $TOOL_NAME tool" >&2
                exit 2
                ;;
            */.claude/settings.json|*/.claude/settings.local.json)
                echo "GUARDIAN BLOCKED [SELF-PROTECT]: Cannot modify Claude Code settings via $TOOL_NAME tool (could disable guardian hook)" >&2
                exit 2
                ;;
        esac
    fi
    exit 0
fi

# Only inspect Bash commands — allow everything else through
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Extract the command
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -z "$COMMAND" ]; then
    echo "GUARDIAN BLOCKED [SAFETY]: Could not extract command from tool call" >&2
    exit 2
fi

# Normalize: lowercase for case-insensitive matching
# Using tr instead of ${,,} for compatibility with bash 3.x (macOS default)
CMD_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')

block() {
    local category="$1"
    local reason="$2"
    echo "GUARDIAN BLOCKED [$category]: $reason" >&2
    echo "Command was: $COMMAND" >&2
    echo "" >&2
    echo "If you need to run this, ask the user to execute it directly with: ! <command>" >&2
    exit 2
}

# =============================================================================
# TIER 1: FAST LITERAL / GLOB CHECKS (< 0.1ms each)
# =============================================================================
# These use bash builtins only — no subprocesses, no regex compilation.
# Catches the most common dangerous patterns with minimal CPU.

GUARDIAN_PROTECTED_FILES="guardian.sh|guardian-custom-rules.txt|settings.json|settings.local.json"

# ── Category 0: Self-protection (literal checks) ──
case "$COMMAND" in
    *guardian.sh*|*guardian-custom-rules.txt*|*settings.json*|*settings.local.json*)
        # Only block modification commands, not reads
        if [[ "$COMMAND" =~ (sed|awk|perl|tee|truncate|mv|cp|chmod|chown|ln|install)[[:space:]].*(guardian\.sh|guardian-custom-rules\.txt|settings\.json|settings\.local\.json) ]]; then
            block "SELF-PROTECT" "Modifying guardian or settings files is not allowed"
        fi
        if [[ "$COMMAND" =~ (rm|unlink)[[:space:]].*(guardian\.sh|guardian-custom-rules\.txt|settings\.json|settings\.local\.json) ]]; then
            block "SELF-PROTECT" "Deleting guardian or settings files is not allowed"
        fi
        # Block redirect/overwrite but allow echo >> to custom rules
        if [[ "$COMMAND" =~ [^\>]\>[^\>].*(guardian\.sh|guardian-custom-rules\.txt|settings\.json|settings\.local\.json) ]]; then
            block "SELF-PROTECT" "Overwriting guardian or settings files is not allowed"
        fi
        if [[ "$COMMAND" =~ \>\>[[:space:]]*.*(guardian\.sh|guardian-custom-rules\.txt|settings\.json|settings\.local\.json) ]] && \
           ! [[ "$COMMAND" =~ ^(echo|printf)[[:space:]].*\>\>[[:space:]]*.*guardian-custom-rules\.txt ]]; then
            block "SELF-PROTECT" "Only echo append (>>) to guardian-custom-rules.txt is allowed"
        fi
        ;;
esac

# Block chmod -x on autopilot scripts
if [[ "$COMMAND" == *"chmod"*"autopilot"*"bin/"*".sh"* ]] || [[ "$COMMAND" == *"chmod"*"MCPs"*"bin/"*".sh"* ]]; then
    if [[ "$COMMAND" =~ chmod[[:space:]]+(-[a-zA-Z]*)?(a-x|u-x|-x|000|644)[[:space:]] ]]; then
        block "SELF-PROTECT" "Removing execute permission from autopilot scripts is not allowed"
    fi
fi

# ── Category 2: System destruction (fast literal pre-screen) ──
if [[ "$CMD_LOWER" == *"rm -rf /"* ]] || [[ "$CMD_LOWER" == *"rm -rf ~"* ]] || [[ "$CMD_LOWER" == *'rm -rf $home'* ]] || [[ "$CMD_LOWER" == *"rm -rf ."* ]]; then
    block "SYSTEM" "Catastrophic deletion detected"
fi
if [[ "$CMD_LOWER" == *"sudo rm -rf"* ]]; then
    block "SYSTEM" "Privileged recursive forced deletion"
fi
if [[ "$CMD_LOWER" == *"mkfs"* ]] || [[ "$CMD_LOWER" == *"fdisk"* ]] || [[ "$CMD_LOWER" == *"diskutil erase"* ]]; then
    block "SYSTEM" "Disk/filesystem destructive operation"
fi
if [[ "$COMMAND" == *':(){ :|:&};'* ]]; then
    block "SYSTEM" "Fork bomb detected"
fi

# ── Category 4: Database (fast literal) ──
if [[ "$CMD_LOWER" == *"drop database"* ]] || [[ "$CMD_LOWER" == *"drop schema"* ]]; then
    block "DATABASE" "Dropping entire database or schema"
fi
if [[ "$CMD_LOWER" == *"truncate "* ]]; then
    if [[ "$CMD_LOWER" =~ truncate[[:space:]]+(table[[:space:]]+)?[a-z] ]]; then
        block "DATABASE" "Truncating table (mass data deletion)"
    fi
fi

# =============================================================================
# TIER 2: COMPOUND BASH REGEX (< 1ms total)
# =============================================================================
# Uses bash =~ builtin — single regex compilation per group.
# No subprocess spawns. Groups related patterns for efficiency.

# ── Category 1: Obfuscation / Evasion ──
if [[ "$CMD_LOWER" =~ (base64.*\|[[:space:]]*(bash|sh|zsh|dash))|(base64[[:space:]]+-d.*\|[[:space:]]*(bash|sh)) ]]; then
    block "EVASION" "Base64-encoded command piped to shell interpreter"
fi

if [[ "$CMD_LOWER" =~ (^|[[:space:]\;\&\|])(bash|sh|zsh|dash)[[:space:]]+-c[[:space:]] ]]; then
    block "EVASION" "Subshell execution via interpreter -c flag. Run the command directly instead."
fi

if [[ "$CMD_LOWER" =~ (^|[[:space:]\;\&\|])eval[[:space:]] ]]; then
    block "EVASION" "eval can execute arbitrary code. Run the command directly instead."
fi

if [[ "$CMD_LOWER" =~ (^|[[:space:]\;\&\|])\.[[:space:]]+[a-zA-Z~/] ]] || [[ "$CMD_LOWER" =~ (^|[[:space:]\;\&\|])source[[:space:]]+ ]]; then
    block "EVASION" "source/dot-source can execute arbitrary scripts — bypasses guardian"
fi

if [[ "$CMD_LOWER" =~ \<\<.*\|[[:space:]]*(bash|sh|zsh|dash) ]]; then
    block "EVASION" "Heredoc piped to shell interpreter — bypasses guardian"
fi

# Interpreter system command execution
if [[ "$CMD_LOWER" =~ python[23]?[[:space:]]+-c[[:space:]].*\b(os\.|subprocess|system|exec|popen) ]]; then
    block "EVASION" "Python executing system commands — bypasses guardian"
fi
if [[ "$CMD_LOWER" =~ node[[:space:]]+-e[[:space:]].*\b(exec|spawn|child_process) ]]; then
    block "EVASION" "Node.js executing system commands — bypasses guardian"
fi
if [[ "$CMD_LOWER" =~ (ruby|perl)[[:space:]]+-e[[:space:]] ]]; then
    block "EVASION" "Interpreter executing system commands — bypasses guardian"
fi

# ── Category 1b: Indirect execution bypass ──
if [[ "$CMD_LOWER" =~ find[[:space:]].*-exec(dir)?[[:space:]] ]]; then
    block "EVASION" "find -exec can execute arbitrary commands — bypasses guardian"
fi

if [[ "$CMD_LOWER" =~ \|[[:space:]]*xargs[[:space:]]+((-[a-zA-Z0-9]+[[:space:]]+)*)*(rm|chmod|chown|mv|bash|sh|python|node|perl|ruby|curl|wget|kill|pkill|killall|dd|mkfs|security) ]]; then
    block "EVASION" "xargs piping to dangerous command — bypasses guardian"
fi

if [[ "$COMMAND" =~ chmod[[:space:]]+\+x[[:space:]]+[^[:space:]]+.*[\;\&\|]+.*\./ ]]; then
    block "EVASION" "Write-then-execute: making file executable and running it — bypasses guardian"
fi

if [[ "$COMMAND" =~ \`[^\`]*(rm|curl|wget|security|keychain|kill|chmod|dd|mkfs|eval|bash[[:space:]]+-c|sh[[:space:]]+-c)[^\`]*\` ]]; then
    block "EVASION" "Backtick expansion containing dangerous command"
fi

if echo "$CMD_LOWER" | grep -qE '<\(.*\b(bash|sh|curl|wget|python|node)\b'; then
    block "EVASION" "Process substitution executing commands — bypasses guardian"
fi

if [[ "$CMD_LOWER" =~ (crontab[[:space:]]+-[erl])|(crontab[[:space:]]+[^[:space:]-]) ]]; then
    block "EVASION" "Crontab modification — schedules commands outside guardian supervision"
fi

# Match actual 'at' command (with time args), not the word "at" in prose/heredocs
if [[ "$CMD_LOWER" =~ (^|[\;\&\|][[:space:]]*)(at)[[:space:]]+(now|noon|midnight|teatime|tomorrow|[0-9]|-[fmMlbdq]) ]]; then
    block "EVASION" "at command schedules deferred command execution — bypasses guardian"
fi
if [[ "$CMD_LOWER" =~ (^|[\;\&\|][[:space:]]*)(batch)[[:space:]] ]]; then
    block "EVASION" "batch schedules deferred command execution — bypasses guardian"
fi

# ── Category 2: System destruction (regex) ──
if [[ "$COMMAND" =~ rm[[:space:]]+(-[a-zA-Z]*f[a-zA-Z]*[[:space:]]+|--force[[:space:]]+)*(-[a-zA-Z]*r[a-zA-Z]*|--recursive)[[:space:]]+(/|~|\$HOME|/Users) ]]; then
    block "SYSTEM" "Recursive deletion of system/home directory"
fi
if [[ "$COMMAND" =~ rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+|--recursive[[:space:]]+)*(-[a-zA-Z]*f[a-zA-Z]*|--force)[[:space:]]+(/|~|\$HOME|/Users) ]]; then
    block "SYSTEM" "Forced recursive deletion of system/home directory"
fi
if [[ "$COMMAND" =~ dd[[:space:]]+if=.*of=/dev/ ]]; then
    block "SYSTEM" "Raw disk write operation"
fi
if echo "$CMD_LOWER" | grep -qE '^\s*(sudo\s+)?(shutdown|reboot|halt|poweroff)\b'; then
    block "SYSTEM" "System shutdown/reboot command"
fi
if [[ "$COMMAND" =~ chmod[[:space:]]+(-R[[:space:]]+)?777[[:space:]]+/ ]]; then
    block "SYSTEM" "Setting world-writable permissions on root"
fi

# ── Category 3: Credential exfiltration ──
if [[ "$COMMAND" =~ (echo|printf|cat)[[:space:]]+.*\$\(.*keychain\.sh[[:space:]]+get ]]; then
    block "CREDENTIALS" "Credential value would be printed to stdout"
fi
if [[ "$COMMAND" =~ keychain\.sh[[:space:]]+get[^|]*\|[[:space:]]*(echo|cat|printf|tee|head|tail) ]]; then
    block "CREDENTIALS" "Credential value being piped to display command"
fi
if [[ "$COMMAND" =~ (curl|wget|http).*\$\(.*keychain\.sh[[:space:]]+get ]]; then
    block "CREDENTIALS" "Credential value being sent to external URL"
fi
if [[ "$COMMAND" =~ \$\(.*keychain\.sh[[:space:]]+get.*\).*(curl|wget|http) ]]; then
    block "CREDENTIALS" "Credential value being sent to external URL"
fi
if [[ "$COMMAND" =~ curl[[:space:]].*(-d|--data|--data-binary|--data-raw|--data-urlencode)[[:space:]].*\$\(.*keychain\.sh ]]; then
    block "CREDENTIALS" "Credential value being sent via curl data flag"
fi
if echo "$COMMAND" | grep -qE 'keychain\.sh\s+get[^;|&]*[^2]>[^&/]'; then
    block "CREDENTIALS" "Credential value being written to a file"
fi
if [[ "$COMMAND" =~ keychain\.sh[[:space:]]+get.*\|[[:space:]]*(curl|wget|http|nc|ncat|netcat|socat|mail|sendmail) ]]; then
    block "CREDENTIALS" "Credential value being piped to network tool"
fi
if [[ "$CMD_LOWER" =~ (^|[[:space:]])(env|printenv|set)[[:space:]]*($|[[:space:]]*[|]\||[[:space:]]*\>) ]]; then
    block "CREDENTIALS" "env/printenv/set can expose exported credential values"
fi

# ── Category 4: Database (DELETE without WHERE) ──
if [[ "$CMD_LOWER" =~ delete[[:space:]]+from[[:space:]]+[a-z] ]] && ! [[ "$CMD_LOWER" =~ where ]]; then
    block "DATABASE" "DELETE without WHERE clause (mass data deletion)"
fi

# ── Category 5: Git / Publishing ──
if [[ "$COMMAND" =~ git[[:space:]]+push[[:space:]]+.*--force-with-lease ]]; then
    : # Allow --force-with-lease (safe alternative)
elif [[ "$COMMAND" =~ git[[:space:]]+push[[:space:]]+.*(-f[[:space:]]|--force[[:space:]]|-f$|--force$) ]]; then
    block "GIT" "Force push can destroy remote history. Use --force-with-lease."
fi
if [[ "$COMMAND" =~ git[[:space:]]+reset[[:space:]]+--hard ]]; then
    block "GIT" "Hard reset discards all uncommitted changes"
fi
if [[ "$COMMAND" =~ git[[:space:]]+clean[[:space:]]+.*-f ]]; then
    block "GIT" "git clean -f permanently deletes untracked files"
fi
if [[ "$CMD_LOWER" =~ (npm[[:space:]]+publish|cargo[[:space:]]+publish|twine[[:space:]]+upload|gem[[:space:]]+push|pip[[:space:]]+.*upload) ]]; then
    block "PUBLISHING" "Publishing a package to a public registry"
fi

# ── Category 6: Production deployments ──
if [[ "$COMMAND" =~ vercel[[:space:]]+(deploy[[:space:]]+)?.*--prod ]]; then
    block "PRODUCTION" "Production deployment to Vercel"
fi
if [[ "$COMMAND" =~ --production([[:space:]]|$|\") ]] && [[ "$CMD_LOWER" =~ (deploy|push|migrate|release) ]]; then
    block "PRODUCTION" "Production operation detected"
fi
if [[ "$CMD_LOWER" =~ terraform[[:space:]]+destroy ]]; then
    block "PRODUCTION" "Terraform destroy will delete infrastructure"
fi

# ── Category 7: Account / Visibility ──
if [[ "$COMMAND" =~ gh[[:space:]]+repo[[:space:]]+edit[[:space:]]+.*--visibility[[:space:]]+public ]]; then
    block "VISIBILITY" "Making repository public — this exposes all code"
fi
if [[ "$COMMAND" =~ gh[[:space:]]+repo[[:space:]]+delete ]]; then
    block "DESTRUCTIVE" "Deleting a GitHub repository"
fi
if [[ "$COMMAND" =~ vercel[[:space:]]+(project[[:space:]]+)?rm[[:space:]] ]]; then
    block "DESTRUCTIVE" "Deleting a Vercel project"
fi
if [[ "$CMD_LOWER" =~ supabase[[:space:]]+projects?[[:space:]]+delete ]]; then
    block "DESTRUCTIVE" "Deleting a Supabase project"
fi

# ── Category 8: Financial / Messaging ──
if [[ "$CMD_LOWER" =~ curl.*api\.stripe\.com.*(charges|payment_intents).*-d ]]; then
    block "FINANCIAL" "Creating a real Stripe charge/payment"
fi
if [[ "$CMD_LOWER" =~ (^|[\|\;\&[:space:]])(sendmail|mailx?|mutt)[[:space:]] ]]; then
    block "MESSAGING" "Sending email to real recipients"
fi

# ── Category 9: Network egress control ──
EGRESS_ALLOWLIST='(github\.com|api\.github\.com|api\.vercel\.com|vercel\.com|api\.supabase\.(com|co)|supabase\.co|api\.stripe\.com|api\.cloudflare\.com|registry\.npmjs\.org|api\.anthropic\.com|api\.openai\.com|pypi\.org|hub\.docker\.com|api\.razorpay\.com|api\.alpaca\.markets|paper-api\.alpaca\.markets|data\.alpaca\.markets|api\.telegram\.org|objects\.githubusercontent\.com|raw\.githubusercontent\.com|localhost|127\.0\.0\.1)'

if [[ "$CMD_LOWER" =~ curl[[:space:]].*(-d[[:space:]]|--data|--data-binary|--data-raw|--data-urlencode|-F[[:space:]]|--upload-file) ]]; then
    if ! [[ "$CMD_LOWER" =~ $EGRESS_ALLOWLIST ]]; then
        block "NETWORK" "curl sending data to non-allowlisted domain"
    fi
fi
if [[ "$CMD_LOWER" =~ wget[[:space:]].*(--post-data|--post-file|--method[[:space:]]*(put|post|patch|delete)) ]]; then
    if ! [[ "$CMD_LOWER" =~ $EGRESS_ALLOWLIST ]]; then
        block "NETWORK" "wget sending data to non-allowlisted domain"
    fi
fi

# =============================================================================
# TIER 3: CUSTOM RULES — single awk pass (< 2ms)
# =============================================================================
# Custom rules from guardian-custom-rules.txt are checked via awk for
# maximum efficiency. One process spawn for all custom rules combined.

AUTOPILOT_DIR="${AUTOPILOT_DIR:-$HOME/MCPs/autopilot}"
CUSTOM_RULES="$AUTOPILOT_DIR/config/guardian-custom-rules.txt"
if [ -f "$CUSTOM_RULES" ] && [ -s "$CUSTOM_RULES" ]; then
    # Build awk program from custom rules file
    AWK_PROG=""
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ ]] && continue
        [ -z "$line" ] && continue

        local_category=""
        local_pattern=""
        local_reason=""

        if [[ "$line" == *":::"* ]]; then
            local_category="${line%%:::*}"
            local_rest="${line#*:::}"
            local_pattern="${local_rest%%:::*}"
            local_reason="${local_rest#*:::}"
        else
            local_field_count=$(echo "$line" | awk -F'|' '{print NF}')
            if [ "$local_field_count" -ge 3 ]; then
                local_category=$(echo "$line" | cut -d'|' -f1)
                local_pattern=$(echo "$line" | cut -d'|' -f2)
                local_reason=$(echo "$line" | cut -d'|' -f3-)
            elif [ "$local_field_count" -eq 2 ]; then
                local_category=$(echo "$line" | cut -d'|' -f1)
                local_pattern=$(echo "$line" | cut -d'|' -f2)
                local_reason="Blocked by custom rule"
            else
                continue
            fi
        fi

        [ -z "$local_category" ] && continue
        [ -z "$local_pattern" ] && continue

        # Check using bash =~ (still fast, avoids awk complexity for regex escaping)
        if [[ "$CMD_LOWER" =~ $local_pattern ]]; then
            block "$local_category" "${local_reason:-Blocked by custom rule}"
        fi
    done < "$CUSTOM_RULES"
fi

# =============================================================================
# ALL CLEAR — allow the command
# =============================================================================

exit 0
