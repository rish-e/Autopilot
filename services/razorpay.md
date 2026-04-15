---
name: "Razorpay"
category: "payments"
credentials:
  - key: "key-id"
    description: "Razorpay Key ID (public)"
    obtain: "https://dashboard.razorpay.com/app/website-app-settings/api-keys"
    rotation_days: 180
  - key: "key-secret"
    description: "Razorpay Key Secret (private)"
    obtain: "Generated alongside Key ID — shown only once"
    rotation_days: 180
  - key: "webhook-secret"
    description: "Webhook signing secret"
    obtain: "Dashboard → Webhooks → Create/Edit webhook"
    rotation_days: 180
auth_pattern: "api-key-header"
2fa: "sms"
mcp: "none"
cli: "none"
rate_limits: "No published limits for standard plan"
related_services: []
decision_levels:
  read: 1
  create-link: 4
  refund: 4
  delete: 4
---

# Razorpay

## Credentials Required

| Key | Description | How to Obtain |
|-----|-------------|---------------|
| `key-id` | Razorpay Key ID (public) | https://dashboard.razorpay.com/app/website-app-settings/api-keys → Generate Key |
| `key-secret` | Razorpay Key Secret (private) | Generated alongside Key ID — shown only once |
| `webhook-secret` | Webhook signing secret | Dashboard → Webhooks → Create/Edit webhook |

## CLI Tool

- **Name**: No official CLI
- **API-based**: Razorpay is REST API-only. Use `curl` or the Node.js/Python SDK.
- **SDK Install**:
  ```bash
  npm install razorpay    # Node.js
  pip install razorpay    # Python
  ```

## Common Operations

### Verify API Keys
```bash
curl -s -u "$(~/MCPs/autopilot/bin/keychain.sh get razorpay key-id):$(~/MCPs/autopilot/bin/keychain.sh get razorpay key-secret)" \
  https://api.razorpay.com/v1/payments?count=1 | head -c 200
```

### Create Payment Link
```bash
# DECISION: Level 2 — Flag cost (involves real money)
curl -s -X POST https://api.razorpay.com/v1/payment_links \
  -u "$(~/MCPs/autopilot/bin/keychain.sh get razorpay key-id):$(~/MCPs/autopilot/bin/keychain.sh get razorpay key-secret)" \
  -H "Content-Type: application/json" \
  -d '{
    "amount": 50000,
    "currency": "INR",
    "description": "Payment for service",
    "customer": { "name": "Customer", "email": "customer@example.com" }
  }'
```

### List Payments
```bash
curl -s -u "$(~/MCPs/autopilot/bin/keychain.sh get razorpay key-id):$(~/MCPs/autopilot/bin/keychain.sh get razorpay key-secret)" \
  "https://api.razorpay.com/v1/payments?count=10" | jq .
```

### Create Subscription Plan
```bash
# DECISION: Level 2 — Flag cost (defines pricing)
curl -s -X POST https://api.razorpay.com/v1/plans \
  -u "$(~/MCPs/autopilot/bin/keychain.sh get razorpay key-id):$(~/MCPs/autopilot/bin/keychain.sh get razorpay key-secret)" \
  -H "Content-Type: application/json" \
  -d '{
    "period": "monthly",
    "interval": 1,
    "item": { "name": "Plan Name", "amount": 50000, "currency": "INR" }
  }'
```

### Fetch Payment Details
```bash
curl -s -u "$(~/MCPs/autopilot/bin/keychain.sh get razorpay key-id):$(~/MCPs/autopilot/bin/keychain.sh get razorpay key-secret)" \
  "https://api.razorpay.com/v1/payments/{payment_id}" | jq .
```

### Verify Webhook Signature (in code)
```javascript
const crypto = require('crypto');
const secret = process.env.RAZORPAY_WEBHOOK_SECRET;
const signature = crypto.createHmac('sha256', secret)
  .update(requestBody)
  .digest('hex');
// Compare with X-Razorpay-Signature header
```

## Browser Fallback

Razorpay dashboard is needed for initial setup and some configuration:

1. Navigate to `https://dashboard.razorpay.com`
2. Check if logged in (look for dashboard overview)
3. If login needed:
   a. Get email: `~/MCPs/autopilot/bin/keychain.sh get razorpay email`
   b. Fill email, click Continue
   c. Enter password or OTP
4. If OTP/2FA: **ESCALATE to user** (Razorpay uses mobile OTP)

### Generate API Keys via Browser
1. Navigate to `https://dashboard.razorpay.com/app/website-app-settings/api-keys`
2. Click "Generate Key" (or "Regenerate" if exists)
3. **WARNING**: Regenerating invalidates the old key
4. Copy Key ID and Key Secret (secret shown only once!)
5. Store both:
   ```
   echo "KEY_ID" | ~/MCPs/autopilot/bin/keychain.sh set razorpay key-id
   echo "KEY_SECRET" | ~/MCPs/autopilot/bin/keychain.sh set razorpay key-secret
   ```

### Configure Webhook via Browser
1. Navigate to `https://dashboard.razorpay.com/app/website-app-settings/webhooks`
2. Click "Add New Webhook"
3. Enter webhook URL
4. Select events (payment.captured, subscription.activated, etc.)
5. Set secret and store: `echo "SECRET" | ~/MCPs/autopilot/bin/keychain.sh set razorpay webhook-secret`

## 2FA Handling

- **Type**: Mobile OTP (SMS to registered phone)
- **Action**: ESCALATE to user — Razorpay always sends OTP for dashboard login

## MCP Integration

- **Available**: No
- **Notes**: No CLI or MCP exists. Use curl for API operations, browser for dashboard configuration.

## Notes

- Razorpay uses test mode vs live mode — keys are different for each
- Store test keys separately: `razorpay-test/key-id`, `razorpay-test/key-secret`
- Amount is always in **paise** (smallest currency unit): INR 500 = 50000 paise
- Razorpay is India-specific — supports UPI, cards, netbanking, wallets
- Dashboard login always requires OTP to registered mobile — browser automation will need user for this step
- For RenderKit: integrate server-side using the Node.js SDK, handle webhooks for payment confirmation
