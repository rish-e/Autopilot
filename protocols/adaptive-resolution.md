# Protocol: Adaptive Resolution
# Loaded on-demand by Autopilot when needed. Not part of the core prompt.
# Location: ~/MCPs/autopilot/protocols/adaptive-resolution.md

### Adaptive Resolution Engine

**This is the core of Autopilot.** When ANY obstacle is encountered during execution — missing credential, failed command, unknown service, broken playbook — the agent MUST attempt to resolve it automatically before ever asking the user. The user is the LAST resort, not the first.

#### Credential Resolution Cascade

When a credential is needed for any service, execute this cascade IN ORDER. Do NOT skip steps. Do NOT ask the user until step 7.

```
1. KEYCHAIN CHECK
   ~/MCPs/autopilot/bin/keychain.sh has {service} api-token 2>/dev/null
   → Found? Use it. Done.

2. HARVEST (scan local machine for existing tokens)
   ~/MCPs/autopilot/bin/harvest.sh {service}
   → Token discovered and imported? Use it. Done.
   → This finds tokens in CLI config files, OS keychains, and MCP configs.
   → It checks: Vercel (~/.../com.vercel.cli/auth.json), GitHub (gh auth token),
     Supabase (~/.config/supabase/), npm (~/.npmrc), Docker (~/.docker/),
     Cloudflare (~/.wrangler/), and common patterns for any unknown service.

3. CLI AUTH FLOW (if the service has a CLI with a login command)
   Check service registry for CLI auth command.
   Example: `gh auth login --web`, `supabase login`, `vercel login`
   → Run it. If it succeeds, harvest the resulting token into keychain.
   → Some CLI logins open a browser — that's fine, let it happen.

4. BROWSER SESSION (check if already logged in)
   Ensure Chrome CDP is running: ~/MCPs/autopilot/bin/chrome-debug.sh start
   Navigate to the service dashboard URL.
   browser_snapshot → check if already logged in (look for dashboard elements).
   → Already logged in? Skip to step 6 (generate token).

5. BROWSER LOGIN (use credentials to log in)
   a. Check keychain for service-specific email/password
   b. If not found, use primary credentials (keychain: primary/email, primary/password)
   c. If no primary credentials exist → this is the ONE-TIME setup:
      Ask the user: "I need a primary email and password for signing up to services.
      I'll store these encrypted in your macOS Keychain."
      Store them. Never ask again.
   d. Fill the login form via browser_type, click submit
   e. If 2FA appears:
      - Check: ~/MCPs/autopilot/bin/totp.sh has {service}
      - If TOTP seed exists: CODE=$(totp.sh generate {service}) → enter it
      - If no seed: ESCALATE to user — "Enter the 6-digit code from your authenticator"
   f. If email verification needed:
      - Use verify-email.sh to search Gmail, extract code/link, complete verification
   g. browser_snapshot → verify login succeeded

6. GENERATE TOKEN (via browser dashboard)
   a. Check for playbook: python3 ~/MCPs/autopilot/lib/playbook.py has {service} get_api_key
   b. If playbook exists: follow it step by step
   c. If no playbook: generate one, navigate to API keys page, create token
   d. Capture token value from browser_snapshot
   e. Store in keychain: echo "$TOKEN" | keychain.sh set {service} api-token
   f. Unset variable immediately

7. ASK USER (absolute last resort)
   Only reach here if ALL of the above failed. When asking, provide:
   - What you tried (every step above)
   - What specifically failed
   - Exactly what you need from them
   - The exact command to store it: echo "TOKEN" | keychain.sh set {service} api-token
```

**After acquiring ANY credential through ANY step, ALWAYS store it in keychain.** This ensures step 1 succeeds next time.

#### Command Resolution Cascade

When a command fails during execution:

```
1. CHECK ERROR MEMORY
   python3 -c "
   import sys; sys.path.insert(0, '$HOME/MCPs/autopilot/lib')
   from memory import AutopilotMemory
   mem = AutopilotMemory()
   match = mem.check_known_error('{error_message}', service='{service}')
   if match: print(f'Known fix: {match[\"resolution\"]}')
   mem.close()
   "
   → Known fix exists? Apply it. Retry the command.

2. DIAGNOSE THE ERROR
   Read the error message. Common categories:
   - "not found" / "command not found" → install the CLI tool
   - "unauthorized" / "401" / "403" → credential expired or missing → run Credential Cascade
   - "not found" (HTTP 404) → wrong URL or resource doesn't exist
   - "rate limit" / "429" → wait and retry
   - "timeout" → retry with longer timeout
   - "permission denied" → check file permissions or credential scope
   - Configuration error → check service registry for correct flags/options

3. TRY ALTERNATIVE APPROACH
   - CLI failed? Try the API directly (curl with keychain token)
   - API failed? Try through MCP if available
   - MCP failed? Try browser automation (playbook)
   - Wrong version/flags? Check docs via WebSearch or context7 MCP

4. RECORD THE ERROR AND FIX
   After finding what works, record it so it never happens again:
   python3 -c "
   import sys; sys.path.insert(0, '$HOME/MCPs/autopilot/lib')
   from memory import AutopilotMemory
   mem = AutopilotMemory()
   mem.log_error('{error_type}', '{error_pattern}', service='{service}',
       resolution='{what_fixed_it}', resolution_type='auto')
   mem.close()
   "

5. RETRY with the fix applied

6. IF SECOND FAILURE → report to user with full context
```

#### Service Resolution Cascade

When encountering an unknown service:

```
1. CHECK CACHE
   - File exists? ~/MCPs/autopilot/services/{service}.md → use it
   - In memory DB? python3 lib/memory.py services → check for cached metadata

2. RESEARCH (automatic, inline, no asking)
   a. WebSearch: "{service} CLI documentation", "{service} API authentication"
   b. WebSearch: "{service} MCP server npm"
   c. WebFetch official docs
   d. Identify: auth method, CLI tool, dangerous operations, dashboard URLs, MCP availability

3. CREATE SERVICE REGISTRY
   a. Read template: ~/MCPs/autopilot/services/_template.md
   b. Fill in all fields from research
   c. Save to ~/MCPs/autopilot/services/{service}.md

4. INSTALL CLI (if one exists)
   which {tool} || brew install {tool} || npm install -g {tool}

5. ADD GUARDIAN RULES
   For each dangerous operation identified in research:
   echo 'CATEGORY:::pattern:::reason' >> ~/MCPs/autopilot/config/guardian-custom-rules.txt

6. GENERATE PLAYBOOK SKELETONS
   python3 ~/MCPs/autopilot/lib/playbook.py generate {service} signup
   python3 ~/MCPs/autopilot/lib/playbook.py generate {service} login
   python3 ~/MCPs/autopilot/lib/playbook.py generate {service} get_api_key

7. CACHE IN MEMORY DB
   python3 -c "
   import sys; sys.path.insert(0, '$HOME/MCPs/autopilot/lib')
   from memory import AutopilotMemory
   mem = AutopilotMemory()
   mem.cache_service('{service}', cli_tool='{tool}', category='{category}',
       website='{url}', has_mcp={0_or_1}, has_registry=1, has_playbook=1)
   mem.close()
   "

8. CHECK FOR MCP
   If an MCP was found in step 2b:
   - Evaluate trust (official org? stars? downloads?)
   - Score > 70 → install silently: claude mcp add {name} -- npx -y {package}
   - Score 40-70 → present to user for approval
   - Add to trusted-mcps.yaml accordingly

9. CONTINUE with the original task using the newly created registry
```

This entire sequence happens INLINE in under 60 seconds. The user sees "Researching {service}..." and then the task continues.

### Pre-Flight Checks

Before presenting a plan (Flow B) or starting execution (Flow A), silently run ALL of these:

1. **Harvest credentials**: Run `~/MCPs/autopilot/bin/harvest.sh 2>/dev/null` to auto-discover any tokens already on the machine. Do this ONCE at the start of every session.

2. **Check procedural memory**: Before planning, search for similar past tasks:
   ```
   python3 -c "
   import sys; sys.path.insert(0, '$HOME/MCPs/autopilot/lib')
   from memory import AutopilotMemory
   mem = AutopilotMemory()
   results = mem.find_procedure(task_desc='{task}')
   for r in results:
       print(f'{r[\"name\"]}: {r[\"success_count\"]} successes, rate={r.get(\"success_rate\",0):.0%}')
   mem.close()
   "
   ```
   If a high-confidence match exists (success_rate > 80%, runs > 2), use that procedure as the plan instead of reasoning from scratch.

3. **Resolve all services**: For every service the task involves, run the Service Resolution Cascade. Ensure registry, CLI, and playbooks exist BEFORE presenting the plan.

4. **Resolve all credentials**: For every service, run the Credential Resolution Cascade through at least steps 1-2 (keychain check + harvest). If a credential is missing and can be obtained automatically (steps 3-6), include it as a plan step. If it requires user input (2FA setup, CAPTCHA), flag it upfront.

5. **Check error memory**: For every service involved, check if there are known error patterns:
   ```
   python3 -c "
   import sys; sys.path.insert(0, '$HOME/MCPs/autopilot/lib')
   from memory import AutopilotMemory
   mem = AutopilotMemory()
   for svc in ['{service1}', '{service2}']:
       errors = mem.db.execute('SELECT pattern, resolution FROM errors WHERE service=? AND resolution IS NOT NULL', (svc,)).fetchall()
       for e in errors:
           print(f'  Known issue with {svc}: {e[0]} → fix: {e[1]}')
   mem.close()
   "
   ```
   Apply known fixes preemptively in the plan.

6. **Flag genuine blockers upfront.** Only flag steps that require human input AFTER the resolution cascades have been exhausted. If the credential can be auto-acquired, don't flag it.

### Post-Task Recording

After EVERY task completion (success or failure), record what happened:

1. **Record procedure** (on success):
   ```
   python3 -c "
   import sys, json; sys.path.insert(0, '$HOME/MCPs/autopilot/lib')
   from memory import AutopilotMemory
   mem = AutopilotMemory()
   mem.save_procedure('{name}', '{task_description}',
       {steps_as_list}, services={services_list})
   mem.close()
   "
   ```

2. **Record errors** (on failure):
   ```
   python3 -c "
   import sys; sys.path.insert(0, '$HOME/MCPs/autopilot/lib')
   from memory import AutopilotMemory
   mem = AutopilotMemory()
   mem.log_error('{error_type}', '{pattern}', service='{service}',
       resolution='{what_fixed_it_if_found}')
   mem.close()
   "
   ```

3. **Update service metadata** (always):
   If you learned something new about a service during execution (new CLI flags, different auth method, changed dashboard URL), update the service registry file and memory DB.

4. **Cache playbook updates** (if browser automation was used):
   If selectors changed or new steps were needed, update the playbook YAML so it works next time.
