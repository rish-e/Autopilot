#!/bin/bash
# notify.sh — Channel-agnostic notification dispatcher for Autopilot
#
# Sends notifications to configured channels (ntfy, telegram, etc.).
# Channels are configured via keychain credentials — no plaintext config files.
#
# Usage:
#   notify.sh send --message "text" [--title "title"] [--priority normal] [--channel ntfy]
#   notify.sh send --message "text" --actions '[{"action":"view","label":"Open","url":"..."}]'
#   notify.sh channels                List configured channels
#   notify.sh test <channel>          Send a test notification
#   notify.sh setup <channel>         Interactive channel setup
#
# Channels:
#   ntfy      — Free push notifications via ntfy.sh (default)
#   telegram  — Telegram bot with interactive buttons
#
# Priority levels: min, low, normal (default), high, urgent

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCHAIN="$SCRIPT_DIR/keychain.sh"

# Defaults
DEFAULT_CHANNEL="${AUTOPILOT_NOTIFY_CHANNEL:-ntfy}"

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
notify.sh — Notification dispatcher for Autopilot

Commands:
  send       Send a notification
  channels   List configured channels and their status
  test       Send a test notification to a channel
  setup      Interactive setup wizard for a channel

Options for 'send':
  --message TEXT       Notification body (required)
  --title TEXT         Notification title
  --priority LEVEL     min | low | normal | high | urgent (default: normal)
  --channel NAME       Channel to use (default: ntfy or $AUTOPILOT_NOTIFY_CHANNEL)
  --actions JSON       JSON array of action buttons (ntfy/telegram)
  --tag TAG            Emoji tag for ntfy (e.g. white_check_mark, warning)
  --attach FILE        Attach a file (ntfy: local file upload)

Examples:
  notify.sh send --message "Deploy complete" --title "Autopilot" --priority high
  notify.sh send --message "Approve?" --actions '[{"action":"view","label":"Open","url":"https://..."}]'
  notify.sh send --message "Failed" --channel telegram --priority urgent
  notify.sh setup ntfy
  notify.sh test ntfy
EOF
}

# ─── ntfy Channel ────────────────────────────────────────────────────────────

send_ntfy() {
    local message="$1" title="${2:-}" priority="${3:-normal}" actions="${4:-}" tag="${5:-}" attach="${6:-}"

    # Get topic from env, then keychain
    local topic="${AUTOPILOT_NTFY_TOPIC:-}"
    if [[ -z "$topic" ]]; then
        topic=$("$KEYCHAIN" get ntfy topic 2>/dev/null) || {
            echo "Error: No ntfy topic configured." >&2
            echo "Run: notify.sh setup ntfy" >&2
            exit 1
        }
    fi

    # Build curl arguments
    local -a curl_args=( -s -o /dev/null -w "%{http_code}" )

    [[ -n "$title" ]] && curl_args+=(-H "Title: $title")
    [[ -n "$tag" ]] && curl_args+=(-H "Tags: $tag")

    # Map priority
    case "$priority" in
        min)    curl_args+=(-H "Priority: min") ;;
        low)    curl_args+=(-H "Priority: low") ;;
        normal) ;; # default — no header needed
        high)   curl_args+=(-H "Priority: high") ;;
        urgent) curl_args+=(-H "Priority: urgent") ;;
    esac

    # Actions — convert JSON array to ntfy header format
    if [[ -n "$actions" ]]; then
        local action_header
        action_header=$(python3 -c "
import json, sys
try:
    actions = json.loads(sys.argv[1])
    parts = []
    for a in actions:
        part = f\"{a.get('action', 'view')}, {a['label']}, {a.get('url', '')}\"
        if 'method' in a:
            part += f\", method={a['method']}\"
        parts.append(part)
    print('; '.join(parts))
except Exception as e:
    print(f'Error parsing actions: {e}', file=sys.stderr)
    sys.exit(1)
" "$actions" 2>/dev/null) || true
        [[ -n "${action_header:-}" ]] && curl_args+=(-H "Actions: $action_header")
    fi

    # Send — with file attachment or plain text
    local http_code
    if [[ -n "$attach" && -f "$attach" ]]; then
        http_code=$(curl "${curl_args[@]}" -T "$attach" -H "Filename: $(basename "$attach")" "ntfy.sh/$topic")
    else
        http_code=$(curl "${curl_args[@]}" -d "$message" "ntfy.sh/$topic")
    fi

    if [[ "$http_code" == "200" ]]; then
        echo -e "${GREEN}Sent via ntfy${NC}" >&2
        return 0
    else
        echo -e "${RED}Error: ntfy returned HTTP $http_code${NC}" >&2
        return 1
    fi
}

# ─── Telegram Channel ───────────────────────────────────────────────────────

send_telegram() {
    local message="$1" title="${2:-}" priority="${3:-normal}" actions="${4:-}"

    # Get credentials from keychain
    local token chat_id
    token=$("$KEYCHAIN" get telegram bot-token 2>/dev/null) || {
        echo "Error: No Telegram bot token configured." >&2
        echo "Run: notify.sh setup telegram" >&2
        exit 1
    }
    chat_id=$("$KEYCHAIN" get telegram chat-id 2>/dev/null) || {
        echo "Error: No Telegram chat ID configured." >&2
        echo "Send /start to your bot, then run: notify.sh setup telegram" >&2
        exit 1
    }

    # Format message with optional title
    local text="$message"
    if [[ -n "$title" ]]; then
        text="*${title}*"$'\n\n'"$message"
    fi

    # Priority emoji prefix
    case "$priority" in
        urgent) text="🚨 $text" ;;
        high)   text="⚠️ $text" ;;
        *)      ;; # no prefix for normal/low/min
    esac

    # Build JSON body with Python (safe escaping)
    local json_body
    json_body=$(python3 -c "
import json, sys

data = {
    'chat_id': sys.argv[1],
    'text': sys.argv[2],
    'parse_mode': 'Markdown'
}

# Build inline keyboard from actions JSON
actions_str = sys.argv[3] if len(sys.argv) > 3 else ''
if actions_str:
    try:
        actions = json.loads(actions_str)
        keyboard = []
        for a in actions:
            if a.get('url'):
                keyboard.append([{'text': a['label'], 'url': a['url']}])
            else:
                callback = a.get('callback', a['label'].lower().replace(' ', '_'))
                keyboard.append([{'text': a['label'], 'callback_data': callback}])
        data['reply_markup'] = {'inline_keyboard': keyboard}
    except Exception:
        pass  # skip invalid actions, send without keyboard

print(json.dumps(data))
" "$chat_id" "$text" "${actions:-}" 2>/dev/null)

    if [[ -z "$json_body" ]]; then
        echo "Error: Failed to build Telegram message JSON" >&2
        return 1
    fi

    # Send
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$json_body")

    # Clean credential from environment
    unset token 2>/dev/null || true

    if [[ "$http_code" == "200" ]]; then
        echo -e "${GREEN}Sent via Telegram${NC}" >&2
        return 0
    else
        echo -e "${RED}Error: Telegram returned HTTP $http_code${NC}" >&2
        return 1
    fi
}

# ─── Channel Dispatcher ─────────────────────────────────────────────────────

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
            *)
                echo "Error: Unknown option '$1'" >&2
                echo "Run 'notify.sh --help' for usage" >&2
                exit 1
                ;;
        esac
    done

    if [[ -z "$message" ]]; then
        echo "Error: --message is required" >&2
        exit 1
    fi

    case "$channel" in
        ntfy)     send_ntfy "$message" "$title" "$priority" "$actions" "$tag" "$attach" ;;
        telegram) send_telegram "$message" "$title" "$priority" "$actions" ;;
        *)
            echo "Error: Unknown channel '$channel'" >&2
            echo "Available channels: ntfy, telegram" >&2
            echo "Run 'notify.sh channels' to see configured channels" >&2
            exit 1
            ;;
    esac
}

# ─── Channel Status ──────────────────────────────────────────────────────────

cmd_channels() {
    echo -e "${BOLD}Configured notification channels:${NC}"
    echo ""

    # ntfy
    local ntfy_status
    if [[ -n "${AUTOPILOT_NTFY_TOPIC:-}" ]] || "$KEYCHAIN" has ntfy topic 2>/dev/null; then
        local topic
        topic="${AUTOPILOT_NTFY_TOPIC:-$("$KEYCHAIN" get ntfy topic 2>/dev/null)}"
        ntfy_status="${GREEN}configured${NC} (topic: $topic)"
    else
        ntfy_status="${YELLOW}not configured${NC} — run: notify.sh setup ntfy"
    fi
    echo -e "  ntfy       $ntfy_status"

    # telegram
    local tg_status
    if "$KEYCHAIN" has telegram bot-token 2>/dev/null && "$KEYCHAIN" has telegram chat-id 2>/dev/null; then
        tg_status="${GREEN}configured${NC}"
    elif "$KEYCHAIN" has telegram bot-token 2>/dev/null; then
        tg_status="${YELLOW}partially configured${NC} — bot token set, missing chat ID"
    else
        tg_status="${YELLOW}not configured${NC} — run: notify.sh setup telegram"
    fi
    echo -e "  telegram   $tg_status"

    echo ""
    echo -e "Default channel: ${BOLD}$DEFAULT_CHANNEL${NC}"
    echo "Set default: export AUTOPILOT_NOTIFY_CHANNEL=telegram"
}

# ─── Test ────────────────────────────────────────────────────────────────────

cmd_test() {
    local channel="${1:?Error: channel name required (ntfy or telegram)}"
    local ts
    ts=$(date "+%H:%M:%S")
    cmd_send \
        --channel "$channel" \
        --message "Test notification from Autopilot at $ts" \
        --title "Autopilot Test" \
        --tag "test_tube" \
        --priority "normal"
}

# ─── Setup Wizards ───────────────────────────────────────────────────────────

setup_ntfy() {
    echo -e "${BOLD}ntfy.sh Setup${NC}"
    echo "============="
    echo ""
    echo "ntfy is a free push notification service. No account required."
    echo ""
    echo "Step 1: Install the ntfy app on your phone"
    echo "  iOS:     https://apps.apple.com/app/ntfy/id1625396347"
    echo "  Android: https://play.google.com/store/apps/details?id=io.heckel.ntfy"
    echo ""
    echo "Step 2: Choose a unique topic name (acts as a private channel)."
    echo "  Make it hard to guess — anyone who knows it can send you notifications."
    echo ""
    read -rp "  Topic name: " topic

    if [[ -z "$topic" ]]; then
        echo "Error: Topic name cannot be empty" >&2
        exit 1
    fi

    echo "$topic" | "$KEYCHAIN" set ntfy topic
    echo ""
    echo -e "${GREEN}Topic saved to keychain.${NC}"
    echo ""
    echo "Step 3: In the ntfy app, tap '+' and subscribe to topic: $topic"
    echo ""
    read -rp "Press Enter when you've subscribed in the app..."
    echo ""
    echo "Step 4: Sending test notification..."
    cmd_test ntfy
    echo ""
    echo -e "${GREEN}Setup complete!${NC} Autopilot will now send notifications via ntfy."
}

setup_telegram() {
    echo -e "${BOLD}Telegram Bot Setup${NC}"
    echo "=================="
    echo ""
    echo "Step 1: Open Telegram and message @BotFather"
    echo "Step 2: Send: /newbot"
    echo "Step 3: Choose a name and username for your bot"
    echo "Step 4: Copy the bot token BotFather gives you"
    echo ""
    read -rp "  Bot token: " token

    if [[ -z "$token" ]]; then
        echo "Error: Bot token cannot be empty" >&2
        exit 1
    fi

    echo "$token" | "$KEYCHAIN" set telegram bot-token
    echo -e "${GREEN}Token saved to keychain.${NC}"
    echo ""
    echo "Step 5: Open your bot in Telegram and send it any message (e.g. /start)"
    echo ""
    read -rp "Press Enter after you've sent a message to the bot..."
    echo ""
    echo "Fetching your chat ID..."

    local chat_id
    chat_id=$(curl -s "https://api.telegram.org/bot${token}/getUpdates" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    results = data.get('result', [])
    if results:
        # Get the most recent message's chat ID
        for r in reversed(results):
            msg = r.get('message', r.get('edited_message', {}))
            if msg and 'chat' in msg:
                print(msg['chat']['id'])
                sys.exit(0)
    print('ERROR', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'Parse error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null) || {
        echo -e "${RED}Error: Could not detect chat ID.${NC}" >&2
        echo "Make sure you sent a message to the bot, then try again." >&2
        # Clean up token variable
        unset token 2>/dev/null || true
        exit 1
    }

    echo "$chat_id" | "$KEYCHAIN" set telegram chat-id
    echo -e "${GREEN}Chat ID saved to keychain.${NC} (ID: $chat_id)"
    echo ""

    # Clean up token variable
    unset token 2>/dev/null || true

    echo "Step 6: Sending test notification..."
    cmd_test telegram
    echo ""
    echo -e "${GREEN}Setup complete!${NC} Autopilot will now send notifications via Telegram."
    echo "To make Telegram your default: export AUTOPILOT_NOTIFY_CHANNEL=telegram"
}

cmd_setup() {
    local channel="${1:?Error: channel name required (ntfy or telegram)}"
    case "$channel" in
        ntfy)     setup_ntfy ;;
        telegram) setup_telegram ;;
        *)
            echo "Error: Unknown channel '$channel'" >&2
            echo "Available: ntfy, telegram" >&2
            exit 1
            ;;
    esac
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

case "${1:-}" in
    send)     shift; cmd_send "$@" ;;
    channels) cmd_channels ;;
    test)     shift; cmd_test "$@" ;;
    setup)    shift; cmd_setup "$@" ;;
    -h|--help|help) usage ;;
    *)
        if [[ -n "${1:-}" ]]; then
            echo "Error: Unknown command '$1'" >&2
            echo "Run 'notify.sh --help' for usage" >&2
            exit 1
        fi
        usage
        exit 1
        ;;
esac
