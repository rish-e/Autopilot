# Protocol: Browser Automation
# Loaded on-demand by Autopilot when needed. Not part of the core prompt.
# Location: ~/MCPs/autopilot/protocols/browser-automation.md

## Browser Automation Protocol

### Pre-Browser Check (Layer 3 — avoid unnecessary browser use)

Before opening the browser, ask: **can this task be done without it?**

DO NOT use Playwright for:
- **Encrypted/authenticated messaging** (WhatsApp, Slack, Telegram) — data is encrypted
- **QR code login flows** — can't scan QR codes programmatically
- **Tasks where a CLI/API exists** — always prefer CLI over browser
- **Native desktop apps** — use Computer Use instead (see Layer 0 below)

Use Playwright for:
- **Signing up for a new service** (no CLI can do this)
- **Getting API tokens from dashboards** (when no CLI auth flow exists)
- **Service-specific web operations** with no API/CLI equivalent

Use Computer Use for:
- **Native GUI apps** (Figma, Xcode, iOS Simulator, spreadsheets, proprietary tools)
- **Visual verification** (screenshot a running app, verify layout/output)
- **When Playwright selectors break** and the element can't be found
- **Cross-app workflows** that span multiple desktop applications

### Browser Automation Steps

When the browser IS needed:

1. **Check Chrome CDP is running**: `~/MCPs/autopilot/bin/chrome-debug.sh status`. If not running, **start it automatically**: `~/MCPs/autopilot/bin/chrome-debug.sh start`. Never ask the user to start it — just do it.
2. **Navigate** to the service dashboard URL
3. **Snapshot** the page (use `browser_snapshot`, NOT screenshots) to understand the current state
4. **Check login status** — look for dashboard elements vs. login form
5. If login needed:
   a. Retrieve email/password from keychain (service-specific or primary)
   b. Fill the login form using `browser_fill_form`
   c. Click the sign-in button
   d. Snapshot again to check result
6. **If 2FA/MFA appears**: STOP IMMEDIATELY. Tell the user exactly what's needed. Do not attempt to bypass.
7. **If CAPTCHA appears**: STOP. Tell the user.
8. **Take it step by step** — snapshot after every significant action to verify it succeeded
9. **Wait for page loads** — use `browser_wait_for` when navigating between pages
10. When done, capture any values needed (API keys, URLs, etc.) and store them in keychain

### Browser Error Recovery (Layer 2 — auto-retry)

If a browser operation fails with "Target page, context or browser has been closed", "Browser is already in use", or similar:

1. **Clean stale locks first**: run `~/MCPs/autopilot/bin/chrome-debug.sh clean-locks`. This removes Playwright/Chrome lock files that prevent browser reuse. NEVER use raw `rm` to delete lock files — always use this command.
2. **Try to recover**: call `browser_close` to clean up, then retry the navigation ONCE. Sometimes only the page/context dies, not the whole browser — a close + reopen can recover it.
3. **If retry fails**: DO NOT attempt to fix it further. Never run `kill`, `pkill`, `killall` on Playwright or MCP processes.
4. **Check if CLI can handle the task.** Most operations that use the browser have a CLI equivalent. Check if the required credential is already in keychain (`keychain.sh has {service} {key}`). If yes, switch to CLI and continue.
5. **If CLI works** → switch to CLI, complete the task, include a brief note: "Browser context error, completed via CLI instead."
6. **If browser is truly required** → restart Chrome automatically: `~/MCPs/autopilot/bin/chrome-debug.sh restart` (this also cleans locks). Then retry the operation once.
7. **If profile is corrupted** (errors about "Something went wrong when opening your profile" or database locked errors) → run `~/MCPs/autopilot/bin/chrome-debug.sh reset`. This wipes the profile and starts fresh. Login sessions will be lost but credentials are safe in keychain.
8. **Fall back to Computer Use** (if enabled and the task is visual/browser-based): Take a screenshot, use vision to identify the element, click by coordinates. This bypasses Playwright's selector system entirely.
9. **Only tell the user** if all recovery paths fail. At that point, recommend they restart Claude Code so the Playwright MCP reconnects with fresh config.

### Computer Use Protocol (Layer 0 — for native apps and vision fallback)

Computer Use is an optional capability. It is EXPENSIVE (~1,600 tokens per screenshot, 3-8 seconds per action) and LESS reliable (~66% success rate) than CLI/Playwright. Use it ONLY when:
- The task involves a **native GUI app** with no CLI/API/browser interface
- Playwright selectors **broke** and can't find an element (vision fallback)
- **Visual verification** is needed (confirm a UI renders correctly)
- A **cross-app workflow** requires interacting with multiple desktop apps

**Before using Computer Use, always check:**
```
Is Computer Use available? Look for screenshot/computer tool in available tools.
If not available → skip entirely, do not mention it, continue with other approaches.
```

**How to use Computer Use:**
1. Take a **screenshot** to see the current screen state
2. Analyze the screenshot — identify the element you need to interact with
3. **Click** at the coordinates of the target element
4. Take another **screenshot** to verify the action succeeded
5. Repeat until the task step is complete

**Cost awareness:**
- Every screenshot costs ~1,600 tokens. A 20-step GUI task costs ~$0.50+
- Always try CLI → API → Playwright FIRST. Computer Use is the last automated option before asking the user
- For repetitive tasks, use Computer Use ONCE to learn the flow, then build a Playwright playbook for next time

**When Computer Use and Playwright work together:**
- Playwright navigates to a page → element not found → screenshot via Computer Use → vision identifies coordinates → click → capture the new page state → update the playbook with corrected selectors
- This is the self-healing playbook pattern: Playwright tries, Computer Use fixes, playbook updates for next time

### Persistent Chrome Architecture

The browser runs as a separate Chrome process with Chrome DevTools Protocol (CDP) on port 9222. Playwright MCP connects to it rather than launching its own browser.

```
Chrome (persistent, background)  ←── CDP ──→  Playwright MCP  ←──→  Claude Code
      ↑                                              ↑
  Survives restarts                           Dies with session
  Login sessions persist                      Reconnects on start
  ~/MCPs/autopilot/browser-profile/
```

Managed via `~/MCPs/autopilot/bin/chrome-debug.sh start|stop|status|restart`.

**Key insight:** Once a credential is stored in Keychain, the browser is rarely needed again. The browser's primary job is first-time credential acquisition. Prioritize getting tokens into Keychain early in any workflow so subsequent operations are browser-independent.
