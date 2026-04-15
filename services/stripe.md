---
name: "Stripe"
category: "payments"
credentials:
  - key: "secret-key"
    description: "Stripe Secret Key (sk_live_* or sk_test_*)"
    obtain: "https://dashboard.stripe.com/apikeys"
    rotation_days: 180
  - key: "publishable-key"
    description: "Stripe Publishable Key (pk_live_* or pk_test_*)"
    obtain: "https://dashboard.stripe.com/apikeys"
    rotation_days: null
  - key: "webhook-secret"
    description: "Webhook signing secret (whsec_*)"
    obtain: "https://dashboard.stripe.com/webhooks → endpoint → Signing secret"
    rotation_days: 180
auth_pattern: "api-key-header"
2fa: "authenticator"
mcp: "none"
cli: "stripe"
rate_limits: "100 reads/sec, 100 writes/sec per key"
related_services: ["vercel"]
decision_levels:
  read: 1
  test-mode: 2
  live-charge: 4
  refund: 4
---

# Stripe

## Credentials Required

| Key | Description | How to Obtain | Rotation |
|-----|-------------|---------------|----------|
| `secret-key` | Stripe Secret Key | https://dashboard.stripe.com/apikeys | 180 days |
| `publishable-key` | Stripe Publishable Key | Same page | N/A (public) |
| `webhook-secret` | Webhook signing secret | Dashboard → Webhooks → endpoint | 180 days |

## CLI Tool

- **Name**: `stripe`
- **Install**: `brew install stripe/stripe-cli/stripe`
- **Auth setup**:
  ```bash
  stripe login --api-key "$(~/MCPs/autopilot/bin/keychain.sh get stripe secret-key)"
  ```
- **Verify**: `stripe config --list`

## Common Operations

### List Recent Payments
```bash
# Decision Level: L1 — read-only
stripe payments list --limit 10 --api-key "$(~/MCPs/autopilot/bin/keychain.sh get stripe secret-key)"
```

### Create a Product + Price
```bash
# Decision Level: L1 — test mode; L2 — live mode (flag cost)
stripe products create --name "Product Name" \
  --api-key "$(~/MCPs/autopilot/bin/keychain.sh get stripe secret-key)"

stripe prices create --product prod_XXX --unit-amount 2999 --currency usd \
  --recurring[interval]=month \
  --api-key "$(~/MCPs/autopilot/bin/keychain.sh get stripe secret-key)"
```

### Create a Checkout Session (via curl)
```bash
# Decision Level: L1 — test mode; L2 — live mode (flag cost)
curl -s https://api.stripe.com/v1/checkout/sessions \
  -u "$(~/MCPs/autopilot/bin/keychain.sh get stripe secret-key):" \
  -d "line_items[0][price]=price_XXX" \
  -d "line_items[0][quantity]=1" \
  -d "mode=subscription" \
  -d "success_url=https://example.com/success" \
  -d "cancel_url=https://example.com/cancel" | jq .url
```

### Listen for Webhooks Locally
```bash
# Forwards webhook events to local server
stripe listen --forward-to localhost:3000/api/webhooks/stripe \
  --api-key "$(~/MCPs/autopilot/bin/keychain.sh get stripe secret-key)"
```

### Create a Customer
```bash
stripe customers create --email "customer@example.com" \
  --api-key "$(~/MCPs/autopilot/bin/keychain.sh get stripe secret-key)"
```

### Issue a Refund
```bash
# Decision Level: L2 — Flag cost (involves real money)
stripe refunds create --payment-intent pi_XXX \
  --api-key "$(~/MCPs/autopilot/bin/keychain.sh get stripe secret-key)"
```

## Browser Fallback

For dashboard-only operations (onboarding, disputes, Connect setup):

1. Navigate to `https://dashboard.stripe.com`
2. Check if logged in (look for dashboard overview)
3. If login needed:
   a. Get email: `~/MCPs/autopilot/bin/keychain.sh get stripe email`
   b. Fill email, fill password
   c. Click "Sign in"
4. If 2FA: **ESCALATE to user** (Stripe uses authenticator app)

### Get API Keys via Browser
1. Navigate to `https://dashboard.stripe.com/apikeys`
2. Copy Secret Key (click "Reveal test/live key")
3. Store: `echo "sk_..." | ~/MCPs/autopilot/bin/keychain.sh set stripe secret-key`

## 2FA Handling

- **Type**: Authenticator app (required for live mode access)
- **Action**: ESCALATE to user

## MCP Integration

- **Available**: No official MCP
- **Notes**: The `stripe` CLI is comprehensive. Use curl for operations the CLI doesn't support.

## Notes

- **Test vs Live mode**: Keys prefixed `sk_test_` / `sk_live_` — always verify which mode you're in
- Store test keys separately: `stripe-test/secret-key`
- Amount is in **cents**: $29.99 = 2999
- Stripe CLI can trigger test events: `stripe trigger payment_intent.succeeded`
- Webhook signature verification is critical for production — always use the webhook secret
- For SaaS billing: use Stripe Billing with Products/Prices/Subscriptions, not one-off charges
