# Protocol: MCP Discovery
# Loaded on-demand by Autopilot when needed. Not part of the core prompt.
# Location: ~/MCPs/autopilot/protocols/mcp-discovery.md

## MCP Discovery Protocol

Before falling back to CLI or browser, check if an MCP server exists that would do a better job. MCPs are superior to CLIs because they provide structured tool calls, type safety, and direct integration — no shell parsing, no output scraping.

### Step 1: Check the whitelist

Read `~/MCPs/autopilot/config/trusted-mcps.yaml`. Check both `installed` and `whitelisted` sections.

- **Already installed?** → Use it. Done.
- **On the whitelist but not installed?** → Install it silently (Step 2). No need to ask the user.
- **Not on the whitelist?** → Search for it (Step 3).

### Step 2: Silent install (whitelisted MCPs)

For MCPs on the whitelist, install without asking:

```bash
# For npm packages:
claude mcp add {name} -- npx -y {package}

# If the MCP needs an API token, get it from keychain or acquire via browser first:
claude mcp add {name} -e API_KEY="$(~/MCPs/autopilot/bin/keychain.sh get {service} api-token)" -- npx -y {package}
```

After installing:
- Move the entry from `whitelisted` to `installed` in the YAML
- Note: The MCP takes effect next session. Fall back to CLI/browser for the current task.
- Notify the user: "Installed {name} MCP for future use. Using CLI for now."

### Step 3: Search for non-whitelisted MCPs

When a service isn't on the whitelist:

1. **Search**: WebSearch for `"{service} MCP server"` or `"{service} model context protocol"`
2. **Evaluate** what you find:
   - **Package name**: exact npm package or GitHub repo
   - **Publisher**: who made it? Official service provider? Anthropic? Unknown?
   - **Activity**: GitHub stars, last commit date, download count
   - **Capabilities**: what tools does it expose? Does it cover what we need?

3. **If found — present to user** with this format:

   ```
   Found MCP: {name}
   Package: {npm package or repo URL}
   Publisher: {who}
   Stars/Downloads: {numbers}
   Last updated: {date}

   Why: {specific reason this MCP is better than CLI/browser for the current task}
   Tools it provides: {list of key tools}

   Install command: claude mcp add {name} -- npx -y {package}

   Want me to install it?
   ```

4. **If user approves**: Install it AND add to the `whitelisted` section in trusted-mcps.yaml (so it's auto-approved forever).

5. **If user declines**: Add to the `candidates` section with a note, then fall back to CLI/browser.

6. **If nothing found**: Fall back to CLI/browser. Do not mention the search to the user — just proceed.

### When to trigger MCP discovery

Don't search for MCPs on every task. Only search when:
- You're about to use CLI/browser for a service you'll interact with **repeatedly** (not a one-off command)
- The service has complex operations that would benefit from structured tool calls (databases, payment providers, infrastructure)
- You're creating a new service registry file (natural time to check for MCPs too)

Do NOT search when:
- The task is a quick one-off (just use CLI)
- An MCP is already installed for this service
- You're in the middle of a time-sensitive operation (search later)

### Trust rules

- **Never install an MCP that isn't on npm or a verifiable GitHub repo**
- **Never install from a fork** when an official version exists
- **Package name is the identity** — `@supabase/mcp-server` is trusted because it's the `@supabase` org, not because it's called "supabase"
- **If the package name doesn't match the org you'd expect** (e.g., a Stripe MCP not from `@stripe`), treat it as untrusted and ask the user
