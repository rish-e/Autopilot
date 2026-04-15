---
name: "Alpaca"
category: "trading"
credentials:
  - key: "api-key"
    description: "Alpaca API Key ID"
    obtain: "https://app.alpaca.markets/paper/dashboard/overview → API Keys"
    rotation_days: 180
  - key: "api-secret"
    description: "Alpaca API Secret Key"
    obtain: "Generated alongside API Key — shown only once"
    rotation_days: 180
auth_pattern: "api-key-header"
2fa: "none"
mcp: "none"
cli: "none"
rate_limits: "200 requests/min"
related_services: ["telegram"]
decision_levels:
  read: 1
  paper-trade: 2
  live-trade: 4
  close-all: 4
---

# Alpaca

## Credentials Required

| Key | Description | How to Obtain | Rotation |
|-----|-------------|---------------|----------|
| `api-key` | Alpaca API Key ID | Dashboard → API Keys → Generate | 180 days |
| `api-secret` | Alpaca API Secret | Generated with Key ID — shown once | 180 days |

## CLI Tool

- **Name**: No official CLI
- **API-based**: REST API + WebSocket streaming. Use `curl` or Python SDK.
- **SDK Install**:
  ```bash
  pip install alpaca-py   # Python (official)
  ```

## Common Operations

### Check Account Status
```bash
# Decision Level: L1 — read-only
curl -s -H "APCA-API-KEY-ID: $(~/MCPs/autopilot/bin/keychain.sh get alpaca api-key)" \
  -H "APCA-API-SECRET-KEY: $(~/MCPs/autopilot/bin/keychain.sh get alpaca api-secret)" \
  https://paper-api.alpaca.markets/v2/account | jq '{status, buying_power, equity, cash}'
```

### List Open Positions
```bash
# Decision Level: L1 — read-only
curl -s -H "APCA-API-KEY-ID: $(~/MCPs/autopilot/bin/keychain.sh get alpaca api-key)" \
  -H "APCA-API-SECRET-KEY: $(~/MCPs/autopilot/bin/keychain.sh get alpaca api-secret)" \
  https://paper-api.alpaca.markets/v2/positions | jq '.[] | {symbol, qty, avg_entry_price, unrealized_pl}'
```

### List Recent Orders
```bash
# Decision Level: L1 — read-only
curl -s -H "APCA-API-KEY-ID: $(~/MCPs/autopilot/bin/keychain.sh get alpaca api-key)" \
  -H "APCA-API-SECRET-KEY: $(~/MCPs/autopilot/bin/keychain.sh get alpaca api-secret)" \
  "https://paper-api.alpaca.markets/v2/orders?status=all&limit=10" | jq '.[] | {symbol, side, qty, status, filled_avg_price}'
```

### Submit Order (Paper)
```bash
# Decision Level: L2 — paper trading
curl -s -X POST -H "APCA-API-KEY-ID: $(~/MCPs/autopilot/bin/keychain.sh get alpaca api-key)" \
  -H "APCA-API-SECRET-KEY: $(~/MCPs/autopilot/bin/keychain.sh get alpaca api-secret)" \
  -H "Content-Type: application/json" \
  https://paper-api.alpaca.markets/v2/orders \
  -d '{"symbol":"SPY","qty":"1","side":"buy","type":"market","time_in_force":"day"}'
```

### Cancel All Orders
```bash
# Decision Level: L1 — Just do it (paper trading)
curl -s -X DELETE -H "APCA-API-KEY-ID: $(~/MCPs/autopilot/bin/keychain.sh get alpaca api-key)" \
  -H "APCA-API-SECRET-KEY: $(~/MCPs/autopilot/bin/keychain.sh get alpaca api-secret)" \
  https://paper-api.alpaca.markets/v2/orders
```

### Get Options Chain (via market data API)
```bash
# Decision Level: L1 — read-only
curl -s -H "APCA-API-KEY-ID: $(~/MCPs/autopilot/bin/keychain.sh get alpaca api-key)" \
  -H "APCA-API-SECRET-KEY: $(~/MCPs/autopilot/bin/keychain.sh get alpaca api-secret)" \
  "https://data.alpaca.markets/v1beta1/options/snapshots?symbols=SPY250404C00570000&feed=indicative" | jq .
```

## Browser Fallback

For dashboard-only operations (account verification, funding):

1. Navigate to `https://app.alpaca.markets`
2. Check if logged in (look for dashboard/portfolio view)
3. If login needed:
   a. Get email: `~/MCPs/autopilot/bin/keychain.sh get alpaca email`
   b. Fill email, fill password
   c. Click "Sign in"
4. If 2FA: **ESCALATE to user**

### Generate API Keys via Browser
1. Navigate to `https://app.alpaca.markets/paper/dashboard/overview`
2. Click "API Keys" in sidebar
3. Click "Generate New Keys"
4. Copy Key ID and Secret Key (secret shown only once!)
5. Store:
   ```
   echo "KEY_ID" | ~/MCPs/autopilot/bin/keychain.sh set alpaca api-key
   echo "SECRET" | ~/MCPs/autopilot/bin/keychain.sh set alpaca api-secret
   ```

## 2FA Handling

- **Type**: None required by default (email verification on new devices)
- **Action**: Generally no escalation needed

## MCP Integration

- **Available**: No
- **Notes**: No CLI or MCP. All operations via REST API (curl) or Python `alpaca-py` SDK.

## Notes

- **Paper vs Live**: Different base URLs — `paper-api.alpaca.markets` vs `api.alpaca.markets`
- Paper trading has no real money risk — L1, just do it
- Live trading is L2 — flag the trade, but execute it
- Rate limit: 200 requests/minute — pace bulk operations
- Options trading requires separate enablement on account
- WebSocket streaming available at `wss://stream.data.alpaca.markets/v2/iex` for real-time data
- Scout bot (~/Claude/scout) already integrates with Alpaca for options scalping
- Market hours: 9:30 AM - 4:00 PM ET (extended hours: 4:00 AM - 8:00 PM ET)
