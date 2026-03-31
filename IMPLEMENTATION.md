# Autopilot v2: Dynamic Architecture Implementation Guide

> This document is the complete technical blueprint for upgrading Autopilot from a static system to a fully dynamic, self-expanding autonomous agent. Every section references exact existing files, functions, and patterns. Every new file includes the full implementation. Every integration point is specified precisely.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Directory Structure Changes](#2-directory-structure-changes)
3. [Sprint 1: Core Engines](#3-sprint-1-core-engines)
   - 3.1 Email Verification Flow
   - 3.2 TOTP Generation
   - 3.3 ntfy Push Notifications
   - 3.4 Dynamic Playbook Engine
   - 3.5 Playbook Template Format
4. [Sprint 2: Intelligence Layer](#4-sprint-2-intelligence-layer)
   - 4.1 SQLite Memory Store
   - 4.2 Procedural Memory
   - 4.3 Error Memory
   - 4.4 Telegram Bot
   - 4.5 Dynamic Model Router
5. [Sprint 3: Self-Expansion](#5-sprint-3-self-expansion)
   - 5.1 Dynamic Playbook Generator
   - 5.2 Dynamic Service Resolver
   - 5.3 Dynamic MCP Discovery
   - 5.4 Dynamic Agent Spawner
6. [Sprint 4: Safety & Observability](#6-sprint-4-safety--observability)
   - 6.1 Dynamic Guardian Evolution
   - 6.2 Structured Audit Events
   - 6.3 Token Cost Tracking
   - 6.4 Dynamic Health Monitor
7. [Sprint 5: Full Autonomy](#7-sprint-5-full-autonomy)
   - 7.1 Dynamic Plan Generator
   - 7.2 Credential Lifecycle Engine
   - 7.3 Autopilot MCP Server
8. [Agent Definition Updates](#8-agent-definition-updates)
9. [Integration Map](#9-integration-map)
10. [Testing Strategy](#10-testing-strategy)

---

## 1. Architecture Overview

### Current Architecture (v1)

```
Agent Prompt (autopilot.md)
  ├── Guardian Hook (guardian.sh) ──── PreToolUse on Bash/Write/Edit
  ├── Keychain (keychain.sh) ──────── macOS Keychain / libsecret / cmdkey
  ├── Chrome CDP (chrome-debug.sh) ── Persistent browser on port 9222
  ├── Snapshot (snapshot.sh) ──────── Git stash-based rollback
  ├── Session (session.sh) ────────── Crash recovery via JSON
  ├── Audit (audit.sh) ───────────── Markdown log viewer
  ├── Service Registry (5 .md files)─ Static per-service configs
  └── MCP Whitelist (YAML) ────────── Static trust list
```

### Target Architecture (v2)

```
Agent Prompt (autopilot.md) ─── upgraded with dynamic protocols
  │
  ├── EXISTING (unchanged)
  │   ├── Guardian Hook (guardian.sh) ──── core 55 patterns immutable
  │   ├── Keychain (keychain.sh) ──────── credential store unchanged
  │   ├── Chrome CDP (chrome-debug.sh) ── browser manager unchanged
  │   ├── Snapshot (snapshot.sh) ──────── rollback unchanged
  │   └── Session (session.sh) ────────── crash recovery unchanged
  │
  ├── UPGRADED
  │   ├── Guardian (guardian.sh) ──── + dynamic rule loader from DB
  │   ├── Audit (audit.sh) ───────── + structured JSON events + chain
  │   └── Service Registry ────────── + auto-generation on unknown service
  │
  └── NEW
      ├── Memory (memory.db) ──────── SQLite: traces, procedures, errors
      ├── Playbook Engine ─────────── generate + execute + cache YAML playbooks
      ├── Telegram Bot ────────────── bidirectional phone interface
      ├── Notification Router ─────── channel-agnostic message dispatch
      ├── TOTP Generator ──────────── 2FA code generation from seeds
      ├── Email Verifier ──────────── Gmail MCP integration for signup flows
      ├── Health Monitor ──────────── auto-discover + check project services
      ├── Cost Tracker ────────────── per-task token attribution
      └── Autopilot MCP Server ────── structured tool calls for all internals
```

### Core Design Principles

Every new component follows the **Generator → Cache → Engine** pattern:

1. **Generator**: When encountering something unknown, research and build it on the fly
2. **Cache**: Store what was learned so the next encounter is instant
3. **Engine**: Universal execution core that runs anything, verified step-by-step

Nothing is hardcoded. Nothing has a fixed list. The system starts knowing nothing about a topic and becomes an expert through experience.

---

## 2. Directory Structure Changes

### New files to create

```
~/MCPs/autopilot/
├── bin/
│   ├── (existing scripts unchanged)
│   ├── notify.sh              # NEW: notification dispatcher
│   ├── totp.sh                # NEW: TOTP code generator
│   ├── verify-email.sh        # NEW: email verification helper
│   ├── health-check.sh        # NEW: service health checker
│   └── cost-tracker.sh        # NEW: token cost tracking
├── config/
│   ├── (existing configs unchanged)
│   ├── channels/              # NEW: notification channel configs
│   │   ├── _template.yaml
│   │   ├── ntfy.yaml
│   │   └── telegram.yaml
│   └── playbook-template.yaml # NEW: universal playbook template
├── lib/                       # NEW: shared Python/TS libraries
│   ├── memory.py              # SQLite memory store
│   ├── playbook.py            # Playbook engine
│   ├── notify.py              # Notification dispatcher
│   └── cost.py                # Cost tracking
├── playbooks/                 # NEW: cached playbook directory (auto-populated)
│   └── .gitkeep
├── mcp-server/                # NEW: custom Autopilot MCP server
│   ├── package.json
│   ├── tsconfig.json
│   └── src/
│       └── index.ts
├── telegram-bot/              # NEW: Telegram bot daemon
│   ├── bot.py
│   ├── handlers.py
│   ├── requirements.txt
│   └── com.autopilot.telegram.plist
└── services/
    ├── (existing 5 services unchanged)
    └── (new services auto-generated here)
```

### Existing files to modify

```
~/MCPs/autopilot/
├── bin/
│   ├── guardian.sh            # ADD: dynamic rule loading from memory.db
│   └── audit.sh              # ADD: structured JSON event output
├── config/
│   └── trusted-mcps.yaml     # ADD: auto-evaluated entries
├── agent/autopilot.md         # MAJOR UPDATE: new protocols
├── install.sh                 # ADD: new component installation
└── README.md                  # UPDATE: new architecture docs

~/.claude/agents/autopilot.md  # SYNC: mirrors agent/autopilot.md
```

---

## 3. Sprint 1: Core Engines

### 3.1 Email Verification Flow

**File: `~/MCPs/autopilot/bin/verify-email.sh`**

This script wraps the Gmail MCP workflow into a callable shell utility. The agent calls it during signup flows when email verification is needed.

```bash
#!/usr/bin/env bash
set -euo pipefail

# verify-email.sh — Wait for and extract verification from email
#
# Usage:
#   verify-email.sh wait --from "noreply@vercel.com" --subject "verify" [--timeout 120]
#   verify-email.sh extract-link --message-id "abc123"
#   verify-email.sh extract-code --message-id "abc123"
#
# This script is a HELPER that provides the search queries and extraction
# patterns. The actual Gmail API calls are made by the agent via Gmail MCP.
# This script outputs the Gmail search query and extraction instructions
# for the agent to execute.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
verify-email.sh — Email verification helper for signup flows

Commands:
  query   --from SENDER --subject KEYWORD [--minutes 5]
          Output a Gmail search query string for the agent to use
          with mcp__claude_ai_Gmail__gmail_search_messages

  parse   --body BODY_TEXT --type link|code
          Parse email body text to extract verification link or code

Examples:
  # Generate search query for Vercel verification email
  verify-email.sh query --from "noreply@vercel.com" --subject "verify" --minutes 5

  # Parse a 6-digit code from email body
  verify-email.sh parse --body "$EMAIL_BODY" --type code

  # Parse a verification link from email body
  verify-email.sh parse --body "$EMAIL_BODY" --type link
EOF
}

cmd_query() {
    local from="" subject="" minutes=5

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) from="$2"; shift 2 ;;
            --subject) subject="$2"; shift 2 ;;
            --minutes) minutes="$2"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    if [[ -z "$from" && -z "$subject" ]]; then
        echo "Error: at least --from or --subject required" >&2
        exit 1
    fi

    # Build Gmail search query
    local query=""
    [[ -n "$from" ]] && query="from:${from}"
    [[ -n "$subject" ]] && query="${query:+$query }subject:${subject}"
    query="${query} newer_than:${minutes}m is:unread"

    echo "$query"
}

cmd_parse() {
    local body="" type=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --body) body="$2"; shift 2 ;;
            --type) type="$2"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    if [[ -z "$body" || -z "$type" ]]; then
        echo "Error: --body and --type required" >&2
        exit 1
    fi

    case "$type" in
        code)
            # Extract 4-8 digit verification code
            echo "$body" | grep -oE '\b[0-9]{4,8}\b' | head -1
            ;;
        link)
            # Extract verification/confirm URL
            echo "$body" | grep -oE 'https?://[^ "'"'"'<>]+\b(verify|confirm|activate|validate|token|auth)[^ "'"'"'<>]*' | head -1
            ;;
        *)
            echo "Error: --type must be 'link' or 'code'" >&2
            exit 1
            ;;
    esac
}

case "${1:-}" in
    query) shift; cmd_query "$@" ;;
    parse) shift; cmd_parse "$@" ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
esac
```

**Integration point — agent definition update:**

Add this protocol to the agent's Credential Management section (in `agent/autopilot.md`):

```markdown
### Email Verification Protocol

When a service sends a verification email during signup:

1. Note the service's noreply sender address (usually visible in the signup page)
2. Generate search query: `verify-email.sh query --from "noreply@service.com" --subject "verify"`
3. Wait 10-30 seconds for email delivery
4. Search Gmail: `mcp__claude_ai_Gmail__gmail_search_messages` with the query
5. If no results, wait 15 seconds and retry (up to 3 retries)
6. Read the email: `mcp__claude_ai_Gmail__gmail_read_message` with the messageId
7. Extract verification:
   - For codes: `verify-email.sh parse --body "$BODY" --type code`
   - For links: `verify-email.sh parse --body "$BODY" --type link`
8. If code: enter it in the browser form
9. If link: navigate to it with `browser_navigate`
10. Snapshot to verify success
```

---

### 3.2 TOTP Generation

**File: `~/MCPs/autopilot/bin/totp.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# totp.sh — Generate TOTP codes from seeds stored in keychain
#
# Usage:
#   totp.sh generate SERVICE          Generate current TOTP code for SERVICE
#   totp.sh store SERVICE SEED        Store TOTP seed in keychain (reads from stdin if no SEED)
#   totp.sh has SERVICE               Check if TOTP seed exists for SERVICE
#   totp.sh remaining SERVICE         Seconds until current code expires
#
# Security:
#   - Seeds are stored in keychain under {service}/totp-seed
#   - Generated codes are printed to stdout (for subshell capture)
#   - Codes are NEVER logged or stored

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCHAIN="$SCRIPT_DIR/keychain.sh"

usage() {
    cat <<'EOF'
totp.sh — TOTP 2FA code generator

Commands:
  generate SERVICE     Generate current 6-digit TOTP code
  store SERVICE [SEED] Store TOTP seed (reads stdin if no SEED arg)
  has SERVICE          Check if seed exists (exit 0=yes, 1=no)
  remaining SERVICE    Seconds until current code expires

Examples:
  totp.sh generate vercel
  echo "JBSWY3DPEHPK3PXP" | totp.sh store vercel
  totp.sh store vercel JBSWY3DPEHPK3PXP
  CODE=$(totp.sh generate vercel)
EOF
}

require_python() {
    if ! command -v python3 &>/dev/null; then
        echo "Error: python3 required" >&2
        exit 1
    fi
    # Check pyotp is available
    if ! python3 -c "import pyotp" 2>/dev/null; then
        echo "Error: pyotp not installed. Run: pip3 install pyotp" >&2
        exit 1
    fi
}

cmd_generate() {
    local service="${1:?Service name required}"
    require_python

    # Get seed from keychain (never echoed, captured in subshell)
    local seed
    seed=$("$KEYCHAIN" get "$service" totp-seed 2>/dev/null) || {
        echo "Error: No TOTP seed stored for '$service'" >&2
        echo "Store one with: totp.sh store $service" >&2
        exit 1
    }

    # Generate code via pyotp — seed goes via env var, never CLI arg
    TOTP_SEED="$seed" python3 -c "
import os, pyotp
seed = os.environ['TOTP_SEED']
print(pyotp.TOTP(seed).now())
"
    unset TOTP_SEED
}

cmd_store() {
    local service="${1:?Service name required}"
    local seed="${2:-}"

    if [[ -z "$seed" ]]; then
        # Read from stdin
        if [[ -t 0 ]]; then
            echo -n "Enter TOTP seed (base32): " >&2
            read -rs seed
            echo >&2
        else
            read -r seed
        fi
    fi

    if [[ -z "$seed" ]]; then
        echo "Error: No seed provided" >&2
        exit 1
    fi

    # Validate it's a valid base32 string
    if ! python3 -c "
import base64, sys
try:
    base64.b32decode('${seed}', casefold=True)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
        echo "Error: Invalid base32 seed" >&2
        exit 1
    fi

    echo "$seed" | "$KEYCHAIN" set "$service" totp-seed
    echo "TOTP seed stored for '$service'" >&2
}

cmd_has() {
    local service="${1:?Service name required}"
    "$KEYCHAIN" has "$service" totp-seed
}

cmd_remaining() {
    local service="${1:?Service name required}"
    require_python

    python3 -c "
import time
interval = 30
remaining = interval - (time.time() % interval)
print(int(remaining))
"
}

case "${1:-}" in
    generate)  shift; cmd_generate "$@" ;;
    store)     shift; cmd_store "$@" ;;
    has)       shift; cmd_has "$@" ;;
    remaining) shift; cmd_remaining "$@" ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
esac
```

**Guardian rule addition** (append to `config/guardian-custom-rules.txt`):

```
CREDENTIAL:::echo.*totp-seed|printf.*totp-seed|cat.*totp-seed:::Exposing TOTP seed value
CREDENTIAL:::totp\.sh.*generate.*\|.*curl|totp\.sh.*generate.*\|.*wget:::Piping TOTP code to network
```

**Integration point — agent definition:**

Add to Credential Management section:

```markdown
### TOTP / 2FA Handling

When setting up 2FA on a new service:
1. During browser automation, detect the TOTP setup page (look for QR code or "manual entry" option)
2. Click "manual entry" or "can't scan QR code" to reveal the base32 seed
3. Capture the seed from the page via browser_snapshot
4. Store it: `totp.sh store {service} {seed}`
5. Generate the initial code: `CODE=$(totp.sh generate {service})`
6. Enter the code in the verification field
7. Save the backup codes if provided (store in keychain as {service}/backup-codes)

When logging in to a service with 2FA:
1. After entering email/password, detect the 2FA prompt
2. Check if we have a TOTP seed: `totp.sh has {service}`
3. If yes: `CODE=$(totp.sh generate {service})` → enter in the form
4. If no: escalate to user (Level 5) — "Enter the 2FA code from your authenticator"
```

---

### 3.3 ntfy Push Notifications

**File: `~/MCPs/autopilot/bin/notify.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# notify.sh — Channel-agnostic notification dispatcher
#
# Usage:
#   notify.sh send --message "text" [--title "title"] [--priority normal] [--channel ntfy]
#   notify.sh send --message "text" --actions '[{"action":"view","label":"Open","url":"https://..."}]'
#   notify.sh channels          List configured channels
#   notify.sh test CHANNEL      Send a test notification
#
# Channels are defined in ~/MCPs/autopilot/config/channels/
# Each channel is a YAML file with send command template

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOPILOT_DIR="$(dirname "$SCRIPT_DIR")"
CHANNELS_DIR="$AUTOPILOT_DIR/config/channels"
KEYCHAIN="$SCRIPT_DIR/keychain.sh"

# Defaults
DEFAULT_CHANNEL="${AUTOPILOT_NOTIFY_CHANNEL:-ntfy}"
NTFY_TOPIC="${AUTOPILOT_NTFY_TOPIC:-}"

usage() {
    cat <<'EOF'
notify.sh — Notification dispatcher

Commands:
  send      Send a notification
  channels  List configured channels
  test      Send a test notification to a channel
  setup     Interactive setup for a channel

Options for 'send':
  --message TEXT       Message body (required)
  --title TEXT         Notification title
  --priority LEVEL     min|low|normal|high|urgent (default: normal)
  --channel NAME       Channel to use (default: ntfy or $AUTOPILOT_NOTIFY_CHANNEL)
  --actions JSON       JSON array of action buttons
  --attach FILE        Attach a file (path)
  --tag TAG            Emoji tag (e.g. "white_check_mark", "warning")

Examples:
  notify.sh send --message "Deploy complete" --title "Autopilot" --priority high
  notify.sh send --message "Approve?" --actions '[{"action":"view","label":"Approve","url":"https://..."}]'
  notify.sh test ntfy
EOF
}

# ── ntfy channel ─────────────────────────────────────────────
send_ntfy() {
    local message="$1" title="${2:-}" priority="${3:-default}" actions="${4:-}" tag="${5:-}" attach="${6:-}"

    if [[ -z "$NTFY_TOPIC" ]]; then
        # Try keychain
        NTFY_TOPIC=$("$KEYCHAIN" get ntfy topic 2>/dev/null) || {
            echo "Error: No ntfy topic configured." >&2
            echo "Set with: echo 'your-topic' | keychain.sh set ntfy topic" >&2
            echo "Or: export AUTOPILOT_NTFY_TOPIC=your-topic" >&2
            exit 1
        }
    fi

    local -a curl_args=(
        -s
        -o /dev/null
        -w "%{http_code}"
    )

    [[ -n "$title" ]] && curl_args+=(-H "Title: $title")
    [[ -n "$tag" ]] && curl_args+=(-H "Tags: $tag")

    # Map priority names to ntfy values
    case "$priority" in
        min)     curl_args+=(-H "Priority: min") ;;
        low)     curl_args+=(-H "Priority: low") ;;
        normal)  ;; # default, no header needed
        high)    curl_args+=(-H "Priority: high") ;;
        urgent)  curl_args+=(-H "Priority: urgent") ;;
    esac

    # Actions (ntfy format: "action, label, url; action2, label2, url2")
    if [[ -n "$actions" ]]; then
        # Convert JSON actions to ntfy header format
        local action_header
        action_header=$(python3 -c "
import json, sys
actions = json.loads('$actions')
parts = []
for a in actions:
    part = f\"{a['action']}, {a['label']}, {a.get('url', '')}\"
    if 'method' in a:
        part += f\", method={a['method']}\"
    parts.append(part)
print('; '.join(parts))
" 2>/dev/null) || action_header=""
        [[ -n "$action_header" ]] && curl_args+=(-H "Actions: $action_header")
    fi

    # Attachment
    if [[ -n "$attach" && -f "$attach" ]]; then
        local http_code
        http_code=$(curl "${curl_args[@]}" -T "$attach" -H "Filename: $(basename "$attach")" "ntfy.sh/$NTFY_TOPIC")
    else
        local http_code
        http_code=$(curl "${curl_args[@]}" -d "$message" "ntfy.sh/$NTFY_TOPIC")
    fi

    if [[ "$http_code" == "200" ]]; then
        echo "sent" >&2
    else
        echo "Error: ntfy returned HTTP $http_code" >&2
        exit 1
    fi
}

# ── Telegram channel ─────────────────────────────────────────
send_telegram() {
    local message="$1" title="${2:-}" priority="${3:-default}" actions="${4:-}"

    local token chat_id
    token=$("$KEYCHAIN" get telegram bot-token 2>/dev/null) || {
        echo "Error: No Telegram bot token. Run: notify.sh setup telegram" >&2
        exit 1
    }
    chat_id=$("$KEYCHAIN" get telegram chat-id 2>/dev/null) || {
        echo "Error: No Telegram chat ID. Send /start to your bot first." >&2
        exit 1
    }

    local text="$message"
    [[ -n "$title" ]] && text="*${title}*"$'\n\n'"$message"

    # Build inline keyboard from actions
    local reply_markup=""
    if [[ -n "$actions" ]]; then
        reply_markup=$(python3 -c "
import json
actions = json.loads('$actions')
buttons = []
for a in actions:
    if a['action'] == 'view' and 'url' in a:
        buttons.append([{'text': a['label'], 'url': a['url']}])
    else:
        buttons.append([{'text': a['label'], 'callback_data': a.get('callback', a['label'].lower())}])
print(json.dumps({'inline_keyboard': buttons}))
" 2>/dev/null)
    fi

    local -a curl_args=(
        -s -o /dev/null -w "%{http_code}"
        -X POST
        "https://api.telegram.org/bot${token}/sendMessage"
        -H "Content-Type: application/json"
    )

    local body
    body=$(python3 -c "
import json
data = {
    'chat_id': '$chat_id',
    'text': $(python3 -c "import json; print(json.dumps('$text'))"),
    'parse_mode': 'Markdown'
}
reply_markup = '$reply_markup'
if reply_markup:
    data['reply_markup'] = json.loads(reply_markup)
print(json.dumps(data))
")

    local http_code
    http_code=$(curl "${curl_args[@]}" -d "$body")

    if [[ "$http_code" == "200" ]]; then
        echo "sent" >&2
    else
        echo "Error: Telegram returned HTTP $http_code" >&2
        exit 1
    fi
}

# ── Dispatcher ───────────────────────────────────────────────
cmd_send() {
    local message="" title="" priority="normal" channel="$DEFAULT_CHANNEL"
    local actions="" tag="" attach=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --message)  message="$2"; shift 2 ;;
            --title)    title="$2"; shift 2 ;;
            --priority) priority="$2"; shift 2 ;;
            --channel)  channel="$2"; shift 2 ;;
            --actions)  actions="$2"; shift 2 ;;
            --tag)      tag="$2"; shift 2 ;;
            --attach)   attach="$2"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    if [[ -z "$message" ]]; then
        echo "Error: --message required" >&2
        exit 1
    fi

    case "$channel" in
        ntfy)     send_ntfy "$message" "$title" "$priority" "$actions" "$tag" "$attach" ;;
        telegram) send_telegram "$message" "$title" "$priority" "$actions" ;;
        *)
            echo "Error: Unknown channel '$channel'" >&2
            echo "Available: ntfy, telegram" >&2
            exit 1
            ;;
    esac
}

cmd_channels() {
    echo "Configured channels:"
    echo "  ntfy      - $(if [[ -n "$NTFY_TOPIC" ]] || "$KEYCHAIN" has ntfy topic 2>/dev/null; then echo "configured"; else echo "not configured"; fi)"
    echo "  telegram  - $(if "$KEYCHAIN" has telegram bot-token 2>/dev/null; then echo "configured"; else echo "not configured"; fi)"
}

cmd_test() {
    local channel="${1:?Channel name required}"
    cmd_send --channel "$channel" --message "Test notification from Autopilot" --title "Autopilot Test" --tag "test_tube"
}

cmd_setup() {
    local channel="${1:?Channel name required}"

    case "$channel" in
        ntfy)
            echo "ntfy.sh Setup"
            echo "============="
            echo ""
            echo "1. Install ntfy app on your phone:"
            echo "   iOS: https://apps.apple.com/app/ntfy/id1625396347"
            echo "   Android: https://play.google.com/store/apps/details?id=io.heckel.ntfy"
            echo ""
            echo "2. Choose a unique topic name (like a private channel ID):"
            read -rp "   Topic name: " topic
            echo "$topic" | "$KEYCHAIN" set ntfy topic
            echo ""
            echo "3. In the ntfy app, subscribe to topic: $topic"
            echo ""
            echo "4. Test it:"
            echo "   notify.sh test ntfy"
            ;;
        telegram)
            echo "Telegram Bot Setup"
            echo "=================="
            echo ""
            echo "1. Open Telegram and message @BotFather"
            echo "2. Send: /newbot"
            echo "3. Choose a name and username for your bot"
            echo "4. Copy the bot token BotFather gives you"
            echo ""
            read -rp "   Bot token: " token
            echo "$token" | "$KEYCHAIN" set telegram bot-token
            echo ""
            echo "5. Open your bot in Telegram and send /start"
            echo "6. Now I need your chat ID. Send any message to your bot,"
            echo "   then I'll fetch it..."
            read -rp "   Press Enter when you've sent a message to the bot..."
            local chat_id
            chat_id=$(curl -s "https://api.telegram.org/bot${token}/getUpdates" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data.get('result'):
    print(data['result'][-1]['message']['chat']['id'])
else:
    print('ERROR', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null) || {
                echo "Error: Could not get chat ID. Make sure you sent a message to the bot." >&2
                exit 1
            }
            echo "$chat_id" | "$KEYCHAIN" set telegram chat-id
            echo ""
            echo "   Chat ID: $chat_id (stored in keychain)"
            echo ""
            echo "7. Test it:"
            echo "   notify.sh test telegram"
            ;;
        *)
            echo "Error: Unknown channel '$channel'" >&2
            exit 1
            ;;
    esac
}

case "${1:-}" in
    send)     shift; cmd_send "$@" ;;
    channels) cmd_channels ;;
    test)     shift; cmd_test "$@" ;;
    setup)    shift; cmd_setup "$@" ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
esac
```

---

### 3.4 Dynamic Playbook Engine

**File: `~/MCPs/autopilot/lib/playbook.py`**

This is the core engine that generates, executes, and caches browser automation playbooks.

```python
#!/usr/bin/env python3
"""
playbook.py — Dynamic Playbook Engine

Generates, executes, and caches browser automation playbooks.
Follows the Generator → Cache → Engine pattern:
  1. Check cache for existing playbook
  2. If not found, generate from research
  3. Execute with step-by-step verification
  4. Cache successful playbooks for reuse
"""

import json
import os
import re
import sqlite3
import time
import hashlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import yaml

# Paths
AUTOPILOT_DIR = Path(os.environ.get("AUTOPILOT_DIR", Path.home() / "MCPs" / "autopilot"))
PLAYBOOKS_DIR = AUTOPILOT_DIR / "playbooks"
MEMORY_DB = Path.home() / ".autopilot" / "memory.db"
TEMPLATE_PATH = AUTOPILOT_DIR / "config" / "playbook-template.yaml"

PLAYBOOKS_DIR.mkdir(parents=True, exist_ok=True)
MEMORY_DB.parent.mkdir(parents=True, exist_ok=True)


class PlaybookStore:
    """Cache layer — stores and retrieves playbooks from disk + SQLite."""

    def __init__(self, playbooks_dir: Path = PLAYBOOKS_DIR, db_path: Path = MEMORY_DB):
        self.playbooks_dir = playbooks_dir
        self.db = sqlite3.connect(str(db_path))
        self.db.row_factory = sqlite3.Row
        self._init_db()

    def _init_db(self):
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS playbooks (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                service         TEXT NOT NULL,
                flow            TEXT NOT NULL,
                version         INTEGER DEFAULT 1,
                yaml_content    TEXT NOT NULL,
                success_count   INTEGER DEFAULT 0,
                fail_count      INTEGER DEFAULT 0,
                last_run_at     REAL,
                last_status     TEXT,
                avg_duration_ms INTEGER,
                cli_available   INTEGER DEFAULT 0,
                cli_tool        TEXT,
                generated_by    TEXT DEFAULT 'auto',
                created_at      REAL NOT NULL DEFAULT (unixepoch('subsec')),
                updated_at      REAL NOT NULL DEFAULT (unixepoch('subsec')),
                UNIQUE(service, flow)
            );
            CREATE INDEX IF NOT EXISTS idx_playbooks_service ON playbooks(service);
        """)
        self.db.commit()

    def get(self, service: str, flow: str) -> Optional[dict]:
        """Get a cached playbook. Returns None if not found."""
        # Check disk first (YAML files)
        yaml_path = self.playbooks_dir / f"{service}" / f"{flow}.yaml"
        if yaml_path.exists():
            with open(yaml_path) as f:
                return yaml.safe_load(f)

        # Check DB
        row = self.db.execute(
            "SELECT * FROM playbooks WHERE service = ? AND flow = ?",
            (service, flow)
        ).fetchone()
        if row:
            return yaml.safe_load(row["yaml_content"])

        return None

    def save(self, service: str, flow: str, playbook: dict,
             generated_by: str = "auto"):
        """Save a playbook to disk and DB."""
        yaml_content = yaml.dump(playbook, default_flow_style=False, sort_keys=False)

        # Save to disk
        service_dir = self.playbooks_dir / service
        service_dir.mkdir(parents=True, exist_ok=True)
        yaml_path = service_dir / f"{flow}.yaml"
        with open(yaml_path, "w") as f:
            f.write(yaml_content)

        # Save to DB
        cli_available = 1 if playbook.get("config", {}).get("cli_available") else 0
        cli_tool = playbook.get("config", {}).get("cli_tool")

        self.db.execute("""
            INSERT INTO playbooks (service, flow, yaml_content, cli_available, cli_tool, generated_by)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(service, flow) DO UPDATE SET
                yaml_content = excluded.yaml_content,
                version = version + 1,
                cli_available = excluded.cli_available,
                cli_tool = excluded.cli_tool,
                updated_at = unixepoch('subsec')
        """, (service, flow, yaml_content, cli_available, cli_tool, generated_by))
        self.db.commit()

    def record_run(self, service: str, flow: str, success: bool, duration_ms: int):
        """Record execution result for a playbook."""
        col = "success_count" if success else "fail_count"
        self.db.execute(f"""
            UPDATE playbooks SET
                {col} = {col} + 1,
                last_run_at = unixepoch('subsec'),
                last_status = ?,
                avg_duration_ms = COALESCE(
                    (avg_duration_ms * (success_count + fail_count - 1) + ?) /
                    NULLIF(success_count + fail_count, 0),
                    ?
                )
            WHERE service = ? AND flow = ?
        """, ("ok" if success else "error", duration_ms, duration_ms, service, flow))
        self.db.commit()

    def list_services(self) -> list[str]:
        """List all services with cached playbooks."""
        rows = self.db.execute(
            "SELECT DISTINCT service FROM playbooks ORDER BY service"
        ).fetchall()
        return [r["service"] for r in rows]

    def list_flows(self, service: str) -> list[dict]:
        """List all flows for a service with stats."""
        rows = self.db.execute(
            "SELECT flow, success_count, fail_count, last_status, last_run_at FROM playbooks WHERE service = ?",
            (service,)
        ).fetchall()
        return [dict(r) for r in rows]

    def get_stats(self) -> dict:
        """Get overall playbook statistics."""
        row = self.db.execute("""
            SELECT
                COUNT(DISTINCT service) as services,
                COUNT(*) as total_playbooks,
                SUM(success_count) as total_successes,
                SUM(fail_count) as total_failures
            FROM playbooks
        """).fetchone()
        return dict(row)

    def close(self):
        self.db.close()


def generate_playbook_skeleton(service: str, flow: str,
                                 urls: dict = None,
                                 cli_info: dict = None) -> dict:
    """
    Generate a playbook skeleton for a service flow.

    This is called by the agent after researching a service.
    The agent fills in the actual steps based on its research.

    Args:
        service: Service name (e.g., "vercel")
        flow: Flow type (e.g., "signup", "login", "get_api_key")
        urls: Dict of URLs (e.g., {"signup": "https://vercel.com/signup"})
        cli_info: Dict with CLI details (e.g., {"tool": "vercel", "install": "npm i -g vercel"})

    Returns:
        A playbook dict ready for the agent to fill in steps.
    """
    playbook = {
        "service": service,
        "flow": flow,
        "version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "config": {
            "timeout_ms": 30000,
            "retry_on_failure": True,
            "max_retries": 2,
            "screenshot_on_error": True,
            "cli_available": bool(cli_info),
            "cli_tool": cli_info.get("tool") if cli_info else None,
            "cli_install": cli_info.get("install") if cli_info else None,
        },
        "urls": urls or {},
        "vars": {
            "email": "{{primary_email}}",
            "password": "{{primary_password}}",
        },
        "steps": [],
        "on_error": [
            {
                "condition": "snapshot_contains:captcha",
                "action": "escalate",
                "message": "CAPTCHA detected — manual intervention needed",
            },
            {
                "condition": "snapshot_contains:rate limit",
                "action": "wait",
                "duration_ms": 60000,
                "then": "retry",
            },
            {
                "condition": "timeout",
                "action": "screenshot_and_escalate",
                "message": "Step timed out",
            },
        ],
    }

    # Pre-populate common steps based on flow type
    if flow == "signup":
        playbook["steps"] = [
            {"id": "navigate", "action": "browser_navigate", "params": {"url": urls.get("signup", f"https://{service}.com/signup")}, "expect": {"snapshot_contains": "sign up|create account|register"}},
            {"id": "fill_email", "action": "browser_type", "params": {"field": "email", "text": "{{email}}"}, "note": "AGENT: update selector from snapshot"},
            {"id": "fill_password", "action": "browser_type", "params": {"field": "password", "text": "{{password}}"}, "note": "AGENT: update selector from snapshot"},
            {"id": "submit", "action": "browser_click", "params": {"target": "submit button"}, "note": "AGENT: update selector from snapshot"},
            {"id": "check_result", "action": "browser_snapshot", "expect": {"one_of": ["dashboard", "verify your email", "welcome"]}},
            {"id": "handle_verification", "action": "verify_email", "params": {"sender": f"noreply@{service}.com", "timeout_ms": 120000}, "condition": "previous_step_contains:verify"},
        ]
    elif flow == "login":
        playbook["steps"] = [
            {"id": "navigate", "action": "browser_navigate", "params": {"url": urls.get("login", f"https://{service}.com/login")}},
            {"id": "fill_email", "action": "browser_type", "params": {"field": "email", "text": "{{email}}"}},
            {"id": "fill_password", "action": "browser_type", "params": {"field": "password", "text": "{{password}}"}},
            {"id": "submit", "action": "browser_click", "params": {"target": "sign in button"}},
            {"id": "handle_2fa", "action": "totp", "params": {"service": service}, "condition": "snapshot_contains:verification code|two-factor|2fa"},
            {"id": "verify_login", "action": "browser_snapshot", "expect": {"snapshot_contains": "dashboard|home|overview"}},
        ]
    elif flow == "get_api_key":
        playbook["steps"] = [
            {"id": "ensure_logged_in", "action": "run_flow", "params": {"flow": "login"}, "condition": "not_logged_in"},
            {"id": "navigate_settings", "action": "browser_navigate", "params": {"url": urls.get("api_keys", f"https://{service}.com/settings/tokens")}},
            {"id": "create_token", "action": "browser_click", "params": {"target": "create token button"}},
            {"id": "name_token", "action": "browser_type", "params": {"field": "token name", "text": "autopilot-{{timestamp}}"}},
            {"id": "submit_create", "action": "browser_click", "params": {"target": "create|generate button"}},
            {"id": "capture_token", "action": "browser_snapshot", "note": "AGENT: extract token value from snapshot, store in keychain"},
            {"id": "store_token", "action": "keychain_set", "params": {"service": service, "key": "api-token"}},
        ]

    return playbook


# ── CLI interface ────────────────────────────────────────────
if __name__ == "__main__":
    import sys

    store = PlaybookStore()

    if len(sys.argv) < 2:
        print("Usage: playbook.py <command> [args]")
        print("Commands: get, save, list, stats, generate")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "get":
        service, flow = sys.argv[2], sys.argv[3]
        pb = store.get(service, flow)
        if pb:
            print(yaml.dump(pb, default_flow_style=False))
        else:
            print(f"No playbook found for {service}/{flow}", file=sys.stderr)
            sys.exit(1)

    elif cmd == "list":
        if len(sys.argv) > 2:
            flows = store.list_flows(sys.argv[2])
            for f in flows:
                status = f"OK({f['success_count']}) FAIL({f['fail_count']})"
                print(f"  {f['flow']:20s} {status}")
        else:
            services = store.list_services()
            for s in services:
                print(f"  {s}")

    elif cmd == "stats":
        stats = store.get_stats()
        print(f"Services: {stats['services']}")
        print(f"Playbooks: {stats['total_playbooks']}")
        print(f"Successes: {stats['total_successes'] or 0}")
        print(f"Failures: {stats['total_failures'] or 0}")

    elif cmd == "generate":
        service, flow = sys.argv[2], sys.argv[3]
        pb = generate_playbook_skeleton(service, flow)
        print(yaml.dump(pb, default_flow_style=False))

    store.close()
```

---

### 3.5 Playbook Template Format

**File: `~/MCPs/autopilot/config/playbook-template.yaml`**

```yaml
# Autopilot Playbook Template
# ============================
# This defines the universal structure for browser automation playbooks.
# Playbooks are auto-generated by the Dynamic Playbook Engine and cached
# in ~/MCPs/autopilot/playbooks/{service}/{flow}.yaml
#
# The agent fills in actual selectors and URLs after researching the service.
# Steps marked with "note: AGENT:" require the agent to update from live data.

# ── Metadata ─────────────────────────────────────────────────
service: "{{service_name}}"           # e.g. "vercel", "supabase"
flow: "{{flow_type}}"                 # e.g. "signup", "login", "get_api_key"
version: 1                            # auto-incremented on updates
generated_at: "{{iso_timestamp}}"     # when this playbook was created
last_verified: null                    # when this playbook last ran successfully

# ── Configuration ────────────────────────────────────────────
config:
  timeout_ms: 30000                   # per-step default timeout
  retry_on_failure: true              # retry failed steps
  max_retries: 2                      # max retries per step
  screenshot_on_error: true           # capture screenshot on failure
  cli_available: false                # true if a CLI tool exists for this service
  cli_tool: null                      # CLI binary name (e.g. "vercel")
  cli_install: null                   # install command (e.g. "npm i -g vercel")
  prefer_cli: true                    # if CLI exists, use it instead of browser

# ── URLs ─────────────────────────────────────────────────────
urls:
  home: "https://{{service}}.com"
  signup: "https://{{service}}.com/signup"
  login: "https://{{service}}.com/login"
  dashboard: "https://{{service}}.com/dashboard"
  api_keys: "https://{{service}}.com/settings/tokens"

# ── Variables ────────────────────────────────────────────────
# These are resolved at runtime from keychain or context
vars:
  email: "{{primary_email}}"          # from keychain: primary email
  password: "{{primary_password}}"    # from keychain: primary password
  username: "{{professional_primary}}" # from keychain: username preference

# ── Steps ────────────────────────────────────────────────────
# Each step has:
#   id:        unique identifier (for goto/reference)
#   action:    what to do (browser_navigate, browser_type, browser_click, etc.)
#   params:    action-specific parameters
#   expect:    what the page should look like after this step (optional)
#   condition: only run this step if condition is met (optional)
#   timeout:   override per-step timeout (optional)
#   fallback:  "vision" to use Computer Use if selector fails (optional)
#   note:      instructions for the agent when generating/updating (optional)
steps:
  - id: example_step
    action: browser_navigate
    params:
      url: "{{urls.signup}}"
    expect:
      snapshot_contains: "create account"
    fallback: vision
    note: "AGENT: verify this URL is correct from research"

# ── Error Handlers ───────────────────────────────────────────
# Global error handlers that apply to any step
on_error:
  - condition: "snapshot_contains:captcha"
    action: escalate
    level: 5
    message: "CAPTCHA detected on {{service}} — manual intervention needed"
    notify: true

  - condition: "snapshot_contains:rate limit"
    action: wait
    duration_ms: 60000
    then: retry

  - condition: "snapshot_contains:blocked|suspended|banned"
    action: escalate
    level: 5
    message: "Account appears blocked on {{service}}"
    notify: true

  - condition: "element_not_found"
    action: vision_fallback
    note: "Selector may have changed — try Computer Use vision"

  - condition: "timeout"
    action: screenshot_and_escalate
    message: "Step timed out — page may not have loaded"

# ── Post-Success Actions ─────────────────────────────────────
on_success:
  - action: log
    message: "{{flow}} completed for {{service}}"
  - action: notify
    channel: default
    priority: normal
    message: "{{service}} {{flow}} complete"
```

---

## 4. Sprint 2: Intelligence Layer

### 4.1 SQLite Memory Store

**File: `~/MCPs/autopilot/lib/memory.py`**

```python
#!/usr/bin/env python3
"""
memory.py — Unified SQLite memory store for Autopilot

Tables:
  - traces:      step-by-step execution records
  - procedures:  abstracted reusable task patterns
  - errors:      deduplicated error patterns with resolutions
  - services:    discovered service metadata cache
  - costs:       per-task token cost tracking
  - health:      service health check results
  - kv:          general key-value store
"""

import hashlib
import json
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

DB_PATH = Path.home() / ".autopilot" / "memory.db"
DB_PATH.parent.mkdir(parents=True, exist_ok=True)

SCHEMA = """
-- Execution traces: every step of every agent run
CREATE TABLE IF NOT EXISTS traces (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      TEXT NOT NULL,
    task_desc   TEXT,
    step_num    INTEGER NOT NULL,
    action      TEXT NOT NULL,
    tool        TEXT,
    service     TEXT,
    input_data  TEXT,
    output_data TEXT,
    status      TEXT NOT NULL DEFAULT 'ok',
    error_msg   TEXT,
    duration_ms INTEGER,
    tokens_in   INTEGER DEFAULT 0,
    tokens_out  INTEGER DEFAULT 0,
    model       TEXT,
    cost_usd    REAL DEFAULT 0,
    created_at  REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
CREATE INDEX IF NOT EXISTS idx_traces_run ON traces(run_id);
CREATE INDEX IF NOT EXISTS idx_traces_service ON traces(service);
CREATE INDEX IF NOT EXISTS idx_traces_status ON traces(status);

-- Learned procedures: successful patterns abstracted for reuse
CREATE TABLE IF NOT EXISTS procedures (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL UNIQUE,
    task_pattern    TEXT NOT NULL,
    services        TEXT,
    domains         TEXT,
    steps_json      TEXT NOT NULL,
    success_count   INTEGER DEFAULT 0,
    fail_count      INTEGER DEFAULT 0,
    last_run_at     REAL,
    last_status     TEXT,
    avg_duration_ms INTEGER,
    avg_cost_usd    REAL,
    version         INTEGER DEFAULT 1,
    created_at      REAL NOT NULL DEFAULT (unixepoch('subsec')),
    updated_at      REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
CREATE INDEX IF NOT EXISTS idx_procedures_services ON procedures(services);

-- Deduplicated error patterns
CREATE TABLE IF NOT EXISTS errors (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    error_hash      TEXT NOT NULL UNIQUE,
    error_type      TEXT NOT NULL,
    pattern         TEXT NOT NULL,
    service         TEXT,
    action          TEXT,
    resolution      TEXT,
    resolution_type TEXT,
    count           INTEGER DEFAULT 1,
    first_seen      REAL NOT NULL DEFAULT (unixepoch('subsec')),
    last_seen       REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
CREATE INDEX IF NOT EXISTS idx_errors_service ON errors(service);
CREATE INDEX IF NOT EXISTS idx_errors_type ON errors(error_type);

-- Service metadata cache
CREATE TABLE IF NOT EXISTS services (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL UNIQUE,
    display_name    TEXT,
    website         TEXT,
    docs_url        TEXT,
    cli_tool        TEXT,
    cli_install     TEXT,
    auth_method     TEXT,
    has_mcp         INTEGER DEFAULT 0,
    mcp_package     TEXT,
    has_playbook    INTEGER DEFAULT 0,
    has_registry    INTEGER DEFAULT 0,
    dangerous_ops   TEXT,
    last_researched REAL,
    created_at      REAL NOT NULL DEFAULT (unixepoch('subsec')),
    updated_at      REAL NOT NULL DEFAULT (unixepoch('subsec'))
);

-- Token cost tracking
CREATE TABLE IF NOT EXISTS costs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      TEXT NOT NULL,
    task_desc   TEXT,
    model       TEXT NOT NULL,
    tokens_in   INTEGER DEFAULT 0,
    tokens_out  INTEGER DEFAULT 0,
    tokens_cache INTEGER DEFAULT 0,
    cost_usd    REAL DEFAULT 0,
    duration_ms INTEGER DEFAULT 0,
    created_at  REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
CREATE INDEX IF NOT EXISTS idx_costs_run ON costs(run_id);
CREATE INDEX IF NOT EXISTS idx_costs_date ON costs(created_at);

-- Service health check results
CREATE TABLE IF NOT EXISTS health (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    service     TEXT NOT NULL,
    check_type  TEXT NOT NULL,
    status      TEXT NOT NULL,
    message     TEXT,
    response_ms INTEGER,
    created_at  REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
CREATE INDEX IF NOT EXISTS idx_health_service ON health(service);

-- General key-value store
CREATE TABLE IF NOT EXISTS kv (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  REAL NOT NULL DEFAULT (unixepoch('subsec'))
);
"""


class AutopilotMemory:
    """Unified memory interface for all Autopilot subsystems."""

    def __init__(self, db_path: Path = DB_PATH):
        self.db = sqlite3.connect(str(db_path))
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript(SCHEMA)

    # ════════════════════════════════════════════════════════════
    # TRACES — step-by-step execution records
    # ════════════════════════════════════════════════════════════

    def log_trace(self, run_id: str, step_num: int, action: str,
                  tool: str = None, service: str = None,
                  input_data: dict = None, output_data: dict = None,
                  status: str = "ok", error_msg: str = None,
                  duration_ms: int = None, tokens_in: int = 0,
                  tokens_out: int = 0, model: str = None,
                  cost_usd: float = 0, task_desc: str = None):
        self.db.execute("""
            INSERT INTO traces (run_id, task_desc, step_num, action, tool, service,
                input_data, output_data, status, error_msg, duration_ms,
                tokens_in, tokens_out, model, cost_usd)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (run_id, task_desc, step_num, action, tool, service,
              json.dumps(input_data) if input_data else None,
              json.dumps(output_data) if output_data else None,
              status, error_msg, duration_ms, tokens_in, tokens_out,
              model, cost_usd))
        self.db.commit()

    def get_run(self, run_id: str) -> list[dict]:
        rows = self.db.execute(
            "SELECT * FROM traces WHERE run_id = ? ORDER BY step_num",
            (run_id,)
        ).fetchall()
        return [dict(r) for r in rows]

    def get_recent_runs(self, limit: int = 20) -> list[dict]:
        rows = self.db.execute("""
            SELECT run_id, task_desc, COUNT(*) as steps,
                   SUM(CASE WHEN status = 'ok' THEN 1 ELSE 0 END) as ok_steps,
                   SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as err_steps,
                   SUM(tokens_in + tokens_out) as total_tokens,
                   SUM(cost_usd) as total_cost,
                   MIN(created_at) as started_at,
                   MAX(created_at) as ended_at
            FROM traces
            GROUP BY run_id
            ORDER BY MAX(created_at) DESC
            LIMIT ?
        """, (limit,)).fetchall()
        return [dict(r) for r in rows]

    # ════════════════════════════════════════════════════════════
    # PROCEDURES — reusable task patterns
    # ════════════════════════════════════════════════════════════

    def save_procedure(self, name: str, task_pattern: str, steps: list[dict],
                       services: list[str] = None, domains: list[str] = None):
        self.db.execute("""
            INSERT INTO procedures (name, task_pattern, services, domains, steps_json)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(name) DO UPDATE SET
                task_pattern = excluded.task_pattern,
                steps_json = excluded.steps_json,
                services = excluded.services,
                domains = excluded.domains,
                version = version + 1,
                updated_at = unixepoch('subsec')
        """, (name, task_pattern,
              json.dumps(services) if services else None,
              json.dumps(domains) if domains else None,
              json.dumps(steps)))
        self.db.commit()

    def find_procedure(self, task_desc: str = None, services: list[str] = None) -> list[dict]:
        """Find procedures matching a task description or service list."""
        conditions = []
        params = []

        if task_desc:
            # Simple keyword matching — upgrade to embeddings later
            words = task_desc.lower().split()
            for word in words[:5]:  # limit to 5 keywords
                conditions.append("LOWER(task_pattern) LIKE ?")
                params.append(f"%{word}%")

        if services:
            for svc in services:
                conditions.append("services LIKE ?")
                params.append(f"%{svc}%")

        if not conditions:
            return []

        where = " OR ".join(conditions)
        rows = self.db.execute(f"""
            SELECT *, (success_count * 1.0 / NULLIF(success_count + fail_count, 0)) as success_rate
            FROM procedures
            WHERE {where}
            ORDER BY success_rate DESC, success_count DESC
            LIMIT 5
        """, params).fetchall()
        return [dict(r) for r in rows]

    def record_procedure_run(self, name: str, success: bool,
                              duration_ms: int, cost_usd: float = 0):
        col = "success_count" if success else "fail_count"
        self.db.execute(f"""
            UPDATE procedures SET
                {col} = {col} + 1,
                last_run_at = unixepoch('subsec'),
                last_status = ?,
                avg_duration_ms = COALESCE(
                    (avg_duration_ms * NULLIF(success_count + fail_count - 1, 0) + ?) /
                    NULLIF(success_count + fail_count, 0), ?
                ),
                avg_cost_usd = COALESCE(
                    (avg_cost_usd * NULLIF(success_count + fail_count - 1, 0) + ?) /
                    NULLIF(success_count + fail_count, 0), ?
                )
            WHERE name = ?
        """, ("ok" if success else "error", duration_ms, duration_ms,
              cost_usd, cost_usd, name))
        self.db.commit()

    # ════════════════════════════════════════════════════════════
    # ERRORS — deduplicated error patterns
    # ════════════════════════════════════════════════════════════

    def log_error(self, error_type: str, pattern: str,
                  service: str = None, action: str = None,
                  resolution: str = None, resolution_type: str = None):
        error_hash = hashlib.sha256(
            f"{error_type}:{pattern}:{service or ''}".encode()
        ).hexdigest()[:16]

        self.db.execute("""
            INSERT INTO errors (error_hash, error_type, pattern, service, action,
                resolution, resolution_type)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(error_hash) DO UPDATE SET
                count = count + 1,
                last_seen = unixepoch('subsec'),
                resolution = COALESCE(excluded.resolution, resolution),
                resolution_type = COALESCE(excluded.resolution_type, resolution_type)
        """, (error_hash, error_type, pattern, service, action,
              resolution, resolution_type))
        self.db.commit()

    def check_known_error(self, error_msg: str, service: str = None) -> Optional[dict]:
        """Check if an error matches a known pattern with a resolution."""
        conditions = ["resolution IS NOT NULL"]
        params = []

        if service:
            conditions.append("(service = ? OR service IS NULL)")
            params.append(service)

        where = " AND ".join(conditions)
        rows = self.db.execute(f"""
            SELECT * FROM errors WHERE {where}
            ORDER BY count DESC
        """, params).fetchall()

        # Match against error message
        error_lower = error_msg.lower()
        for row in rows:
            if row["pattern"].lower() in error_lower:
                return dict(row)

        return None

    # ════════════════════════════════════════════════════════════
    # SERVICES — discovered service metadata
    # ════════════════════════════════════════════════════════════

    def cache_service(self, name: str, **kwargs):
        cols = ["name"] + list(kwargs.keys())
        vals = [name] + list(kwargs.values())
        placeholders = ", ".join(["?"] * len(vals))
        col_names = ", ".join(cols)
        updates = ", ".join(f"{k} = excluded.{k}" for k in kwargs.keys())

        self.db.execute(f"""
            INSERT INTO services ({col_names}) VALUES ({placeholders})
            ON CONFLICT(name) DO UPDATE SET {updates}, updated_at = unixepoch('subsec')
        """, vals)
        self.db.commit()

    def get_service(self, name: str) -> Optional[dict]:
        row = self.db.execute(
            "SELECT * FROM services WHERE name = ?", (name,)
        ).fetchone()
        return dict(row) if row else None

    # ════════════════════════════════════════════════════════════
    # COSTS — token usage tracking
    # ════════════════════════════════════════════════════════════

    def log_cost(self, run_id: str, model: str, tokens_in: int,
                 tokens_out: int, tokens_cache: int = 0,
                 cost_usd: float = 0, duration_ms: int = 0,
                 task_desc: str = None):
        self.db.execute("""
            INSERT INTO costs (run_id, task_desc, model, tokens_in, tokens_out,
                tokens_cache, cost_usd, duration_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (run_id, task_desc, model, tokens_in, tokens_out,
              tokens_cache, cost_usd, duration_ms))
        self.db.commit()

    def get_cost_summary(self, days: int = 7) -> dict:
        cutoff = time.time() - (days * 86400)
        row = self.db.execute("""
            SELECT
                COUNT(DISTINCT run_id) as tasks,
                SUM(tokens_in) as total_in,
                SUM(tokens_out) as total_out,
                SUM(tokens_cache) as total_cache,
                SUM(cost_usd) as total_cost,
                AVG(cost_usd) as avg_cost_per_task
            FROM costs
            WHERE created_at > ?
        """, (cutoff,)).fetchone()
        return dict(row)

    def get_cost_by_model(self, days: int = 7) -> list[dict]:
        cutoff = time.time() - (days * 86400)
        rows = self.db.execute("""
            SELECT model,
                COUNT(*) as calls,
                SUM(tokens_in + tokens_out) as total_tokens,
                SUM(cost_usd) as total_cost
            FROM costs
            WHERE created_at > ?
            GROUP BY model
            ORDER BY total_cost DESC
        """, (cutoff,)).fetchall()
        return [dict(r) for r in rows]

    # ════════════════════════════════════════════════════════════
    # HEALTH — service health tracking
    # ════════════════════════════════════════════════════════════

    def log_health(self, service: str, check_type: str,
                   status: str, message: str = None,
                   response_ms: int = None):
        self.db.execute("""
            INSERT INTO health (service, check_type, status, message, response_ms)
            VALUES (?, ?, ?, ?, ?)
        """, (service, check_type, status, message, response_ms))
        self.db.commit()

    def get_health_status(self) -> list[dict]:
        """Get latest health check for each service."""
        rows = self.db.execute("""
            SELECT h.* FROM health h
            INNER JOIN (
                SELECT service, MAX(created_at) as max_created
                FROM health GROUP BY service
            ) latest ON h.service = latest.service AND h.created_at = latest.max_created
            ORDER BY h.service
        """).fetchall()
        return [dict(r) for r in rows]

    # ════════════════════════════════════════════════════════════
    # KV — general key-value store
    # ════════════════════════════════════════════════════════════

    def kv_set(self, key: str, value: str):
        self.db.execute("""
            INSERT INTO kv (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = unixepoch('subsec')
        """, (key, value))
        self.db.commit()

    def kv_get(self, key: str) -> Optional[str]:
        row = self.db.execute("SELECT value FROM kv WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else None

    def close(self):
        self.db.close()


# ── CLI interface ────────────────────────────────────────────
if __name__ == "__main__":
    import sys

    mem = AutopilotMemory()

    if len(sys.argv) < 2:
        print("Usage: memory.py <command>")
        print("Commands: stats, runs, costs, errors, health, services")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "stats":
        runs = mem.get_recent_runs(5)
        print(f"Recent runs: {len(runs)}")
        for r in runs:
            print(f"  {r['run_id'][:8]}  {r['task_desc'] or 'unknown':40s}  "
                  f"steps={r['steps']}  ok={r['ok_steps']}  err={r['err_steps']}  "
                  f"tokens={r['total_tokens']}  ${r['total_cost']:.4f}")

    elif cmd == "costs":
        days = int(sys.argv[2]) if len(sys.argv) > 2 else 7
        summary = mem.get_cost_summary(days)
        print(f"Cost summary (last {days} days):")
        print(f"  Tasks:      {summary['tasks'] or 0}")
        print(f"  Tokens in:  {summary['total_in'] or 0:,}")
        print(f"  Tokens out: {summary['total_out'] or 0:,}")
        print(f"  Cached:     {summary['total_cache'] or 0:,}")
        print(f"  Total cost: ${summary['total_cost'] or 0:.4f}")
        print(f"  Avg/task:   ${summary['avg_cost_per_task'] or 0:.4f}")
        print()
        by_model = mem.get_cost_by_model(days)
        for m in by_model:
            print(f"  {m['model'] or 'unknown':20s}  calls={m['calls']}  "
                  f"tokens={m['total_tokens']:,}  ${m['total_cost']:.4f}")

    elif cmd == "errors":
        rows = mem.db.execute(
            "SELECT * FROM errors ORDER BY count DESC LIMIT 20"
        ).fetchall()
        for r in rows:
            resolved = "RESOLVED" if r["resolution"] else "UNRESOLVED"
            print(f"  [{r['count']:3d}x] {r['error_type']:15s} {r['service'] or '*':15s} "
                  f"{resolved:12s} {r['pattern'][:60]}")

    elif cmd == "health":
        statuses = mem.get_health_status()
        for s in statuses:
            icon = "OK" if s["status"] == "ok" else "FAIL"
            print(f"  [{icon:4s}] {s['service']:20s} {s['check_type']:15s} "
                  f"{s.get('message', '') or ''}")

    elif cmd == "services":
        rows = mem.db.execute(
            "SELECT name, cli_tool, has_mcp, has_playbook, has_registry FROM services ORDER BY name"
        ).fetchall()
        for r in rows:
            flags = []
            if r["cli_tool"]: flags.append(f"cli:{r['cli_tool']}")
            if r["has_mcp"]: flags.append("mcp")
            if r["has_playbook"]: flags.append("playbook")
            if r["has_registry"]: flags.append("registry")
            print(f"  {r['name']:20s} {', '.join(flags)}")

    mem.close()
```

---

### 4.2-4.3 Procedural Memory & Error Memory

These are built INTO `memory.py` above. The agent definition needs protocols for when to record and when to retrieve.

**Agent definition additions** (add to `agent/autopilot.md`):

```markdown
### Procedural Memory Protocol

**Recording (after every successful task):**
1. After completing any multi-step task successfully, abstract the execution into a procedure
2. Procedure name format: "{action}_{primary_service}_{secondary_service}" (e.g., "deploy_nextjs_vercel_supabase")
3. Store: `python3 ~/MCPs/autopilot/lib/memory.py` or call the memory MCP tool
4. Record: task pattern (natural language), services involved, step sequence, duration, cost

**Retrieval (before starting any task):**
1. Before planning, search procedures: match by task description keywords + services detected
2. If high-confidence match (success_rate > 0.8, success_count > 2):
   - Use the procedure's step sequence as the plan
   - Use cheaper model (Sonnet/Haiku) since we're following proven steps
3. If partial match:
   - Use as starting guidance but verify each step
   - Full reasoning model (Opus)
4. If no match:
   - Full reasoning from scratch (Opus)
   - Record the execution for future retrieval

### Error Memory Protocol

**Recording (on every failure):**
1. When any step fails, immediately record:
   - Error type (timeout, not_found, auth_failure, rate_limit, etc.)
   - Error message pattern (normalized — strip timestamps, UUIDs, specific values)
   - Service involved
   - Action that triggered it
2. When a fix is found, update the error record with the resolution

**Preemptive checking (before every command):**
1. Before executing any CLI command or browser action, check error memory:
   "Has this service + action combination failed before?"
2. If a known error with resolution exists:
   - Apply the resolution preemptively
   - Example: if "vercel deploy" has failed with "framework not detected" before,
     check vercel.json has the framework field BEFORE deploying
3. This turns past mistakes into preemptive fixes
```

---

### 4.4 Telegram Bot

**File: `~/MCPs/autopilot/telegram-bot/bot.py`**

```python
#!/usr/bin/env python3
"""
Autopilot Telegram Bot — Bidirectional phone interface

Features:
- Push notifications on task completion/failure
- Interactive approve/deny buttons for L3+ decisions
- Accept commands from phone → queue for agent
- Voice message support (via Whisper STT)
- File sharing (logs, screenshots, diffs)
"""

import json
import logging
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from telegram import (
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Update,
)
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

# ── Configuration ────────────────────────────────────────────
AUTOPILOT_DIR = Path(os.environ.get("AUTOPILOT_DIR", Path.home() / "MCPs" / "autopilot"))
KEYCHAIN = AUTOPILOT_DIR / "bin" / "keychain.sh"
QUEUE_DIR = Path.home() / ".autopilot" / "queue"
QUEUE_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger("autopilot-bot")


def get_credential(service: str, key: str) -> str:
    """Read credential from keychain."""
    result = subprocess.run(
        [str(KEYCHAIN), "get", service, key],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"Keychain: {service}/{key} not found")
    return result.stdout.strip()


# ── Handlers ─────────────────────────────────────────────────

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /start command — register chat ID."""
    chat_id = str(update.effective_chat.id)
    # Store chat ID in keychain
    subprocess.run(
        [str(KEYCHAIN), "set", "telegram", "chat-id"],
        input=chat_id, text=True, capture_output=True
    )
    await update.message.reply_text(
        "Autopilot connected.\n\n"
        "Commands:\n"
        "/status — current task progress\n"
        "/tasks — list queued tasks\n"
        "/health — service health check\n"
        "/cost — token cost summary\n"
        "\nOr just send a message to queue a task."
    )


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /status — show current session state."""
    # Check for active session
    result = subprocess.run(
        [str(AUTOPILOT_DIR / "bin" / "session.sh"), "status"],
        capture_output=True, text=True, cwd=str(Path.home())
    )
    if result.returncode == 0:
        await update.message.reply_text(f"```\n{result.stdout[:4000]}\n```", parse_mode="Markdown")
    else:
        await update.message.reply_text("No active task session.")


async def cmd_health(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /health — run health checks."""
    result = subprocess.run(
        ["python3", str(AUTOPILOT_DIR / "lib" / "memory.py"), "health"],
        capture_output=True, text=True
    )
    text = result.stdout if result.stdout else "No health data yet."
    await update.message.reply_text(f"```\n{text[:4000]}\n```", parse_mode="Markdown")


async def cmd_cost(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /cost — show cost summary."""
    result = subprocess.run(
        ["python3", str(AUTOPILOT_DIR / "lib" / "memory.py"), "costs"],
        capture_output=True, text=True
    )
    text = result.stdout if result.stdout else "No cost data yet."
    await update.message.reply_text(f"```\n{text[:4000]}\n```", parse_mode="Markdown")


async def cmd_tasks(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /tasks — list queued tasks."""
    tasks = sorted(QUEUE_DIR.glob("*.json"), key=lambda p: p.stat().st_mtime)
    if not tasks:
        await update.message.reply_text("No tasks in queue.")
        return

    lines = []
    for t in tasks[-10:]:
        data = json.loads(t.read_text())
        status = data.get("status", "pending")
        icon = {"pending": "\\u23f3", "running": "\\u25b6\\ufe0f", "done": "\\u2705", "failed": "\\u274c"}.get(status, "\\u2753")
        lines.append(f"{icon} {data.get('task', 'unknown')[:60]}")

    await update.message.reply_text("Recent tasks:\n" + "\n".join(lines))


async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle free-text messages — queue as tasks."""
    text = update.message.text
    if not text:
        return

    # Save to task queue
    task_id = f"tg_{int(datetime.now(timezone.utc).timestamp())}_{update.message.message_id}"
    task_file = QUEUE_DIR / f"{task_id}.json"
    task_file.write_text(json.dumps({
        "id": task_id,
        "task": text,
        "status": "pending",
        "source": "telegram",
        "chat_id": update.effective_chat.id,
        "message_id": update.message.message_id,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }))

    await update.message.reply_text(
        f"Task queued: {text[:100]}{'...' if len(text) > 100 else ''}\n\n"
        f"ID: `{task_id}`",
        parse_mode="Markdown"
    )


async def handle_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle inline keyboard button presses."""
    query = update.callback_query
    await query.answer()

    data = query.data
    if data.startswith("approve:"):
        task_id = data.split(":", 1)[1]
        # Write approval to queue
        approval_file = QUEUE_DIR / f"{task_id}.approval"
        approval_file.write_text(json.dumps({
            "task_id": task_id,
            "decision": "approved",
            "decided_by": "telegram",
            "decided_at": datetime.now(timezone.utc).isoformat(),
        }))
        await query.edit_message_text(f"Approved task {task_id[:12]}...")

    elif data.startswith("deny:"):
        task_id = data.split(":", 1)[1]
        approval_file = QUEUE_DIR / f"{task_id}.approval"
        approval_file.write_text(json.dumps({
            "task_id": task_id,
            "decision": "denied",
            "decided_by": "telegram",
            "decided_at": datetime.now(timezone.utc).isoformat(),
        }))
        await query.edit_message_text(f"Denied task {task_id[:12]}...")

    elif data.startswith("rollback:"):
        task_id = data.split(":", 1)[1]
        # Queue rollback command
        rollback_file = QUEUE_DIR / f"rollback_{task_id}.json"
        rollback_file.write_text(json.dumps({
            "id": f"rollback_{task_id}",
            "task": f"rollback {task_id}",
            "status": "pending",
            "source": "telegram",
            "created_at": datetime.now(timezone.utc).isoformat(),
        }))
        await query.edit_message_text(f"Rollback queued for {task_id[:12]}...")


# ── Notification API (called by notify.sh or agent) ──────────

async def send_notification(bot, chat_id: int, message: str,
                             title: str = None, priority: str = "normal",
                             actions: list = None, file_path: str = None):
    """Send a notification to the user. Called externally."""
    text = message
    if title:
        text = f"*{title}*\n\n{message}"

    reply_markup = None
    if actions:
        keyboard = []
        for action in actions:
            if action.get("url"):
                keyboard.append([InlineKeyboardButton(
                    action["label"], url=action["url"]
                )])
            else:
                keyboard.append([InlineKeyboardButton(
                    action["label"],
                    callback_data=action.get("callback", action["label"].lower())
                )])
        reply_markup = InlineKeyboardMarkup(keyboard)

    await bot.send_message(
        chat_id=chat_id,
        text=text,
        parse_mode="Markdown",
        reply_markup=reply_markup,
    )

    if file_path and os.path.exists(file_path):
        await bot.send_document(
            chat_id=chat_id,
            document=open(file_path, "rb"),
            filename=os.path.basename(file_path),
        )


# ── Main ─────────────────────────────────────────────────────

def main():
    try:
        token = get_credential("telegram", "bot-token")
    except RuntimeError:
        logger.error("No Telegram bot token in keychain. Run: notify.sh setup telegram")
        sys.exit(1)

    app = Application.builder().token(token).build()

    # Command handlers
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("health", cmd_health))
    app.add_handler(CommandHandler("cost", cmd_cost))
    app.add_handler(CommandHandler("tasks", cmd_tasks))

    # Callback handler (button presses)
    app.add_handler(CallbackQueryHandler(handle_callback))

    # Free-text message handler (task queuing)
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))

    logger.info("Autopilot Telegram bot starting...")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
```

**File: `~/MCPs/autopilot/telegram-bot/com.autopilot.telegram.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.autopilot.telegram</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/Frameworks/Python.framework/Versions/3.13/bin/python3</string>
        <string>/Users/rishi_kolisetty/MCPs/autopilot/telegram-bot/bot.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Users/rishi_kolisetty/MCPs/autopilot</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/rishi_kolisetty/.autopilot/logs/telegram-bot.out.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/rishi_kolisetty/.autopilot/logs/telegram-bot.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PYTHONUNBUFFERED</key>
        <string>1</string>
        <key>AUTOPILOT_DIR</key>
        <string>/Users/rishi_kolisetty/MCPs/autopilot</string>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
```

---

## 8. Agent Definition Updates

The following sections need to be ADDED to `~/MCPs/autopilot/agent/autopilot.md`. These are the dynamic protocols that replace static behaviors.

### Addition 1: Dynamic Service Resolution Protocol

Add after the existing "Service Interaction Priority" section:

```markdown
### Dynamic Service Resolution

When a task involves ANY service, resolve it through this cascade:

1. **Check service cache**: `~/MCPs/autopilot/services/{service}.md` exists?
   - Yes → use it directly
   - No → continue to step 2

2. **Check aliases**: Common aliases map to known services:
   - "postgres"/"pg"/"postgresql" → supabase or neon (check project deps)
   - "s3"/"object storage" → cloudflare-r2 or aws-s3
   - "deploy"/"hosting" → vercel or netlify (check project framework)
   - If alias matches a cached service → use it

3. **Check memory DB**: `python3 lib/memory.py services` — has this service been researched before?
   - Yes → use cached metadata, generate registry if missing

4. **Auto-research** (if not cached anywhere):
   a. WebSearch: `"{service} CLI documentation"`, `"{service} API authentication"`
   b. WebSearch: `"{service} MCP server npm"`
   c. WebFetch official docs
   d. Identify: auth method, CLI tool, dangerous operations, MCP availability
   e. Generate service registry file from `services/_template.md`
   f. Append dangerous operations to `guardian-custom-rules.txt`
   g. Cache in memory DB: `python3 lib/memory.py`
   h. If CLI exists and not installed → install it
   i. If MCP exists → evaluate trust and install if score > 70

5. **Generate playbook if needed**:
   - Check: `python3 lib/playbook.py get {service} {flow}`
   - If not cached → generate skeleton → fill from research → save

This entire cascade happens INLINE — the user sees nothing except "Researching {service}..." status update. No pause to ask. No manual steps.
```

### Addition 2: Dynamic Playbook Execution Protocol

```markdown
### Dynamic Playbook Execution

When browser automation is needed for any service:

1. **Check for playbook**: `python3 lib/playbook.py get {service} {flow}`
2. **If cached**: Load and execute step-by-step
3. **If not cached**: Generate via Playbook Engine:
   a. Research the service's web interface (WebSearch + WebFetch)
   b. Generate playbook skeleton from template
   c. Navigate to the target URL
   d. `browser_snapshot` to see the actual page structure
   e. Fill in selectors from the accessibility tree
   f. Execute each step with verification
   g. Save successful playbook to cache

4. **Execution loop** (for each step):
   a. Execute the action (navigate, type, click, etc.)
   b. `browser_snapshot` to verify
   c. Check `expect` conditions
   d. If step fails:
      - Check error memory for known fix
      - If known fix → apply and retry
      - If unknown → try Computer Use fallback (screenshot → vision)
      - If Computer Use succeeds → update playbook selector
      - If both fail → screenshot, notify user, halt

5. **After successful completion**:
   a. Save/update playbook to cache
   b. Record in procedural memory
   c. Log to audit trail
   d. Notify via configured channel
```

### Addition 3: Notification Integration Protocol

```markdown
### Notification Protocol

Use `~/MCPs/autopilot/bin/notify.sh` for all notifications:

**When to notify:**
- Task completion (always): `notify.sh send --message "Done: {summary}" --tag "white_check_mark"`
- Task failure (always): `notify.sh send --message "Failed: {error}" --priority high --tag "x"`
- L3+ approval needed: `notify.sh send --message "{description}" --actions '[{"action":"view","label":"Approve","callback":"approve:{task_id}"},{"action":"view","label":"Deny","callback":"deny:{task_id}"}]'`
- Account created: `notify.sh send --message "Created account on {service}" --tag "key"`
- Credential acquired: `notify.sh send --message "API token stored for {service}" --tag "lock"`
- Health alert: `notify.sh send --message "{service}: {issue}" --priority high`

**Priority mapping:**
- L1/L2 results → normal
- L3 approvals → high
- L4/L5 escalations → urgent
- Failures → high
- Health alerts → high
```

---

## 9. Integration Map

This shows how every component connects:

```
EXISTING COMPONENT          INTEGRATES WITH NEW COMPONENT
──────────────────          ─────────────────────────────
guardian.sh             →   memory.db (read dynamic rules from errors table)
keychain.sh             →   totp.sh (stores/reads TOTP seeds)
                        →   notify.sh (stores/reads channel credentials)
                        →   telegram-bot (reads bot token + chat ID)
chrome-debug.sh         →   playbook engine (provides browser for execution)
snapshot.sh             →   (unchanged — used by session.sh as before)
session.sh              →   telegram-bot (reports progress to phone)
                        →   memory.db (records execution traces)
audit.sh                →   memory.db (reads structured events for display)
service registry        →   memory.db (services table caches metadata)
                        →   playbook engine (generates playbooks for services)
                        →   guardian (auto-generates safety rules)
agent/autopilot.md      →   ALL new components via updated protocols
```

### Data Flow for a Typical Task

```
1. User says "Deploy this to Vercel with Supabase"
   │
2. Agent checks procedural memory → match found (90% success rate)
   │
3. Agent loads cached procedure → generates plan from it
   │
4. notify.sh → Telegram: "Starting deploy (6 steps)"
   │
5. For each step:
   │  a. Check error memory → preemptive fixes applied
   │  b. Execute (CLI preferred, playbook if browser needed)
   │  c. Log trace to memory.db
   │  d. Update Telegram message in-place: "[3/6] Running migrations..."
   │
6. On completion:
   │  a. Record procedure run (success, duration, cost)
   │  b. Log to audit trail
   │  c. notify.sh → Telegram: "Done! Preview: https://..."
   │  d. Update cost tracking
```

---

## 10. Testing Strategy

### Existing Tests (keep running)
- `bin/test-guardian.sh` — 55 test cases for guardian patterns

### New Tests to Create

**File: `~/MCPs/autopilot/bin/test-memory.sh`**

```bash
#!/usr/bin/env bash
# Test the SQLite memory store
set -euo pipefail

TEST_DB="/tmp/autopilot-test-memory.db"
MEMORY="python3 $(dirname "$0")/../lib/memory.py"

# Clean
rm -f "$TEST_DB"

echo "Testing memory store..."

# Test 1: Create DB and verify schema
python3 -c "
import sys; sys.path.insert(0, '$(dirname "$0")/../lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
tables = [r[0] for r in mem.db.execute(\"SELECT name FROM sqlite_master WHERE type='table'\").fetchall()]
expected = {'traces', 'procedures', 'errors', 'services', 'costs', 'health', 'kv'}
assert expected.issubset(set(tables)), f'Missing tables: {expected - set(tables)}'
mem.close()
print('PASS: Schema created')
"

# Test 2: Log and retrieve traces
python3 -c "
import sys; sys.path.insert(0, '$(dirname "$0")/../lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
mem.log_trace('run1', 1, 'deploy', tool='Bash', service='vercel', status='ok')
mem.log_trace('run1', 2, 'migrate', tool='Bash', service='supabase', status='error', error_msg='connection timeout')
traces = mem.get_run('run1')
assert len(traces) == 2
assert traces[0]['status'] == 'ok'
assert traces[1]['status'] == 'error'
mem.close()
print('PASS: Trace logging and retrieval')
"

# Test 3: Procedure save and find
python3 -c "
import sys; sys.path.insert(0, '$(dirname "$0")/../lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
mem.save_procedure('deploy_vercel', 'deploy next.js to vercel', [{'step': 'vercel deploy'}], services=['vercel'])
mem.record_procedure_run('deploy_vercel', True, 5000)
mem.record_procedure_run('deploy_vercel', True, 4500)
results = mem.find_procedure(task_desc='deploy to vercel')
assert len(results) > 0
assert results[0]['name'] == 'deploy_vercel'
assert results[0]['success_count'] == 2
mem.close()
print('PASS: Procedure save, find, and run recording')
"

# Test 4: Error logging and known-error lookup
python3 -c "
import sys; sys.path.insert(0, '$(dirname "$0")/../lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
mem.log_error('timeout', 'connection timed out', service='supabase', resolution='retry with --timeout 60')
match = mem.check_known_error('Error: connection timed out after 30s', service='supabase')
assert match is not None
assert 'retry' in match['resolution']
mem.close()
print('PASS: Error logging and known-error lookup')
"

# Test 5: Cost tracking
python3 -c "
import sys; sys.path.insert(0, '$(dirname "$0")/../lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
mem.log_cost('run1', 'opus', 1000, 500, cost_usd=0.05)
mem.log_cost('run1', 'haiku', 200, 100, cost_usd=0.001)
summary = mem.get_cost_summary(1)
assert summary['total_cost'] > 0
by_model = mem.get_cost_by_model(1)
assert len(by_model) == 2
mem.close()
print('PASS: Cost tracking')
"

# Test 6: Service caching
python3 -c "
import sys; sys.path.insert(0, '$(dirname "$0")/../lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
mem.cache_service('vercel', cli_tool='vercel', has_mcp=0, has_playbook=1, has_registry=1)
svc = mem.get_service('vercel')
assert svc['cli_tool'] == 'vercel'
assert svc['has_playbook'] == 1
mem.close()
print('PASS: Service caching')
"

# Cleanup
rm -f "$TEST_DB"
echo ""
echo "All memory tests passed."
```

**File: `~/MCPs/autopilot/bin/test-notify.sh`**

```bash
#!/usr/bin/env bash
# Test notification dispatcher (dry run — no actual sends)
set -euo pipefail

NOTIFY="$(dirname "$0")/notify.sh"

echo "Testing notify.sh..."

# Test 1: Help text
"$NOTIFY" --help >/dev/null 2>&1 && echo "PASS: Help text" || echo "FAIL: Help text"

# Test 2: Channel listing
"$NOTIFY" channels >/dev/null 2>&1 && echo "PASS: Channel listing" || echo "FAIL: Channel listing"

# Test 3: Missing message error
if "$NOTIFY" send 2>&1 | grep -q "required"; then
    echo "PASS: Missing message error"
else
    echo "FAIL: Missing message error"
fi

# Test 4: Unknown channel error
if "$NOTIFY" send --message "test" --channel "nonexistent" 2>&1 | grep -q "Unknown"; then
    echo "PASS: Unknown channel error"
else
    echo "FAIL: Unknown channel error"
fi

echo ""
echo "Notify tests complete (no actual notifications sent)."
```

**File: `~/MCPs/autopilot/bin/test-totp.sh`**

```bash
#!/usr/bin/env bash
# Test TOTP generator
set -euo pipefail

TOTP="$(dirname "$0")/totp.sh"

echo "Testing totp.sh..."

# Test 1: Help text
"$TOTP" --help >/dev/null 2>&1 && echo "PASS: Help text" || echo "FAIL: Help text"

# Test 2: Generate from known seed (RFC 6238 test vector)
# Base32 of "12345678901234567890" = GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
CODE=$("$TOTP" generate test-totp-rfc 2>/dev/null) || {
    # First, store the test seed
    echo "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" | "$(dirname "$0")/keychain.sh" set test-totp-rfc totp-seed 2>/dev/null
    CODE=$("$TOTP" generate test-totp-rfc 2>/dev/null)
}
if [[ ${#CODE} -eq 6 && "$CODE" =~ ^[0-9]+$ ]]; then
    echo "PASS: TOTP generation (${#CODE}-digit code)"
else
    echo "FAIL: TOTP generation (got: '$CODE')"
fi

# Test 3: Has check
if "$TOTP" has test-totp-rfc 2>/dev/null; then
    echo "PASS: Has check (exists)"
else
    echo "FAIL: Has check"
fi

# Test 4: Remaining seconds
REMAINING=$("$TOTP" remaining test-totp-rfc 2>/dev/null)
if [[ "$REMAINING" -ge 0 && "$REMAINING" -le 30 ]]; then
    echo "PASS: Remaining seconds ($REMAINING)"
else
    echo "FAIL: Remaining seconds (got: '$REMAINING')"
fi

# Cleanup test seed
"$(dirname "$0")/keychain.sh" delete test-totp-rfc totp-seed 2>/dev/null || true

echo ""
echo "TOTP tests complete."
```

---

## Summary: What to Build, In Order

| Sprint | Duration | Deliverables | Files Created |
|--------|----------|-------------|---------------|
| **1** | 1 week | Email verification, TOTP, ntfy, Playbook template & engine skeleton | `verify-email.sh`, `totp.sh`, `notify.sh`, `playbook-template.yaml`, `lib/playbook.py` |
| **2** | 2 weeks | Memory DB, Procedural + Error memory, Telegram bot, Model router | `lib/memory.py`, `telegram-bot/bot.py`, `telegram-bot/*.plist`, agent def updates |
| **3** | 2 weeks | Dynamic playbook generator, Service resolver, MCP discovery, Agent spawner | Agent def updates (protocols), dynamic agent `.md` generator |
| **4** | 1-2 weeks | Guardian dynamic rules, Structured audit, Cost tracking, Health monitor | `guardian.sh` update, `audit.sh` update, `cost-tracker.sh`, `health-check.sh` |
| **5** | 1-2 weeks | Plan generator, Credential lifecycle, Autopilot MCP server | Agent def updates, `mcp-server/src/index.ts` |

**After all sprints**: Nothing is static. Nothing has a fixed list. The system handles any service, any workflow, any domain — researching what it doesn't know, caching what it learns, and getting smarter with every task.
