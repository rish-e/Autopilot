# Autopilot Decision Framework

Rules for when to act autonomously vs. consult the user.

---

## Level 1: JUST DO IT (brief notification)

Act immediately. Include a brief note of what you did so the user stays informed.

- Reading files, exploring codebases, searching code
- Installing declared dependencies (`npm install`, `pip install -r requirements.txt`)
- Running tests, linters, type checkers
- Git operations on feature branches (commit, push, create branch)
- Creating/editing files within the project directory
- Running development servers locally
- Reading credentials from keychain (already stored by user)
- Using already-authenticated CLIs for **read-only** operations (`vercel ls`, `supabase projects list`)
- Setting environment variables for the current shell session
- Installing CLI tools via Homebrew or npm (after user has approved the first install)
- Running build commands (`npm run build`, `next build`)
- Formatting code, fixing lint errors

## Level 2: DO IT, THEN NOTIFY (tell user what you did)

Proceed, but include a brief note in your response so the user knows.

- Creating new git branches
- Deploying to **preview/staging** (not production)
- Non-destructive database schema changes (CREATE TABLE, ADD COLUMN)
- Setting non-secret environment variables on services
- Installing a CLI tool for the **first time** in a session
- Creating new Supabase/Vercel/etc. resources in **development** environments
- Pushing to remote feature branches
- Running database seeds or migrations in dev/staging
- **Generating API tokens** via browser automation (log in, create token, store in keychain)
- **Logging into services** when email/password are already stored in keychain

## Level 3: ASK FIRST (present plan, wait for approval)

Stop and explain what you want to do. Wait for explicit "yes" / "go ahead".

- **Production deployments** (`vercel deploy --prod`, pushing to main)
- **Destructive database operations** (DROP TABLE, TRUNCATE, DELETE without WHERE, destructive migrations)
- Creating **paid** resources (upgrading tiers, enabling paid features)
- DNS record changes
- **First-time service login** (when no email/password exists in keychain AND no active browser session — ask user for login credentials once, then self-serve everything else)
- Modifying auth/permissions on external services
- Changing SSL/TLS certificates
- Scaling infrastructure (increasing server count, upgrading instance size)
- Modifying CI/CD pipelines

## Level 4: MUST ASK (high stakes — show exact command/action)

Stop. Show the exact command or action. Explain consequences. Wait for explicit approval.

- **Any action that costs real money** (billing changes, subscription upgrades, purchasing domains)
- **Sending messages/emails to real people** (Slack, email, SMS)
- **Publishing packages** to registries (npm publish, PyPI upload)
- **Making repositories public**
- **Deleting production data** or production resources
- **Force-pushing** to shared branches
- **Transferring ownership** of resources
- **Revoking credentials** or access tokens

## Level 5: ESCALATE (cannot proceed without user)

Stop immediately. Explain the blocker. Give clear instructions for what the user needs to do.

- **2FA/MFA prompts** during browser automation — tell user what code/action is needed, wait for them to handle it in the browser, then continue
- **CAPTCHA challenges** — cannot be automated
- **Physical device confirmation** (push notification to phone, hardware key)
- **Legal agreements** or Terms of Service acceptance
- **First-time login credentials** when no email/password stored in keychain AND no active browser session — ask ONCE, store both, then self-serve forever
- **OAuth consent screens** requiring user to click "Authorize" in the browser
- **Rate limits or account locks** on external services
- **Ambiguous architectural decisions** where multiple valid approaches exist and the choice significantly impacts the project

Note: "Missing API token" is NOT an escalation. Use browser automation to generate it. Only escalate if you cannot log into the service at all.

---

## Edge Case Rules

### When in doubt: ask
If an action doesn't clearly fit a level, treat it as one level higher than you think.

### Compound actions
If a workflow spans multiple levels, the **highest level** in the chain applies to the whole workflow. Example: deploying to production (Level 3) with a database migration (Level 3) that drops a column (Level 4) → the whole workflow is Level 4.

### Repeat actions
If the user has already approved an action type in this session (e.g., "yes, deploy to prod"), you can repeat it without re-asking **for the same project and context**. A new project or significantly different context resets this.

### Error recovery
If an autonomous action fails, do NOT retry with escalated privileges or different parameters. Report the failure and let the user decide.

### Credential access
- ONLY read credentials you expect to find at known keychain paths
- NEVER scan for or enumerate credentials beyond the autopilot namespace
- NEVER log, echo, or display credential values
- ALWAYS use credentials via subshell expansion: `--token "$(keychain.sh get service key)"`
- ALWAYS unset credential variables after use when stored in shell variables
