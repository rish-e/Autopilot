---
name: "Telegram"
category: "messaging"
credentials:
  - key: "phone"
    description: "Phone number for Telegram Web login (with country code, e.g. +1234567890)"
    obtain: "Ask user once, store forever"
    rotation_days: null
  - key: "bot-token"
    description: "Telegram Bot API token"
    obtain: "Autopilot creates via BotFather on Telegram Web (Playwright)"
    rotation_days: null
  - key: "chat-id"
    description: "Target chat/group ID for notifications"
    obtain: "Message bot, then GET https://api.telegram.org/bot{token}/getUpdates"
    rotation_days: null
auth_pattern: "api-key-header"
2fa: "none"
mcp: "none"
cli: "none"
rate_limits: "30 messages/sec to different chats, 1 msg/sec to same chat, 20 msgs/min to same group"
related_services: ["alpaca"]
decision_levels:
  read: 1
  send-message: 2
  send-to-new-chat: 3
---

# Telegram

## Credentials Required

| Key | Description | How to Obtain | Rotation |
|-----|-------------|---------------|----------|
| `bot-token` | Telegram Bot API token | @BotFather → /newbot | Never (revoke via /revoke) |
| `chat-id` | Target chat/group ID | getUpdates API after messaging bot | N/A |

## CLI Tool

- **Name**: No official CLI
- **API-based**: REST API. Use `curl` for all operations.
- **Base URL**: `https://api.telegram.org/bot{TOKEN}/{method}`

## Common Operations

### Send Message
```bash
# Decision Level: L2 — notify user (sending to known chat)
curl -s -X POST "https://api.telegram.org/bot$(~/MCPs/autopilot/bin/keychain.sh get telegram bot-token)/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{\"chat_id\": \"$(~/MCPs/autopilot/bin/keychain.sh get telegram chat-id)\", \"text\": \"Message here\", \"parse_mode\": \"HTML\"}"
```

### Send Message with Markdown
```bash
curl -s -X POST "https://api.telegram.org/bot$(~/MCPs/autopilot/bin/keychain.sh get telegram bot-token)/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{\"chat_id\": \"$(~/MCPs/autopilot/bin/keychain.sh get telegram chat-id)\", \"text\": \"*Bold* _italic_ \`code\`\", \"parse_mode\": \"MarkdownV2\"}"
```

### Get Bot Info
```bash
# Decision Level: L1 — read-only
curl -s "https://api.telegram.org/bot$(~/MCPs/autopilot/bin/keychain.sh get telegram bot-token)/getMe" | jq .
```

### Get Recent Updates (find chat IDs)
```bash
# Decision Level: L1 — read-only
curl -s "https://api.telegram.org/bot$(~/MCPs/autopilot/bin/keychain.sh get telegram bot-token)/getUpdates" | jq '.result[-3:] | .[].message.chat'
```

### Send Document/File
```bash
# Decision Level: L2
curl -s -X POST "https://api.telegram.org/bot$(~/MCPs/autopilot/bin/keychain.sh get telegram bot-token)/sendDocument" \
  -F "chat_id=$(~/MCPs/autopilot/bin/keychain.sh get telegram chat-id)" \
  -F "document=@/path/to/file.pdf"
```

### Send Photo
```bash
# Decision Level: L2
curl -s -X POST "https://api.telegram.org/bot$(~/MCPs/autopilot/bin/keychain.sh get telegram bot-token)/sendPhoto" \
  -F "chat_id=$(~/MCPs/autopilot/bin/keychain.sh get telegram chat-id)" \
  -F "photo=@/path/to/image.png" \
  -F "caption=Image description"
```

### Set Webhook (for bot receiving messages)
```bash
# Decision Level: L3 — changes bot behavior
curl -s -X POST "https://api.telegram.org/bot$(~/MCPs/autopilot/bin/keychain.sh get telegram bot-token)/setWebhook" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://your-domain.com/api/telegram/webhook"}'
```

## Browser Fallback

Generally not needed — all Telegram Bot API operations work via curl.

### BotFather Operations (creating/managing bots via Telegram Web)

BotFather operations MUST be done via Playwright on Telegram Web — do NOT escalate to user.

**Flow:**
1. Start Chrome CDP: `~/MCPs/autopilot/bin/chrome-debug.sh start`
2. Navigate to `https://web.telegram.org/a/`
3. Snapshot — check if logged in. If login needed:
   a. Retrieve phone number from keychain (`keychain.sh get telegram phone`)
   b. Enter phone, request code → **ESCALATE only for the SMS/Telegram code** (L3)
   c. After user provides code, complete login
4. Search for `@BotFather` in the chat search bar
5. Open the BotFather chat
6. Send `/newbot`
7. Snapshot — BotFather will ask for a display name → type the bot name (e.g., "SiteViz QA Bot")
8. Snapshot — BotFather will ask for a username → type the bot username (e.g., "siteviz_qa_bot")
9. Snapshot — BotFather returns the token (format: `123456789:ABCdef...`)
10. Extract the token from the message
11. Store: `echo "TOKEN" | ~/MCPs/autopilot/bin/keychain.sh set telegram bot-token --project {project}`
12. Continue with remaining setup (webhooks, chat ID, etc.)

**Escalation**: Only escalate for SMS/Telegram login code (Step 3b) or 2FA. Everything else is autonomous.
**Decision Level**: L2 — creating a bot is a non-destructive, free operation.

## 2FA Handling

- **Type**: None for Bot API (token-based)
- **Action**: Not applicable — bot tokens don't require 2FA

## MCP Integration

- **Available**: No
- **Notes**: No MCP exists. All operations via REST API with curl. The API is simple and comprehensive.

## Notes

- Bot tokens look like `123456789:ABCdefGhIJKlmNOPQrsTUVwxYZ` — never expose
- Rate limits are per-bot: 30 msgs/sec to different chats, 1/sec to same chat
- MarkdownV2 requires escaping special chars: `_*[]()~>#+-=|{}.!`
- HTML parse mode is often easier: `<b>bold</b> <i>italic</i> <code>mono</code>`
- Messages over 4096 chars must be split
- Scout bot uses Telegram for trade notifications — chat-id is already stored
- For inline keyboards / interactive bots, use `reply_markup` parameter with JSON
- Group chat IDs are negative numbers (e.g., `-1001234567890`)
